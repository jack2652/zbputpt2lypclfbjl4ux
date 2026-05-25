#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

current_arch=""
managed_swap_file="${SWAP_FILE:-}"
disk_reserve_mb=512
swap_reduce_buffer_mb=512

function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

show_usage() {
    cat <<'EOF'
用法:
  bash swap-alpine.sh
  SWAP_FILE=/swap.img bash swap-alpine.sh
  bash swap-alpine.sh --help

说明:
  1. 提供查看当前虚拟内存、增加虚拟内存、减少虚拟内存、退出四项菜单
  2. 默认自动识别单个现有 swap 文件；未识别到时默认管理 /swapfile
  3. 增加和减少会同步维护 /etc/fstab，重启后仍然生效
  4. 允许与宿主提供的 virtual swap 共存；如果存在其他 file/partition swap，则只允许查看
EOF
}

pause_return() {
    echo
    read -r -p "按回车键返回主菜单: " temp
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo "amd64" ;;
        aarch64 | arm64 | armv8 | armv8*) echo "arm64" ;;
        *) return 1 ;;
    esac
}

ensure_environment() {
    [[ "$1" == "--help" || "$1" == "-h" ]] && show_usage && exit 0

    [[ $EUID -ne 0 ]] && LOGE "严重错误: 请以 root 权限运行此脚本" && exit 1

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    elif [[ -f /usr/lib/os-release ]]; then
        . /usr/lib/os-release
    else
        LOGE "系统类型检查失败, 未找到 os-release"
        exit 1
    fi

    if [[ "${ID}" != "alpine" ]]; then
        LOGE "当前脚本仅支持 Alpine Linux"
        exit 1
    fi

    current_arch=$(detect_arch)
    if [[ -z "${current_arch}" ]]; then
        LOGE "当前仅支持 amd64 和 arm64/aarch64 架构"
        exit 1
    fi

    [[ -f /etc/fstab ]] || touch /etc/fstab
}

ensure_swap_tools() {
    if command -v mkswap >/dev/null 2>&1 && command -v swapon >/dev/null 2>&1 && command -v swapoff >/dev/null 2>&1; then
        return 0
    fi

    LOGD "检测到缺少 swap 管理工具, 正在尝试安装 util-linux-misc..."
    apk add --no-cache util-linux-misc >/dev/null 2>&1 || apk add --no-cache util-linux >/dev/null 2>&1

    if ! command -v mkswap >/dev/null 2>&1 || ! command -v swapon >/dev/null 2>&1 || ! command -v swapoff >/dev/null 2>&1; then
        LOGE "安装 swap 管理工具失败, 请先手动安装 util-linux-misc 后再重试"
        exit 1
    fi
}

format_mb() {
    local mb="$1"
    awk -v mb="${mb}" 'BEGIN {
        if (mb >= 1024) {
            printf "%.2fGiB", mb / 1024
        } else {
            printf "%dMiB", mb
        }
    }'
}

get_meminfo_mb() {
    local key="$1"
    awk -v key="${key}" '$1 == key ":" {print int(($2 + 1023) / 1024)}' /proc/meminfo
}

get_total_swap_mb() {
    get_meminfo_mb "SwapTotal"
}

get_free_swap_mb() {
    get_meminfo_mb "SwapFree"
}

get_used_swap_mb() {
    local total_mb
    local free_mb

    total_mb=$(get_total_swap_mb)
    free_mb=$(get_free_swap_mb)
    echo $((total_mb - free_mb))
}

get_mem_total_mb() {
    get_meminfo_mb "MemTotal"
}

get_mem_available_mb() {
    get_meminfo_mb "MemAvailable"
}

get_file_size_mb() {
    local target_file="$1"
    local bytes=""

    if [[ ! -f "${target_file}" ]]; then
        echo 0
        return 0
    fi

    bytes=$(wc -c < "${target_file}" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "${bytes}" ]]; then
        echo 0
        return 0
    fi

    echo $(((bytes + 1048575) / 1048576))
}

get_disk_free_mb() {
    local target_dir

    target_dir=$(dirname "${managed_swap_file}")
    while [[ ! -d "${target_dir}" && "${target_dir}" != "/" ]]; do
        target_dir=$(dirname "${target_dir}")
    done
    df -kP "${target_dir}" | awk 'NR == 2 {print int(($4 + 1023) / 1024)}'
}

detect_managed_swap_file() {
    local fstab_swap_file=""
    local active_swap_file=""

    if [[ -n "${managed_swap_file}" ]]; then
        return 0
    fi

    fstab_swap_file=$(awk '$3 == "swap" && $1 ~ /^\// && $1 !~ /^\/dev\// {print $1; exit}' /etc/fstab 2>/dev/null)
    if [[ -n "${fstab_swap_file}" ]]; then
        managed_swap_file="${fstab_swap_file}"
        return 0
    fi

    active_swap_file=$(awk 'NR > 1 && $2 == "file" {count++; path=$1} END {if (count == 1) print path}' /proc/swaps)
    if [[ -n "${active_swap_file}" ]]; then
        managed_swap_file="${active_swap_file}"
        return 0
    fi

    managed_swap_file="/swapfile"
}

validate_managed_swap_file() {
    if [[ -z "${managed_swap_file}" || "${managed_swap_file}" != /* ]]; then
        LOGE "受管 swap 文件路径必须是绝对路径"
        exit 1
    fi

    if [[ "${managed_swap_file}" =~ ^/dev/ ]]; then
        LOGE "当前脚本仅支持基于文件的 swap，不支持直接管理 /dev 下的分区型 swap"
        exit 1
    fi

    if [[ -e "${managed_swap_file}" && ! -f "${managed_swap_file}" ]]; then
        LOGE "${managed_swap_file} 已存在，但它不是普通文件，无法由本脚本管理"
        exit 1
    fi
}

has_active_managed_swap() {
    awk -v target="${managed_swap_file}" 'NR > 1 && $1 == target {found=1} END {exit !found}' /proc/swaps
}

has_virtual_active_swap() {
    awk 'NR > 1 && $2 == "virtual" {found=1} END {exit !found}' /proc/swaps
}

has_conflicting_active_swap() {
    awk -v target="${managed_swap_file}" 'NR > 1 && $1 != target && $2 != "virtual" {found=1} END {exit !found}' /proc/swaps
}

is_swap_persistent() {
    awk -v target="${managed_swap_file}" '$1 == target && $3 == "swap" {found=1} END {exit !found}' /etc/fstab
}

swap_changes_allowed() {
    if has_conflicting_active_swap; then
        return 1
    fi

    return 0
}

show_swap_change_status() {
    if has_conflicting_active_swap; then
        echo -e "  调整状态: ${yellow}检测到其他 file/partition swap, 当前仅允许查看${plain}"
    elif has_virtual_active_swap; then
        echo -e "  调整状态: ${green}可调整${plain} ${yellow}(将与宿主提供的 virtual swap 共存)${plain}"
    else
        echo -e "  调整状态: ${green}可调整${plain}"
    fi
}

parse_size_to_mb() {
    local raw_input="${1}"
    local normalized=""
    local value=""
    local unit=""

    normalized=$(echo "${raw_input}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    if [[ -z "${normalized}" ]]; then
        return 1
    fi

    if [[ "${normalized}" =~ ^[0-9]+$ ]]; then
        value="${normalized}"
        unit="M"
    elif [[ "${normalized}" =~ ^([0-9]+)(M|MB|G|GB)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    if (( value <= 0 )); then
        return 1
    fi

    case "${unit}" in
        G | GB) echo $((value * 1024)) ;;
        M | MB) echo "${value}" ;;
        *) return 1 ;;
    esac
}

show_status_summary() {
    local total_mem_mb
    local available_mem_mb
    local total_swap_mb
    local used_swap_mb
    local free_swap_mb
    local current_file_mb

    total_mem_mb=$(get_mem_total_mb)
    available_mem_mb=$(get_mem_available_mb)
    total_swap_mb=$(get_total_swap_mb)
    used_swap_mb=$(get_used_swap_mb)
    free_swap_mb=$(get_free_swap_mb)
    current_file_mb=$(get_file_size_mb "${managed_swap_file}")

    echo "————————————————"
    echo -e "  系统架构: ${green}${current_arch}${plain}"
    echo -e "  受管文件: ${green}${managed_swap_file}${plain}"
    echo -e "  内存总量: ${green}$(format_mb "${total_mem_mb}")${plain}"
    echo -e "  可用内存: ${green}$(format_mb "${available_mem_mb}")${plain}"
    echo -e "  当前Swap: ${green}$(format_mb "${total_swap_mb}")${plain}"
    echo -e "  已用Swap: ${green}$(format_mb "${used_swap_mb}")${plain}"
    echo -e "  剩余Swap: ${green}$(format_mb "${free_swap_mb}")${plain}"
    echo -e "  文件大小: ${green}$(format_mb "${current_file_mb}")${plain}"
    show_swap_change_status
}

show_current_swap() {
    local total_mem_mb
    local available_mem_mb
    local total_swap_mb
    local used_swap_mb
    local free_swap_mb
    local current_file_mb
    local disk_free_mb

    total_mem_mb=$(get_mem_total_mb)
    available_mem_mb=$(get_mem_available_mb)
    total_swap_mb=$(get_total_swap_mb)
    used_swap_mb=$(get_used_swap_mb)
    free_swap_mb=$(get_free_swap_mb)
    current_file_mb=$(get_file_size_mb "${managed_swap_file}")
    disk_free_mb=$(get_disk_free_mb)

    echo
    echo -e "${green}当前虚拟内存详情${plain}"
    echo "————————————————"
    echo -e "系统架构: ${current_arch}"
    echo -e "受管文件: ${managed_swap_file}"
    echo -e "内存总量: $(format_mb "${total_mem_mb}")"
    echo -e "可用内存: $(format_mb "${available_mem_mb}")"
    echo -e "Swap总量: $(format_mb "${total_swap_mb}")"
    echo -e "Swap已用: $(format_mb "${used_swap_mb}")"
    echo -e "Swap剩余: $(format_mb "${free_swap_mb}")"
    echo -e "受管文件大小: $(format_mb "${current_file_mb}")"
    echo -e "所在分区剩余空间: $(format_mb "${disk_free_mb}")"
    if is_swap_persistent; then
        echo -e "开机持久化: 是"
    else
        echo -e "开机持久化: 否"
    fi
    echo
    echo "当前活动 swap 列表:"
    cat /proc/swaps
    echo
    if has_conflicting_active_swap; then
        LOGD "检测到除 ${managed_swap_file} 之外还有其他 file/partition swap, 本脚本当前只允许查看"
    elif has_virtual_active_swap; then
        LOGD "检测到宿主提供的 virtual swap，本脚本允许在其基础上额外创建或调整 ${managed_swap_file}"
    fi
    pause_return
}

rewrite_fstab_swap_entry() {
    local keep_entry="$1"
    local temp_file=""

    temp_file=$(mktemp)
    awk -v target="${managed_swap_file}" '($1 != target || $3 != "swap") {print}' /etc/fstab > "${temp_file}"
    if [[ "${keep_entry}" == "yes" ]]; then
        printf "%s none swap sw 0 0\n" "${managed_swap_file}" >> "${temp_file}"
    fi
    cat "${temp_file}" > /etc/fstab
    rm -f "${temp_file}"
}

create_swap_file() {
    local target_mb="$1"
    local create_mode="${2:-auto}"

    mkdir -p "$(dirname "${managed_swap_file}")"

    if [[ "${create_mode}" == "dd" ]]; then
        LOGD "正在使用 dd 方式重建 ${managed_swap_file}..."
        dd if=/dev/zero of="${managed_swap_file}" bs=1M count="${target_mb}" >/dev/null 2>&1
        return $?
    fi

    if command -v fallocate >/dev/null 2>&1; then
        if fallocate -l "${target_mb}M" "${managed_swap_file}" 2>/dev/null; then
            return 0
        fi
        LOGD "fallocate 创建失败, 正在回退到 dd..."
        rm -f "${managed_swap_file}"
    fi

    dd if=/dev/zero of="${managed_swap_file}" bs=1M count="${target_mb}" >/dev/null 2>&1
}

read_error_message() {
    local stderr_file="$1"
    tr '\n' ' ' < "${stderr_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

is_holes_error_message() {
    local error_message="$1"
    local normalized_message=""

    normalized_message=$(printf '%s' "${error_message}" | tr '[:upper:]' '[:lower:]')
    [[ "${normalized_message}" == *"file has holes"* || "${normalized_message}" == *"swapfile has holes"* ]]
}

prepare_swap_file() {
    local target_mb="$1"
    local create_mode="${2:-auto}"

    rm -f "${managed_swap_file}"

    if ! create_swap_file "${target_mb}" "${create_mode}"; then
        LOGE "创建 ${managed_swap_file} 失败"
        return 1
    fi

    chmod 600 "${managed_swap_file}" || {
        LOGE "设置 ${managed_swap_file} 权限失败"
        return 1
    }

    mkswap "${managed_swap_file}" >/dev/null 2>&1 || {
        LOGE "执行 mkswap 失败"
        return 1
    }

    return 0
}

handle_swapon_failure() {
    local stderr_file="$1"
    local retry_note="${2:-}"
    local error_message=""
    local normalized_message=""

    error_message=$(read_error_message "${stderr_file}")
    [[ -z "${error_message}" ]] && error_message="未知错误"
    normalized_message=$(printf '%s' "${error_message}" | tr '[:upper:]' '[:lower:]')

    LOGE "系统报错: ${error_message}"
    if [[ -n "${retry_note}" ]]; then
        LOGE "${retry_note}"
    fi

    case "${normalized_message}" in
        *"operation not permitted"* | *"permission denied"* | *"function not implemented"* | *"not supported"*)
            LOGE "中文说明: 当前系统环境可能不支持新增 swapfile，或 swapon 被宿主/容器策略限制"
            LOGE "处理建议: 这通常不是输入大小问题，请改为在宿主机或控制面板层面开启 swap，或更换到支持 swapon 的环境后再试"
            ;;
        *"invalid argument"* | *"swapfile has holes"* | *"file has holes"* | *"read swap header failed"*)
            LOGE "中文说明: 这是 swap 文件格式或所在文件系统的问题，不是单纯的环境不支持"
            LOGE "处理建议: 如果脚本已经自动改用 dd 重建后仍失败，通常说明当前文件系统不适合 swapfile"
            ;;
        *"already in use"* | *"device or resource busy"*)
            LOGE "中文说明: 该 swap 文件已启用或正在被占用，请先检查当前 swap 状态"
            ;;
        *"no such file or directory"*)
            LOGE "中文说明: 目标 swap 文件不存在，可能在重建过程中被移除，请重新执行并观察创建步骤"
            ;;
        *"cannot allocate memory"* | *"cannot allocate"* | *"enomem"*)
            LOGE "中文说明: 当前内存状态不足以完成 swapon，请先释放内存或降低目标大小后再试"
            ;;
        *)
            LOGE "中文说明: 启用 swapfile 失败，当前无法确定是否为环境限制，请结合上面的系统原始报错继续排查"
            ;;
    esac

    LOGE "补充提醒: 如果这是调整现有 swap 的过程中失败，请立即重新查看当前 Swap 状态"
}

apply_target_swap_size() {
    local target_mb="$1"
    local swapon_stderr_file=""
    local swapon_error_message=""

    if (( target_mb <= 0 )); then
        LOGE "目标大小必须大于 0"
        return 1
    fi

    if has_active_managed_swap; then
        LOGD "正在停用当前受管 swap 文件..."
        if ! swapoff "${managed_swap_file}"; then
            LOGE "停用 ${managed_swap_file} 失败, 请先确认当前系统有足够可用内存"
            return 1
        fi
    fi

    if ! prepare_swap_file "${target_mb}" "auto"; then
        return 1
    fi

    swapon_stderr_file=$(mktemp)
    swapon "${managed_swap_file}" 2> "${swapon_stderr_file}" || {
        swapon_error_message=$(read_error_message "${swapon_stderr_file}")
        if is_holes_error_message "${swapon_error_message}"; then
            LOGD "检测到 ${managed_swap_file} 存在 holes，正在自动改用 dd 重建并重试..."
            rm -f "${swapon_stderr_file}"
            if ! prepare_swap_file "${target_mb}" "dd"; then
                return 1
            fi

            swapon_stderr_file=$(mktemp)
            swapon "${managed_swap_file}" 2> "${swapon_stderr_file}" || {
                handle_swapon_failure "${swapon_stderr_file}" "脚本已自动改用 dd 重建后再次尝试，但仍然失败"
                rm -f "${swapon_stderr_file}"
                return 1
            }
            rm -f "${swapon_stderr_file}"
            rewrite_fstab_swap_entry "yes"
            LOGI "已将 ${managed_swap_file} 调整为 $(format_mb "${target_mb}")，并自动改用 dd 方式启用成功，重启后仍然生效"
            return 0
        fi

        handle_swapon_failure "${swapon_stderr_file}"
        rm -f "${swapon_stderr_file}"
        return 1
    }
    rm -f "${swapon_stderr_file}"

    rewrite_fstab_swap_entry "yes"
    LOGI "已将 ${managed_swap_file} 调整为 $(format_mb "${target_mb}")，重启后仍然生效"
    return 0
}

increase_swap() {
    local current_file_mb
    local disk_free_mb
    local increase_mb
    local target_mb
    local future_disk_free_mb
    local raw_input=""

    if ! swap_changes_allowed; then
        LOGE "当前系统存在其他 file/partition swap, 为避免误操作, 暂不允许直接增加"
        pause_return
        return 1
    fi

    current_file_mb=$(get_file_size_mb "${managed_swap_file}")
    disk_free_mb=$(get_disk_free_mb)

    echo
    echo -e "${green}增加虚拟内存${plain}"
    echo "————————————————"
    echo -e "受管文件: ${managed_swap_file}"
    echo -e "当前大小: $(format_mb "${current_file_mb}")"
    echo -e "当前Swap已用: $(format_mb "$(get_used_swap_mb)")"
    echo -e "当前磁盘剩余: $(format_mb "${disk_free_mb}")"
    echo -e "输入格式示例: 512M、1G、2G，纯数字按 MiB 处理"
    read -r -p "请输入本次要增加的大小, 直接回车取消: " raw_input

    if [[ -z "${raw_input}" ]]; then
        LOGI "已取消增加操作"
        pause_return
        return 0
    fi

    increase_mb=$(parse_size_to_mb "${raw_input}") || {
        LOGE "输入格式不正确, 仅支持 512M、1G、2048 这类格式"
        pause_return
        return 1
    }

    target_mb=$((current_file_mb + increase_mb))
    future_disk_free_mb=$((disk_free_mb + current_file_mb - target_mb))

    if (( future_disk_free_mb < disk_reserve_mb )); then
        LOGE "增加后磁盘剩余空间不足, 请至少预留 $(format_mb "${disk_reserve_mb}")"
        pause_return
        return 1
    fi

    echo
    echo -e "当前大小: $(format_mb "${current_file_mb}")"
    echo -e "目标大小: $(format_mb "${target_mb}")"
    echo -e "本次增加: $(format_mb "${increase_mb}")"
    echo -e "执行后预估磁盘剩余: $(format_mb "${future_disk_free_mb}")"
    echo -e "重启后生效: 是"
    read -r -p "确认执行本次增加? [y/N]: " confirm

    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        LOGI "已取消增加操作"
        pause_return
        return 0
    fi

    apply_target_swap_size "${target_mb}"
    pause_return
}

reduce_swap() {
    local current_file_mb
    local used_swap_mb
    local reduce_mb
    local target_mb
    local min_safe_target_mb
    local raw_input=""
    local confirm_input=""
    local confirm_target_mb=""

    if ! swap_changes_allowed; then
        LOGE "当前系统存在其他 file/partition swap, 为避免误操作, 暂不允许直接减少"
        pause_return
        return 1
    fi

    current_file_mb=$(get_file_size_mb "${managed_swap_file}")
    if (( current_file_mb <= 0 )); then
        LOGE "当前没有可减少的受管 swap 文件"
        pause_return
        return 1
    fi

    used_swap_mb=$(get_used_swap_mb)
    min_safe_target_mb=$((used_swap_mb + swap_reduce_buffer_mb))

    echo
    echo -e "${green}减少虚拟内存${plain}"
    echo "————————————————"
    echo -e "受管文件: ${managed_swap_file}"
    echo -e "当前大小: $(format_mb "${current_file_mb}")"
    echo -e "当前Swap已用: $(format_mb "${used_swap_mb}")"
    echo -e "建议最低目标值: $(format_mb "${min_safe_target_mb}")"
    echo -e "输入格式示例: 512M、1G，纯数字按 MiB 处理"
    echo -e "${yellow}注意: 当前脚本不支持直接减到 0，如需关闭 swap 请单独处理${plain}"
    read -r -p "请输入本次要减少的大小, 直接回车取消: " raw_input

    if [[ -z "${raw_input}" ]]; then
        LOGI "已取消减少操作"
        pause_return
        return 0
    fi

    reduce_mb=$(parse_size_to_mb "${raw_input}") || {
        LOGE "输入格式不正确, 仅支持 512M、1G、2048 这类格式"
        pause_return
        return 1
    }

    if (( reduce_mb >= current_file_mb )); then
        LOGE "减少值不能大于或等于当前受管 swap 文件大小"
        pause_return
        return 1
    fi

    target_mb=$((current_file_mb - reduce_mb))
    if (( target_mb < min_safe_target_mb )); then
        LOGE "目标大小过小, 至少需要保留 $(format_mb "${min_safe_target_mb}") 以容纳当前已用 Swap 和安全缓冲"
        pause_return
        return 1
    fi

    echo
    echo -e "当前大小: $(format_mb "${current_file_mb}")"
    echo -e "目标大小: $(format_mb "${target_mb}")"
    echo -e "本次减少: $(format_mb "${reduce_mb}")"
    echo -e "重启后生效: 是"
    read -r -p "请再次输入目标大小以确认缩容, 例如 $(format_mb "${target_mb}"): " confirm_input

    confirm_target_mb=$(parse_size_to_mb "${confirm_input}") || {
        LOGE "确认值格式不正确, 已取消本次缩容"
        pause_return
        return 1
    }

    if (( confirm_target_mb != target_mb )); then
        LOGE "确认值与目标值不一致, 已取消本次缩容"
        pause_return
        return 1
    fi

    apply_target_swap_size "${target_mb}"
    pause_return
}

show_menu() {
    while true; do
        echo -e "
  ${green}Alpine虚拟内存管理脚本${plain}
  ${green}1.${plain} 查看当前虚拟内存
  ${green}2.${plain} 增加虚拟内存
  ${green}3.${plain} 减少虚拟内存
  ${green}4.${plain} 退出
"
        show_status_summary
        echo
        read -r -p "请输入选项[1-4]: " menu_choice

        case "${menu_choice}" in
            1) show_current_swap ;;
            2) increase_swap ;;
            3) reduce_swap ;;
            4) exit 0 ;;
            *) LOGE "请输入 1-4 之间的选项" ;;
        esac
    done
}

ensure_environment "$1"
ensure_swap_tools
detect_managed_swap_file
validate_managed_swap_file
show_menu
