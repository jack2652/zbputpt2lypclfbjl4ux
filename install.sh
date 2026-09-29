#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
repo_owner="jack2652"
repo_name="zbputpt2lypclfbjl4ux"
repo_raw_base="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/main"

distro=""
service_manager=""

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}严重错误: ${plain} 请以 root 权限运行此脚本 \n" && exit 1

detect_platform() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    elif [[ -f /usr/lib/os-release ]]; then
        # shellcheck disable=SC1091
        . /usr/lib/os-release
    else
        echo -e "${red}无法识别当前发行版: 未找到 os-release${plain}"
        exit 1
    fi

    case "${ID}" in
        alpine)
            distro="alpine"
            service_manager="openrc"
            ;;
        debian|ubuntu)
            distro="debian"
            local init_name=""
            init_name=$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || true)
            if command -v systemctl >/dev/null 2>&1 && \
                [[ "${init_name}" == "systemd" || -d /run/systemd/system ]]; then
                service_manager="systemd"
            elif command -v service >/dev/null 2>&1; then
                service_manager="sysvinit"
            elif command -v systemctl >/dev/null 2>&1; then
                service_manager="systemd"
            else
                echo -e "${red}Debian/Ubuntu 环境缺少 systemd 或 SysV service 命令${plain}"
                exit 1
            fi
            ;;
        *)
            echo -e "${red}当前仅支持 Alpine、Debian 和 Ubuntu${plain}"
            exit 1
            ;;
    esac

    if [[ "${service_manager}" == "openrc" ]] && ! command -v rc-service >/dev/null 2>&1; then
        echo -e "${red}当前 Alpine 环境缺少 OpenRC 命令 rc-service${plain}"
        exit 1
    fi
    if [[ "${service_manager}" == "systemd" ]] && ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${red}当前 Debian/Ubuntu 环境缺少 systemctl${plain}"
        exit 1
    fi

    echo -e "${green}检测到系统: ${ID}，服务管理器: ${service_manager}${plain}"
}

install_base() {
    echo -e "${yellow}安装系统依赖...${plain}"
    if [[ "${distro}" == "alpine" ]]; then
        if ! apk add --no-cache --update \
            ca-certificates tzdata bash curl wget tar gzip coreutils openssl \
            util-linux-misc socat procps-ng kmod; then
            echo -e "${red}安装 Alpine 依赖失败${plain}"
            exit 1
        fi
        if ! apk add --no-cache cronie; then
            echo -e "${yellow}警告：未能安装 cronie，已跳过 Xray 自动重启定时任务${plain}"
        fi
        if ! apk add --no-cache fail2ban; then
            echo -e "${yellow}警告：未能安装 fail2ban，面板核心功能仍可使用，但 Fail2ban 菜单不可用${plain}"
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update || ! apt-get install -y \
            ca-certificates tzdata bash curl wget tar gzip coreutils openssl \
            util-linux cron socat procps kmod init-system-helpers; then
            echo -e "${red}安装 Debian/Ubuntu 依赖失败${plain}"
            exit 1
        fi
        if ! apt-get install -y fail2ban; then
            echo -e "${yellow}警告：未能安装 fail2ban，面板核心功能仍可使用，但 Fail2ban 菜单不可用${plain}"
        fi
    fi

    configure_fail2ban
}

configure_fail2ban() {
    local jail_local="/etc/fail2ban/jail.local"

    [[ -f /etc/fail2ban/jail.d/alpine-ssh.conf ]] && rm -f /etc/fail2ban/jail.d/alpine-ssh.conf
    [[ -f /etc/fail2ban/jail.conf ]] || return 0

    if [[ ! -f "${jail_local}" ]]; then
        cp /etc/fail2ban/jail.conf "${jail_local}"
    fi

    for jail in ssh sshd; do
        if grep -q "^\[${jail}\]$" "${jail_local}" && \
            ! grep -A2 "^\[${jail}\]$" "${jail_local}" | grep -q "enabled = false"; then
            sed -i "/^\[${jail}\]$/a enabled = false" "${jail_local}"
        fi
    done

    if [[ -f /etc/fail2ban/fail2ban.conf ]]; then
        sed -i 's/^#allowipv6 = auto/allowipv6 = auto/' /etc/fail2ban/fail2ban.conf
    fi
}

gen_random_string() {
    local length="$1"
    local random_string
    random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "${length}" | head -n 1)
    echo "${random_string}"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo "amd64" ;;
        i?86 | x86) echo "386" ;;
        aarch64 | arm64 | armv8 | armv8*) echo "arm64" ;;
        armv7* | armv7 | arm) echo "armv7" ;;
        armv6* | armv6) echo "armv6" ;;
        armv5* | armv5) echo "armv5" ;;
        s390x) echo "s390x" ;;
        *) return 1 ;;
    esac
}

get_download_url() {
    local tag_version="$1"
    local arch="$2"
    echo "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-${arch}.tar.gz"
}

get_available_space_mb() {
    local target_path="$1"
    df -Pk "${target_path}" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}'
}

check_install_space() {
    local target_path="$1"
    local available_mb=""
    local existing_mb=0
    local required_mb=512

    available_mb=$(get_available_space_mb "${target_path}")
    if ! [[ "${available_mb}" =~ ^[0-9]+$ ]]; then
        echo -e "${red}无法检查 ${target_path} 的可用磁盘空间${plain}"
        return 1
    fi

    if [[ -d "${target_path}/x-ui" ]]; then
        existing_mb=$(du -sm "${target_path}/x-ui" 2>/dev/null | awk 'NR == 1 {print $1}')
        [[ "${existing_mb}" =~ ^[0-9]+$ ]] || existing_mb=0
    fi

    required_mb=$((required_mb + existing_mb))

    if (( available_mb < required_mb )); then
        echo -e "${red}${target_path} 可用空间不足：当前约 ${available_mb} MiB，预计至少需要 ${required_mb} MiB（含现有 x-ui 临时保留空间）${plain}"
        echo -e "${yellow}请先清理磁盘空间后再重试；安装器不会删除现有 x-ui 目录${plain}"
        return 1
    fi
}

version_at_least() {
    local actual="$1"
    local required="$2"
    local actual_major actual_minor actual_patch
    local required_major required_minor required_patch

    [[ "${actual}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    actual_major="${BASH_REMATCH[1]}"
    actual_minor="${BASH_REMATCH[2]}"
    actual_patch="${BASH_REMATCH[3]}"
    [[ "${required}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    required_major="${BASH_REMATCH[1]}"
    required_minor="${BASH_REMATCH[2]}"
    required_patch="${BASH_REMATCH[3]}"

    (( 10#${actual_major} > 10#${required_major} )) || \
        { (( 10#${actual_major} == 10#${required_major} && 10#${actual_minor} > 10#${required_minor} )); } || \
        { (( 10#${actual_major} == 10#${required_major} && 10#${actual_minor} == 10#${required_minor} && 10#${actual_patch} >= 10#${required_patch} )); }
}

install_asset() {
    local asset_name="$1"
    local target_path="$2"
    local temp_path="${target_path}.tmp.$$"

    mkdir -p "$(dirname "${target_path}")"
    rm -f "${temp_path}"
    if [[ -f "${script_dir}/${asset_name}" ]]; then
        cp "${script_dir}/${asset_name}" "${temp_path}"
    else
        curl -fL --retry 3 --proto '=https' --tlsv1.2 \
            -o "${temp_path}" "${repo_raw_base}/${asset_name}"
    fi

    if [[ $? -ne 0 || ! -s "${temp_path}" ]]; then
        rm -f "${temp_path}"
        return 1
    fi
    mv -f "${temp_path}" "${target_path}"
}

service_stop() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui stop >/dev/null 2>&1 || true
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl stop x-ui.service >/dev/null 2>&1 || true
    else
        service x-ui stop >/dev/null 2>&1 || true
    fi
}

service_enable() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-update add x-ui default
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable x-ui.service
    else
        update-rc.d x-ui defaults
    fi
}

service_start() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui start
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl start x-ui.service
    else
        service x-ui start
    fi
}

install_service_definition() {
    if [[ "${service_manager}" == "openrc" ]]; then
        install_asset "ui.rc" /etc/init.d/x-ui || return 1
        chmod +x /etc/init.d/x-ui
    elif [[ "${service_manager}" == "systemd" ]]; then
        mkdir -p /etc/systemd/system
        install_asset "ui.service" /etc/systemd/system/x-ui.service || return 1
        chmod 644 /etc/systemd/system/x-ui.service
        systemctl daemon-reload
    else
        install_asset "ui.init" /etc/init.d/x-ui || return 1
        chmod +x /etc/init.d/x-ui
    fi
}

config_after_install() {
    local existing_username
    local existing_password
    local existing_webBasePath
    local existing_port
    local server_ip

    existing_username=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'username: .+' | awk '{print $2}')
    existing_password=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'password: .+' | awk '{print $2}')
    existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    server_ip=$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || echo "服务器地址")

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "${existing_username}" == "admin" && "${existing_password}" == "admin" ]]; then
            local config_webBasePath
            local config_username
            local config_password
            local config_port

            config_webBasePath=$(gen_random_string 15)
            config_username=$(gen_random_string 10)
            config_password=$(gen_random_string 10)

            read -r -p "您是否需要自定义面板端口? (如果不需要自定义, 系统将随机生成端口) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -r -p "请输入面板自定义端口: " config_port
                if ! [[ "${config_port}" =~ ^[0-9]+$ ]] || (( config_port < 1 || config_port > 65535 )); then
                    echo -e "${red}端口无效，请输入 1-65535 之间的数字${plain}"
                    exit 1
                fi
            else
                config_port=$(shuf -i 1024-62000 -n 1)
            fi

            /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" \
                -port "${config_port}" -webBasePath "${config_webBasePath}"
            echo -e "这是全新安装, 出于安全考虑, 会生成随机登录信息:"
            echo -e "###############################################"
            echo -e "${green}用户名: ${config_username}${plain}"
            echo -e "${green}密码: ${config_password}${plain}"
            echo -e "${green}端口: ${config_port}${plain}"
            echo -e "${green}面板路径: ${config_webBasePath}${plain}"
            echo -e "${green}访问面板URL: http://${server_ip}:${config_port}/${config_webBasePath}${plain}"
            echo -e "###############################################"
        else
            local config_webBasePath
            config_webBasePath=$(gen_random_string 15)
            echo -e "${yellow}面板路径缺失或太短, 正在生成一个新的...${plain}"
            /usr/local/x-ui/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}新的面板路径: ${config_webBasePath}${plain}"
            echo -e "${green}访问面板URL: http://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
        fi
    elif [[ "${existing_username}" == "admin" && "${existing_password}" == "admin" ]]; then
        local config_username
        local config_password
        config_username=$(gen_random_string 10)
        config_password=$(gen_random_string 10)

        echo -e "${yellow}检测到默认用户名和密码, 需要安全更新...${plain}"
        /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}"
        echo -e "生成新的随机登录用户名和密码:"
        echo -e "###############################################"
        echo -e "${green}用户名: ${config_username}${plain}"
        echo -e "${green}密码: ${config_password}${plain}"
        echo -e "###############################################"
    else
        echo -e "${green}用户名, 密码和面板路径已正确设置. 退出...${plain}"
    fi

    /usr/local/x-ui/x-ui migrate
}

setup_xray_auto_restart() {
    local cron_file=""
    local cron_line=""

    echo -e "${yellow}配置 Xray 自动重启定时任务...${plain}"
    if [[ "${distro}" == "alpine" ]]; then
        if ! command -v crond >/dev/null 2>&1; then
            echo -e "${yellow}未找到 crond，跳过 Xray 自动重启定时任务${plain}"
            return 0
        fi
        cron_file="/etc/crontabs/root"
        cron_line="30 3 * * * /usr/bin/x-ui restart-xray >/dev/null 2>&1"
        mkdir -p /etc/crontabs
    else
        cron_file="/etc/cron.d/x-ui"
        cron_line="30 3 * * * root /usr/bin/x-ui restart-xray >/dev/null 2>&1"
        mkdir -p /etc/cron.d
    fi

    if ! grep -Fq "x-ui restart-xray" "${cron_file}" 2>/dev/null; then
        {
            echo "# Auto restart xray daily at 3:30 AM"
            echo "${cron_line}"
        } >> "${cron_file}"
    fi
    chmod 644 "${cron_file}"

    if [[ "${distro}" == "alpine" ]]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl enable --now cron.service >/dev/null 2>&1 || true
    else
        update-rc.d cron defaults >/dev/null 2>&1 || true
        service cron start >/dev/null 2>&1 || true
    fi

    echo -e "${green}Xray 自动重启任务配置完成${plain}"
}

install_x_ui() {
    local arch=""
    local download_url=""
    local xray_binary=""
    local tag_version=""
    local tag_version_numeric=""
    local min_version="2.4.8"
    local staging_dir=""

    cd /usr/local || exit 1

    arch=$(detect_arch) || {
        echo -e "${red}当前架构没有对应的 x-ui 发布包, 退出安装...${plain}"
        exit 1
    }

    case "${arch}" in
        armv5|armv6|armv7) xray_binary="xray-linux-arm32" ;;
        *) xray_binary="xray-linux-${arch}" ;;
    esac
    if [[ $# -eq 0 ]]; then
        tag_version=$(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
            "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" |
            grep '"tag_name":' | sed -E 's/.*"([^\"]+)".*/\1/' | head -n 1)
        if [[ -z "${tag_version}" ]]; then
            echo -e "${red}获取 x-ui 版本失败，请检查网络连接或 GitHub API 状态${plain}"
            exit 1
        fi
    else
        tag_version="$1"
    fi

    [[ "${tag_version}" == v* ]] || tag_version="v${tag_version}"
    tag_version_numeric="${tag_version#v}"
    if ! [[ "${tag_version_numeric}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
        ! version_at_least "${tag_version_numeric}" "${min_version}"; then
        echo -e "${red}请使用不低于 v${min_version} 的有效版本号${plain}"
        exit 1
    fi

    if ! check_install_space /usr/local; then
        exit 1
    fi

    download_url=$(get_download_url "${tag_version}" "${arch}")
    echo -e "${yellow}开始下载并解压 x-ui ${tag_version} (${arch})...${plain}"
    staging_dir=$(mktemp -d /usr/local/x-ui-install.XXXXXX) || {
        echo -e "${red}无法创建临时安装目录，请检查 /usr/local 权限和磁盘空间${plain}"
        exit 1
    }

    # 直接将压缩包流式传给 tar，避免同时占用压缩包和解压目录的磁盘空间。
    curl -fL --retry 3 --proto '=https' --tlsv1.2 "${download_url}" | \
        tar -xzf - -C "${staging_dir}"
    local pipeline_status=("${PIPESTATUS[@]}")
    local curl_status="${pipeline_status[0]:-1}"
    local tar_status="${pipeline_status[1]:-1}"
    if (( curl_status != 0 || tar_status != 0 )); then
        echo -e "${red}下载或解压 x-ui 安装包失败（curl=${curl_status}, tar=${tar_status}）${plain}"
        rm -rf "${staging_dir}"
        exit 1
    fi

    if [[ -d "${staging_dir}/x-ui/app" ]]; then
        cp -a "${staging_dir}/x-ui/app/." "${staging_dir}/x-ui/"
        rm -rf "${staging_dir}/x-ui/app" "${staging_dir}/x-ui/DockerEntrypoint.sh"
    fi

    if [[ "${arch}" == armv5 || "${arch}" == armv6 || "${arch}" == armv7 ]]; then
        if [[ -f "${staging_dir}/x-ui/bin/xray-linux-${arch}" ]]; then
            mv "${staging_dir}/x-ui/bin/xray-linux-${arch}" "${staging_dir}/x-ui/bin/xray-linux-arm32"
        fi
        if [[ -f "${staging_dir}/x-ui/bin/mtg-linux-${arch}" ]]; then
            mv "${staging_dir}/x-ui/bin/mtg-linux-${arch}" "${staging_dir}/x-ui/bin/mtg-linux-arm"
        fi
    fi

    if [[ ! -x "${staging_dir}/x-ui/x-ui" || ! -f "${staging_dir}/x-ui/bin/${xray_binary}" ]]; then
        echo -e "${red}安装包缺少 x-ui 主程序或 ${xray_binary}${plain}"
        rm -rf "${staging_dir}"
        exit 1
    fi

    service_stop
    if [[ -e /usr/local/x-ui ]]; then
        echo -e "${yellow}停止并替换旧版本...${plain}"
        rm -rf /usr/local/x-ui
    fi
    mv "${staging_dir}/x-ui" /usr/local/x-ui
    rm -rf "${staging_dir}"

    chmod +x /usr/local/x-ui/x-ui "/usr/local/x-ui/bin/${xray_binary}"
    install_asset "ui.sh" /usr/bin/x-ui || {
        echo -e "${red}安装 x-ui 管理脚本失败${plain}"
        exit 1
    }
    chmod +x /usr/bin/x-ui
    if ! install_service_definition; then
        echo -e "${red}安装服务定义失败${plain}"
        exit 1
    fi
    config_after_install
    export XRAY_VMESS_AEAD_FORCED="false"
    fail2ban-client -x start >/dev/null 2>&1 || true
    if ! service_enable || ! service_start; then
        echo -e "${red}注册或启动 x-ui 服务失败${plain}"
        exit 1
    fi
    setup_xray_auto_restart

    echo -e "${green}x-ui ${tag_version} 安装完成, 运行中...${plain}"
    echo -e ""
    echo -e "x-ui 子命令: start / stop / restart / restart-xray / status / settings / update / uninstall"
}

detect_platform
install_base
install_x_ui "$@"
