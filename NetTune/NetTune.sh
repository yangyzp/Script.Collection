#!/usr/bin/env bash
# ==================================================================
# NetTune.sh v4.4.0 - Linux 生产服务器网络调优脚本
#
# 场景：
#   1. 高并发 Web/API/反向代理
#   2. 通用业务服务器
#   3. 数据库/缓存/长连接服务
#   4. 批处理/大数据任务
#   5. gost 中转/落地代理（用户 -> 中转 -> 落地）
#   6. 多用户直连代理（用户 -> 服务器）
#
# v4.4.0 主要调整：
#   - 保留 /etc/sysctl.conf 单文件集中管理方式
#   - 移除通用 tcp_mem 三档、busy_poll、tcp_notsent_lowat
#   - 不再修改 tcp_syn_retries/tcp_synack_retries
#   - 普通 gost 模式默认不启用 ip_forward/conntrack 专项参数
#   - 模式 5 按两段链路的瓶颈带宽和较大 P95 RTT 计算缓冲区
#   - 模式 6 可输入用户侧 P95 RTT，默认 200ms
#   - TCP rmem/wmem 的 max 计算逻辑与 TCP-Tuning-Simple-Version.sh 一致
#   - tcp_rmem default 固定为 131072，提升新连接的初始接收缓冲区
#   - tcp_wmem 保留系统当前 min/default
#   - 已有更高的 TCP max 不降低，只在计算值更高时提升
#   - 文件句柄、somaxconn、socket max 只升不降
#   - 模式 5、6 可选提高 tcp_mem 全局水位，默认保持内核自动
# ==================================================================

set -Eeuo pipefail
export LC_NUMERIC=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MARKER_START="# >>> NETTUNE_START >>>"
MARKER_END="# <<< NETTUNE_END <<<"
SYSCTL_CONF="/etc/sysctl.conf"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
BACKUP_DIR="/etc/optimize_backup_$(date +%Y%m%d_%H%M%S)"

log_info() {
    echo -e "${BLUE}$1${NC}"
}

log_ok() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

die() {
    echo -e "${RED}✗ $1${NC}" >&2
    exit 1
}

trap 'echo -e "\n\033[0;31m脚本被中断，配置可能不完整，请使用备份目录回滚\033[0m"; exit 1' INT TERM

if [ "$(id -u)" -ne 0 ]; then
    die "必须以 root 权限运行"
fi

for command_name in awk bc cat cp cut free getconf grep mkdir nproc rm sed sysctl touch uname; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少必要命令：$command_name"
done

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

max_int() {
    if [ "$1" -ge "$2" ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "$2"
    fi
}

sysctl_exists() {
    local key_path="/proc/sys/${1//./\/}"
    [ -e "$key_path" ]
}

get_sysctl_uint() {
    local key="$1"
    local fallback="$2"
    local value
    value=$(sysctl -n "$key" 2>/dev/null || true)
    if is_uint "$value"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
    fi
}

read_number() {
    local prompt="$1"
    local default_value="$2"
    local max_value="$3"
    local output_var="$4"
    local value

    while true; do
        if [ -n "$default_value" ]; then
            read -r -p "$prompt [默认 $default_value]: " value
            value=${value:-$default_value}
        else
            read -r -p "$prompt: " value
        fi

        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           [ "$(awk "BEGIN { print ($value > 0 && $value <= $max_value) ? 1 : 0 }")" = "1" ]; then
            printf -v "$output_var" '%s' "$value"
            return
        fi
        log_warn "请输入大于 0 且不超过 $max_value 的数字"
    done
}

# 与 TCP-Tuning-Simple-Version.sh 的 bdp_auto_calculate 保持完全相同：
#   1. BDP(KB) = Mbps × RTT(ms) ÷ 8
#   2. BDP(MB) = BDP(KB) ÷ 1024
#   3. 建议值 = BDP(MB) × 1.5
#   4. 四舍五入到整数 MiB，最小 1 MiB
simple_buffer_mib() {
    local bandwidth="$1"
    local rtt_ms="$2"
    local bdp_kb bdp_mb recommended_mb final_mb

    bdp_kb=$(echo "scale=2; $bandwidth * $rtt_ms / 8" | bc)
    bdp_mb=$(echo "scale=2; $bdp_kb / 1024" | bc)
    recommended_mb=$(echo "scale=2; $bdp_mb * 1.5" | bc)
    final_mb=$(printf "%.0f" "$recommended_mb")

    if [ "$final_mb" -lt 1 ]; then
        final_mb=1
    fi

    printf '%s\n' "$final_mb"
}

kernel_lt() {
    local version_a="$1"
    local version_b="$2"
    local IFS='.'
    local -a a b
    local i av bv

    read -r -a a <<< "$version_a"
    read -r -a b <<< "$version_b"
    for i in 0 1 2; do
        av=${a[$i]:-0}
        bv=${b[$i]:-0}
        (( av < bv )) && return 0
        (( av > bv )) && return 1
    done
    return 1
}

detect_memory_mb() {
    local detected_mb cgroup_bytes cgroup_mb
    detected_mb=$(free -m | awk '/^Mem:/{print $2}')

    if [ -r /sys/fs/cgroup/memory.max ]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory.max)
        if is_uint "$cgroup_bytes" && [ "$cgroup_bytes" -lt 9223372036854771712 ]; then
            cgroup_mb=$(( cgroup_bytes / 1024 / 1024 ))
            [ "$cgroup_mb" -gt 0 ] && [ "$cgroup_mb" -lt "$detected_mb" ] && detected_mb="$cgroup_mb"
        fi
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        if is_uint "$cgroup_bytes" && [ "$cgroup_bytes" -lt 9223372036854771712 ]; then
            cgroup_mb=$(( cgroup_bytes / 1024 / 1024 ))
            [ "$cgroup_mb" -gt 0 ] && [ "$cgroup_mb" -lt "$detected_mb" ] && detected_mb="$cgroup_mb"
        fi
    fi

    printf '%s\n' "$detected_mb"
}

clean_sysctl_params() {
    local target_file="$1"
    local param pattern
    local params=(
        "fs.file-max"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "net.core.netdev_budget"
        "net.core.netdev_budget_usecs"
        "net.ipv4.tcp_syncookies"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_keepalive_time"
        "net.ipv4.tcp_keepalive_intvl"
        "net.ipv4.tcp_keepalive_probes"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.tcp_retries2"
        "net.ipv4.tcp_syn_retries"
        "net.ipv4.tcp_synack_retries"
        "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.conf.default.accept_redirects"
        "net.ipv4.conf.all.send_redirects"
        "net.ipv4.conf.default.send_redirects"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.default.rp_filter"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_mem"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_tw_recycle"
        "net.ipv4.tcp_no_metrics_save"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.tcp_early_retrans"
        "net.ipv4.tcp_reordering"
        "net.core.busy_read"
        "net.core.busy_poll"
        "net.ipv4.tcp_bbr_cwnd_gain"
        "net.ipv4.tcp_bbr_bw_gain"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.tcp_window_scaling"
        "net.ipv4.tcp_sack"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.forwarding"
        "net.netfilter.nf_conntrack_max"
        "net.netfilter.nf_conntrack_tcp_timeout_established"
        "net.netfilter.nf_conntrack_tcp_timeout_time_wait"
    )

    for param in "${params[@]}"; do
        pattern=${param//./\\.}
        sed -i -E "/^[[:space:]#]*${pattern}[[:space:]]*=/d" "$target_file"
    done
}

append_optional_sysctl() {
    local key="$1"
    local value="$2"
    if sysctl_exists "$key"; then
        OPTIONAL_SYSCTL_CONFIG+="
$key = $value"
    fi
}

TOTAL_MEM_MB=$(detect_memory_mb)
CPU_CORES=$(nproc)
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)

if [ "$CPU_CORES" -le 1 ] || [ "$TOTAL_MEM_MB" -le 1024 ]; then
    HARDWARE_TIER="low"
    TIER_DESC="低配模式（1核/小内存优先稳定）"
    SYSTEM_MAX_FILE=131072
    BASE_SOMAXCONN=8192
    NETDEV_MAX_BACKLOG=2048
    NETDEV_BUDGET=300
    NETDEV_BUDGET_USECS=2000
elif [ "$CPU_CORES" -le 3 ] || [ "$TOTAL_MEM_MB" -le 2048 ]; then
    HARDWARE_TIER="mid"
    TIER_DESC="中配模式（性能与资源平衡）"
    SYSTEM_MAX_FILE=262144
    BASE_SOMAXCONN=16384
    NETDEV_MAX_BACKLOG=4096
    NETDEV_BUDGET=300
    NETDEV_BUDGET_USECS=2000
else
    HARDWARE_TIER="high"
    TIER_DESC="高配模式（4核以上且内存充足）"
    SYSTEM_MAX_FILE=524288
    BASE_SOMAXCONN=32768
    NETDEV_MAX_BACKLOG=8192
    NETDEV_BUDGET=600
    NETDEV_BUDGET_USECS=4000
fi

echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE} NetTune.sh v4.4.0 | Linux 生产网络调优${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo -e "CPU：${GREEN}${CPU_CORES} 核${NC}"
echo -e "可用内存判定：${GREEN}${TOTAL_MEM_MB} MiB${NC}"
echo -e "内核：${GREEN}$KERNEL_VERSION${NC}"
echo -e "硬件档位：${GREEN}$TIER_DESC${NC}"
echo ""
echo -e "${YELLOW}请选择业务场景：${NC}"
echo "1. 高并发 Web/API/反向代理"
echo "2. 通用业务服务器（默认）"
echo "3. 数据库/缓存/长连接服务"
echo "4. 批处理/大数据任务"
echo "5. gost 中转/落地代理（用户 -> 中转 -> 落地）"
echo "6. 多用户直连代理（用户 -> 服务器）"
read -r -p "请输入选项 [默认 2]: " SCENARIO
SCENARIO=${SCENARIO:-2}

case "$SCENARIO" in
    1)
        SCENARIO_DESC="高并发 Web/API/反向代理"
        TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=30
        TCP_KEEPALIVE_TIME=300
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=3
        TCP_REORDERING=3
        TCP_TW_REUSE=1
        IP_LOCAL_PORT_RANGE="10000 65535"
        EXPECTED_SOMAXCONN=$(( BASE_SOMAXCONN * 2 ))
        ;;
    2)
        SCENARIO_DESC="通用业务服务器"
        TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=60
        TCP_KEEPALIVE_TIME=600
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=5
        TCP_REORDERING=3
        TCP_TW_REUSE=0
        IP_LOCAL_PORT_RANGE="32768 60999"
        EXPECTED_SOMAXCONN="$BASE_SOMAXCONN"
        ;;
    3)
        SCENARIO_DESC="数据库/缓存/长连接服务"
        TCP_RETRIES2=15
        TCP_FIN_TIMEOUT=60
        TCP_KEEPALIVE_TIME=600
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=5
        TCP_REORDERING=3
        TCP_TW_REUSE=0
        IP_LOCAL_PORT_RANGE="32768 60999"
        EXPECTED_SOMAXCONN="$BASE_SOMAXCONN"
        ;;
    4)
        SCENARIO_DESC="批处理/大数据任务"
        TCP_RETRIES2=15
        TCP_FIN_TIMEOUT=60
        TCP_KEEPALIVE_TIME=600
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=5
        TCP_REORDERING=3
        TCP_TW_REUSE=1
        IP_LOCAL_PORT_RANGE="10000 65535"
        EXPECTED_SOMAXCONN="$BASE_SOMAXCONN"
        ;;
    5)
        SCENARIO_DESC="gost 中转/落地代理"
        TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=30
        TCP_KEEPALIVE_TIME=180
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=3
        TCP_REORDERING=5
        TCP_TW_REUSE=1
        IP_LOCAL_PORT_RANGE="10000 65535"
        EXPECTED_SOMAXCONN=$(( BASE_SOMAXCONN * 2 ))
        ;;
    6)
        SCENARIO_DESC="多用户直连代理"
        TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=30
        TCP_KEEPALIVE_TIME=180
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=3
        TCP_REORDERING=5
        TCP_TW_REUSE=1
        IP_LOCAL_PORT_RANGE="10000 65535"
        EXPECTED_SOMAXCONN=$(( BASE_SOMAXCONN * 2 ))
        ;;
    *)
        log_warn "无效选项，使用模式 2"
        SCENARIO=2
        SCENARIO_DESC="通用业务服务器"
        TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=60
        TCP_KEEPALIVE_TIME=600
        TCP_KEEPALIVE_INTVL=30
        TCP_KEEPALIVE_PROBES=5
        TCP_REORDERING=3
        TCP_TW_REUSE=0
        IP_LOCAL_PORT_RANGE="32768 60999"
        EXPECTED_SOMAXCONN="$BASE_SOMAXCONN"
        ;;
esac

[ "$EXPECTED_SOMAXCONN" -gt 65535 ] && EXPECTED_SOMAXCONN=65535

ENABLE_KERNEL_FORWARDING=0
TCP_MEM_CONFIG=""
TCP_MEM_DESC="内核自动（不写 tcp_mem）"
TCP_MEM_EXPECTED=""

if [ "$SCENARIO" = "5" ] || [ "$SCENARIO" = "6" ]; then
    echo ""
    echo -e "${YELLOW}⚡ TCP 内存余量（仅影响高并发时的全局 TCP 缓冲空间）${NC}"
    echo "1. 内核自动（默认；大多数 200Mbps/少量连接场景足够）"
    echo "2. 高并发代理（仅提高到至少总内存约 1/8）"
    echo "3. 极限代理（仅提高到至少总内存约 1/6；建议专用且内存 ≥4GiB）"
    read -r -p "请输入选项 [默认 1]: " TCP_MEM_MODE
    TCP_MEM_MODE=${TCP_MEM_MODE:-1}

    case "$TCP_MEM_MODE" in
        1)
            ;;
        2)
            TCP_MEM_LOW_DIV=16
            TCP_MEM_PRESSURE_DIV=12
            TCP_MEM_HIGH_DIV=8
            TCP_MEM_DESC="高并发代理（目标 high ≥ 总内存 1/8）"
            ;;
        3)
            if [ "$TOTAL_MEM_MB" -lt 4096 ]; then
                log_warn "内存低于 4GiB，极限代理档改用高并发代理档"
                TCP_MEM_LOW_DIV=16
                TCP_MEM_PRESSURE_DIV=12
                TCP_MEM_HIGH_DIV=8
                TCP_MEM_DESC="高并发代理（内存不足 4GiB，已降级）"
            else
                TCP_MEM_LOW_DIV=12
                TCP_MEM_PRESSURE_DIV=8
                TCP_MEM_HIGH_DIV=6
                TCP_MEM_DESC="极限代理（目标 high ≥ 总内存 1/6）"
            fi
            ;;
        *)
            log_warn "无效选项，保持内核自动"
            TCP_MEM_MODE=1
            ;;
    esac

    if [ "$TCP_MEM_MODE" != "1" ] && sysctl_exists net.ipv4.tcp_mem; then
        PAGE_SIZE=$(getconf PAGESIZE)
        is_uint "$PAGE_SIZE" || die "无法获取系统页大小"
        TOTAL_PAGES=$(( TOTAL_MEM_MB * 1024 * 1024 / PAGE_SIZE ))
        TARGET_TCP_MEM_LOW=$(( TOTAL_PAGES / TCP_MEM_LOW_DIV ))
        TARGET_TCP_MEM_PRESSURE=$(( TOTAL_PAGES / TCP_MEM_PRESSURE_DIV ))
        TARGET_TCP_MEM_HIGH=$(( TOTAL_PAGES / TCP_MEM_HIGH_DIV ))

        read -r CUR_TCP_MEM_LOW CUR_TCP_MEM_PRESSURE CUR_TCP_MEM_HIGH <<< "$(sysctl -n net.ipv4.tcp_mem)"
        for value_name in CUR_TCP_MEM_LOW CUR_TCP_MEM_PRESSURE CUR_TCP_MEM_HIGH; do
            value=${!value_name}
            is_uint "$value" || die "无法解析当前 tcp_mem：$value_name=$value"
        done

        FINAL_TCP_MEM_LOW=$(max_int "$CUR_TCP_MEM_LOW" "$TARGET_TCP_MEM_LOW")
        FINAL_TCP_MEM_PRESSURE=$(max_int "$CUR_TCP_MEM_PRESSURE" "$TARGET_TCP_MEM_PRESSURE")
        FINAL_TCP_MEM_HIGH=$(max_int "$CUR_TCP_MEM_HIGH" "$TARGET_TCP_MEM_HIGH")
        TCP_MEM_EXPECTED="$FINAL_TCP_MEM_LOW $FINAL_TCP_MEM_PRESSURE $FINAL_TCP_MEM_HIGH"
        TCP_MEM_CONFIG="net.ipv4.tcp_mem = $TCP_MEM_EXPECTED"
    elif [ "$TCP_MEM_MODE" != "1" ]; then
        log_warn "当前内核不支持 tcp_mem，保持内核默认"
        TCP_MEM_DESC="内核自动（当前内核不支持 tcp_mem）"
    fi
fi

echo ""
if [ "$SCENARIO" = "5" ]; then
    echo -e "${YELLOW}模式 5 使用整条中转链路的瓶颈带宽和较大 P95 RTT。${NC}"
    read_number "两段链路的瓶颈单连接带宽 Mbps" "100" "10000" BANDWIDTH
    read_number "两段链路中较大的 P95 RTT ms" "100" "1000" RTT_MS
    FINAL_BUFFER_MB=$(simple_buffer_mib "$BANDWIDTH" "$RTT_MS")
    BANDWIDTH_DISPLAY="${BANDWIDTH}Mbps"
    RTT_DISPLAY="${RTT_MS}ms"

    echo ""
    read -r -p "是否使用 TUN/NAT/透明代理，需要内核转发？[y/N]: " forward_answer
    case "$forward_answer" in
        y|Y|yes|YES)
            ENABLE_KERNEL_FORWARDING=1
            ;;
    esac
else
    read_number "服务器最大单连接期望带宽 Mbps" "100" "10000" BANDWIDTH
    if [ "$SCENARIO" = "6" ]; then
        read_number "用户到服务器的 P95 RTT ms" "200" "1000" RTT_MS
    else
        read_number "主要链路的 P95 RTT ms" "100" "1000" RTT_MS
    fi
    FINAL_BUFFER_MB=$(simple_buffer_mib "$BANDWIDTH" "$RTT_MS")
    BANDWIDTH_DISPLAY="${BANDWIDTH}Mbps"
    RTT_DISPLAY="${RTT_MS}ms"
fi

DESIRED_BUFFER_BYTES=$(( FINAL_BUFFER_MB * 1024 * 1024 ))

# Simple 版只计算 max；rmem default 固定 131072，其他值尽量保留。
read -r CUR_TCP_RMEM_MIN CUR_TCP_RMEM_DEFAULT CUR_TCP_RMEM_MAX <<< "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo '4096 131072 6291456')"
read -r CUR_TCP_WMEM_MIN CUR_TCP_WMEM_DEFAULT CUR_TCP_WMEM_MAX <<< "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo '4096 16384 4194304')"
for value_name in CUR_TCP_RMEM_MIN CUR_TCP_RMEM_DEFAULT CUR_TCP_RMEM_MAX CUR_TCP_WMEM_MIN CUR_TCP_WMEM_DEFAULT CUR_TCP_WMEM_MAX; do
    value=${!value_name}
    is_uint "$value" || die "无法解析系统 TCP 缓冲区参数：$value_name=$value"
done

TCP_RMEM_MAX=$(max_int "$CUR_TCP_RMEM_MAX" "$DESIRED_BUFFER_BYTES")
TCP_WMEM_MAX=$(max_int "$CUR_TCP_WMEM_MAX" "$DESIRED_BUFFER_BYTES")
CORE_RMEM_CURRENT=$(get_sysctl_uint net.core.rmem_max 212992)
CORE_WMEM_CURRENT=$(get_sysctl_uint net.core.wmem_max 212992)
CORE_RMEM_MAX=$(max_int "$CORE_RMEM_CURRENT" "$TCP_RMEM_MAX")
CORE_WMEM_MAX=$(max_int "$CORE_WMEM_CURRENT" "$TCP_WMEM_MAX")

TCP_RMEM_EXPECTED="$CUR_TCP_RMEM_MIN 131072 $TCP_RMEM_MAX"
TCP_WMEM_EXPECTED="$CUR_TCP_WMEM_MIN $CUR_TCP_WMEM_DEFAULT $TCP_WMEM_MAX"

CURRENT_FS_FILE_MAX=$(get_sysctl_uint fs.file-max 0)
TARGET_FS_FILE_MAX=$(( SYSTEM_MAX_FILE * 4 ))
EXPECTED_FS_FILE_MAX=$(max_int "$CURRENT_FS_FILE_MAX" "$TARGET_FS_FILE_MAX")
CURRENT_SOMAXCONN=$(get_sysctl_uint net.core.somaxconn 4096)
EXPECTED_SOMAXCONN=$(max_int "$CURRENT_SOMAXCONN" "$EXPECTED_SOMAXCONN")

OPTIONAL_SYSCTL_CONFIG=""
append_optional_sysctl net.ipv4.tcp_window_scaling 1
append_optional_sysctl net.ipv4.tcp_sack 1
append_optional_sysctl net.ipv4.tcp_timestamps 1
append_optional_sysctl net.ipv4.tcp_mtu_probing 1
append_optional_sysctl net.ipv4.tcp_early_retrans 3
append_optional_sysctl net.ipv4.tcp_reordering "$TCP_REORDERING"
append_optional_sysctl net.ipv4.tcp_slow_start_after_idle 1
append_optional_sysctl net.core.busy_read 0
append_optional_sysctl net.core.busy_poll 0

BBR_CONFIG=""
BBR_ENABLED=0
if ! kernel_lt "$KERNEL_VERSION" "4.9"; then
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null || true
    command -v modprobe >/dev/null 2>&1 && modprobe sch_fq 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_CONFIG="net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
        BBR_ENABLED=1
    else
        log_warn "当前内核没有可用的 BBR，将保留系统拥塞控制算法"
    fi
else
    log_warn "内核低于 4.9，不支持 BBR"
fi

FORWARDING_CONFIG=""
CONNTRACK_MAX_DISPLAY=""
if [ "$SCENARIO" = "5" ] && [ "$ENABLE_KERNEL_FORWARDING" -eq 1 ]; then
    FORWARDING_CONFIG="net.ipv4.ip_forward = 1"
    command -v modprobe >/dev/null 2>&1 && modprobe nf_conntrack 2>/dev/null || true
    if sysctl_exists net.netfilter.nf_conntrack_max; then
        CURRENT_CONNTRACK_MAX=$(get_sysctl_uint net.netfilter.nf_conntrack_max 65536)
        TARGET_CONNTRACK_MAX=$(( TOTAL_MEM_MB * 64 ))
        [ "$TARGET_CONNTRACK_MAX" -lt 65536 ] && TARGET_CONNTRACK_MAX=65536
        FINAL_CONNTRACK_MAX=$(max_int "$CURRENT_CONNTRACK_MAX" "$TARGET_CONNTRACK_MAX")
        FORWARDING_CONFIG+="
net.netfilter.nf_conntrack_max = $FINAL_CONNTRACK_MAX"
        CONNTRACK_MAX_DISPLAY="$FINAL_CONNTRACK_MAX"
    fi
fi

echo ""
log_info "正在备份配置..."
mkdir -p "$BACKUP_DIR"
[ -e "$SYSCTL_CONF" ] || touch "$SYSCTL_CONF"
[ -e "$LIMITS_CONF" ] || touch "$LIMITS_CONF"
[ -e "$SYSTEMD_CONF" ] || touch "$SYSTEMD_CONF"
cp "$SYSCTL_CONF" "$BACKUP_DIR/sysctl.conf" || die "sysctl.conf 备份失败"
cp "$LIMITS_CONF" "$BACKUP_DIR/limits.conf" || die "limits.conf 备份失败"
cp "$SYSTEMD_CONF" "$BACKUP_DIR/system.conf" || die "system.conf 备份失败"
log_ok "备份完成：$BACKUP_DIR"

echo ""
log_info "清理历史 NetTune 配置和同名参数..."
sed -i "/$MARKER_START/,/$MARKER_END/d" "$SYSCTL_CONF"
clean_sysctl_params "$SYSCTL_CONF"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$LIMITS_CONF"

shopt -s nullglob
for config_file in /etc/sysctl.d/*.conf; do
    if grep -qF "$MARKER_START" "$config_file" 2>/dev/null; then
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$config_file"
        echo "  已清理 $config_file 中的历史 NetTune 块"
    fi
done

CONFLICT_PARAMS='fs[.]file-max|net[.]core[.]somaxconn|net[.]ipv4[.]tcp_congestion_control|net[.]core[.]default_qdisc|net[.]ipv4[.]tcp_rmem|net[.]ipv4[.]tcp_wmem'
for config_file in /etc/sysctl.d/*.conf; do
    if grep -qE "^[[:space:]]*(${CONFLICT_PARAMS})[[:space:]]*=" "$config_file" 2>/dev/null; then
        log_warn "$config_file 中存在可能覆盖本脚本的参数，请手动确认加载顺序"
    fi
done
shopt -u nullglob

if [ -f /etc/sysctl.d/99-high-concurrency.conf ]; then
    rm -f /etc/sysctl.d/99-high-concurrency.conf
    echo "  已删除 /etc/sysctl.d/99-high-concurrency.conf"
fi

echo ""
log_info "设置文件句柄限制..."
cat >> "$LIMITS_CONF" <<EOF
$MARKER_START
* soft nofile $SYSTEM_MAX_FILE
* hard nofile $SYSTEM_MAX_FILE
root soft nofile $SYSTEM_MAX_FILE
root hard nofile $SYSTEM_MAX_FILE
$MARKER_END
EOF

if command -v systemctl >/dev/null 2>&1; then
    # 清理由旧版 NetTune 写入的全局 NPROC 值；进程数应由具体服务管理。
    sed -i -E '/^[#[:space:]]*DefaultLimitNPROC=65535[[:space:]]*$/d' "$SYSTEMD_CONF"
    sed -i -E "s/^[#[:space:]]*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=$SYSTEM_MAX_FILE/" "$SYSTEMD_CONF"
    if ! grep -qE '^[[:space:]]*DefaultLimitNOFILE=' "$SYSTEMD_CONF"; then
        echo "DefaultLimitNOFILE=$SYSTEM_MAX_FILE" >> "$SYSTEMD_CONF"
    fi
    systemctl daemon-reexec 2>/dev/null || log_warn "systemd daemon-reexec 执行失败"
fi

TCP_TW_REUSE_CONFIG=""
if [ "$TCP_TW_REUSE" -eq 1 ]; then
    TCP_TW_REUSE_CONFIG="net.ipv4.tcp_tw_reuse = 1"
fi

echo ""
log_info "写入 $SYSCTL_CONF ..."
cat >> "$SYSCTL_CONF" <<EOF
$MARKER_START
# =====================================================
# NetTune.sh v4.4.0
# 场景：$SCENARIO_DESC
# 硬件：$TIER_DESC
# 带宽：$BANDWIDTH_DISPLAY
# RTT：$RTT_DISPLAY
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# =====================================================

# 系统容量（只升不降）
fs.file-max = $EXPECTED_FS_FILE_MAX
net.core.somaxconn = $EXPECTED_SOMAXCONN

# 网络接收软中断预算
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.core.netdev_budget = $NETDEV_BUDGET
net.core.netdev_budget_usecs = $NETDEV_BUDGET_USECS

# TCP 基础配置
net.ipv4.tcp_syncookies = 1
$TCP_TW_REUSE_CONFIG
net.ipv4.tcp_fin_timeout = $TCP_FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $TCP_KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $TCP_KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $TCP_KEEPALIVE_PROBES
net.ipv4.ip_local_port_range = $IP_LOCAL_PORT_RANGE
net.ipv4.tcp_retries2 = $TCP_RETRIES2

# 禁用 ICMP 重定向；宽松反向路径检查兼容多出口/Docker/TUN
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# TCP 缓冲区：Simple 版算法计算 max，rmem default 固定 131072
net.core.rmem_max = $CORE_RMEM_MAX
net.core.wmem_max = $CORE_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_EXPECTED
net.ipv4.tcp_wmem = $TCP_WMEM_EXPECTED
$OPTIONAL_SYSCTL_CONFIG

# 模式 5、6 的可选 TCP 内存余量
$TCP_MEM_CONFIG

# 拥塞控制
$BBR_CONFIG

# 仅模式 5 明确选择 TUN/NAT/透明转发时生成
$FORWARDING_CONFIG
$MARKER_END
EOF

echo ""
log_info "应用内核配置..."
set +e
SYSCTL_OUTPUT=$(sysctl -p "$SYSCTL_CONF" 2>&1)
SYSCTL_STATUS=$?
set -e

if [ "$SYSCTL_STATUS" -ne 0 ]; then
    log_warn "部分参数应用失败："
    echo "$SYSCTL_OUTPUT"
else
    log_ok "sysctl 参数已应用"
fi

echo ""
echo -e "${BLUE}=======================================================${NC}"
echo -e "${GREEN}NetTune.sh v4.4.0 部署完成${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo "场景：$SCENARIO_DESC"
echo "硬件：$TIER_DESC"
echo "带宽：$BANDWIDTH_DISPLAY"
echo "RTT：$RTT_DISPLAY"
echo "计算缓冲区 max：${FINAL_BUFFER_MB} MiB（TCP-Tuning-Simple-Version 算法）"
echo "最终 tcp_rmem：$TCP_RMEM_EXPECTED"
echo "最终 tcp_wmem：$TCP_WMEM_EXPECTED"
echo "TCP 内存余量：$TCP_MEM_DESC"
[ -n "$TCP_MEM_EXPECTED" ] && echo "最终 tcp_mem：$TCP_MEM_EXPECTED"
echo "somaxconn：$EXPECTED_SOMAXCONN"
echo "nofile：$SYSTEM_MAX_FILE"

if [ "$BBR_ENABLED" -eq 1 ]; then
    echo "拥塞控制：BBR + fq（新建连接生效）"
else
    echo "拥塞控制：保留系统当前设置"
fi

if [ "$SCENARIO" = "5" ]; then
    if [ "$ENABLE_KERNEL_FORWARDING" -eq 1 ]; then
        echo "内核转发：已启用"
        [ -n "$CONNTRACK_MAX_DISPLAY" ] && echo "conntrack_max：$CONNTRACK_MAX_DISPLAY"
    else
        echo "内核转发：未启用（普通 gost 用户态中转不需要）"
    fi
fi

echo ""
echo -e "${YELLOW}验证命令：${NC}"
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  sysctl net.core.default_qdisc"
echo "  tc qdisc show 2>/dev/null"
echo "  sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem"
if [ -n "$TCP_MEM_EXPECTED" ]; then
    echo "  sysctl net.ipv4.tcp_mem"
    echo "  nstat -az 2>/dev/null | grep -E 'TCPMemoryPressures|TCPMemoryPressuresChrono'"
fi
echo "  ss -s"
echo "  nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpOutSegs|TCPLostRetransmit'"
echo "  cat /proc/net/softnet_stat"
if [ "$SCENARIO" = "5" ]; then
    echo "  建议分别测试用户到中转、中转到落地，再填瓶颈带宽和较大 P95 RTT"
fi

echo ""
echo -e "${YELLOW}生效说明：${NC}"
echo "1. 重新登录 SSH 后，PAM 文件句柄限制才会更新"
echo "2. 重启 gost/Nginx/数据库等服务，使新连接使用新参数"
echo "3. 建议维护窗口重启服务器，以恢复已移除旧参数的内核运行时默认值"
echo "4. fq 是默认 qdisc 设置；请以 tc qdisc show 的实际输出为准"

echo ""
echo -e "${YELLOW}回滚命令：${NC}"
echo "  cp $BACKUP_DIR/sysctl.conf /etc/sysctl.conf"
echo "  cp $BACKUP_DIR/limits.conf /etc/security/limits.conf"
echo "  cp $BACKUP_DIR/system.conf /etc/systemd/system.conf"
echo "  sysctl -p /etc/sysctl.conf"
echo "  systemctl daemon-reexec"
echo ""
echo "备份目录：$BACKUP_DIR"
