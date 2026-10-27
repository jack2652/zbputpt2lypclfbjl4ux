#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
repo_owner="jack2652"
repo_name="zbputpt2lypclfbjl4ux"
repo_raw_base="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/main"
distro=""
service_manager=""
service_file=""
maintenance_lock_file="/run/x-ui-xray-watchdog.lock"
maintenance_request_dir="/run/x-ui-maintenance-requests"
watchdog_paused_file="/run/x-ui-xray-watchdog.paused"
watchdog_cooldown_file="/run/x-ui-xray-watchdog.cooldown"
maintenance_lock_depth=0

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

with_maintenance_lock() {
    local lock_fd=""
    local status=0
    local previous_lock_state="${XUI_MAINTENANCE_LOCK_HELD:-0}"
    local flock_bin=""
    local process_start=""
    local request_marker=""

    if (( maintenance_lock_depth > 0 )) || [[ "${previous_lock_state}" == "1" ]]; then
        "$@"
        return $?
    fi

    flock_bin=$(command -v flock 2>/dev/null || true)
    if [[ -z "${flock_bin}" ]]; then
        LOGE "未找到 flock，无法安全执行 x-ui 维护操作"
        return 1
    fi
    mkdir -p "${maintenance_request_dir}" || {
        LOGE "无法创建维护请求目录 ${maintenance_request_dir}"
        return 1
    }
    process_start=$(process_start_time "${BASHPID}") || {
        LOGE "无法识别当前进程，维护操作已取消"
        return 1
    }
    request_marker="${maintenance_request_dir}/${BASHPID}.${process_start}"
    printf '%s\n' "${BASHPID}" > "${request_marker}" || {
        LOGE "无法登记维护请求，维护操作已取消"
        return 1
    }
    if ! exec {lock_fd}>"${maintenance_lock_file}"; then
        rm -f "${request_marker}"
        LOGE "无法打开 x-ui 维护锁 ${maintenance_lock_file}"
        return 1
    fi
    if ! "${flock_bin}" -n "${lock_fd}"; then
        LOGI "watchdog 或其他维护操作正在使用维护锁，等待其到达安全退出点..."
        if ! "${flock_bin}" -x "${lock_fd}"; then
            rm -f "${request_marker}"
            exec {lock_fd}>&-
            LOGE "获取 x-ui 维护锁失败"
            return 1
        fi
    fi
    rm -f "${request_marker}"

    maintenance_lock_depth=1
    export XUI_MAINTENANCE_LOCK_HELD=1
    "$@" || status=$?
    maintenance_lock_depth=0
    if [[ "${previous_lock_state}" == "1" ]]; then
        export XUI_MAINTENANCE_LOCK_HELD=1
    else
        unset XUI_MAINTENANCE_LOCK_HELD
    fi
    "${flock_bin}" -u "${lock_fd}" || true
    exec {lock_fd}>&-
    return "${status}"
}

process_start_time() {
    local pid="$1"
    local stat=""
    local stat_fields=()

    IFS= read -r stat < "/proc/${pid}/stat" 2>/dev/null || return 1
    stat="${stat##*) }"
    read -r -a stat_fields <<< "${stat}"
    [[ "${stat_fields[0]:-}" != "Z" ]] || return 1
    [[ "${stat_fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${stat_fields[19]}"
}

maintenance_requests_pending() {
    local request_marker=""
    local request_id=""
    local request_pid=""
    local expected_start=""
    local actual_start=""

    for request_marker in "${maintenance_request_dir}"/*; do
        [[ -f "${request_marker}" ]] || continue
        request_id="${request_marker##*/}"
        request_pid="${request_id%%.*}"
        expected_start="${request_id#*.}"
        if [[ "${request_pid}" =~ ^[1-9][0-9]*$ && "${expected_start}" =~ ^[0-9]+$ ]] && \
            kill -0 "${request_pid}" 2>/dev/null; then
            actual_start=$(process_start_time "${request_pid}" || true)
            if [[ "${actual_start}" == "${expected_start}" ]]; then
                return 0
            fi
        fi
        rm -f "${request_marker}"
    done
    return 1
}

watchdog_yield_to_maintenance() {
    if maintenance_requests_pending; then
        LOGI "检测到人工维护请求，结束本轮自动恢复并释放维护锁"
        return 0
    fi
    return 1
}

watchdog_set_cooldown() {
    local now=""
    now=$(date +%s)
    [[ "${now}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${now}" > "${watchdog_cooldown_file}"
}

# check root
[[ $EUID -ne 0 ]] && LOGE "严重错误: ${plain} 请以 root 权限运行此脚本 \n" && exit 1

# Check OS and select package/service managers
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
else
    echo "系统OS检查失败, 请联系作者!" >&2
    exit 1
fi

case "${ID}" in
alpine)
    distro="alpine"
    service_manager="openrc"
    service_file="/etc/init.d/x-ui"
    ;;
debian|ubuntu)
    distro="debian"
    init_name="$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || true)"
    if command -v systemctl >/dev/null 2>&1 && \
        [[ "${init_name}" == "systemd" || -d /run/systemd/system ]]; then
        service_manager="systemd"
        service_file="/etc/systemd/system/x-ui.service"
    elif command -v service >/dev/null 2>&1; then
        service_manager="sysvinit"
        service_file="/etc/init.d/x-ui"
    elif command -v systemctl >/dev/null 2>&1; then
        service_manager="systemd"
        service_file="/etc/systemd/system/x-ui.service"
    else
        echo -e "${red}Debian/Ubuntu 环境缺少 systemd 或 SysV service 命令${plain}"
        exit 1
    fi
    ;;
*)
    echo -e "${red}该脚本仅支持 Alpine、Debian 和 Ubuntu${plain}\n"
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
if [[ "${distro}" == "debian" ]] && ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${red}当前 Debian/Ubuntu 环境缺少 apt-get${plain}"
    exit 1
fi
if [[ "${distro}" == "alpine" ]] && ! command -v apk >/dev/null 2>&1; then
    echo -e "${red}当前 Alpine 环境缺少 apk${plain}"
    exit 1
fi

echo "您的系统类型为: ${ID}，服务管理器为: ${service_manager}"

install_package() {
    if [[ "${distro}" == "alpine" ]]; then
        apk add --no-cache "$@"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y "$@"
    fi
}

validate_domain() {
    local candidate="$1"
    [[ "${candidate}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && \
        [[ "${candidate}" == *.* ]] && [[ "${candidate}" != *..* ]]
}

service_start() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui start
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl start x-ui.service
    else
        service x-ui start
    fi
}

service_stop() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui stop
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl stop x-ui.service
    else
        service x-ui stop
    fi
}

service_pid_file="/run/x-ui.pid"
service_binary="/usr/local/x-ui/x-ui"
service_stop_timeout=15
service_start_timeout=15

service_is_xui_process() {
    local pid="$1"
    local executable=""

    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -r "/proc/${pid}/exe" ]] || return 1
    executable=$(readlink -f "/proc/${pid}/exe" 2>/dev/null) || return 1
    [[ "${executable}" == "${service_binary}" ]]
}

service_get_pid() {
    local pid=""

    if [[ "${service_manager}" == "systemd" ]]; then
        pid=$(systemctl show -p MainPID --value x-ui.service 2>/dev/null || true)
    elif [[ -r "${service_pid_file}" ]]; then
        pid=$(cat "${service_pid_file}" 2>/dev/null || true)
    fi

    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    echo "${pid}"
}

service_wait_stopped() {
    local timeout="${1:-${service_stop_timeout}}"
    local elapsed=0

    while (( elapsed < timeout )); do
        check_status
        if [[ $? != 0 ]]; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    check_status
    [[ $? != 0 ]]
}

service_wait_started() {
    local timeout="${1:-${service_start_timeout}}"
    local elapsed=0

    while (( elapsed < timeout )); do
        check_status
        if [[ $? == 0 ]]; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    check_status
    [[ $? == 0 ]]
}

service_wait_process_exit() {
    local pid="$1"
    local timeout="${2:-5}"
    local elapsed=0

    while (( elapsed < timeout )); do
        if ! service_is_xui_process "${pid}"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    ! service_is_xui_process "${pid}"
}

service_clear_pid_file() {
    local pid="$1"
    local stored_pid=""

    [[ -f "${service_pid_file}" ]] || return 0
    stored_pid=$(cat "${service_pid_file}" 2>/dev/null || true)
    if [[ "${stored_pid}" == "${pid}" ]]; then
        rm -f "${service_pid_file}"
    fi
}

service_force_stop() {
    local pid="${1:-}"

    if [[ -z "${pid}" ]]; then
        pid=$(service_get_pid) || {
            LOGE "无法读取 x-ui 主进程 PID，已拒绝强制结束"
            return 1
        }
    fi
    if ! service_is_xui_process "${pid}"; then
        LOGE "PID ${pid} 当前不是 /usr/local/x-ui/x-ui，已拒绝强制结束"
        return 1
    fi

    LOGD "常规停止未完成，向 x-ui 主进程 ${pid} 发送 TERM"
    kill -TERM "${pid}" 2>/dev/null || true
    if service_wait_process_exit "${pid}" 5; then
        service_clear_pid_file "${pid}"
        return 0
    fi

    if ! service_is_xui_process "${pid}"; then
        service_clear_pid_file "${pid}"
        return 0
    fi

    LOGD "x-ui 未响应 TERM，向 x-ui 主进程 ${pid} 发送 KILL"
    kill -KILL "${pid}" 2>/dev/null || true
    if service_wait_process_exit "${pid}" 5; then
        service_clear_pid_file "${pid}"
        return 0
    fi

    LOGE "强制结束 x-ui 失败，请检查进程 ${pid} 和系统日志"
    return 1
}

service_stop_with_fallback() {
    local pid=""
    local pid_is_xui=1

    pid=$(service_get_pid || true)
    if [[ -n "${pid}" ]] && service_is_xui_process "${pid}"; then
        pid_is_xui=0
    fi
    service_stop || true

    if [[ "${pid_is_xui}" == 0 ]]; then
        if service_wait_process_exit "${pid}" "${service_stop_timeout}"; then
            if service_wait_stopped 5; then
                service_clear_pid_file "${pid}"
                return 0
            fi

            pid=$(service_get_pid || true)
            if [[ -z "${pid}" ]] || ! service_is_xui_process "${pid}"; then
                LOGE "x-ui 主进程已退出，但服务仍报告运行且无法确认新的主进程"
                return 1
            fi
        fi
    elif service_wait_stopped; then
        return 0
    fi

    LOGD "常规停止未完成，开始执行强制停止兜底"
    if ! service_force_stop "${pid}"; then
        return 1
    fi
    if [[ "${pid_is_xui}" == 0 ]] && ! service_wait_process_exit "${pid}" 5; then
        return 1
    fi
    service_wait_stopped 5
}

service_restart() {
    service_stop_with_fallback || return 1
    service_start
}

service_status() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui status
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl --no-pager status x-ui.service
    else
        service x-ui status
    fi
}

service_enable() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-update add x-ui default
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl enable x-ui.service
    else
        update-rc.d x-ui defaults
    fi
}

service_disable() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-update del x-ui
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl disable x-ui.service
    else
        update-rc.d -f x-ui remove
    fi
}

service_daemon_reload() {
    if [[ "${service_manager}" == "systemd" ]]; then
        systemctl daemon-reload
    fi
}

service_reload() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-service x-ui reload
    elif [[ "${service_manager}" == "systemd" ]]; then
        systemctl reload x-ui.service
    else
        service x-ui reload
    fi
}

# Declare Variables
log_folder="${XUI_LOG_FOLDER:=/var/log}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "重启面板, 注意: 重启面板也会重启xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单: ${plain}" && read temp
    show_menu
}

run_installer() {
    local installer_url="${repo_raw_base}/install.sh"
    if [[ $# -gt 0 ]]; then
        bash <(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "${installer_url}") "$1"
    else
        bash <(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "${installer_url}")
    fi
}

install() {
    if with_maintenance_lock run_installer; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此功能将强制重新安装最新版本, 数据不会丢失是否继续?" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if with_maintenance_lock run_installer; then
        LOGI "更新完成, 面板已自动重启"
        before_show_menu
    fi
}

update_menu() {
    echo -e "${yellow}更新主菜单${plain}"
    confirm "此功能将更新菜单以适应最新更改." "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    if with_maintenance_lock update_menu_locked; then
        echo -e "${green}主菜单更新成功.${plain}"
        before_show_menu
    else
        echo -e "${red}主菜单更新失败.${plain}"
        return 1
    fi
}

update_menu_locked() {
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o /usr/bin/x-ui "${repo_raw_base}/ui.sh" || return 1
    chmod +x /usr/bin/x-ui

    local cron_file=""
    if [[ "${distro}" == "alpine" ]]; then
        cron_file="/etc/crontabs/root"
    else
        cron_file="/etc/cron.d/x-ui"
    fi
    if [[ -f "${cron_file}" ]]; then
        sed -i \
            -e '/x-ui watchdog-xray/ s|^\* \* \* \* \*|*/5 * * * *|' \
            -e '/x-ui watchdog-xray/ s|$(/usr/bin/x-ui watchdog-xray|$(XUI_MAINTENANCE_LOCK_HELD=1 /usr/bin/x-ui watchdog-xray|' \
            -e 's/Xray API health check every minute/Xray API health check every 5 minutes/' \
            "${cron_file}"
    fi
}

legacy_version() {
    echo "输入版本信息 (例如 2.4.8):"
    read -r tag_version

    if [[ -z "${tag_version}" || ! "${tag_version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        echo "版本信息不能为空, 退出."
        exit 1
    fi

    # 始终复用当前主分支安装器, 以便不同发行版和架构走统一逻辑。
    [[ "${tag_version}" == v* ]] || tag_version="v${tag_version}"

    echo "下载安装 x-ui 版本: ${tag_version}..."
    with_maintenance_lock run_installer "${tag_version}"
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
}

uninstall() {
    confirm "您确定要卸载面板吗?xray也会被卸载!" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    with_maintenance_lock uninstall_locked
}

uninstall_locked() {
      service_disable >/dev/null 2>&1 || true
      service_stop >/dev/null 2>&1 || true
      rm -rf /usr/local/x-ui /etc/x-ui
      if [[ "${service_manager}" == "openrc" ]]; then
          rm -f /etc/init.d/x-ui
      elif [[ "${service_manager}" == "systemd" ]]; then
          rm -f /etc/systemd/system/x-ui.service
          service_daemon_reload
      else
          update-rc.d -f x-ui remove >/dev/null 2>&1 || true
          rm -f /etc/init.d/x-ui
      fi
      if [[ "${distro}" == "alpine" ]]; then
          sed -i '/x-ui restart-xray/d' /etc/crontabs/root 2>/dev/null || true
          sed -i '/x-ui watchdog-xray/d' /etc/crontabs/root 2>/dev/null || true
          sed -i '/Auto restart xray daily at 3:30 AM/d' /etc/crontabs/root 2>/dev/null || true
          sed -i '/Xray API health check every minute/d' /etc/crontabs/root 2>/dev/null || true
          sed -i '/Xray API health check every 5 minutes/d' /etc/crontabs/root 2>/dev/null || true
      else
          rm -f /etc/cron.d/x-ui
      fi
      rm -f "${watchdog_paused_file}"
	  if [[ -e /app/bin/ ]]; then
	    pgrep -f x-ui | xargs -r kill -9
        rm /app -rf
	  fi
    echo ""
    echo -e "卸载成功.\n"
    echo "如果需要再次安装此面板, 可以使用以下命令:"
    echo -e "${green}bash <(curl -fsSL ${repo_raw_base}/install.sh)${plain}"
    echo ""
    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    local restart_after=0
    local result=0

    confirm "您确定要重置面板用户名和密码吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    read -rp "请设置登录用户名 [默认用户名系统随机生成]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "请设置登录密码 [默认密码系统随机生成]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 10)
    confirm "立即重启面板以应用新凭据吗?" "y" && restart_after=1
    if ! with_maintenance_lock reset_user_locked "${config_account}" "${config_password}" "${restart_after}"; then
        LOGE "重置凭据流程未完全成功，请检查上方错误信息"
        result=1
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

reset_user_locked() {
    local account="$1"
    local password="$2"
    local restart_after="$3"

    /usr/local/x-ui/x-ui setting -username "${account}" -password "${password}" || {
        LOGE "设置新用户名和密码失败"
        return 1
    }
    echo -e "面板登录用户名已重置为: ${green} ${account} ${plain}"
    echo -e "面板登录密码已重置为: ${green} ${password} ${plain}"
    if /usr/local/x-ui/x-ui setting -remove_secret; then
        echo -e "${yellow} 面板登录秘密令牌已禁用 ${plain}"
    else
        LOGE "新凭据已设置，但清除面板秘密令牌失败；请检查上方错误信息"
    fi
    echo -e "${green} 请使用新的登录用户名和密码访问 X-UI 面板请记住它们! ${plain}"
    if [[ "${restart_after}" == "1" ]]; then
        restart_locked
    fi
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

reset_webbasepath() {
    echo -e "${yellow}重置面板路径${plain}"

    read -rp "您确定要重置面板路径吗? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}操作已取消.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 10)
    with_maintenance_lock reset_webbasepath_locked "${config_webBasePath}" || return 1
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

reset_webbasepath_locked() {
    local web_base_path="$1"
    /usr/local/x-ui/x-ui setting -webBasePath "${web_base_path}" >/dev/null 2>&1 || return 1
    echo -e "面板路径已重置为: ${green}${web_base_path}${plain}"
    echo -e "${green}请访问新面板径.${plain}"
    restart_locked
}

reset_config() {
    local result=0

    confirm "您确定要重置所有面板设置吗?账户数据不会丢失, 用户名和密码不会改变" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if ! with_maintenance_lock reset_config_locked; then
        LOGE "配置重置流程未完全成功，请检查上方错误信息"
        result=1
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

reset_config_locked() {
    /usr/local/x-ui/x-ui setting -reset || return 1
    echo -e "所有面板设置已重置为默认值."
    restart_locked
}

check_config() {
    local info=$(/usr/local/x-ui/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "获取当前设置错误, 请检查日志"
        show_menu
        return
    fi
    LOGI "${info}"

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(/usr/local/x-ui/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local server_ip
    server_ip=$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || echo "服务器地址")

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问面板URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问面板URL: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${green}访问面板URL: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
    fi
}

set_port() {
    local restart_after=0

    echo && echo -n -e "输入端口号[1-65535]: " && read -r port
    if [[ -z "${port}" ]]; then
        LOGD "已取消"
        before_show_menu
    elif ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        LOGE "端口必须是 1-65535 之间的数字"
        before_show_menu
    else
        confirm "立即重启面板以应用新端口吗?" "y" && restart_after=1
        with_maintenance_lock set_port_locked "${port}" "${restart_after}" || return 1
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
    fi
}

set_port_locked() {
    local port="$1"
    local restart_after="$2"
    /usr/local/x-ui/x-ui setting -port "${port}" || return 1
    if [[ "${restart_after}" == "1" ]]; then
        restart_locked
    else
        echo -e "端口已设置, 请手动重启面板, 并使用新的端口 ${green}${port}${plain} 访问面板"
    fi
}

start_locked() {
    rm -f "${watchdog_paused_file}"
    rm -f "${watchdog_cooldown_file}"
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板正在运行, 无需再次启动, 如需重启请选择重启"
    else
        service_start || return 1
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            watchdog_set_cooldown || true
            LOGI "x-ui启动成功"
        else
            LOGE "面板启动失败, 可能是因为启动时间超过两秒, 请稍后查看日志信息"
            return 1
        fi
    fi
}

start() {
    local result=0
    with_maintenance_lock start_locked || result=$?
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

stop_locked() {
    local result=0

    if ! : > "${watchdog_paused_file}"; then
        LOGE "无法记录手动停止状态，已取消停止操作"
        return 1
    fi
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已停止, 无需再次停止!"
    else
        if service_stop_with_fallback; then
            LOGI "x-ui和xray已成功停止"
        else
            LOGE "面板停止失败，常规停止和强制停止均未成功"
            result=1
        fi
    fi
    return "${result}"
}

stop() {
    local result=0
    with_maintenance_lock stop_locked || result=$?
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

restart_locked() {
    local result=0

    rm -f "${watchdog_paused_file}"
    rm -f "${watchdog_cooldown_file}"
    if service_restart && service_wait_started; then
        watchdog_set_cooldown || true
        if wait_xray_process 5; then
            LOGI "x-ui和xray重启成功"
        else
            LOGE "x-ui服务已重启，但 5 秒内未发现 Xray 进程，请检查面板日志和节点配置"
        fi
    else
        LOGE "面板重启失败，停止或启动阶段未成功"
        result=1
    fi
    return "${result}"
}

restart() {
    local result=0
    with_maintenance_lock restart_locked || result=$?
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

status() {
    service_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    service_enable
    if [[ $? == 0 ]]; then
        LOGI "x-ui成功设置为开机自动启动"
    else
        LOGE "x-ui无法设置自动启动"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    service_disable
    if [[ $? == 0 ]]; then
        LOGI "x-ui自动启动已成功取消"
    else
        LOGE "x-ui无法取消自动启动"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu

}

show_banlog() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

restart_xray() {
    with_maintenance_lock restart_xray_locked || true
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray_locked() {
    if service_reload; then
        watchdog_set_cooldown || true
        LOGI "已向 x-ui 发送 Xray 重启信号，请检查服务状态确认重启结果"
    else
        LOGE "发送 Xray 重启信号失败"
        return 1
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} 开启BBR"
    echo -e "${green}\t2.${plain} 关闭BBR"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -p "请输入选项: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        enable_bbr
        bbr_menu
        ;;
    2)
        disable_bbr
        bbr_menu
        ;;
    *) 
        echo -e "${red}选项无效请选择有效数字${plain}\n"
        bbr_menu
        ;;
    esac
}

disable_bbr() {
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$current_cc" = "cubic" ] || [ "$current_cc" != "bbr" ]; then
      echo "BBR 当前未启用, 无需禁用"
    else
      echo "禁用 BBR 拥塞控制算法..."
      # 设置 TCP 拥塞控制算法为 cubic 或其他默认算法
      sysctl -w net.ipv4.tcp_congestion_control=cubic
      # 卸载 tcp_bbr 模块
      modprobe -r tcp_bbr
      # 从 sysctl 配置文件中删除 BBR 设置
      sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
	  sed -i '/net.ipv4.tcp_congestion_control= bbr/d' /etc/sysctl.conf
	  sed -i '/net.ipv4.tcp_congestion_control =bbr/d' /etc/sysctl.conf
	  sed -i '/net.ipv4.tcp_congestion_control = bbr/d' /etc/sysctl.conf
      # 重新加载 sysctl 配置
      sysctl -p
      echo "BBR 已禁用！"
    fi
}

enable_bbr() {
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$current_cc" = "bbr" ]; then
      echo "BBR 已经启用, 无需再次启用"
    else
      echo "启用 BBR 拥塞控制算法..."
      # 设置 TCP 拥塞控制算法为 BBR
      sysctl -w net.ipv4.tcp_congestion_control=bbr
      # 加载 tcp_bbr 模块
      if ! lsmod | grep -q tcp_bbr; then
          modprobe tcp_bbr
      fi
      # 确保设置在重启后生效
      echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
      # 重新加载 sysctl 配置
      sysctl -p
      echo "BBR 已启用！"
	fi
}

update_shell() {
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o /usr/bin/x-ui "${repo_raw_base}/ui.sh"
    if [[ $? != 0 ]]; then
        echo ""
        LOGE "下载脚本失败, 请检查机器是否可以连接Github"
        before_show_menu
    else
        chmod +x /usr/bin/x-ui
        LOGI "升级脚本成功, 请重新运行脚本" 
        before_show_menu
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f "${service_file}" ]]; then
        return 2
    fi
    if [[ "${service_manager}" == "openrc" ]]; then
        if rc-service x-ui status 2>/dev/null | grep -q started; then
            return 0
        fi
    elif [[ "${service_manager}" == "systemd" ]]; then
        if systemctl is-active --quiet x-ui.service; then
            return 0
        fi
    elif service x-ui status >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_enabled() {
    if [[ "${service_manager}" == "openrc" ]]; then
        rc-update show 2>/dev/null | grep -q "x-ui"
        return $?
    elif [[ "${service_manager}" == "sysvinit" ]]; then
        compgen -G "/etc/rc*.d/[SK][0-9][0-9]x-ui" >/dev/null 2>&1
        return $?
    fi
    systemctl is-enabled --quiet x-ui.service
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已安装, 请勿重复安装"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
    0)
        echo -e "面板状态: ${green}运行中...${plain}"
        show_enable_status
        ;;
    1)
        echo -e "面板状态: ${yellow}未启动${plain}"
        show_enable_status
        ;;
    2)
        echo -e "面板状态: ${red}未安装${plain}"
        ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自动启动: ${green}是${plain}"
    else
        echo -e "是否开机自动启动: ${red}否${plain}"
    fi
}

check_xray_status() {
    xray_process_ids | grep -q .
}

wait_xray_process() {
    local timeout="${1:-5}"
    local elapsed=0

    while (( elapsed < timeout )); do
        check_xray_status && return 0
        sleep 1
        ((elapsed++))
    done
    check_xray_status
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray状态: ${green}运行中...${plain}"
    else
        echo -e "xray状态: ${red}未启动${plain}"
    fi
}

xray_process_ids() {
    local proc_dir=""
    local executable=""

    for proc_dir in /proc/[0-9]*; do
        [[ -L "${proc_dir}/exe" ]] || continue
        executable=$(readlink "${proc_dir}/exe" 2>/dev/null) || continue
        case "${executable}" in
        /usr/local/x-ui/bin/xray-linux-*)
            printf '%s\n' "${proc_dir##*/}"
            ;;
        esac
    done
}

xray_binary_path() {
    local candidate=""

    for candidate in /usr/local/x-ui/bin/xray-linux-*; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

xray_api_check() {
    local api_address="${1:-${XUI_XRAY_API_ADDRESS:-127.0.0.1:62789}}"
    local xray_binary=""

    xray_binary=$(xray_binary_path) || return 2
    command -v timeout >/dev/null 2>&1 || return 2
    timeout 5 "${xray_binary}" api statsquery --server="${api_address}" >/dev/null 2>&1
}

check_xray_health() {
    local api_address="${1:-${XUI_XRAY_API_ADDRESS:-127.0.0.1:62789}}"
    local pid=""
    local process_state=""
    local pid_pattern=""
    local listener_output=""
    local result=0
    local api_result=2
    local api_status=0
    local -a pids=()

    while IFS= read -r pid; do
        [[ -n "${pid}" ]] && pids+=("${pid}")
    done < <(xray_process_ids)

    echo -e "${yellow}开始手动检测 Xray（只读，不会重启服务）${plain}"
    if [[ ${#pids[@]} -eq 0 ]]; then
        LOGE "未发现 Xray 进程"
        result=1
    else
        for pid in "${pids[@]}"; do
            process_state=$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null || echo "?")
            case "${process_state}" in
            D)
                LOGE "发现 Xray 进程 PID ${pid}，状态 D（不可中断睡眠）"
                result=1
                ;;
            Z)
                LOGE "发现 Xray 进程 PID ${pid}，状态 Z（僵尸进程）"
                result=1
                ;;
            *)
                LOGI "发现 Xray 进程 PID ${pid}，状态 ${process_state}"
                ;;
            esac
        done

        if command -v ss >/dev/null 2>&1; then
            pid_pattern=$(IFS='|'; printf '%s' "${pids[*]}")
            listener_output=$(ss -lntup 2>/dev/null | grep -E "pid=(${pid_pattern})," || true)
            if [[ -n "${listener_output}" ]]; then
                echo "Xray 监听端口："
                echo "${listener_output}"
            else
                LOGD "ss 未显示 Xray 监听端口；请结合下方 API 检测结果判断"
            fi
        else
            LOGD "系统未安装 ss，跳过监听端口检查"
        fi
    fi

    if xray_api_check "${api_address}"; then
        LOGI "Xray 本机 API ${api_address} 有响应"
        api_result=0
    else
        api_status=$?
        if [[ ${api_status} -eq 2 ]]; then
            LOGD "未找到 Xray 可执行文件或 timeout，跳过本机 API 检测"
        else
            LOGD "Xray 本机 API ${api_address} 未确认响应；API 可能未启用或地址不同"
        fi
        [[ ${result} -eq 0 ]] && result=2
    fi

    if [[ ${#pids[@]} -eq 0 ]]; then
        LOGE "检测结论：当前未发现 Xray 进程"
    elif [[ ${result} -eq 1 ]]; then
        LOGE "检测结论：发现 Xray 进程异常状态，请查看服务日志"
    elif [[ ${api_result} -eq 0 ]]; then
        LOGI "检测结论：Xray 进程存在且本机 API 可响应"
    else
        LOGD "检测结论：Xray 进程存在，但本机 API 状态未确认"
    fi
    echo "此检测不验证真实客户端连接和端到端数据传输。"

    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
    return "${result}"
}

watchdog_xray() {
    local api_address="${1:-${XUI_XRAY_API_ADDRESS:-127.0.0.1:62789}}"
    local api_status=0
    local attempt=0
    local now=""
    local last_attempt=""
    local wait_elapsed=0
    local service_started=0

    if watchdog_yield_to_maintenance; then
        return 0
    fi
    if [[ -e "${watchdog_paused_file}" ]]; then
        return 0
    fi

    if xray_api_check "${api_address}"; then
        rm -f "${watchdog_cooldown_file}"
        return 0
    else
        api_status=$?
    fi
    if watchdog_yield_to_maintenance; then
        return 0
    fi
    if [[ ${api_status} -eq 2 ]]; then
        LOGE "Xray API 检测依赖不可用，无法自动判断健康状态"
        return 2
    fi

    now=$(date +%s)
    last_attempt=$(cat "${watchdog_cooldown_file}" 2>/dev/null || true)
    if [[ "${now}" =~ ^[0-9]+$ && "${last_attempt}" =~ ^[0-9]+$ ]] && \
        (( now >= last_attempt && now - last_attempt < 60 )); then
        LOGD "Xray API 仍无响应，最近一次恢复失败不足 1 分钟，暂不重复重启"
        return 1
    fi

    LOGE "Xray API ${api_address} 无响应，先尝试重载 Xray"
    if service_reload; then
        if watchdog_yield_to_maintenance; then
            return 0
        fi
        for ((wait_elapsed = 0; wait_elapsed < 5; wait_elapsed++)); do
            if watchdog_yield_to_maintenance; then
                return 0
            fi
            sleep 1
        done
        if watchdog_yield_to_maintenance; then
            return 0
        fi
        if xray_api_check "${api_address}"; then
            rm -f "${watchdog_cooldown_file}"
            LOGI "Xray 重载后 API 已恢复"
            return 0
        elif watchdog_yield_to_maintenance; then
            return 0
        fi
    else
        LOGE "向 x-ui 发送 Xray 重载信号失败"
    fi

    if watchdog_yield_to_maintenance; then
        return 0
    fi
    LOGE "Xray 重载后 API 仍无响应，开始重启 x-ui 服务"
    if service_restart; then
        if watchdog_yield_to_maintenance; then
            return 0
        fi
        for ((wait_elapsed = 0; wait_elapsed < service_start_timeout; wait_elapsed++)); do
            if watchdog_yield_to_maintenance; then
                return 0
            fi
            if check_status; then
                service_started=1
                break
            fi
            sleep 1
        done
        if watchdog_yield_to_maintenance; then
            return 0
        fi
        if [[ ${service_started} -eq 0 ]] && check_status; then
            service_started=1
        fi
        if [[ ${service_started} -eq 0 ]]; then
            LOGE "x-ui 服务未能在超时内启动，Xray API 仍未恢复"
        else
            for ((attempt = 1; attempt <= 5; attempt++)); do
                if watchdog_yield_to_maintenance; then
                    return 0
                fi
                if xray_api_check "${api_address}"; then
                    rm -f "${watchdog_cooldown_file}"
                    LOGI "x-ui 服务重启后 Xray API 已恢复"
                    return 0
                elif watchdog_yield_to_maintenance; then
                    return 0
                fi
                if [[ ${attempt} -lt 5 ]]; then
                    for ((wait_elapsed = 0; wait_elapsed < 3; wait_elapsed++)); do
                        if watchdog_yield_to_maintenance; then
                            return 0
                        fi
                        sleep 1
                    done
                fi
            done
            LOGE "x-ui 服务重启后 Xray API 仍无响应，请检查服务日志"
        fi
    else
        if watchdog_yield_to_maintenance; then
            return 0
        fi
        LOGE "x-ui 服务重启失败，Xray API 仍未恢复"
    fi

    [[ "${now}" =~ ^[0-9]+$ ]] && printf '%s\n' "${now}" > "${watchdog_cooldown_file}"
    return 1
}

firewall_menu() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu

}

open_ports() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu

}

delete_ports() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu

}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} vuong2023 (geoip_VN.dat, geosite_VN.dat)"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -p "请输入选项: " choice

    if [[ ! -d /usr/local/x-ui/bin ]]; then
        LOGE "未找到 /usr/local/x-ui/bin，无法更新 Geo 文件"
        before_show_menu
        return 1
    fi
    cd /usr/local/x-ui/bin || return 1

    download_geo_asset() {
        local target="$1"
        local url="$2"
        local temp="${target}.tmp.$$"

        if ! curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "${temp}" "${url}" || [[ ! -s "${temp}" ]]; then
            rm -f "${temp}"
            return 1
        fi
        mv -f "${temp}" "${target}"
    }

    update_geo_files_locked() {
        local label="$1"
        local first_target="$2"
        local first_url="$3"
        local second_target="$4"
        local second_url="$5"

        service_stop
        if download_geo_asset "${first_target}" "${first_url}" && \
            download_geo_asset "${second_target}" "${second_url}"; then
            echo -e "${green}${label} 数据升级成功!${plain}"
        else
            LOGE "${label} 数据下载失败，未主动删除原有文件"
        fi
        service_start
    }

    case "$choice" in
    0)
        show_menu
        ;;
    1)
        with_maintenance_lock update_geo_files_locked "Loyalsoldier" geoip.dat \
            https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat \
            geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
        ;;
    2)
        with_maintenance_lock update_geo_files_locked "chocolate4u" geoip_IR.dat \
            https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat \
            geosite_IR.dat https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat
        ;;
    3)
        with_maintenance_lock update_geo_files_locked "vuong2023" geoip_VN.dat \
            https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geoip.dat \
            geosite_VN.dat https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geosite.dat
        ;;
    *)
        echo -e "${red}选项无效请选择一个有效的数字${plain}\n"
        update_geo
        ;;
    esac

    before_show_menu
}

install_acme() {
    # Check if acme.sh is already installed
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        LOGI "acme.sh已经安装"
        return 0
    fi

    LOGI "安装中 acme.sh..."
    cd ~ || return 1 # Ensure you can change to the home directory

    curl -fsSL --retry 3 --proto '=https' --tlsv1.2 https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "安装acme.sh失败."
        return 1
    else
        LOGI "安装acme.sh成功"
    fi

    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} 安装证书"
    echo -e "${green}\t2.${plain} 撤销证书"
    echo -e "${green}\t3.${plain} 强制更新"
    echo -e "${green}\t4.${plain} 显示配置的域名"
    echo -e "${green}\t5.${plain} 设置面板的证书路径"
    echo -e "${green}\t0.${plain} 返回主菜单"

    read -p "请输入选项: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        ssl_cert_issue
        ssl_cert_issue_main
        ;;
    2)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "未发现需要撤销的证书"
        else
            echo "域名列表:"
            echo "$domains"
            read -p "请从输入列表中的域名撤销证书: " domain
            if echo "$domains" | grep -qw "$domain"; then
                ~/.acme.sh/acme.sh --revoke -d ${domain}
                LOGI "域名证书已被吊销: $domain"
            else
                echo "输入的域名无效!"
            fi
        fi
        ssl_cert_issue_main
        ;;
    3)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "未找到需要续订的证书"
        else
            echo "域名列表:"
            echo "$domains"
            read -p "请从输入列表中的域名更新SSL证书: " domain
            if echo "$domains" | grep -qw "$domain"; then
                ~/.acme.sh/acme.sh --renew -d ${domain} --force
                LOGI "为域名强制续订证书: $domain"
            else
                echo "输入的域名无效!"
            fi
        fi
        ssl_cert_issue_main
        ;;
    4)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "未找到证书"
        else
            echo "现有域名及其路径: "
            for domain in $domains; do
                local cert_path="/root/cert/${domain}/fullchain.pem"
                local key_path="/root/cert/${domain}/privkey.pem"
                if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                    echo -e "域名: ${domain}"
                    echo -e "\t证书路径: ${cert_path}"
                    echo -e "\t私钥路径: ${key_path}"
                else
                    echo -e "域名: ${domain} - 证书或密钥丢失"
                fi
            done
        fi
        ssl_cert_issue_main
        ;;
    5)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "未找到证书"
        else
            echo "可用域名列表:"
            echo "$domains"
            read -p "请选择一个域名来设置面板路径: " domain

            if echo "$domains" | grep -qw "$domain"; then
                local webCertFile="/root/cert/${domain}/fullchain.pem"
                local webKeyFile="/root/cert/${domain}/privkey.pem"

                if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                    /usr/local/x-ui/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    echo "设置域名路径: $domain"
                    echo "  - 证书文件: $webCertFile"
                    echo "  - 私钥文件: $webKeyFile"
                    restart
                else
                    echo "未找到域名的证书或私钥: $domain."
                fi
            else
                echo "输入的域名无效"
            fi
        fi
        ssl_cert_issue_main
        ;;

    *)
        echo -e "${red}选项无效, 请选择一个有效的数字${plain}\n"
        ssl_cert_issue_main
        ;;
    esac
}

ssl_cert_issue() {
    local existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "acme.sh无法找到, 我们将安装它"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme 失败, 请检查日志"
            exit 1
        fi
    fi
    install_package socat
    if [ $? -ne 0 ]; then
        LOGE "安装socat失败"
        exit 1
    else
        LOGI "安装socat成功"
    fi

    # get the domain here, and we need to verify it
    local domain=""
    read -r -p "请输入您的域名: " domain
    if ! validate_domain "${domain}"; then
        LOGE "域名格式无效"
        return 1
    fi
    LOGD "您的域名是: ${domain}"

    # check if there already exists a certificate
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "系统已有此域名的证书。无法再次颁发。当前证书详细信息:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "您的域名现在已准备好颁发证书..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -p "请选择要使用的端口(默认为 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "您输入的${WebPort}端口无效, 将使用默认端口80"
        WebPort=80
    fi
    LOGI "将使用端口: ${WebPort} 颁发证书, 请确保此端口已开放"

    # issue the certificate
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "${domain}" --listen-v6 --standalone --httpport "${WebPort}"
    if [ $? -ne 0 ]; then
        LOGE "颁发证书失败, 请检查日志"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGE "颁发证书成功, 正在安装证书……"
    fi

    # install the certificate
    ~/.acme.sh/acme.sh --installcert -d "${domain}" \
        --key-file "/root/cert/${domain}/privkey.pem" \
        --fullchain-file "/root/cert/${domain}/fullchain.pem"

    if [ $? -ne 0 ]; then
        LOGE "安装证书失败, 退出"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书安装成功, 正在启用自动更新..."
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动续订失败, 证书详细信息:"
        ls -lah cert/*
        chmod 700 "${certPath}"
        chmod 644 "${certPath}/fullchain.pem"
        chmod 600 "${certPath}/privkey.pem"
        exit 1
    else
        LOGI "自动续订成功, 证书详细信息:"
        ls -lah cert/*
        chmod 700 "${certPath}"
        chmod 644 "${certPath}/fullchain.pem"
        chmod 600 "${certPath}/privkey.pem"
    fi

    # Prompt user to set panel paths after successful certificate installation
    read -p "您要为面板设置此证书吗? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            /usr/local/x-ui/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "配置面板域名: $domain"
            LOGI "  - 证书文件: $webCertFile"
            LOGI "  - 私钥文件: $webKeyFile"
            echo -e "${green}访问面板URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "错误: 未找到域的证书或私钥文件: $domain."
        fi
    else
        LOGI "跳过面板路径设置"
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** 使用说明 ******"
    LOGI "请按照以下步骤完成此过程:"
    LOGI "1. Cloudflare注册的邮箱地址."
    LOGI "2. Cloudflare Global API Key."
    LOGI "3. 域名."
    LOGI "4. 证书颁发后, 系统将提示您为面板设置证书(可选)."
    LOGI "5. 该脚本还支持安装后自动更新 SSL 证书."

    confirm "您是否确认该信息并希望继续? [y/n]" "y"

    if [ $? -eq 0 ]; then
        # Check for acme.sh first
        if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
            echo "acme.sh无法找到, 我们将安装它"
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "安装acme失败, 请检查日志"
                exit 1
            fi
        fi

        CF_Domain=""
        certPath="/root/cert-CF"
        if [ ! -d "$certPath" ]; then
            mkdir -p "${certPath}"
        else
            rm -rf "${certPath}"
            mkdir -p "${certPath}"
        fi

        LOGD "请设置域名:"
        read -r -p "在此输入您的域名: " CF_Domain
        if ! validate_domain "${CF_Domain}"; then
            LOGE "域名格式无效"
            return 1
        fi
        LOGD "您的域名设置为: ${CF_Domain}"

        # Set up Cloudflare API details
        CF_GlobalKey=""
        CF_AccountEmail=""
        LOGD "请设置API key:"
        read -r -s -p "输入您的Global API Key: " CF_GlobalKey
        echo

        LOGD "请设置注册的邮箱地址:"
        read -r -p "输入您的邮箱地址: " CF_AccountEmail
        LOGD "你的邮箱地址是: ${CF_AccountEmail}"

        # Set the default CA to Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [ $? -ne 0 ]; then
            LOGE "默认CA, Let's Encrypt失败, 脚本退出..."
            exit 1
        fi

        export CF_Key="${CF_GlobalKey}"
        export CF_Email="${CF_AccountEmail}"

        # Issue the certificate using Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${CF_Domain}" -d "*.${CF_Domain}" --log
        if [ $? -ne 0 ]; then
            LOGE "证书颁发失败, 脚本退出..."
            exit 1
        else
            LOGI "证书颁发成功, 正在安装..."
        fi

        # Install the certificate
        mkdir -p "${certPath}/${CF_Domain}"
        if [ $? -ne 0 ]; then
            LOGE "无法创建目录: ${certPath}/${CF_Domain}"
            exit 1
        fi

        ~/.acme.sh/acme.sh --installcert -d "${CF_Domain}" -d "*.${CF_Domain}" \
            --fullchain-file "${certPath}/${CF_Domain}/fullchain.pem" \
            --key-file "${certPath}/${CF_Domain}/privkey.pem"

        if [ $? -ne 0 ]; then
            LOGE "证书安装失败, 脚本退出..."
            exit 1
        else
            LOGI "证书安装成功, 正在打开自动更新..."
        fi

        # Enable auto-update
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "自动更新设置失败, 脚本退出..."
            exit 1
        else
            LOGI "证书安装完毕, 并开启自动续订, 具体信息如下:"
            ls -lah ${certPath}/${CF_Domain}
            chmod 700 "${certPath}/${CF_Domain}"
            chmod 644 "${certPath}/${CF_Domain}/fullchain.pem"
            chmod 600 "${certPath}/${CF_Domain}/privkey.pem"
        fi

        # Prompt user to set panel paths after successful certificate installation
        read -p "是否要为面板设置此证书? (y/n): " setPanel
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/${CF_Domain}/fullchain.pem"
            local webKeyFile="${certPath}/${CF_Domain}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                /usr/local/x-ui/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "配置面板域名: $CF_Domain"
                LOGI "  - 证书文件: $webCertFile"
                LOGI "  - 私钥文件: $webKeyFile"
                echo -e "${green}访问面板URL: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                restart
            else
                LOGE "错误: 未找到域的证书或私钥文件: $CF_Domain."
            fi
        else
            LOGI "跳过面板路径设置"
        fi
    else
        show_menu
    fi
}

run_speedtest() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

create_iplimit_jails() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

iplimit_remove_conflicts() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

iplimit_main() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

install_iplimit() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

remove_iplimit() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

SSH_port_forwarding() {
        echo -e "${red}此功能未完成, 请关注后续更新...${plain}\n"
        before_show_menu
}

show_usage() {
    echo "x-ui命令行功能: "
    echo "------------------------------------------"
    echo -e "SUBCOMMANDS:"
    echo -e "x-ui              - 主菜单"
    echo -e "x-ui start        - 启动服务"
    echo -e "x-ui stop         - 停止服务"
    echo -e "x-ui restart      - 重启服务"
    echo -e "x-ui restart-xray - 重启xray服务"
    echo -e "x-ui check-xray [api-address] - 手动检测xray状态"
    echo -e "x-ui watchdog-xray [api-address] - 检测并自动恢复xray"
    echo -e "x-ui status       - 查看服务状态"
    echo -e "x-ui settings     - 查看服务配置"
    echo -e "x-ui enable       - 设置开机启动"
    echo -e "x-ui disable      - 关闭开机启动"
    echo -e "x-ui log          - 查看日志"
    echo -e "x-ui banlog       - 查看Fail2ban日志"
    echo -e "x-ui update       - 升级"
    echo -e "x-ui custom       - 安装指定版本"
    echo -e "x-ui install      - 安装"
    echo -e "x-ui uninstall    - 卸载"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}3X-UI面板管理脚本${plain}
  ${green}0.${plain} 退出菜单
————————————————
  ${green}1.${plain} 安装
  ${green}2.${plain} 更新
  ${green}3.${plain} 更新主菜单
  ${green}4.${plain} 安装指定版本
  ${green}5.${plain} 卸载
————————————————
  ${green}6.${plain} 重置用户名密码
  ${green}7.${plain} 重置面板路径
  ${green}8.${plain} 重置配置数据(用户名密码和面板路径不变)
  ${green}9.${plain} 重置面板端口
  ${green}10.${plain} 查看面板配置
————————————————
  ${green}11.${plain} 启动服务
  ${green}12.${plain} 停止服务
  ${green}13.${plain} 重启服务
  ${green}14.${plain} 查看服务状态
  ${green}15.${plain} 查看日志
  ${green}16.${plain} 重启xray服务
————————————————
  ${green}17.${plain} 设置开机启动
  ${green}18.${plain} 关闭开机启动
————————————————
  ${green}19.${plain} ACME证书管理
  ${green}20.${plain} Cloudflare证书管理
  ${green}21.${plain} IP限制管理
  ${green}22.${plain} 防火墙管理
  ${green}23.${plain} SSH端口转发管理
————————————————
  ${green}24.${plain} BBR功能
  ${green}25.${plain} 更新Geo文件
  ${green}26.${plain} 速度测试(Ookla)
  ${green}27.${plain} 手动检测Xray状态
"
    show_status
    echo && read -p "请输入选项[0-27]: " num

    case "${num}" in
    0)
        exit 0
        ;;
    1)
        check_uninstall && install
        ;;
    2)
        check_install && update
        ;;
    3)
        check_install && update_menu
        ;;
    4)
        check_install && legacy_version
        ;;
    5)
        check_install && uninstall
        ;;
    6)
        check_install && reset_user
        ;;
    7)
        check_install && reset_webbasepath
        ;;
    8)
        check_install && reset_config
        ;;
    9)
        check_install && set_port
        ;;
    10)
        check_install && check_config
        ;;
    11)
        check_install && start
        ;;
    12)
        check_install && stop
        ;;
    13)
        check_install && restart
        ;;
    14)
        check_install && status
        ;;
    15)
        check_install && show_log
        ;;
    16)
        check_install && restart_xray
        ;;
    17)
        check_install && enable
        ;;
    18)
        check_install && disable
        ;;
    19)
        ssl_cert_issue_main
        ;;
    20)
        ssl_cert_issue_CF
        ;;
    21)
        iplimit_main
        ;;
    22)
        firewall_menu
        ;;
    23)
        SSH_port_forwarding
        ;;
    24)
        bbr_menu
        ;;
    25)
        update_geo
        ;;
    26)
        run_speedtest
        ;;
    27)
        check_install && check_xray_health
        ;;
    *)
        LOGE "请输入正确的数字 [0-27]"
        ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
    "start")
        check_install 0 && start 0
        ;;
    "stop")
        check_install 0 && stop 0
        ;;
    "restart")
        check_install 0 && restart 0
        ;;
    "status")
        check_install 0 && status 0
        ;;
    "settings")
        check_install 0 && check_config 0
        ;;
    "enable")
        check_install 0 && enable 0
        ;;
    "disable")
        check_install 0 && disable 0
        ;;
    "log")
        check_install 0 && show_log 0
        ;;
    "banlog")
        check_install 0 && show_banlog 0
        ;;
    "update")
        check_install 0 && update 0
        ;;
    "legacy")
        check_install 0 && legacy_version 0
        ;;
    "install")
        check_uninstall 0 && install 0
        ;;
    "uninstall")
        check_install 0 && uninstall 0
        ;;
    "restart-xray")
        check_install 0 && restart_xray 0
        ;;
    "check-xray")
        check_install 0 && check_xray_health "${2:-}"
        ;;
    "watchdog-xray")
        check_install 0 && with_maintenance_lock watchdog_xray "${2:-}"
        ;;
    *) show_usage ;;
    esac
else
    show_menu
fi
