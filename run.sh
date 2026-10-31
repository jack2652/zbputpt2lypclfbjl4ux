#!/usr/bin/env bash

set -o pipefail

XRAY_HOME="/usr/local/xray-standalone"
XRAY_BIN="/usr/local/xray-standalone/xray"
CONFIG_DIR="/etc/xray-standalone"
CONFIG_FILE="/etc/xray-standalone/config.json"
LOG_DIR="/var/log/xray-standalone"
MANAGER_BIN="/usr/local/bin/r-ui"
SERVICE_NAME="xray-standalone"
LOCK_FILE="/run/lock/xray-standalone.lock"
LOCK_OWNER_FILE="/run/lock/xray-standalone.lock.owner"
WATCHDOG_LOOP_LOCK_FILE="/run/lock/xray-standalone-watchdog-loop.lock"
WATCHDOG_LOOP_PID_FILE="/run/xray-standalone-watchdog-loop.pid"
WATCHDOG_PAUSED_FILE="/run/xray-standalone-watchdog.paused"
WATCHDOG_COOLDOWN_FILE="/run/xray-standalone-watchdog.cooldown"
WATCHDOG_DISABLED_FILE="/run/xray-standalone-watchdog.disabled"
WATCHDOG_DISABLED_CONFIG="/etc/xray-standalone/watchdog.disabled"
WATCHDOG_INTERVAL_CONFIG="/etc/xray-standalone/watchdog.interval"
WATCHDOG_LOG_FILE="/var/log/xray-standalone/watchdog.log"
WATCHDOG_DEFAULT_INTERVAL=40
XRAY_API_DEFAULT_PORT=62789
XRAY_API_TAG="r-ui-api"
API_CONFIG_CHANGED="n"
SCRIPT_URL="https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/run.sh"
SERVICE_MANAGER=""
DISTRO=""
REPLY=""
PROMPT_FD=0
PROMPT_ERROR=0
SCRIPT_FROM_STDIN="n"
LOCK_ACQUIRED="n"
GENERATED_TLS_CERTIFICATE_PATH=""
GENERATED_TLS_KEY_PATH=""
[[ -z "${BASH_SOURCE[0]:-}" ]] && SCRIPT_FROM_STDIN="y"

print_info() {
    printf '[INF] %s\n' "$*"
}

print_warn() {
    printf '[WRN] %s\n' "$*" >&2
}

print_error() {
    printf '[ERR] %s\n' "$*" >&2
}

require_root() {
    if [[ "$(id -u)" != "0" ]]; then
        print_error "请使用 root 权限运行"
        exit 1
    fi
}

detect_platform() {
    local os_id=""
    local init_name=""

    if [[ -r /etc/os-release ]]; then
        os_id=$(. /etc/os-release; printf '%s' "$ID")
    elif [[ -r /usr/lib/os-release ]]; then
        os_id=$(. /usr/lib/os-release; printf '%s' "$ID")
    else
        print_error "未找到 os-release，无法识别系统"
        return 1
    fi

    case "$os_id" in
        alpine)
            DISTRO="alpine"
            SERVICE_MANAGER="openrc"
            ;;
        debian|ubuntu)
            DISTRO="debian"
            init_name=$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || true)
            if command -v systemctl >/dev/null 2>&1 && \
                [[ "$init_name" == "systemd" || -d /run/systemd/system ]]; then
                SERVICE_MANAGER="systemd"
            elif command -v service >/dev/null 2>&1; then
                SERVICE_MANAGER="sysvinit"
            else
                print_error "Debian/Ubuntu 环境未找到 systemd 或 SysV service"
                return 1
            fi
            ;;
        *)
            print_error "当前支持 Alpine、Debian 和 Ubuntu"
            return 1
            ;;
    esac

    if [[ "$SERVICE_MANAGER" == "openrc" ]] && ! command -v rc-service >/dev/null 2>&1; then
        print_error "OpenRC 命令 rc-service 不存在"
        return 1
    fi
    if [[ "$SERVICE_MANAGER" == "systemd" ]] && ! command -v systemctl >/dev/null 2>&1; then
        print_error "systemctl 不存在"
        return 1
    fi
    print_info "系统：$os_id；服务管理器：$SERVICE_MANAGER"
}

install_dependencies() {
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache bash ca-certificates curl jq unzip coreutils openssl util-linux util-linux-misc cronie
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || return 1
        apt-get install -y bash ca-certificates curl jq unzip coreutils openssl util-linux init-system-helpers cron
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '64\n' ;;
        i?86|x86) printf '32\n' ;;
        aarch64|arm64) printf 'arm64-v8a\n' ;;
        armv7*|armv7l) printf 'arm32-v7a\n' ;;
        armv6*|armv6l) printf 'arm32-v6\n' ;;
        armv5*|armv5l) printf 'arm32-v5\n' ;;
        s390x) printf 's390x\n' ;;
        ppc64le) printf 'ppc64le\n' ;;
        ppc64) printf 'ppc64\n' ;;
        riscv64) printf 'riscv64\n' ;;
        loongarch64) printf 'loong64\n' ;;
        mips) printf 'mips32\n' ;;
        mipsel|mipsle) printf 'mips32le\n' ;;
        mips64) printf 'mips64\n' ;;
        mips64el|mips64le) printf 'mips64le\n' ;;
        *)
            print_error "不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

download_latest_release() {
    local arch=""
    local asset=""
    local latest_json=""
    local asset_url=""
    local digest_url=""
    local expected_sha=""
    local actual_sha=""
    local tmp_dir=""
    local staged_bin=""
    local staged_geoip=""
    local staged_geosite=""
    local version=""

    arch=$(detect_arch) || return 1
    asset="Xray-linux-$arch.zip"
    latest_json=$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest) || {
        print_error "读取 Xray 官方最新版本失败"
        return 1
    }
    version=$(jq -r '.tag_name // empty' <<< "$latest_json")
    if [[ ! "$version" =~ ^v[0-9] ]]; then
        print_error "Xray 官方 API 返回了无效版本号"
        return 1
    fi
    asset_url=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' <<< "$latest_json")
    digest_url=$(jq -r --arg asset "$asset.dgst" '.assets[] | select(.name == $asset) | .browser_download_url' <<< "$latest_json")
    if [[ -z "$asset_url" || -z "$digest_url" ]]; then
        print_error "官方版本 $version 未提供架构 $arch 的发布包或摘要"
        return 1
    fi

    tmp_dir=$(mktemp -d) || return 1
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 180 "$asset_url" -o "$tmp_dir/$asset" || \
        ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 "$digest_url" -o "$tmp_dir/release.dgst"; then
        rm -rf "$tmp_dir"
        print_error "下载 Xray 发布包失败"
        return 1
    fi
    expected_sha=$(awk -F'= *' '$1 == "SHA2-256" {print tolower($2); exit}' "$tmp_dir/release.dgst")
    actual_sha=$(sha256sum "$tmp_dir/$asset" | awk '{print tolower($1)}')
    if [[ -z "$expected_sha" || "$expected_sha" != "$actual_sha" ]]; then
        rm -rf "$tmp_dir"
        print_error "Xray 发布包 SHA-256 校验失败"
        return 1
    fi
    mkdir -p "$tmp_dir/unpacked"
    if ! unzip -oq "$tmp_dir/$asset" -d "$tmp_dir/unpacked" || [[ ! -f "$tmp_dir/unpacked/xray" ]]; then
        rm -rf "$tmp_dir"
        print_error "无法解压 Xray 发布包或找不到 xray 可执行文件"
        return 1
    fi
    chmod 0755 "$tmp_dir/unpacked/xray"
    if [[ -f "$CONFIG_FILE" ]] && ! (
        cd "$tmp_dir/unpacked" || exit 1
        ./xray run -test -config "$CONFIG_FILE"
    ); then
        rm -rf "$tmp_dir"
        print_error "当前配置未通过新版本 Xray 校验；保留已安装版本"
        return 1
    fi

    mkdir -p "$XRAY_HOME" "$CONFIG_DIR" "$LOG_DIR"
    staged_bin="$XRAY_BIN.new"
    staged_geoip="$XRAY_HOME/geoip.dat.new"
    staged_geosite="$XRAY_HOME/geosite.dat.new"
    install -m 0755 "$tmp_dir/unpacked/xray" "$staged_bin" || {
        rm -f "$staged_bin"
        rm -rf "$tmp_dir"
        return 1
    }
    if ! "$staged_bin" version >/dev/null 2>&1; then
        rm -f "$staged_bin"
        rm -rf "$tmp_dir"
        print_error "安装 Xray 二进制失败"
        return 1
    fi
    if [[ -f "$tmp_dir/unpacked/geoip.dat" ]]; then
        install -m 0644 "$tmp_dir/unpacked/geoip.dat" "$staged_geoip" || {
            rm -f "$staged_bin" "$staged_geoip" "$staged_geosite"
            rm -rf "$tmp_dir"
            return 1
        }
    fi
    if [[ -f "$tmp_dir/unpacked/geosite.dat" ]]; then
        install -m 0644 "$tmp_dir/unpacked/geosite.dat" "$staged_geosite" || {
            rm -f "$staged_bin" "$staged_geoip" "$staged_geosite"
            rm -rf "$tmp_dir"
            return 1
        }
    fi
    if [[ -f "$staged_geoip" ]] && ! mv -f "$staged_geoip" "$XRAY_HOME/geoip.dat"; then
        rm -f "$staged_bin" "$staged_geoip" "$staged_geosite"
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ -f "$staged_geosite" ]] && ! mv -f "$staged_geosite" "$XRAY_HOME/geosite.dat"; then
        rm -f "$staged_bin" "$staged_geoip" "$staged_geosite"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! mv -f "$staged_bin" "$XRAY_BIN"; then
        rm -f "$staged_bin"
        rm -rf "$tmp_dir"
        print_error "安装 Xray 二进制失败"
        return 1
    fi
    chmod 0750 "$XRAY_HOME"
    rm -rf "$tmp_dir"
    print_info "已安装 Xray $version（$arch）"
}

service_install_definition() {
    mkdir -p "$LOG_DIR"
    case "$SERVICE_MANAGER" in
        systemd)
            cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Standalone Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$XRAY_HOME
ExecStart=$XRAY_BIN run -config $CONFIG_FILE
Restart=on-failure
RestartSec=3s
TimeoutStopSec=15s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            ;;
        openrc)
            cat > "/etc/init.d/$SERVICE_NAME" <<'EOF'
#!/sbin/openrc-run

name="Standalone Xray"
description="Standalone Xray service"
command="/usr/local/xray-standalone/xray"
command_args="run -config /etc/xray-standalone/config.json"
command_background=true
pidfile="/run/xray-standalone.pid"
directory="/usr/local/xray-standalone"
output_log="/var/log/xray-standalone/service.log"
error_log="/var/log/xray-standalone/service.log"
retry="TERM/15/KILL/5"

depend() {
    need net
}
EOF
            chmod 0755 "/etc/init.d/$SERVICE_NAME"
            ;;
        sysvinit)
            cat > "/etc/init.d/$SERVICE_NAME" <<'EOF'
#!/bin/sh

### BEGIN INIT INFO
# Provides:          xray-standalone
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Standalone Xray service
### END INIT INFO

DAEMON=/usr/local/xray-standalone/xray
PIDFILE=/run/xray-standalone.pid
WORKDIR=/usr/local/xray-standalone
LOGFILE=/var/log/xray-standalone/service.log

case "$1" in
    start)
        start-stop-daemon --start --quiet --background --make-pidfile --pidfile "$PIDFILE" \
            --chdir "$WORKDIR" --exec "$DAEMON" -- run -config /etc/xray-standalone/config.json \
            >> "$LOGFILE" 2>&1
        ;;
    stop)
        start-stop-daemon --stop --retry=TERM/15/KILL/5 --pidfile "$PIDFILE" --exec "$DAEMON"
        status=$?
        rm -f "$PIDFILE"
        exit "$status"
        ;;
    restart|force-reload)
        "$0" stop
        "$0" start
        ;;
    status)
        start-stop-daemon --status --pidfile "$PIDFILE" --exec "$DAEMON"
        exit $?
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 2
        ;;
esac
EOF
            chmod 0755 "/etc/init.d/$SERVICE_NAME"
            ;;
    esac
}

service_definition_exists() {
    case "$SERVICE_MANAGER" in
        systemd) [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]] ;;
        openrc|sysvinit) [[ -x "/etc/init.d/$SERVICE_NAME" ]] ;;
        *) return 1 ;;
    esac
}

ensure_service_definition() {
    if service_definition_exists; then
        return 0
    fi
    if [[ ! -x "$XRAY_BIN" || ! -f "$CONFIG_FILE" ]]; then
        print_error "服务定义不存在，且未找到已安装的 Xray 和配置；请先运行选项 1 安装或初始化"
        return 1
    fi
    print_warn "服务定义不存在，正在根据现有 Xray 和配置重建"
    service_install_definition
}

service_manager_command() {
    (
        if [[ "$LOCK_ACQUIRED" == "y" ]]; then
            exec 9>&- 2>/dev/null
        fi
        "$@"
    )
}

service_is_enabled() {
    local link=""

    case "$SERVICE_MANAGER" in
        systemd)
            service_manager_command systemctl is-enabled --quiet "$SERVICE_NAME.service"
            ;;
        openrc)
            [[ -L "/etc/runlevels/default/$SERVICE_NAME" ]]
            ;;
        sysvinit)
            for link in /etc/rc[2345].d/S??"$SERVICE_NAME"; do
                [[ -L "$link" || -e "$link" ]] && return 0
            done
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

service_enable() {
    ensure_service_definition || return 1
    if service_is_enabled; then
        print_info "开机启动已经设置，无需重复设置"
        return 0
    fi
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl enable "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-update add "$SERVICE_NAME" default ;;
        sysvinit) service_manager_command update-rc.d "$SERVICE_NAME" defaults ;;
    esac || return 1
    print_info "开机启动设置成功"
}

service_disable() {
    if ! service_is_enabled; then
        print_info "当前未设置开机启动，无需取消"
        return 0
    fi
    if ! service_definition_exists; then
        print_error "检测到开机启动项，但服务定义不存在；请先修复服务定义"
        return 1
    fi
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl disable "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-update del "$SERVICE_NAME" default ;;
        sysvinit) service_manager_command update-rc.d -f "$SERVICE_NAME" remove ;;
    esac || return 1
    print_info "开机启动已取消"
}

service_start() {
    ensure_service_definition || return 1
    rm -f "$WATCHDOG_PAUSED_FILE"
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl start "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-service "$SERVICE_NAME" start ;;
        sysvinit) service_manager_command service "$SERVICE_NAME" start ;;
    esac
}

service_stop() {
    ensure_service_definition || return 1
    : > "$WATCHDOG_PAUSED_FILE" || return 1
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl stop "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-service "$SERVICE_NAME" stop ;;
        sysvinit) service_manager_command service "$SERVICE_NAME" stop ;;
    esac || {
        rm -f "$WATCHDOG_PAUSED_FILE"
        return 1
    }
}

service_restart() {
    ensure_service_definition || return 1
    rm -f "$WATCHDOG_PAUSED_FILE"
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl restart "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-service "$SERVICE_NAME" restart ;;
        sysvinit) service_manager_command service "$SERVICE_NAME" restart ;;
    esac
}

service_is_active() {
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl is-active --quiet "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
        sysvinit) service_manager_command service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
    esac
}

service_status() {
    ensure_service_definition || return 1
    case "$SERVICE_MANAGER" in
        systemd) service_manager_command systemctl --no-pager --full status "$SERVICE_NAME.service" ;;
        openrc) service_manager_command rc-service "$SERVICE_NAME" status ;;
        sysvinit) service_manager_command service "$SERVICE_NAME" status ;;
    esac
}

service_logs() {
    local found_logs="n"

    if ! service_definition_exists; then
        print_warn "未找到服务定义；如未完成安装，请先运行选项 1"
    fi
    case "$SERVICE_MANAGER" in
        systemd)
            journalctl --no-pager -n 100 -u "$SERVICE_NAME.service"
            if [[ -s "$LOG_DIR/error.log" ]]; then
                found_logs="y"
                printf '\nXray error.log：\n'
                tail -n 100 "$LOG_DIR/error.log"
            elif [[ -f "$LOG_DIR/error.log" ]]; then
                print_info "Xray error.log 当前为空"
            fi
            ;;
        *)
            if [[ -s "$LOG_DIR/service.log" ]]; then
                found_logs="y"
                tail -n 100 "$LOG_DIR/service.log"
            elif [[ -f "$LOG_DIR/service.log" ]]; then
                print_info "service.log 当前为空"
            fi
            if [[ -s "$LOG_DIR/error.log" ]]; then
                found_logs="y"
                printf '\nXray error.log：\n'
                tail -n 100 "$LOG_DIR/error.log"
            elif [[ -f "$LOG_DIR/error.log" ]]; then
                print_info "Xray error.log 当前为空"
            fi
            if [[ "$found_logs" == "n" && ! -f "$LOG_DIR/service.log" && ! -f "$LOG_DIR/error.log" ]]; then
                print_warn "日志文件尚未创建"
            fi
            ;;
    esac
    if [[ -s "$WATCHDOG_LOG_FILE" ]]; then
        printf '\nXray API 健康检测日志（最近 50 行）：\n'
        tail -n 50 "$WATCHDOG_LOG_FILE"
    elif [[ -f "$WATCHDOG_LOG_FILE" ]]; then
        print_info "Xray API 健康检测日志当前为空"
    fi
}

process_start_time() {
    local stat=""
    local -a fields=()

    [[ "$1" =~ ^[1-9][0-9]*$ && -r "/proc/$1/stat" ]] || return 1
    stat=$(<"/proc/$1/stat") || return 1
    stat="${stat##*) }"
    read -r -a fields <<< "$stat"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

watchdog_append_log() {
    local output="$1"
    local tmp=""
    local status=0

    [[ -n "$output" ]] || return 0
    mkdir -p "$LOG_DIR" || return 1
    tmp="$WATCHDOG_LOG_FILE.tmp.$BASHPID"
    {
        [[ -f "$WATCHDOG_LOG_FILE" ]] && tail -n 49 "$WATCHDOG_LOG_FILE"
        printf '%s\n' "$output" | sed "s/^/[$(date '+%Y-%m-%d %H:%M:%S')] /"
    } | tail -n 50 > "$tmp"
    status=$?
    if (( status == 0 )); then
        mv -f "$tmp" "$WATCHDOG_LOG_FILE" || status=$?
    fi
    rm -f "$tmp"
    return "$status"
}

xray_api_address() {
    local api_tag=""
    local api_port=""

    [[ -f "$CONFIG_FILE" ]] || return 1
    api_tag=$(jq -r '.api.tag // empty' "$CONFIG_FILE") || return 1
    [[ -n "$api_tag" ]] || return 1
    api_port=$(jq -er --arg tag "$api_tag" \
        '.inbounds[] | select(.tag == $tag and .protocol == "dokodemo-door") | .port | tostring | select(test("^[0-9]+$"))' \
        "$CONFIG_FILE" | head -n 1) || return 1
    [[ "$api_port" =~ ^[0-9]+$ ]] || return 1
    printf '127.0.0.1:%s\n' "$api_port"
}

xray_api_check() {
    local api_address=""

    api_address=$(xray_api_address) || return 1
    [[ -x "$XRAY_BIN" ]] && command -v timeout >/dev/null 2>&1 || return 1
    timeout 5 "$XRAY_BIN" api statsquery --server="$api_address" >/dev/null 2>&1
}

watchdog_check() {
    local api_address=""
    local now=""
    local last_attempt=""
    local wait_elapsed=0

    [[ -e "$WATCHDOG_PAUSED_FILE" || -e "$WATCHDOG_DISABLED_FILE" || -e "$WATCHDOG_DISABLED_CONFIG" ]] && return 0
    if ! service_is_active && ! service_is_enabled; then
        return 0
    fi
    if xray_api_check; then
        rm -f "$WATCHDOG_COOLDOWN_FILE"
        return 0
    fi

    if ! acquire_lock quiet watchdog; then
        return 0
    fi
    [[ -e "$WATCHDOG_PAUSED_FILE" || -e "$WATCHDOG_DISABLED_FILE" || -e "$WATCHDOG_DISABLED_CONFIG" ]] && return 0
    if ! service_is_active && ! service_is_enabled; then
        return 0
    fi
    if xray_api_check; then
        rm -f "$WATCHDOG_COOLDOWN_FILE"
        return 0
    fi

    api_address=$(xray_api_address 2>/dev/null || printf '127.0.0.1:unknown')
    now=$(date +%s)
    last_attempt=$(cat "$WATCHDOG_COOLDOWN_FILE" 2>/dev/null || true)
    if [[ "$now" =~ ^[0-9]+$ && "$last_attempt" =~ ^[0-9]+$ ]] && \
        (( now >= last_attempt && now - last_attempt < 60 )); then
        return 0
    fi

    print_error "Xray 本机 API $api_address 无响应，正在重启独立 Xray 服务"
    if ! service_restart; then
        print_error "Xray 服务重启失败"
        printf '%s\n' "$now" > "$WATCHDOG_COOLDOWN_FILE"
        return 1
    fi
    for ((wait_elapsed = 0; wait_elapsed < 3; wait_elapsed++)); do
        if xray_api_check; then
            rm -f "$WATCHDOG_COOLDOWN_FILE"
            print_info "Xray 服务重启后本机 API 已恢复"
            return 0
        fi
        [[ "$wait_elapsed" == "2" ]] || sleep 1
    done
    printf '%s\n' "$now" > "$WATCHDOG_COOLDOWN_FILE"
    print_error "Xray 服务已重启，但本机 API 仍无响应；60 秒内不再重复重启"
    return 1
}

watchdog_loop_cleanup() {
    local recorded_pid=""

    [[ -n "${WATCHDOG_LOOP_SLEEP_PID:-}" ]] && kill "$WATCHDOG_LOOP_SLEEP_PID" 2>/dev/null || true
    if read -r recorded_pid _ < "$WATCHDOG_LOOP_PID_FILE" 2>/dev/null && \
        [[ "$recorded_pid" == "$BASHPID" ]]; then
        rm -f "$WATCHDOG_LOOP_PID_FILE"
    fi
    exit 0
}

watchdog_loop() {
    local loop_start=""
    local output=""
    local status=0
    local interval=""

    [[ -e "$WATCHDOG_DISABLED_FILE" || -e "$WATCHDOG_DISABLED_CONFIG" ]] && return 0
    command -v flock >/dev/null 2>&1 || {
        print_error "未找到 flock，无法保证 Xray 巡检循环不会重复运行"
        return 1
    }
    command -v setsid >/dev/null 2>&1 || {
        print_error "未找到 setsid，无法为自动恢复设置独立进程组"
        return 1
    }
    mkdir -p /run/lock || return 1
    exec 8>"$WATCHDOG_LOOP_LOCK_FILE" || return 1
    flock -n 8 || return 0
    loop_start=$(process_start_time "$BASHPID") || return 1
    printf '%s %s\n' "$BASHPID" "$loop_start" > "$WATCHDOG_LOOP_PID_FILE" || return 1
    trap watchdog_loop_cleanup TERM INT HUP

    while [[ -x "$MANAGER_BIN" && -f "$CONFIG_FILE" && \
        ! -e "$WATCHDOG_DISABLED_FILE" && ! -e "$WATCHDOG_DISABLED_CONFIG" ]]; do
        output=$( (exec 8>&-; setsid "$MANAGER_BIN" watchdog) 2>&1)
        status=$?
        watchdog_append_log "$output" || true
        interval=$(watchdog_interval_read)
        sleep "$interval" &
        WATCHDOG_LOOP_SLEEP_PID=$!
        wait "$WATCHDOG_LOOP_SLEEP_PID" || true
        WATCHDOG_LOOP_SLEEP_PID=""
    done
    rm -f "$WATCHDOG_LOOP_PID_FILE"
    return "$status"
}

watchdog_interval_valid() {
    local interval="$1"

    [[ "$interval" =~ ^[1-9][0-9]*$ && ${#interval} -le 5 ]] || return 1
    (( 10#$interval <= 86400 ))
}

watchdog_interval_read() {
    local interval=""

    interval=$(cat "$WATCHDOG_INTERVAL_CONFIG" 2>/dev/null || true)
    if watchdog_interval_valid "$interval"; then
        printf '%s\n' "$interval"
    else
        printf '%s\n' "$WATCHDOG_DEFAULT_INTERVAL"
    fi
}

watchdog_interval_save() {
    local interval="$1"
    local temporary=""

    watchdog_interval_valid "$interval" || return 1
    mkdir -p "$CONFIG_DIR" || return 1
    temporary=$(mktemp "$CONFIG_DIR/.watchdog-interval.XXXXXX") || return 1
    if ! printf '%s\n' "$interval" > "$temporary" || ! chmod 0644 "$temporary" || \
        ! mv -f "$temporary" "$WATCHDOG_INTERVAL_CONFIG"; then
        rm -f "$temporary"
        return 1
    fi
}

watchdog_prompt_interval() {
    local interval=""

    read_prompt -r -p "请输入检测间隔秒数 [默认 ${WATCHDOG_DEFAULT_INTERVAL}]: " interval || return 1
    [[ -n "$interval" ]] || interval="$WATCHDOG_DEFAULT_INTERVAL"
    if ! watchdog_interval_valid "$interval"; then
        print_error "检测间隔必须是 1-86400 的正整数"
        return 1
    fi
    WATCHDOG_SELECTED_INTERVAL="$interval"
}

watchdog_loop_stop() {
    local recorded_pid=""
    local recorded_start=""
    local actual_start=""
    local attempt=0

    if ! read -r recorded_pid recorded_start < "$WATCHDOG_LOOP_PID_FILE" 2>/dev/null || \
        [[ ! "$recorded_pid" =~ ^[1-9][0-9]*$ || ! "$recorded_start" =~ ^[0-9]+$ ]]; then
        rm -f "$WATCHDOG_LOOP_PID_FILE"
        return 0
    fi
    actual_start=$(process_start_time "$recorded_pid" || true)
    if [[ "$actual_start" == "$recorded_start" ]]; then
        kill -TERM "$recorded_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 10; attempt++)); do
            actual_start=$(process_start_time "$recorded_pid" || true)
            [[ "$actual_start" != "$recorded_start" ]] && break
            sleep 0.1
        done
        if [[ "$(process_start_time "$recorded_pid" || true)" == "$recorded_start" ]]; then
            kill -KILL "$recorded_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$WATCHDOG_LOOP_PID_FILE"
}

watchdog_cron_remove() {
    if [[ -f /etc/crontabs/root ]]; then
        sed -i '/# r-ui Xray API health check loop/d' /etc/crontabs/root || return 1
        sed -i '/r-ui watchdog-loop/d' /etc/crontabs/root || return 1
    fi
    if [[ -f /etc/cron.d/r-ui-xray-watchdog ]]; then
        rm -f /etc/cron.d/r-ui-xray-watchdog || return 1
    fi
}

watchdog_is_enabled() {
    [[ ! -e "$WATCHDOG_DISABLED_CONFIG" && ! -e "$WATCHDOG_DISABLED_FILE" ]] || return 1
    if [[ "$DISTRO" == "alpine" ]]; then
        grep -Fq '/usr/local/bin/r-ui watchdog-loop' /etc/crontabs/root 2>/dev/null
    else
        grep -Fq '/usr/local/bin/r-ui watchdog-loop' /etc/cron.d/r-ui-xray-watchdog 2>/dev/null
    fi
}

watchdog_install() {
    local cron_file=""
    local cron_line=""
    local already_enabled="n"
    local requested_interval="${1:-}"
    local interval=""
    local previous_interval=""
    local interval_changed="n"

    [[ -x "$MANAGER_BIN" ]] || {
        print_error "管理命令 $MANAGER_BIN 不存在，无法启动 Xray 健康检测"
        return 1
    }
    if [[ -e "$WATCHDOG_DISABLED_CONFIG" ]]; then
        print_info "Xray 健康检测已手动关闭，保持关闭状态"
        return 0
    fi
    previous_interval=$(watchdog_interval_read)
    if [[ -n "$requested_interval" ]]; then
        watchdog_interval_valid "$requested_interval" || {
            print_error "检测间隔必须是 1-86400 的正整数"
            return 1
        }
        interval="$requested_interval"
        [[ "$previous_interval" == "$interval" ]] || interval_changed="y"
    else
        interval="$previous_interval"
    fi
    watchdog_interval_save "$interval" || {
        print_error "保存 Xray 健康检测间隔失败"
        return 1
    }
    rm -f "$WATCHDOG_DISABLED_FILE"
    if watchdog_is_enabled; then
        already_enabled="y"
    fi
    if [[ "$DISTRO" == "alpine" ]]; then
        command -v crond >/dev/null 2>&1 || {
            print_error "未找到 crond，无法设置 Xray API 健康检测"
            return 1
        }
        cron_file="/etc/crontabs/root"
        cron_line='* * * * * /usr/local/bin/r-ui watchdog-loop >/dev/null 2>&1'
        mkdir -p /etc/crontabs || return 1
    else
        cron_file="/etc/cron.d/r-ui-xray-watchdog"
        cron_line='* * * * * root /usr/local/bin/r-ui watchdog-loop >/dev/null 2>&1'
        mkdir -p /etc/cron.d || return 1
    fi
    if [[ "$already_enabled" != "y" ]]; then
        watchdog_cron_remove || return 1
        {
            printf '# r-ui Xray API health check loop\n'
            printf '%s\n' "$cron_line"
        } >> "$cron_file" || return 1
        chmod 0644 "$cron_file" || return 1
    fi

    if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
        rc-update add crond default >/dev/null 2>&1 || return 1
        rc-service crond start >/dev/null 2>&1 || rc-service crond status >/dev/null 2>&1 || return 1
    elif [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        service_manager_command systemctl enable --now cron.service >/dev/null 2>&1 || return 1
    else
        service_manager_command update-rc.d cron defaults >/dev/null 2>&1 || return 1
        service_manager_command service cron start >/dev/null 2>&1 || \
            service_manager_command service cron status >/dev/null 2>&1 || return 1
    fi
    if [[ "$already_enabled" == "y" && "$interval_changed" == "y" ]]; then
        watchdog_loop_stop
    fi
    nohup /bin/sh -c 'exec 9>&-; exec /usr/local/bin/r-ui watchdog-loop' \
        >/dev/null 2>&1 </dev/null &
    if [[ "$already_enabled" == "y" ]]; then
        if [[ "$interval_changed" == "y" ]]; then
            print_info "Xray 本机 API 健康检测间隔已更新为 ${interval} 秒"
        else
            print_info "Xray ${interval} 秒健康检测已经启用，无需重复设置"
        fi
    else
        print_info "Xray 本机 API 每 ${interval} 秒健康检测已启用，重启后会自动运行"
    fi
}

watchdog_enable() {
    detect_platform || return 1
    if ! watchdog_prompt_interval; then
        return 1
    fi
    if watchdog_is_enabled; then
        watchdog_install "$WATCHDOG_SELECTED_INTERVAL"
        return $?
    fi
    if [[ ! -x "$XRAY_BIN" ]]; then
        print_error "尚未安装 Xray；请先执行安装或初始化"
        return 1
    fi
    install_dependencies || return 1
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" || return 1
    ensure_api_config || return 1
    ensure_service_definition || return 1
    if service_is_active && { [[ "$API_CONFIG_CHANGED" == "y" ]] || ! xray_api_check; }; then
        service_restart || {
            print_error "加载本机 API 配置失败；请检查 Xray 服务日志"
            return 1
        }
    fi
    config_test || return 1
    install_manager_script || return 1
    rm -f "$WATCHDOG_DISABLED_CONFIG" "$WATCHDOG_DISABLED_FILE"
    if ! watchdog_install "$WATCHDOG_SELECTED_INTERVAL"; then
        : > "$WATCHDOG_DISABLED_CONFIG" || true
        : > "$WATCHDOG_DISABLED_FILE" || true
        watchdog_cron_remove
        watchdog_loop_stop
        print_error "${WATCHDOG_SELECTED_INTERVAL} 秒健康检测启用失败，请检查 cron 服务状态"
        return 1
    fi
}

watchdog_disable() {
    detect_platform || return 1
    if ! watchdog_is_enabled && [[ ! -e "$WATCHDOG_LOOP_PID_FILE" ]]; then
        print_info "Xray API 健康检测当前未启用，无需取消"
        return 0
    fi
    mkdir -p "$CONFIG_DIR" || return 1
    : > "$WATCHDOG_DISABLED_CONFIG" || return 1
    watchdog_cron_remove || {
        watchdog_loop_stop
        return 1
    }
    : > "$WATCHDOG_DISABLED_FILE" || true
    watchdog_loop_stop
    rm -f "$WATCHDOG_COOLDOWN_FILE"
    print_info "Xray API 健康检测已取消，重启后也不会自动运行"
}

install_manager_script() {
    local source_path=""
    source_path="$BASH_SOURCE"
    if [[ -f "$source_path" && "$source_path" != /dev/* ]]; then
        source_path=$(readlink -f "$source_path" 2>/dev/null || true)
        if [[ -n "$source_path" && -f "$source_path" ]]; then
            if [[ "$source_path" != "$MANAGER_BIN" ]]; then
                install -m 0755 "$source_path" "$MANAGER_BIN"
            fi
            return 0
        fi
    fi
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$MANAGER_BIN" || {
        print_warn "管理脚本未能保存到 $MANAGER_BIN；当前安装仍可通过重新下载脚本管理"
        return 0
    }
    chmod 0755 "$MANAGER_BIN"
}

make_default_config() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    jq -n --arg error "$LOG_DIR/error.log" --arg tag "$XRAY_API_TAG" \
        --argjson port "$XRAY_API_DEFAULT_PORT" \
        '{log:{access:"none",error:$error,loglevel:"warning"},
          api:{tag:$tag,services:["StatsService"]},
          inbounds:[{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}],
          outbounds:[{protocol:"freedom",tag:"direct"}],
          routing:{rules:[{type:"field",inboundTag:[$tag],outboundTag:"api"}]}}' \
        > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

ensure_api_config() {
    local candidate=""
    local candidate_dir=""
    local api_tag=""
    local api_port=""
    local inbound_count=0
    local inbound_protocol=""
    local api_rule=''
    local port=0

    API_CONFIG_CHANGED="n"
    [[ -f "$CONFIG_FILE" ]] || make_default_config
    api_tag=$(jq -r '.api.tag // "r-ui-api"' "$CONFIG_FILE") || return 1
    [[ -n "$api_tag" && "$api_tag" != "null" ]] || api_tag="r-ui-api"
    inbound_count=$(jq --arg tag "$api_tag" '[.inbounds[]? | select(.tag == $tag)] | length' "$CONFIG_FILE") || return 1
    if (( inbound_count > 1 )); then
        print_error "配置中存在多个 Xray API 入站标签 $api_tag；请先修正配置"
        return 1
    fi
    if (( inbound_count == 1 )); then
        inbound_protocol=$(jq -r --arg tag "$api_tag" '.inbounds[] | select(.tag == $tag) | .protocol' "$CONFIG_FILE")
        api_port=$(jq -r --arg tag "$api_tag" '.inbounds[] | select(.tag == $tag) | .port' "$CONFIG_FILE")
        if [[ "$inbound_protocol" != "dokodemo-door" || ! "$api_port" =~ ^[0-9]+$ ]] || \
            (( api_port < 1 || api_port > 65535 )); then
            print_error "Xray API 入站 $api_tag 必须是有效端口的 dokodemo-door"
            return 1
        fi
    else
        for ((port = XRAY_API_DEFAULT_PORT; port <= XRAY_API_DEFAULT_PORT + 100; port++)); do
            if ! jq -e --argjson port "$port" \
                '[.inbounds[]? | select((.port | tostring) == ($port | tostring))] | length > 0' \
                "$CONFIG_FILE" >/dev/null; then
                api_port="$port"
                break
            fi
        done
        if [[ -z "$api_port" ]]; then
            print_error "无法为 Xray 本机 API 找到空闲端口（$XRAY_API_DEFAULT_PORT-$((XRAY_API_DEFAULT_PORT + 100))）"
            return 1
        fi
    fi

    api_rule=$(jq -cn --arg tag "$api_tag" '{type:"field",inboundTag:[$tag],outboundTag:"api"}')
    candidate_dir=$(mktemp -d "$CONFIG_DIR/.api-config.XXXXXX") || return 1
    candidate="$candidate_dir/config.json"
    if ! jq --arg tag "$api_tag" --argjson port "$api_port" --argjson rule "$api_rule" '
        .inbounds = (.inbounds // [])
        | .api = ((.api // {})
            | .tag = $tag
            | .services = (((if (.services | type) == "array" then .services else [] end) + ["StatsService"]) | unique))
        | if any(.inbounds[]?; .tag == $tag) then
            .inbounds |= map(if .tag == $tag then
                .listen = "127.0.0.1"
                | .settings = (if (.settings | type) == "object" then .settings else {} end)
                | .settings.address = "127.0.0.1"
            else . end)
          else
            .inbounds += [{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}]
          end
        | .routing = ((.routing // {}) as $routing
            | $routing + {rules:([$rule] + [($routing.rules // [])[] |
                select((.outboundTag != "api") or (((.inboundTag // []) | index($tag)) == null))])})
    ' "$CONFIG_FILE" > "$candidate"; then
        rm -rf "$candidate_dir"
        print_error "启用 Xray 本机 API 配置失败"
        return 1
    fi

    if ! config_validate_file "$candidate"; then
        rm -rf "$candidate_dir"
        print_error "启用 Xray 本机 API 后配置校验失败；现有配置未修改"
        return 1
    fi
    if ! cp -p "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)" || \
        ! chmod 0600 "$candidate" || ! mv -f "$candidate" "$CONFIG_FILE"; then
        rm -rf "$candidate_dir"
        print_error "保存 Xray 本机 API 配置失败"
        return 1
    fi
    rm -rf "$candidate_dir"
    XRAY_API_TAG="$api_tag"
    API_CONFIG_CHANGED="y"
    print_info "Xray 本机 Stats API 已配置为 127.0.0.1:$api_port"
}

config_validate_file() {
    local file="$1"
    if ! jq -e . "$file" >/dev/null 2>&1; then
        print_error "JSON 格式无效"
        return 1
    fi
    if [[ ! -x "$XRAY_BIN" ]]; then
        print_error "尚未安装 Xray；请先执行 install"
        return 1
    fi
    (
        cd "$XRAY_HOME" || exit 1
        "$XRAY_BIN" run -test -format=json -config "$file"
    )
}

config_test() {
    [[ -f "$CONFIG_FILE" ]] || {
        print_error "配置文件不存在：$CONFIG_FILE"
        return 1
    }
    config_validate_file "$CONFIG_FILE"
}

prompt_value() {
    local label="$1"
    local default_value="$2"

    read_prompt -r -p "$label [$default_value]: " REPLY || return 1
    if [[ -z "$REPLY" ]]; then
        REPLY="$default_value"
    fi
}

is_valid_ipv4_address() {
    local address="$1"
    local octet=""
    local -a octets=()

    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

detect_public_ip() {
    local candidate=""

    candidate=$(curl --noproxy '*' -4 -fsS --connect-timeout 2 --max-time 4 \
        https://api.ipify.org 2>/dev/null) || candidate=""
    if is_valid_ipv4_address "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    candidate=$(curl --noproxy '*' -6 -fsS --connect-timeout 2 --max-time 4 \
        https://api64.ipify.org 2>/dev/null) || candidate=""
    if [[ "$candidate" =~ ^[0-9A-Fa-f:]+$ && "$candidate" == *:* ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

# 管道执行时 bash 从标准输入读取脚本，提示输入应改从控制终端读取。
read_prompt() {
    PROMPT_ERROR=0
    if [[ "$SCRIPT_FROM_STDIN" == "y" && "$PROMPT_FD" == "0" && ! -t 0 ]]; then
        if [[ ! -r /dev/tty ]]; then
            print_error "通过管道运行时需要可用的交互终端"
            PROMPT_ERROR=1
            return 1
        fi
        { exec {PROMPT_FD}</dev/tty; } 2>/dev/null || {
            print_error "无法打开交互终端"
            PROMPT_ERROR=1
            return 1
        }
    fi
    if [[ "$PROMPT_FD" == "0" ]]; then
        builtin read "$@" || {
            PROMPT_ERROR=1
            return 1
        }
    else
        builtin read -u "$PROMPT_FD" "$@" || {
            PROMPT_ERROR=1
            return 1
        }
    fi
}

prompt_yesno() {
    local label="$1"
    local default_value="$2"
    local answer=""

    if [[ "$default_value" == "y" ]]; then
        read_prompt -r -p "$label [Y/n]: " answer || return 1
        [[ -z "$answer" ]] && answer="y"
    else
        read_prompt -r -p "$label [y/N]: " answer || return 1
        [[ -z "$answer" ]] && answer="n"
    fi
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

url_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

acquire_lock() {
    local quiet=""
    local operation=""
    local owner_pid=""
    local owner_start=""
    local owner_operation=""
    local actual_start=""
    local owner_tmp=""

    if [[ "$1" == "quiet" ]]; then
        quiet="y"
        operation="$2"
    else
        operation="$1"
    fi

    if ! command -v flock >/dev/null 2>&1; then
        [[ "$quiet" == "y" ]] || print_error "未找到 flock，无法串行化服务操作"
        return 1
    fi
    mkdir -p /run/lock || return 1
    exec 9>"$LOCK_FILE" || return 1
    if ! flock -n 9; then
        if [[ "$operation" != "watchdog" ]] && \
            read -r owner_pid owner_start owner_operation < "$LOCK_OWNER_FILE" 2>/dev/null && \
            [[ "$owner_operation" == "watchdog" ]]; then
            actual_start=$(process_start_time "$owner_pid" 2>/dev/null || true)
            if [[ "$actual_start" == "$owner_start" ]]; then
                kill -TERM -- "-$owner_pid" 2>/dev/null || kill -TERM "$owner_pid" 2>/dev/null || true
                if ! flock -w 1 9; then
                    kill -KILL -- "-$owner_pid" 2>/dev/null || kill -KILL "$owner_pid" 2>/dev/null || true
                    flock -w 1 9 || {
                        exec 9>&-
                        print_error "已强制中止 Xray 自动恢复，但 2 秒内未能取得维护锁"
                        return 1
                    }
                fi
            else
                exec 9>&-
                [[ "$quiet" == "y" ]] || print_error "另一个独立 Xray 管理操作正在执行"
                return 1
            fi
        else
            exec 9>&-
            [[ "$quiet" == "y" ]] || print_error "另一个独立 Xray 管理操作正在执行"
            return 1
        fi
    fi
    LOCK_ACQUIRED="y"
    owner_tmp="$LOCK_OWNER_FILE.$BASHPID"
    if ! printf '%s %s %s\n' "$BASHPID" "$(process_start_time "$BASHPID")" "$operation" > "$owner_tmp" || \
        ! mv -f "$owner_tmp" "$LOCK_OWNER_FILE"; then
        rm -f "$owner_tmp"
        flock -u 9 || true
        exec 9>&-
        LOCK_ACQUIRED="n"
        print_error "无法记录维护锁持有者，操作已取消"
        return 1
    fi
}

release_lock() {
    if [[ "$LOCK_ACQUIRED" == "y" ]]; then
        local owner_pid=""
        local owner_start=""
        local owner_operation=""
        read -r owner_pid owner_start owner_operation < "$LOCK_OWNER_FILE" 2>/dev/null || true
        if [[ "$owner_pid" == "$BASHPID" ]]; then
            rm -f "$LOCK_OWNER_FILE"
        fi
        flock -u 9 2>/dev/null || true
        exec 9>&-
        LOCK_ACQUIRED="n"
    fi
}

commit_config_file() {
    local candidate="$1"
    local normalized_dir=""
    local normalized=""
    local backup=""
    local rollback_tmp=""

    normalized_dir=$(mktemp -d "$CONFIG_DIR/.validate.XXXXXX") || return 1
    normalized="$normalized_dir/config.json"
    if ! jq . "$candidate" > "$normalized" || ! config_validate_file "$normalized"; then
        rm -rf "$normalized_dir"
        print_error "配置未应用；现有配置保持不变"
        return 1
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        backup="$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)"
        cp -p "$CONFIG_FILE" "$backup" || {
            rm -rf "$normalized_dir"
            print_error "配置备份失败，未替换现有配置"
            return 1
        }
    fi
    chmod 0600 "$normalized"
    mv -f "$normalized" "$CONFIG_FILE" || {
        rm -rf "$normalized_dir"
        return 1
    }
    rmdir "$normalized_dir"
    print_info "配置已写入 $CONFIG_FILE"
    if service_is_active; then
        if prompt_yesno "配置已更新，立即重启服务吗？" "y"; then
            if ! service_restart; then
                print_error "新配置启动失败，正在恢复上一份配置"
                rollback_tmp=$(mktemp "$CONFIG_DIR/.rollback.XXXXXX") || return 1
                if [[ -n "$backup" ]] && cp -p "$backup" "$rollback_tmp" && \
                    mv -f "$rollback_tmp" "$CONFIG_FILE" && service_restart; then
                    print_warn "已恢复上一份配置并重新启动服务"
                else
                    rm -f "$rollback_tmp"
                    print_error "恢复配置或重新启动服务失败，请检查日志"
                fi
                return 1
            fi
            print_info "Xray 服务已重启"
        else
            if [[ "$PROMPT_ERROR" == "1" ]]; then
                print_warn "配置已保存，但无法读取确认输入；服务尚未重启"
                return 1
            fi
            print_info "配置已保存，服务重启后生效"
        fi
    fi
}

choose_protocol() {
    printf '选择入站协议：\n'
    printf '  1. VLESS\n  2. VMess\n  3. Trojan\n  4. Shadowsocks\n  5. SOCKS\n  6. HTTP\n  7. Dokodemo-door 端口转发\n'
    read_prompt -r -p "请输入选项 [1-7]: " REPLY || return 1
    case "$REPLY" in
        1) PROTOCOL="vless" ;;
        2) PROTOCOL="vmess" ;;
        3) PROTOCOL="trojan" ;;
        4) PROTOCOL="shadowsocks" ;;
        5) PROTOCOL="socks" ;;
        6) PROTOCOL="http" ;;
        7) PROTOCOL="dokodemo-door" ;;
        *) print_error "无效的协议选项"; return 1 ;;
    esac
    case "$PROTOCOL" in
        vmess|trojan|shadowsocks)
            print_warn "Xray 当前版本将 $PROTOCOL 标记为旧协议；新配置优先考虑 VLESS"
            ;;
    esac
}

choose_security() {
    case "$PROTOCOL" in
        vless)
            printf '选择传输层安全：\n  1. Reality\n  2. TLS\n  3. 不启用\n'
            read_prompt -r -p "请输入选项 [1-3]: " REPLY || return 1
            case "$REPLY" in
                1) SECURITY="reality" ;;
                2) SECURITY="tls" ;;
                3) SECURITY="none" ;;
                *) print_error "无效的安全模式"; return 1 ;;
            esac
            ;;
        vmess|http)
            printf '选择传输层安全：\n  1. TLS\n  2. 不启用\n'
            read_prompt -r -p "请输入选项 [1-2]: " REPLY || return 1
            case "$REPLY" in
                1) SECURITY="tls" ;;
                2) SECURITY="none" ;;
                *) print_error "无效的安全模式"; return 1 ;;
            esac
            ;;
        trojan)
            SECURITY="tls"
            print_info "Trojan 入站使用 TLS"
            ;;
        *)
            SECURITY="none"
            ;;
    esac
}

choose_transport() {
    if [[ "$PROTOCOL" == "socks" || "$PROTOCOL" == "http" || "$PROTOCOL" == "dokodemo-door" ]]; then
        NETWORK="tcp"
        return 0
    fi
    if [[ "$SECURITY" == "reality" ]]; then
        printf '选择 Reality 传输：\n  1. TCP\n  2. gRPC\n  3. XHTTP\n'
        read_prompt -r -p "请输入选项 [1-3]: " REPLY || return 1
        case "$REPLY" in
            1) NETWORK="tcp" ;;
            2) NETWORK="grpc" ;;
            3) NETWORK="xhttp" ;;
            *) print_error "无效的传输选项"; return 1 ;;
        esac
        [[ "$NETWORK" == "grpc" ]] && print_warn "gRPC 在当前 Xray 版本中已标记为旧传输；新配置可选 XHTTP"
        return 0
    fi

    printf '选择传输方式：\n  1. TCP\n  2. WebSocket\n  3. gRPC\n  4. HTTPUpgrade\n  5. XHTTP\n'
    read_prompt -r -p "请输入选项 [1-5]: " REPLY || return 1
    case "$REPLY" in
        1) NETWORK="tcp" ;;
        2) NETWORK="ws" ;;
        3) NETWORK="grpc" ;;
        4) NETWORK="httpupgrade" ;;
        5) NETWORK="xhttp" ;;
        *) print_error "无效的传输选项"; return 1 ;;
    esac
    if [[ "$NETWORK" == "grpc" || "$NETWORK" == "ws" ]]; then
        print_warn "$NETWORK 在当前 Xray 版本中已标记为旧传输；新配置可选 XHTTP"
    fi
}

choose_credentials() {
    local counter=1
    local email=""
    local credential=""
    local username=""
    local flow="$CLIENT_FLOW"

    CLIENTS_JSON='[]'
    while true; do
        prompt_value "用户备注" "user-$counter" || return 1
        email="$REPLY"
        case "$PROTOCOL" in
            vless|vmess)
                while true; do
                    read_prompt -r -p "用户 UUID（留空自动生成）: " credential || return 1
                    if [[ -z "$credential" ]]; then
                        credential=$("$XRAY_BIN" uuid 2>/dev/null | tr -d '\r\n')
                        if [[ ! "$credential" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                            print_error "Xray 未能生成有效 UUID"
                            return 1
                        fi
                    else
                        credential=$(printf '%s' "$credential" | tr '[:upper:]' '[:lower:]')
                    fi
                    if [[ ! "$credential" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                        print_error "UUID 格式无效，应为 8-4-4-4-12 位十六进制字符"
                        continue
                    fi
                    if jq -e --arg id "$credential" \
                        'any(.[]; ((.id // "") | ascii_downcase) == ($id | ascii_downcase))' \
                        <<< "$CLIENTS_JSON" >/dev/null; then
                        print_error "该 UUID 已用于当前入站的其他用户"
                        continue
                    fi
                    break
                done
                if [[ "$PROTOCOL" == "vless" ]]; then
                    CLIENTS_JSON=$(jq --arg id "$credential" --arg email "$email" --arg flow "$flow" \
                        '. + [({id:$id,email:$email} + (if $flow == "" then {} else {flow:$flow} end))]' <<< "$CLIENTS_JSON")
                else
                    CLIENTS_JSON=$(jq --arg id "$credential" --arg email "$email" \
                        '. + [{id:$id,email:$email,alterId:0}]' <<< "$CLIENTS_JSON")
                fi
                printf '用户 %s UUID：%s\n' "$email" "$credential"
                ;;
            trojan)
                credential=$(openssl rand -hex 16) || return 1
                CLIENTS_JSON=$(jq --arg password "$credential" --arg email "$email" \
                    '. + [{password:$password,email:$email}]' <<< "$CLIENTS_JSON")
                printf '用户 %s 密码：%s\n' "$email" "$credential"
                ;;
            socks|http)
                prompt_value "登录用户名" "user-$counter" || return 1
                username="$REPLY"
                credential=$(openssl rand -hex 16) || return 1
                CLIENTS_JSON=$(jq --arg user "$username" --arg pass "$credential" \
                    '. + [{user:$user,pass:$pass}]' <<< "$CLIENTS_JSON")
                printf '用户 %s 密码：%s\n' "$username" "$credential"
                ;;
        esac
        if ! prompt_yesno "继续添加用户吗？" "n"; then
            [[ "$PROMPT_ERROR" == "1" ]] && return 1
            break
        fi
        counter=$((counter + 1))
    done
}

build_transport_json() {
    local path=""
    local host=""
    local service_name=""
    local xhttp_mode=""

    TRANSPORT_JSON=$(jq -n --arg network "$NETWORK" '{network:$network}')
    case "$NETWORK" in
        tcp)
            ;;
        ws|httpupgrade)
            if [[ "$NETWORK" == "ws" ]]; then
                prompt_value "WebSocket 路径" "/ws" || return 1
            else
                prompt_value "HTTPUpgrade 路径" "/upgrade" || return 1
            fi
            path="$REPLY"
            prompt_value "传输 Host（可留空）" "" || return 1
            host="$REPLY"
            if [[ "$NETWORK" == "ws" ]]; then
                TRANSPORT_JSON=$(jq -n --arg path "$path" --arg host "$host" \
                    '{network:"ws",wsSettings:({path:$path} + (if $host == "" then {} else {headers:{Host:$host}} end))}')
            else
                TRANSPORT_JSON=$(jq -n --arg path "$path" --arg host "$host" \
                    '{network:"httpupgrade",httpupgradeSettings:({path:$path} + (if $host == "" then {} else {host:$host} end))}')
            fi
            ;;
        grpc)
            prompt_value "gRPC serviceName" "grpc" || return 1
            service_name="$REPLY"
            if prompt_yesno "启用 gRPC multiMode 吗？" "n"; then
                TRANSPORT_JSON=$(jq -n --arg name "$service_name" \
                    '{network:"grpc",grpcSettings:{serviceName:$name,multiMode:true}}')
            else
                [[ "$PROMPT_ERROR" == "1" ]] && return 1
                TRANSPORT_JSON=$(jq -n --arg name "$service_name" \
                    '{network:"grpc",grpcSettings:{serviceName:$name}}')
            fi
            ;;
        xhttp)
            prompt_value "XHTTP 路径" "/xhttp" || return 1
            path="$REPLY"
            prompt_value "XHTTP Host（可留空）" "" || return 1
            host="$REPLY"
            printf 'XHTTP 模式：\n  1. auto\n  2. packet-up\n  3. stream-up\n  4. stream-one\n'
            read_prompt -r -p "请输入选项 [1-4]: " REPLY || return 1
            case "$REPLY" in
                1) xhttp_mode="auto" ;;
                2) xhttp_mode="packet-up" ;;
                3) xhttp_mode="stream-up" ;;
                4) xhttp_mode="stream-one" ;;
                *) print_error "无效的 XHTTP 模式"; return 1 ;;
            esac
            TRANSPORT_JSON=$(jq -n --arg path "$path" --arg host "$host" --arg mode "$xhttp_mode" \
                '{network:"xhttp",xhttpSettings:({path:$path,mode:$mode,xPaddingBytes:"100-1000"} + (if $host == "" then {} else {host:$host} end))}')
            ;;
    esac
}

read_pem_contents() {
    local label="$1"
    local hide_input="$2"
    local pem_type="$3"
    local line=""
    local marker_line=""
    local contents=""
    local begin_marker=""
    local end_marker=""
    local paste_begin_marker=$'\e[200~'
    local paste_end_marker=$'\e[201~'

    if [[ "$hide_input" == "y" && ! -t "$PROMPT_FD" ]]; then
        print_error "手动输入私钥需要交互终端；请使用文件路径方式"
        return 1
    fi
    case "$pem_type" in
        certificate)
            begin_marker="-----BEGIN CERTIFICATE-----"
            end_marker="-----END CERTIFICATE-----"
            ;;
        private-key)
            ;;
        *)
            print_error "未知的 PEM 内容类型"
            return 1
            ;;
    esac
    printf '%s\n粘贴 PEM 内容，读到对应的 END 标记后自动结束。\n' "$label" >&2
    while true; do
        if [[ "$hide_input" == "y" ]]; then
            read_prompt -r -s line || {
                printf '\n' >&2
                print_error "读取私钥时未遇到匹配的 END 标记"
                return 1
            }
        else
            read_prompt -r line || {
                print_error "读取证书时未遇到 END CERTIFICATE 标记"
                return 1
            }
        fi
        line="${line#"$paste_begin_marker"}"
        line="${line%"$paste_end_marker"}"
        line="${line%$'\r'}"
        marker_line="${line#$'\xEF\xBB\xBF'}"
        marker_line="${marker_line#"${marker_line%%[![:space:]]*}"}"
        marker_line="${marker_line%"${marker_line##*[![:space:]]}"}"
        if [[ -z "$contents" && -z "$marker_line" ]]; then
            continue
        fi
        if [[ "$pem_type" == "private-key" && -z "$begin_marker" ]]; then
            case "$marker_line" in
                "-----BEGIN "*"PRIVATE KEY-----")
                    begin_marker="$marker_line"
                    end_marker="${marker_line/BEGIN/END}"
                    line="$marker_line"
                    ;;
                "-----BEGIN CERTIFICATE-----")
                    print_error "TLS KEY 输入收到了证书标记；请粘贴私钥 PEM（BEGIN ... PRIVATE KEY）"
                    return 1
                    ;;
                *)
                    print_error "未找到有效的私钥 PEM 首行；请从 -----BEGIN ... PRIVATE KEY----- 开始粘贴"
                    return 1
                    ;;
            esac
        elif [[ "$marker_line" == "$end_marker" ]]; then
            line="$marker_line"
            contents+="$line"$'\n'
            [[ "$hide_input" == "y" ]] && printf '\n' >&2
            break
        elif [[ "$marker_line" == "-----END "* ]]; then
            [[ "$hide_input" == "y" ]] && printf '\n' >&2
            print_error "PEM END 标记与 BEGIN 标记不匹配"
            return 1
        elif [[ -z "$contents" && "$marker_line" != "$begin_marker" ]]; then
            print_error "PEM 内容必须以有效的 BEGIN 标记开始"
            return 1
        elif [[ -z "$contents" ]]; then
            line="$marker_line"
        fi
        contents+="$line"$'\n'
    done
    if [[ -z "$contents" ]]; then
        print_error "PEM 内容不能为空"
        return 1
    fi
    REPLY="$contents"
}

validate_tls_pair() {
    local certificate="$1"
    local certificate_key="$2"
    local certificate_public_key=""
    local private_public_key=""

    if ! openssl x509 -in "$certificate" -noout >/dev/null 2>&1; then
        print_error "PEM 证书无法解析"
        return 1
    fi
    if ! openssl pkey -in "$certificate_key" -passin pass: -noout >/dev/null 2>&1; then
        print_error "PEM 私钥无法解析；请提供未加密的 PEM 私钥"
        return 1
    fi
    certificate_public_key=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    private_public_key=$(openssl pkey -in "$certificate_key" -passin pass: -pubout -outform DER 2>/dev/null | \
        sha256sum | awk '{print $1}') || return 1
    if [[ -z "$certificate_public_key" || "$certificate_public_key" != "$private_public_key" ]]; then
        print_error "证书与私钥不匹配"
        return 1
    fi
}

save_tls_contents() {
    local certificate_pem="$1"
    local private_key_pem="$2"
    local certificate_dir="$CONFIG_DIR/certs"
    local certificate_file=""
    local private_key_file=""

    mkdir -p "$certificate_dir" && chmod 0700 "$certificate_dir" || {
        print_error "无法创建权限受限的 TLS 证书目录"
        return 1
    }
    certificate_file=$(mktemp "$certificate_dir/certificate.XXXXXX") || return 1
    private_key_file=$(mktemp "$certificate_dir/private-key.XXXXXX") || {
        rm -f "$certificate_file"
        return 1
    }
    if ! printf '%s' "$certificate_pem" > "$certificate_file" || \
        ! printf '%s' "$private_key_pem" > "$private_key_file"; then
        rm -f "$certificate_file" "$private_key_file"
        print_error "保存 TLS PEM 文件失败"
        return 1
    fi
    if ! chmod 0644 "$certificate_file" || ! chmod 0600 "$private_key_file" || \
        ! validate_tls_pair "$certificate_file" "$private_key_file"; then
        rm -f "$certificate_file" "$private_key_file"
        return 1
    fi
    GENERATED_TLS_CERTIFICATE_PATH="$certificate_file"
    GENERATED_TLS_KEY_PATH="$private_key_file"
}

cleanup_unreferenced_tls_files() {
    local file=""
    local config_path=""
    local referenced="n"

    for file in "$GENERATED_TLS_CERTIFICATE_PATH" "$GENERATED_TLS_KEY_PATH" \
        "$CONFIG_DIR"/certs/certificate.* "$CONFIG_DIR"/certs/private-key.*; do
        [[ -n "$file" && -f "$file" ]] || continue
        referenced="n"
        for config_path in "$CONFIG_FILE" "$CONFIG_FILE".backup.*; do
            [[ -f "$config_path" ]] || continue
            if jq -e --arg target "$file" 'any(.. | strings; . == $target)' \
                "$config_path" >/dev/null 2>&1; then
                referenced="y"
                break
            fi
        done
        if [[ "$referenced" == "y" ]]; then
            continue
        fi
        rm -f "$file"
    done
    GENERATED_TLS_CERTIFICATE_PATH=""
    GENERATED_TLS_KEY_PATH=""
}

build_inbound() {
    local default_port="443"
    local port=""
    local listen=""
    local tag=""
    local server_name=""
    local certificate=""
    local certificate_key=""
    local certificate_pem=""
    local private_key_pem=""
    local tls_input_mode=""
    local reality_dest=""
    local reality_private=""
    local reality_public=""
    local reality_output=""
    local short_id=""
    local flow_choice=""
    local settings=""
    local stream="{}"
    local inbound=""
    local method=""
    local password=""
    local client_address=""
    local alpn_json='["h2","http/1.1"]'
    local forward_address=""
    local forward_port=""
    local forward_network=""

    choose_protocol || return 1
    if [[ "$PROTOCOL" == "shadowsocks" ]]; then
        SECURITY="none"
        NETWORK="tcp,udp"
    else
        choose_security || return 1
        choose_transport || return 1
    fi

    case "$PROTOCOL" in
        shadowsocks) default_port="8388" ;;
        socks) default_port="1080" ;;
        http) default_port="8080" ;;
        dokodemo-door) default_port="12345" ;;
    esac
    prompt_value "监听端口" "$default_port" || return 1
    port="$REPLY"
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then
        print_error "端口必须是 1 到 65535 之间的整数"
        return 1
    fi
    port=$((10#$port))
    if (( port < 1 || port > 65535 )); then
        print_error "端口必须是 1 到 65535 之间的整数"
        return 1
    fi
    if jq -e --argjson port "$port" 'any(.inbounds[]?; .port == $port)' "$CONFIG_FILE" >/dev/null; then
        print_error "该端口已在独立 Xray 配置中使用"
        return 1
    fi
    prompt_value "监听地址" "0.0.0.0" || return 1
    listen="$REPLY"
    prompt_value "入站标签" "$PROTOCOL-$port" || return 1
    tag="$REPLY"

    CLIENT_FLOW=""
    if [[ "$PROTOCOL" == "vless" && "$NETWORK" == "tcp" && "$SECURITY" != "none" ]]; then
        printf 'VLESS flow：\n  1. xtls-rprx-vision\n  2. 不启用\n'
        read_prompt -r -p "请输入选项 [1-2]: " flow_choice || return 1
        case "$flow_choice" in
            1) CLIENT_FLOW="xtls-rprx-vision" ;;
            2) CLIENT_FLOW="" ;;
            *) print_error "无效的 flow 选项"; return 1 ;;
        esac
    fi

    if [[ "$PROTOCOL" == "dokodemo-door" ]]; then
        prompt_value "转发目标地址" "127.0.0.1" || return 1
        forward_address="$REPLY"
        prompt_value "转发目标端口" "443" || return 1
        forward_port="$REPLY"
        if [[ ! "$forward_port" =~ ^[0-9]{1,5}$ ]]; then
            print_error "目标端口必须是 1 到 65535 之间的整数"
            return 1
        fi
        forward_port=$((10#$forward_port))
        if (( forward_port < 1 || forward_port > 65535 )); then
            print_error "目标端口必须是 1 到 65535 之间的整数"
            return 1
        fi
        printf '转发网络：\n  1. TCP\n  2. UDP\n  3. TCP 和 UDP\n'
        read_prompt -r -p "请输入选项 [1-3]: " REPLY || return 1
        case "$REPLY" in
            1) forward_network="tcp" ;;
            2) forward_network="udp" ;;
            3) forward_network="tcp,udp" ;;
            *) print_error "无效的网络选项"; return 1 ;;
        esac
        settings=$(jq -n --arg address "$forward_address" --argjson port "$forward_port" \
            --arg network "$forward_network" \
            '{address:$address,port:$port,network:$network,followRedirect:false}')
        CLIENTS_JSON='[]'
    elif [[ "$PROTOCOL" == "shadowsocks" ]]; then
        printf 'Shadowsocks 加密方式：\n  1. chacha20-poly1305\n  2. aes-128-gcm\n  3. aes-256-gcm\n'
        read_prompt -r -p "请输入选项 [1-3]: " REPLY || return 1
        case "$REPLY" in
            1) method="chacha20-poly1305" ;;
            2) method="aes-128-gcm" ;;
            3) method="aes-256-gcm" ;;
            *) print_error "无效的加密方式"; return 1 ;;
        esac
        prompt_value "Shadowsocks 密码（留空自动生成）" "" || return 1
        password="$REPLY"
        [[ -z "$password" ]] && password=$(openssl rand -hex 24)
        CLIENTS_JSON='[]'
        settings=$(jq -n --arg method "$method" --arg password "$password" \
            '{method:$method,password:$password,network:"tcp,udp"}')
    else
        if [[ "$SECURITY" == "tls" ]]; then
            printf 'TLS 证书输入方式：\n  1. PEM 证书链和 KEY 文件路径\n  2. 手动粘贴 PEM 证书链和 KEY 内容\n'
            read_prompt -r -p "请输入选项 [1-2]: " tls_input_mode || return 1
            case "$tls_input_mode" in
                1)
                    prompt_value "TLS PEM 证书链文件路径" "" || return 1
                    certificate="$REPLY"
                    prompt_value "TLS KEY 私钥文件路径" "" || return 1
                    certificate_key="$REPLY"
                    if [[ ! -r "$certificate" || ! -r "$certificate_key" ]]; then
                        print_error "TLS PEM 证书或 KEY 私钥不可读；请检查路径和权限"
                        return 1
                    fi
                    certificate=$(readlink -f -- "$certificate") || return 1
                    certificate_key=$(readlink -f -- "$certificate_key") || return 1
                    validate_tls_pair "$certificate" "$certificate_key" || return 1
                    ;;
                2)
                    read_pem_contents "粘贴一段 TLS PEM 证书" "n" certificate || return 1
                    certificate_pem="$REPLY"
                    read_pem_contents "粘贴 TLS KEY 私钥（输入不回显）" "y" private-key || return 1
                    private_key_pem="$REPLY"
                    save_tls_contents "$certificate_pem" "$private_key_pem" || return 1
                    certificate="$GENERATED_TLS_CERTIFICATE_PATH"
                    certificate_key="$GENERATED_TLS_KEY_PATH"
                    printf 'TLS PEM 证书路径：%s\nTLS KEY 私钥路径：%s（权限 0600）\n' \
                        "$certificate" "$certificate_key"
                    ;;
                *)
                    print_error "无效的 TLS 证书输入方式"
                    return 1
                    ;;
            esac
            prompt_value "TLS SNI 域名" "example.com" || return 1
            server_name="$REPLY"
            if [[ "$server_name" == *:* ]] || is_valid_ipv4_address "$server_name"; then
                if ! openssl x509 -in "$certificate" -noout -checkip "$server_name" >/dev/null 2>&1; then
                    print_warn "TLS 证书不包含 SNI IP $server_name；客户端可能因证书校验失败而无法连接"
                fi
            elif ! openssl x509 -in "$certificate" -noout -checkhost "$server_name" >/dev/null 2>&1; then
                print_warn "TLS 证书不匹配 SNI 域名 $server_name；客户端可能因证书校验失败而无法连接"
            fi
            [[ "$NETWORK" == "grpc" ]] && alpn_json='["h2"]'
            [[ "$NETWORK" == "xhttp" ]] && alpn_json='["h2","http/1.1"]'
            [[ "$NETWORK" != "grpc" && "$NETWORK" != "tcp" && "$NETWORK" != "xhttp" ]] && alpn_json='["http/1.1"]'
        elif [[ "$SECURITY" == "reality" ]]; then
            prompt_value "Reality SNI 域名" "www.cloudflare.com" || return 1
            server_name="$REPLY"
            prompt_value "Reality dest 地址" "$server_name:443" || return 1
            reality_dest="$REPLY"
            reality_output=$("$XRAY_BIN" x25519 2>&1) || {
                print_error "Xray x25519 生成 Reality 密钥失败"
                return 1
            }
            reality_private=$(awk -F': *' '{
                label=tolower($1); gsub(/[^a-z]/,"",label);
                if (label == "privatekey") {print $2; exit}
            }' <<< "$reality_output")
            reality_public=$(awk -F': *' '{
                label=tolower($1); gsub(/[^a-z]/,"",label);
                if (label ~ /publickey/ || label == "password") {print $2; exit}
            }' <<< "$reality_output")
            if [[ -z "$reality_private" || -z "$reality_public" ]]; then
                print_error "无法从 Xray x25519 输出中解析密钥"
                return 1
            fi
            short_id=$(openssl rand -hex 8) || return 1
            printf 'Reality 公钥：%s\nReality shortId：%s\n' "$reality_public" "$short_id"
        fi

        build_transport_json || return 1
        if [[ "$SECURITY" == "tls" ]]; then
            stream=$(jq -n --argjson transport "$TRANSPORT_JSON" --arg cert "$certificate" \
                --arg key "$certificate_key" --argjson alpn "$alpn_json" \
                '$transport + {security:"tls",tlsSettings:{alpn:$alpn,certificates:[{certificateFile:$cert,keyFile:$key}]}}')
        elif [[ "$SECURITY" == "reality" ]]; then
            stream=$(jq -n --argjson transport "$TRANSPORT_JSON" --arg dest "$reality_dest" \
                --arg server "$server_name" --arg private "$reality_private" --arg sid "$short_id" \
                '$transport + {security:"reality",realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$server],privateKey:$private,shortIds:[$sid]}}')
        else
            stream=$(jq -n --argjson transport "$TRANSPORT_JSON" '$transport + {security:"none"}')
        fi

        if [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" || "$PROTOCOL" == "trojan" ]]; then
            choose_credentials || return 1
            case "$PROTOCOL" in
                vless) settings=$(jq -n --argjson clients "$CLIENTS_JSON" '{clients:$clients,decryption:"none"}') ;;
                vmess) settings=$(jq -n --argjson clients "$CLIENTS_JSON" '{clients:$clients}') ;;
                trojan) settings=$(jq -n --argjson clients "$CLIENTS_JSON" '{clients:$clients}') ;;
            esac
        elif [[ "$PROTOCOL" == "socks" || "$PROTOCOL" == "http" ]]; then
            choose_credentials || return 1
            if [[ "$PROTOCOL" == "socks" ]]; then
                settings=$(jq -n --argjson clients "$CLIENTS_JSON" \
                    '{auth:"password",accounts:$clients,udp:true}')
            else
                settings=$(jq -n --argjson clients "$CLIENTS_JSON" '{accounts:$clients}')
            fi
        fi
    fi

    inbound=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg protocol "$PROTOCOL" --argjson settings "$settings" --argjson stream "$stream" \
        --argjson use_stream "$([[ "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "dokodemo-door" ]] && printf false || printf true)" \
        '{tag:$tag,listen:$listen,port:$port,protocol:$protocol,settings:$settings} +
         (if $use_stream then {streamSettings:$stream} else {} end) +
         {sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
    [[ "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "dokodemo-door" ]] && inbound=$(jq 'del(.sniffing)' <<< "$inbound")

    NEW_INBOUND_JSON="$inbound"
    CLIENT_PORT="$port"
    CLIENT_TAG="$tag"
    CLIENT_PROTOCOL="$PROTOCOL"
    CLIENT_NETWORK="$NETWORK"
    CLIENT_SECURITY="$SECURITY"
    CLIENT_SERVER_NAME="$server_name"
    CLIENT_PUBLIC_KEY="$reality_public"
    CLIENT_SHORT_ID="$short_id"
    CLIENT_METHOD="$method"
    CLIENT_PASSWORD="$password"
    CLIENT_WS_PATH=""
    CLIENT_HOST=""
    CLIENT_SERVICE_NAME=""
    CLIENT_XHTTP_MODE=""
    CLIENT_XHTTP_PADDING_BYTES=""
    CLIENT_XHTTP_EXTRA='{}'
    if [[ "$PROTOCOL" != "shadowsocks" ]]; then
        CLIENT_WS_PATH=$(jq -r '.wsSettings.path // .httpupgradeSettings.path // .xhttpSettings.path // empty' <<< "$TRANSPORT_JSON")
        CLIENT_HOST=$(jq -r '.wsSettings.headers.Host // .httpupgradeSettings.host // .xhttpSettings.host // empty' <<< "$TRANSPORT_JSON")
        CLIENT_SERVICE_NAME=$(jq -r '.grpcSettings.serviceName // empty' <<< "$TRANSPORT_JSON")
        CLIENT_XHTTP_MODE=$(jq -r '.xhttpSettings.mode // empty' <<< "$TRANSPORT_JSON")
        CLIENT_XHTTP_PADDING_BYTES=$(jq -r '.xhttpSettings.xPaddingBytes // empty' <<< "$TRANSPORT_JSON")
        if [[ "$NETWORK" == "xhttp" ]]; then
            CLIENT_XHTTP_EXTRA=$(jq -c '.xhttpSettings | {mode,xPaddingBytes}' <<< "$TRANSPORT_JSON")
        fi
    fi
    if [[ "$PROTOCOL" == "dokodemo-door" ]]; then
        CLIENT_DEST_ADDRESS="$forward_address"
        CLIENT_DEST_PORT="$forward_port"
        CLIENT_FORWARD_NETWORK="$forward_network"
        return 0
    fi
    client_address=$(detect_public_ip) || client_address=""
    if [[ -n "$client_address" ]]; then
        print_info "自动检测到公网出口地址：$client_address；若服务器位于 NAT 后，请改为可连接的映射地址或域名"
        prompt_value "客户端连接地址（公网 IP 或域名）" "$client_address" || return 1
        CLIENT_ADDRESS="$REPLY"
    else
        print_warn "无法自动检测公网 IP；服务器位于 NAT 后时，请输入映射地址或域名"
        read_prompt -r -p "请输入客户端连接地址（公网 IP 或域名）: " CLIENT_ADDRESS || return 1
        if [[ -z "$CLIENT_ADDRESS" ]]; then
            print_error "客户端连接地址不能为空"
            return 1
        fi
    fi
    if [[ "$CLIENT_ADDRESS" == *:* ]]; then
        case "$CLIENT_ADDRESS" in
            \[*\]) ;;
            *) CLIENT_ADDRESS="[$CLIENT_ADDRESS]" ;;
        esac
    fi
}

print_client_links() {
    local client=""
    local credential=""
    local email=""
    local params=""
    local link=""
    local payload=""
    local encoded=""
    local password=""
    local username=""
    local path=""
    local userinfo=""
    local vmess_address=""

    if [[ "$CLIENT_PROTOCOL" == "shadowsocks" ]]; then
        userinfo=$(printf '%s' "$CLIENT_METHOD:$CLIENT_PASSWORD" | base64 | tr -d '\n=' | tr '+/' '-_')
        printf 'Shadowsocks 分享链接：ss://%s@%s:%s#%s\n' "$userinfo" "$CLIENT_ADDRESS" "$CLIENT_PORT" "$(url_encode "$CLIENT_TAG")"
        return
    fi
    if [[ "$CLIENT_PROTOCOL" == "dokodemo-door" ]]; then
        printf '端口转发：监听端口 %s -> %s:%s（%s）\n' "$CLIENT_PORT" \
            "$CLIENT_DEST_ADDRESS" "$CLIENT_DEST_PORT" "$CLIENT_FORWARD_NETWORK"
        return
    fi

    while IFS= read -r client; do
        [[ -n "$client" ]] || continue
        email=$(jq -r '.email // .user // "user"' <<< "$client")
        case "$CLIENT_PROTOCOL" in
            vless)
                credential=$(jq -r '.id' <<< "$client")
                params="encryption=none&type=$CLIENT_NETWORK&security=$CLIENT_SECURITY"
                if [[ "$CLIENT_SECURITY" == "reality" ]]; then
                    params="$params&sni=$(url_encode "$CLIENT_SERVER_NAME")&fp=chrome&pbk=$(url_encode "$CLIENT_PUBLIC_KEY")&sid=$CLIENT_SHORT_ID"
                elif [[ "$CLIENT_SECURITY" == "tls" ]]; then
                    params="$params&sni=$(url_encode "$CLIENT_SERVER_NAME")&fp=chrome"
                    [[ "$CLIENT_NETWORK" == "xhttp" ]] && params="$params&alpn=h2%2Chttp%2F1.1"
                fi
                if [[ -n "$CLIENT_FLOW" ]]; then
                    params="$params&flow=$(url_encode "$CLIENT_FLOW")"
                fi
                case "$CLIENT_NETWORK" in
                    ws) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&host=$(url_encode "$CLIENT_HOST")" ;;
                    grpc) params="$params&serviceName=$(url_encode "$CLIENT_SERVICE_NAME")" ;;
                    httpupgrade) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&host=$(url_encode "$CLIENT_HOST")" ;;
                    xhttp) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&mode=$CLIENT_XHTTP_MODE&host=$(url_encode "$CLIENT_HOST")&extra=$(url_encode "$CLIENT_XHTTP_EXTRA")" ;;
                esac
                link="vless://$credential@$CLIENT_ADDRESS:$CLIENT_PORT?$params#$(url_encode "$CLIENT_TAG-$email")"
                printf 'VLESS 分享链接（%s）：%s\n' "$email" "$link"
                ;;
            vmess)
                credential=$(jq -r '.id' <<< "$client")
                path="$CLIENT_WS_PATH"
                [[ "$CLIENT_NETWORK" == "grpc" ]] && path="$CLIENT_SERVICE_NAME"
                vmess_address="$CLIENT_ADDRESS"
                case "$vmess_address" in
                    \[*\])
                        vmess_address="${vmess_address#\[}"
                        vmess_address="${vmess_address%\]}"
                        ;;
                esac
                payload=$(jq -nc --arg ps "$CLIENT_TAG-$email" --arg add "$vmess_address" \
                    --arg port "$CLIENT_PORT" --arg id "$credential" --arg net "$CLIENT_NETWORK" \
                    --arg host "$CLIENT_HOST" --arg path "$path" \
                    --arg mode "$CLIENT_XHTTP_MODE" --arg xPaddingBytes "$CLIENT_XHTTP_PADDING_BYTES" \
                    --arg tls "$([[ "$CLIENT_SECURITY" == "tls" ]] && printf tls || printf '')" \
                    --arg sni "$CLIENT_SERVER_NAME" \
                    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$sni} + (if $net == "xhttp" then {mode:$mode,xPaddingBytes:$xPaddingBytes} else {} end)')
                encoded=$(printf '%s' "$payload" | base64 | tr -d '\n')
                printf 'VMess 分享链接（%s）：vmess://%s\n' "$email" "$encoded"
                ;;
            trojan)
                password=$(jq -r '.password' <<< "$client")
                params="security=tls&type=$CLIENT_NETWORK&sni=$(url_encode "$CLIENT_SERVER_NAME")"
                [[ "$CLIENT_NETWORK" == "xhttp" ]] && params="$params&alpn=h2%2Chttp%2F1.1"
                case "$CLIENT_NETWORK" in
                    ws) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&host=$(url_encode "$CLIENT_HOST")" ;;
                    grpc) params="$params&serviceName=$(url_encode "$CLIENT_SERVICE_NAME")" ;;
                    httpupgrade) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&host=$(url_encode "$CLIENT_HOST")" ;;
                    xhttp) params="$params&path=$(url_encode "$CLIENT_WS_PATH")&mode=$CLIENT_XHTTP_MODE&host=$(url_encode "$CLIENT_HOST")&extra=$(url_encode "$CLIENT_XHTTP_EXTRA")" ;;
                esac
                printf 'Trojan 分享链接（%s）：trojan://%s@%s:%s?%s#%s\n' "$email" \
                    "$(url_encode "$password")" "$CLIENT_ADDRESS" "$CLIENT_PORT" "$params" "$(url_encode "$CLIENT_TAG-$email")"
                ;;
            socks|http)
                username=$(jq -r '.user' <<< "$client")
                password=$(jq -r '.pass' <<< "$client")
                printf '%s 连接地址（%s）：%s:%s 用户名：%s 密码：%s\n' \
                    "$CLIENT_PROTOCOL" "$email" "$CLIENT_ADDRESS" "$CLIENT_PORT" "$username" "$password"
                ;;
        esac
    done < <(jq -c '.[]' <<< "$CLIENTS_JSON")
}

add_inbound() {
    local candidate=""

    [[ -x "$XRAY_BIN" ]] || {
        print_error "请先安装 Xray"
        return 1
    }
    [[ -f "$CONFIG_FILE" ]] || make_default_config
    TRANSPORT_JSON='{}'
    NEW_INBOUND_JSON=""
    CLIENT_FLOW=""
    CLIENTS_JSON='[]'
    GENERATED_TLS_CERTIFICATE_PATH=""
    GENERATED_TLS_KEY_PATH=""
    if ! build_inbound; then
        cleanup_unreferenced_tls_files
        return 1
    fi
    candidate=$(mktemp "$CONFIG_DIR/config.XXXXXX") || {
        cleanup_unreferenced_tls_files
        return 1
    }
    if ! jq --argjson inbound "$NEW_INBOUND_JSON" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"; then
        rm -f "$candidate"
        cleanup_unreferenced_tls_files
        print_error "生成配置失败"
        return 1
    fi
    if ! commit_config_file "$candidate"; then
        rm -f "$candidate"
        cleanup_unreferenced_tls_files
        return 1
    fi
    rm -f "$candidate"
    cleanup_unreferenced_tls_files
    print_info "入站 $CLIENT_TAG 已创建"
    print_client_links
}

list_inbounds() {
    local api_tag=""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_warn "配置文件不存在"
        return 1
    fi
    api_tag=$(jq -r '.api.tag // "r-ui-api"' "$CONFIG_FILE") || return 1
    jq -r --arg api_tag "$api_tag" '
        [.inbounds[]? | select(.tag != $api_tag)] as $entries |
        if ($entries | length) == 0 then
            "当前没有入站配置"
        else
            $entries | to_entries[] |
            "\(.key + 1). \(.value.tag // "untagged") | \(.value.protocol) | \(.value.listen // "0.0.0.0"):\(.value.port) | \(.value.streamSettings.network // "tcp") / \(.value.streamSettings.security // "none")"
        end
    ' "$CONFIG_FILE"
}

delete_inbound() {
    local count=0
    local index=""
    local actual_index=""
    local api_tag=""
    local candidate=""

    [[ -f "$CONFIG_FILE" ]] || {
        print_error "配置文件不存在"
        return 1
    }
    list_inbounds || return 1
    api_tag=$(jq -r '.api.tag // "r-ui-api"' "$CONFIG_FILE") || return 1
    count=$(jq --arg api_tag "$api_tag" '[.inbounds[]? | select(.tag != $api_tag)] | length' "$CONFIG_FILE")
    (( count > 0 )) || return 0
    read_prompt -r -p "输入要删除的编号 [1-$count]: " index || return 1
    if [[ ! "$index" =~ ^[0-9]+$ ]]; then
        print_error "编号无效"
        return 1
    fi
    index="${index#"${index%%[!0]*}"}"
    [[ -n "$index" ]] || index="0"
    if (( ${#index} > ${#count} )); then
        print_error "编号无效"
        return 1
    fi
    index=$((10#$index))
    if (( index < 1 || index > count )); then
        print_error "编号无效"
        return 1
    fi
    if ! prompt_yesno "确定删除该入站吗？" "n"; then
        [[ "$PROMPT_ERROR" == "1" ]] && return 1
        return 0
    fi
    actual_index=$(jq -er --argjson index "$index" --arg api_tag "$api_tag" \
        '[.inbounds | to_entries[] | select(.value.tag != $api_tag)] | .[$index - 1].key' "$CONFIG_FILE") || return 1
    candidate=$(mktemp "$CONFIG_DIR/config.XXXXXX") || return 1
    if ! jq --argjson index "$actual_index" 'del(.inbounds[$index])' "$CONFIG_FILE" > "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    if ! commit_config_file "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    rm -f "$candidate"
    cleanup_unreferenced_tls_files
}

configure_service() {
    local was_active="n"

    detect_platform || return 1
    install_dependencies || {
        print_error "安装系统依赖失败"
        return 1
    }
    mkdir -p "$XRAY_HOME" "$CONFIG_DIR" "$LOG_DIR"
    [[ -f "$CONFIG_FILE" ]] || make_default_config
    if service_is_active; then
        was_active="y"
        service_stop || {
            print_error "停止现有独立 Xray 服务失败"
            return 1
        }
    fi
    download_latest_release || {
        [[ "$was_active" == "y" ]] && service_start
        return 1
    }
    ensure_api_config || {
        [[ "$was_active" == "y" ]] && service_start
        return 1
    }
    if ! config_test; then
        print_error "当前配置未通过 Xray 校验；没有启动服务"
        [[ "$was_active" == "y" ]] && service_start
        return 1
    fi
    if [[ "$(jq --arg tag "$XRAY_API_TAG" '[.inbounds[]? | select(.tag != $tag)] | length' "$CONFIG_FILE")" == "0" ]]; then
        if prompt_yesno "当前没有入站配置，现在运行交互式配置吗？" "y"; then
            if ! add_inbound; then
                [[ "$was_active" == "y" ]] && service_start
                return 1
            fi
        elif [[ "$PROMPT_ERROR" == "1" ]]; then
            print_error "无法读取交互输入，已取消安装"
            [[ "$was_active" == "y" ]] && service_start
            return 1
        fi
    fi
    service_install_definition || return 1
    service_enable || return 1
    install_manager_script || return 1
    service_start || {
        print_error "服务启动失败；请执行 logs 查看错误"
        return 1
    }
    watchdog_install "$WATCHDOG_DEFAULT_INTERVAL" || {
        print_error "Xray 已启动，但每 40 秒 API 健康检测未能配置"
        return 1
    }
    print_info "Xray 服务已启动并设置为开机启动"
}

update_xray() {
    local was_active="n"

    detect_platform || return 1
    if [[ ! -x "$XRAY_BIN" || ! -f "$CONFIG_FILE" ]]; then
        print_error "独立 Xray 尚未安装；请先执行 install"
        return 1
    fi
    install_dependencies || return 1
    if service_is_active; then
        was_active="y"
        service_stop || {
            print_error "停止服务失败，未更新 Xray"
            return 1
        }
    fi
    download_latest_release || {
        [[ "$was_active" == "y" ]] && service_start
        return 1
    }
    ensure_api_config || {
        [[ "$was_active" == "y" ]] && service_start
        return 1
    }
    if ! config_test; then
        print_error "新版本配置校验失败；请检查配置和日志"
        [[ "$was_active" == "y" ]] && service_start
        return 1
    fi
    install_manager_script || return 1
    if [[ "$was_active" == "y" ]]; then
        service_start || {
            print_error "Xray 更新完成，但服务启动失败"
            return 1
        }
    fi
    watchdog_install || {
        print_error "Xray 已更新，但 API 健康检测未能配置"
        return 1
    }
    print_info "Xray 已更新到最新版"
}

uninstall_service() {
    local remove_config="n"

    detect_platform || return 1
    if ! prompt_yesno "确定卸载独立 Xray 服务吗？" "n"; then
        [[ "$PROMPT_ERROR" == "1" ]] && return 1
        return 0
    fi
    if service_is_active && ! service_stop; then
        print_error "停止服务失败；为避免留下孤立进程，已中止卸载"
        return 1
    fi
    service_disable || {
        print_error "取消 Xray 开机启动失败；已中止卸载"
        return 1
    }
    watchdog_disable || {
        print_error "取消 Xray 状态检测失败；已中止卸载"
        return 1
    }
    rm -f "$WATCHDOG_PAUSED_FILE" "$WATCHDOG_DISABLED_FILE" "$WATCHDOG_COOLDOWN_FILE" "$LOCK_OWNER_FILE"
    case "$SERVICE_MANAGER" in
        systemd)
            rm -f "/etc/systemd/system/$SERVICE_NAME.service"
            systemctl daemon-reload
            ;;
        *)
            rm -f "/etc/init.d/$SERVICE_NAME"
            ;;
    esac
    rm -rf "$XRAY_HOME"
    if prompt_yesno "同时删除配置和备份吗？" "n"; then
        remove_config="y"
    fi
    if [[ "$remove_config" == "y" ]]; then
        rm -rf "$CONFIG_DIR" "$LOG_DIR"
    fi
    rm -f "$MANAGER_BIN"
    print_info "独立 Xray 服务已卸载"
    [[ "$remove_config" == "n" ]] && print_info "配置和日志保留在 $CONFIG_DIR 与 $LOG_DIR"
}

run_menu() {
    local choice=""

    while true; do
        printf '\n独立 Xray 管理脚本\n'
        printf '  0. 退出\n'
        printf '  1. 安装或初始化\n'
        printf '  2. 交互添加入站并生成 JSON\n'
        printf '  3. 查看入站\n'
        printf '  4. 删除入站\n'
        printf '  5. 校验配置\n'
        printf '  6. 更新 Xray 到最新版\n'
        printf '  7. 启动服务\n'
        printf '  8. 停止服务\n'
        printf '  9. 重启服务\n'
        printf ' 10. 查看服务状态\n'
        printf ' 11. 查看最近日志\n'
        printf ' 12. 设置开机启动\n'
        printf ' 13. 取消开机启动\n'
        printf ' 14. 启用 Xray 状态检测\n'
        printf ' 15. 取消 Xray 状态检测\n'
        printf ' 16. 卸载\n'
        read_prompt -r -p "请输入选项 [0-16]: " choice || return 1
        case "$choice" in
            0) return 0 ;;
            1) acquire_lock menu && configure_service ;;
            2) acquire_lock menu && detect_platform && add_inbound ;;
            3) list_inbounds ;;
            4) acquire_lock menu && detect_platform && delete_inbound ;;
            5) config_test ;;
            6) acquire_lock menu && update_xray ;;
            7) acquire_lock menu && detect_platform && service_start ;;
            8) acquire_lock menu && detect_platform && service_stop ;;
            9) acquire_lock menu && detect_platform && service_restart ;;
            10) detect_platform && service_status ;;
            11) detect_platform && service_logs ;;
            12) acquire_lock menu && detect_platform && service_enable ;;
            13) acquire_lock menu && detect_platform && service_disable ;;
            14) acquire_lock menu && watchdog_enable ;;
            15) acquire_lock menu && watchdog_disable ;;
            16) acquire_lock menu && uninstall_service ;;
            *) print_error "无效选项" ;;
        esac
        release_lock
        read_prompt -r -p "按回车键继续..." _ || return 1
    done
}

main() {
    local status=0

    require_root
    if [[ "$#" -eq 0 ]]; then
        run_menu
        return
    fi
    case "$1" in
        list|test|check|watchdog|watchdog-loop)
            ;;
        *)
            acquire_lock "$1" || return 1
            ;;
    esac
    case "$1" in
        install) configure_service; status=$? ;;
        add|configure) detect_platform && add_inbound; status=$? ;;
        list) list_inbounds; status=$? ;;
        delete) detect_platform && delete_inbound; status=$? ;;
        test|check) config_test; status=$? ;;
        update) update_xray; status=$? ;;
        start) detect_platform && service_start; status=$? ;;
        stop) detect_platform && service_stop; status=$? ;;
        restart) detect_platform && service_restart; status=$? ;;
        status) detect_platform && service_status; status=$? ;;
        logs) detect_platform && service_logs; status=$? ;;
        enable) detect_platform && service_enable; status=$? ;;
        disable) detect_platform && service_disable; status=$? ;;
        uninstall) uninstall_service; status=$? ;;
        watchdog-enable|monitor-enable) watchdog_enable; status=$? ;;
        watchdog-disable|monitor-disable) watchdog_disable; status=$? ;;
        watchdog) detect_platform && watchdog_check; status=$? ;;
        watchdog-loop) watchdog_loop; status=$? ;;
        *)
            printf '用法：%s [install|add|list|delete|test|update|start|stop|restart|status|logs|enable|disable|watchdog-enable|watchdog-disable|uninstall]\n' "$0"
            status=2
            ;;
    esac
    release_lock
    return "$status"
}

main "$@"
