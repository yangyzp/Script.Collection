#!/bin/bash
# ==================== 依赖检查与安装 ====================
if ! command -v bc &>/dev/null || ! command -v iperf3 &>/dev/null; then
    echo "检测到缺少必要依赖 (bc, iperf3)，正在自动安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq bc iperf3
    elif command -v yum &>/dev/null; then
        yum install -y -q bc iperf3
    elif command -v dnf &>/dev/null; then
        dnf install -y -q bc iperf3
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm bc iperf3
    else
        echo "错误：未检测到支持的包管理器，请手动安装 bc 和 iperf3"
        exit 1
    fi
    echo "✓ 依赖安装完成"
fi
# ==================== 依赖检查结束 ====================
# Linux 生产级智能优化脚本 v3.4.2 (代理场景专项优化版)
# 更新：代理场景参数全面审核修正，修复tcp_mem偏小问题，新增conntrack适配
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
# 自动检测硬件信息
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
# ==================== 硬件档位自动判定 ====================
# 低配：1核及以下 或 内存≤1G → 极致降CPU，优先稳定性
# 中配：2核 或 1G<内存≤2G → 平衡性能与CPU占用
# 高配：4核及以上 或 内存>2G → 全性能模式
if [ $CPU_CORES -le 1 ] || [ $TOTAL_MEM_MB -le 1024 ]; then
    HARDWARE_TIER="low"
    TIER_DESC="低配模式 (低CPU优先)"
    SYSTEM_MAX_FILE=131072
    EXPECTED_SOMAXCONN=32768
    FS_FILE_MAX_CEILING=524288
    NETDEV_BUDGET=150
    NETDEV_MAX_BACKLOG=2048
    BBR_CWND_GAIN=1.7
    BBR_BW_GAIN=1.25
    BUSY_POLL_ENABLE=0
elif [ $CPU_CORES -le 2 ] || [ $TOTAL_MEM_MB -le 2048 ]; then
    HARDWARE_TIER="mid"
    TIER_DESC="中配模式 (性能平衡)"
    SYSTEM_MAX_FILE=262144
    EXPECTED_SOMAXCONN=65535
    FS_FILE_MAX_CEILING=1048576
    NETDEV_BUDGET=300
    NETDEV_MAX_BACKLOG=4096
    BBR_CWND_GAIN=2.0
    BBR_BW_GAIN=1.25
    BUSY_POLL_ENABLE=0
else
    HARDWARE_TIER="high"
    TIER_DESC="高配模式 (满速优先)"
    SYSTEM_MAX_FILE=524288
    EXPECTED_SOMAXCONN=131072
    FS_FILE_MAX_CEILING=2097152
    NETDEV_BUDGET=600
    NETDEV_MAX_BACKLOG=8192
    BBR_CWND_GAIN=2.0
    BBR_BW_GAIN=1.25
    BUSY_POLL_ENABLE=1
fi
# 应用分级推荐值
NGINX_GENERAL=$EXPECTED_SOMAXCONN
NGINX_HIGH=$(( EXPECTED_SOMAXCONN * 2 ))
MYSQL_GENERAL=$EXPECTED_SOMAXCONN
PHP_GENERAL=$EXPECTED_SOMAXCONN
REDIS_GENERAL=10000
REDIS_HIGH=20000
# 自动计算fs.file-max（按档位适配系数）
FILE_MAX_FACTOR=100
[ "$HARDWARE_TIER" = "mid" ] && FILE_MAX_FACTOR=150
[ "$HARDWARE_TIER" = "high" ] && FILE_MAX_FACTOR=200
EXPECTED_FS_FILE_MAX=$(( TOTAL_MEM_MB * FILE_MAX_FACTOR ))
if [ $EXPECTED_FS_FILE_MAX -gt $FS_FILE_MAX_CEILING ]; then
    EXPECTED_FS_FILE_MAX=$FS_FILE_MAX_CEILING
fi
# ==================== 核心函数 ====================
kernel_lt() {
    local IFS='.'
    read -ra KV <<< "$1"
    read -ra CV <<< "$2"
    (( KV[0] < CV[0] )) && return 0
    (( KV[0] > CV[0] )) && return 1
    (( KV[1] < CV[1] )) && return 0
    (( KV[1] > CV[1] )) && return 1
    (( KV[2] < CV[2] )) && return 0
    return 1
}
# 清理所有重复的内核参数
clean_sysctl_params() {
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
        "net.core.rmem_default"
        "net.core.wmem_default"
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
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.forwarding"
        "net.netfilter.nf_conntrack_max"
        "net.netfilter.nf_conntrack_tcp_timeout_established"
        "net.netfilter.nf_conntrack_tcp_timeout_time_wait"
    )
    for param in "${params[@]}"; do
        sed -i "/^[#]*\s*$param\s*=/d" "$1"
    done
}
# ==================== 主程序开始 ====================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：必须以 root 权限运行${NC}"
    exit 1
fi
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  Linux 生产级智能优化脚本 v3.4.2 | 代理场景专项优化${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}📊 服务器硬件检测${NC}"
echo -e "CPU核心数：${GREEN}${CPU_CORES} 核${NC}"
echo -e "内存总大小：${GREEN}${TOTAL_MEM_MB} MB${NC}"
echo -e "硬件档位：${GREEN}${TIER_DESC}${NC}"
echo -e "自动计算系统句柄上限：${GREEN}${EXPECTED_FS_FILE_MAX}${NC}"
echo -e "单进程最大句柄：${GREEN}${SYSTEM_MAX_FILE}${NC}"
echo ""
echo -e "${YELLOW}🎯 选择业务场景${NC}"
echo "1. 高并发Web/API/反向代理"
echo "2. 通用业务服务器 (默认)"
echo "3. 数据库/缓存/长连接服务"
echo "4. 批处理/大数据任务"
echo "5. 代理网络/流量转发/视频代理 ✅ 专项优化"
echo "6. 全国多用户公网接入/通用Web服务"
read -p "请输入选项(1-6，默认2): " SCENARIO
SCENARIO=${SCENARIO:-2}
# 场景参数初始化
NETDEV_BUDGET_USECS=4000
TCP_KEEPALIVE_TIME=200
TCP_EARLY_RETRANS=2
TCP_REORDERING=8
TCP_SLOW_START=0
TCP_NOTSENT_LOWAT=16384
case $SCENARIO in
    1)
        EXPECTED_TCP_RETRIES2=4
        TCP_FIN_TIMEOUT=10
        SCENARIO_DESC="高并发Web/API/反向代理"
        ;;
    2)
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=12
        SCENARIO_DESC="通用业务服务器"
        ;;
    3)
        EXPECTED_TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=20
        SCENARIO_DESC="数据库/缓存/长连接服务"
        ;;
    4)
        EXPECTED_TCP_RETRIES2=10
        TCP_FIN_TIMEOUT=30
        SCENARIO_DESC="批处理/大数据任务"
        ;;
    5)
        EXPECTED_TCP_RETRIES2=4
        TCP_FIN_TIMEOUT=8
        TCP_KEEPALIVE_TIME=100
        TCP_EARLY_RETRANS=2
        TCP_REORDERING=8
        TCP_SLOW_START=0
        TCP_NOTSENT_LOWAT=16384
        SCENARIO_DESC="代理网络/流量转发/视频代理"
        ;;
    6)
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=12
        TCP_KEEPALIVE_TIME=180
        TCP_EARLY_RETRANS=2
        TCP_REORDERING=5
        TCP_SLOW_START=1
        TCP_NOTSENT_LOWAT=-1
        BUSY_POLL_ENABLE=0
        SCENARIO_DESC="全国多用户公网接入/通用Web服务"
        ;;
    *)
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=12
        SCENARIO_DESC="通用业务服务器"
        ;;
esac
BACKUP_DIR="/etc/optimize_backup_$(date +%Y%m%d_%H%M%S)"
SYSCTL_CONF="/etc/sysctl.conf"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
MARKER_START="# >>> LINUX_OPT_START >>>"
MARKER_END="# <<< LINUX_OPT_END <<<"
TCP_RMEM_EXPECTED=""
TCP_WMEM_EXPECTED=""
TCP_MEM_EXPECTED=""
BBR_ENABLED=0
PROXY_EXTRA_CONFIG=""
BUSY_POLL_CONFIG=""
CONNTRACK_CONFIG=""
echo -e "${YELLOW}1. 备份原始配置...${NC}"
mkdir -p "$BACKUP_DIR"
cp "$LIMITS_CONF" "$BACKUP_DIR/"
cp "$SYSTEMD_CONF" "$BACKUP_DIR/"
cp "$SYSCTL_CONF" "$BACKUP_DIR/"
echo -e "${GREEN}✓ 备份完成：$BACKUP_DIR${NC}"
echo ""
echo -e "${YELLOW}2. 深度清理历史配置（自动去重）...${NC}"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$LIMITS_CONF"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$SYSCTL_CONF"
clean_sysctl_params "$SYSCTL_CONF"
[ -f "/etc/sysctl.d/99-high-concurrency.conf" ] && rm -f "/etc/sysctl.d/99-high-concurrency.conf"
echo -e "${GREEN}✓ 所有历史配置已清理${NC}"
echo ""
echo -e "${YELLOW}3. 设置系统文件句柄上限...${NC}"
cat >> "$LIMITS_CONF" << EOF
$MARKER_START
* soft nofile $SYSTEM_MAX_FILE
* hard nofile $SYSTEM_MAX_FILE
root soft nofile $SYSTEM_MAX_FILE
root hard nofile $SYSTEM_MAX_FILE
* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
$MARKER_END
EOF
echo -e "${GREEN}✓ 单进程句柄上限：$SYSTEM_MAX_FILE${NC}"
echo -e "${YELLOW}4. 配置systemd全局限制...${NC}"
if command -v systemctl &>/dev/null; then
    sed -i "s/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=$SYSTEM_MAX_FILE/" "$SYSTEMD_CONF"
    sed -i "s/^#*DefaultLimitNPROC=.*/DefaultLimitNPROC=65535/" "$SYSTEMD_CONF"
    if ! grep -q "^DefaultLimitNOFILE=" "$SYSTEMD_CONF"; then
        echo "DefaultLimitNOFILE=$SYSTEM_MAX_FILE" >> "$SYSTEMD_CONF"
    fi
    if ! grep -q "^DefaultLimitNPROC=" "$SYSTEMD_CONF"; then
        echo "DefaultLimitNPROC=65535" >> "$SYSTEMD_CONF"
    fi
    systemctl daemon-reexec 2>/dev/null
    echo -e "${GREEN}✓ systemd已配置完成${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到systemd，跳过${NC}"
fi
echo ""
echo -e "${YELLOW}5. TCP缓冲区自动计算${NC}"
TCP_BUFFER_CONFIG=""
AUTO_CALC_DONE=0

# ========== 场景6：全国多用户，免RTT输入，保守自动配置 ==========
if [[ "$SCENARIO" == "6" ]]; then
    # 仅输入服务器出口带宽
    while true; do
        read -p "输入服务器带宽(Mbps，如70/100/500): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]*\.?[0-9]+$ ]] && (( $(echo "$BANDWIDTH > 0 && $BANDWIDTH <= 10000" | bc -l) )); then
            break
        fi
        echo -e "${RED}请输入有效带宽数字(0~10000)${NC}"
    done

    RTT_MS="自适应"
    SAFE_FACTOR=1.2

    # 按硬件档位设定保守缓冲区上限
    if [ "$HARDWARE_TIER" = "low" ]; then
        final_mb=4
    elif [ "$HARDWARE_TIER" = "mid" ]; then
        final_mb=8
    else
        final_mb=16
    fi
    # 100M以下小带宽再减半，进一步避免队列积压
    if (( $(echo "$BANDWIDTH <= 100" | bc -l) )); then
        final_mb=$(( final_mb / 2 ))
        [ "$final_mb" -lt 1 ] && final_mb=1
    fi

    value_bytes=$(( final_mb * 1024 * 1024 ))
    echo -e "${BLUE}  多用户场景：内核自动适配各地区链路RTT，采用保守缓冲区上限${NC}"
    echo -e "${GREEN}✓ 缓冲区上限设定：${final_mb}MiB${NC}"

# ========== 其他场景：保留带宽+RTT输入，BDP精确计算 ==========
else
    # 带宽手动输入
    while true; do
        read -p "输入服务器带宽(Mbps，如70/100/500): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]*\.?[0-9]+$ ]] && (( $(echo "$BANDWIDTH > 0 && $BANDWIDTH <= 10000" | bc -l) )); then
            break
        fi
        echo -e "${RED}请输入有效带宽数字(0~10000)${NC}"
    done
    # RTT延迟输入校验
    while true; do
        read -p "输入平均延迟(ms，如50/100/200): " RTT_MS
        if [[ "$RTT_MS" =~ ^[0-9]*\.?[0-9]+$ ]] && (( $(echo "$RTT_MS > 0 && $RTT_MS <= 1000" | bc -l) )); then
            break
        fi
        echo -e "${RED}请输入有效延迟数字(0~1000)${NC}"
    done
    # BDP标准计算公式
    bdp_kb=$(echo "scale=4; $BANDWIDTH * $RTT_MS / 8" | bc)
    bdp_mb=$(echo "scale=4; $bdp_kb / 1024" | bc)
    # 安全系数：按带宽分档，优先控制队列积压与丢包
    if (( $(echo "$BANDWIDTH <= 100" | bc -l) )); then
        SAFE_FACTOR=1.2
    elif (( $(echo "$BANDWIDTH <= 500" | bc -l) )); then
        SAFE_FACTOR=1.4
    elif (( $(echo "$BANDWIDTH <= 1000" | bc -l) )); then
        SAFE_FACTOR=1.6
    else
        SAFE_FACTOR=1.8
    fi
    # 内存自适应封顶
    recommended_mb=$(echo "scale=2; $bdp_mb * $SAFE_FACTOR" | bc)
    final_mb=$(printf "%.0f" "$recommended_mb")
    if [ "$final_mb" -lt 1 ]; then
        final_mb=1
    fi
    value_bytes=$(echo "$final_mb * 1024 * 1024" | bc)
    # 缓冲区硬封顶（按硬件档位）
    if [ "$HARDWARE_TIER" = "low" ]; then
        MAX_BUFFER_BYTES=$(( 8 * 1024 * 1024 ))
    elif [ "$HARDWARE_TIER" = "mid" ]; then
        MAX_BUFFER_BYTES=$(( 16 * 1024 * 1024 ))
    else
        MAX_BUFFER_BYTES=$(( 32 * 1024 * 1024 ))
    fi
    if [ $value_bytes -gt $MAX_BUFFER_BYTES ]; then
        value_bytes=$MAX_BUFFER_BYTES
        final_mb=$(( MAX_BUFFER_BYTES / 1024 / 1024 ))
    fi
    echo -e "${BLUE}  安全系数：${SAFE_FACTOR}倍${NC}"
    echo -e "${GREEN}✓ BDP缓冲区计算完成，最终上限：${final_mb}MiB${NC}"
fi

# 三段式缓冲区（收发对称，通用逻辑）
TCP_RMEM_MIN=4096
TCP_WMEM_MIN=4096
calc_default=$(echo "$value_bytes / 4" | bc)
if [ $calc_default -lt 87380 ]; then
    TCP_RMEM_DEFAULT=87380
    TCP_WMEM_DEFAULT=87380
else
    TCP_RMEM_DEFAULT=$calc_default
    TCP_WMEM_DEFAULT=$calc_default
fi
TCP_RMEM_MAX=$value_bytes
TCP_WMEM_MAX=$value_bytes
TCP_RMEM_EXPECTED="$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX"
TCP_WMEM_EXPECTED="$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"
AUTO_CALC_DONE=1

TCP_BUFFER_CONFIG="# TCP 缓冲区优化 (${SCENARIO_DESC} | ${BANDWIDTH}Mbps @ ${RTT_MS}ms)
# 安全放大${SAFE_FACTOR}倍 | 最终设置${final_mb}MiB
net.core.rmem_default = $TCP_RMEM_DEFAULT
net.core.wmem_default = $TCP_WMEM_DEFAULT
net.core.rmem_max = $TCP_RMEM_MAX
net.core.wmem_max = $TCP_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_EXPECTED
net.ipv4.tcp_wmem = $TCP_WMEM_EXPECTED
# 重传与乱序优化
net.ipv4.tcp_early_retrans = $TCP_EARLY_RETRANS
net.ipv4.tcp_reordering = $TCP_REORDERING
net.ipv4.tcp_slow_start_after_idle = $TCP_SLOW_START
net.ipv4.tcp_notsent_lowat = $TCP_NOTSENT_LOWAT"

# 高配机才开启busy poll，低配/多用户场景默认关闭省CPU
if [ $BUSY_POLL_ENABLE -eq 1 ]; then
    BUSY_POLL_CONFIG="# 高配低延迟优化（CPU占用较高，仅局域网推荐）
net.core.busy_read = 512
net.core.busy_poll = 512"
fi

# ========== 全局TCP内存限制（按系统总内存动态计算，修复原固定值偏小问题） ==========
# 单位：页，1页=4KB；比例：总内存的1/16(低压)、1/12(压力)、1/8(上限)
total_pages=$(( TOTAL_MEM_MB * 1024 / 4 ))
tcp_mem_low=$(( total_pages / 16 ))
tcp_mem_pressure=$(( total_pages / 12 ))
tcp_mem_high=$(( total_pages / 8 ))
TCP_MEM_EXPECTED="$tcp_mem_low $tcp_mem_pressure $tcp_mem_high"

# 500M以上大带宽额外放宽10%
if (( $(echo "$BANDWIDTH >= 500" | bc -l) )); then
    tcp_mem_low=$(echo "$tcp_mem_low * 1.1" | bc | xargs printf "%.0f")
    tcp_mem_pressure=$(echo "$tcp_mem_pressure * 1.1" | bc | xargs printf "%.0f")
    tcp_mem_high=$(echo "$tcp_mem_high * 1.1" | bc | xargs printf "%.0f")
    TCP_MEM_EXPECTED="$tcp_mem_low $tcp_mem_pressure $tcp_mem_high"
fi

TCP_BUFFER_CONFIG="$TCP_BUFFER_CONFIG
$BUSY_POLL_CONFIG
net.ipv4.tcp_mem = $TCP_MEM_EXPECTED"

# ========== 代理场景专属参数 ==========
if [[ "$SCENARIO" == "5" ]]; then
    PROXY_EXTRA_CONFIG="# 代理中转专属优化
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1"

    # 自动检测并配置conntrack连接跟踪表
    if lsmod | grep -q nf_conntrack || modprobe nf_conntrack 2>/dev/null; then
        # 连接跟踪表上限按内存配比：每1MB内存约8条连接
        conntrack_max=$(( TOTAL_MEM_MB * 8 ))
        [ $conntrack_max -lt 8192 ] && conntrack_max=8192
        CONNTRACK_CONFIG="# 连接跟踪表优化（四层转发/代理必备）
net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120"
        echo -e "${GREEN}✓ 已检测到nf_conntrack模块，同步优化连接跟踪表${NC}"
    fi
fi
echo ""
echo -e "${YELLOW}6. 自动配置BBR+fq拥塞控制${NC}"
BBR_CONFIG=""
if ! kernel_lt "$KERNEL_VERSION" "4.9"; then
    modprobe tcp_bbr 2>/dev/null
    modprobe sch_fq 2>/dev/null
    if lsmod | grep -q bbr; then
        BBR_CONFIG="# BBR 拥塞控制 + fq 队列（${TIER_DESC}）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# BBR增益分档
net.ipv4.tcp_bbr_cwnd_gain = $BBR_CWND_GAIN
net.ipv4.tcp_bbr_bw_gain = $BBR_BW_GAIN"
        BBR_ENABLED=1
        echo -e "${GREEN}✓ 内核支持，已启用BBR+fq${NC}"
    else
        echo -e "${YELLOW}⚠ BBR模块加载失败，将使用默认拥塞控制${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 内核版本低于4.9，不支持BBR，建议升级内核${NC}"
fi
echo ""
echo -e "${YELLOW}7. 写入内核优化配置...${NC}"
cat >> "$SYSCTL_CONF" << EOF
$MARKER_START
# ==============================================
# Linux 内核优化配置
# 业务场景：$SCENARIO_DESC
# 硬件档位：$TIER_DESC
# 带宽适配：${BANDWIDTH}Mbps | 延迟适配：${RTT_MS}ms
# 自动生成于：$(date '+%Y-%m-%d %H:%M:%S')
# ==============================================
# 系统文件描述符总上限
fs.file-max = $EXPECTED_FS_FILE_MAX
# 连接队列优化
net.core.somaxconn = $EXPECTED_SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.core.netdev_budget = $NETDEV_BUDGET
net.core.netdev_budget_usecs = $NETDEV_BUDGET_USECS
# TCP 基础优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $TCP_FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $TCP_KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
# 端口范围扩展
net.ipv4.ip_local_port_range = 1024 65534
# 重传控制
net.ipv4.tcp_retries2 = $EXPECTED_TCP_RETRIES2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# 反向路径过滤(宽松模式，兼容Docker/NAT/转发)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# ==============================================
# TCP 缓冲区配置
# ==============================================
$TCP_BUFFER_CONFIG
# ==============================================
# BBR 拥塞控制配置
# ==============================================
$BBR_CONFIG
$PROXY_EXTRA_CONFIG
$CONNTRACK_CONFIG
$MARKER_END
EOF
# 旧内核兼容处理
if kernel_lt "$KERNEL_VERSION" "4.12"; then
    sed -i "/$MARKER_END/i # 旧内核兼容：禁用tcp_tw_recycle
net.ipv4.tcp_tw_recycle = 0" "$SYSCTL_CONF"
    echo -e "${YELLOW}⚠ 旧内核检测，添加兼容参数${NC}"
fi
# 应用配置
echo -e "${YELLOW}8. 应用内核配置...${NC}"
sysctl -p >/dev/null 2>&1
echo -e "${GREEN}✅ 所有优化已应用完成！${NC}"
echo ""
# ==================== 最终输出 ====================
echo -e "${BLUE}=======================================================${NC}"
echo -e "${GREEN}🎉 优化部署成功！${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}🔍 验证命令${NC}"
echo -e "  ulimit -n                          # 应显示：$SYSTEM_MAX_FILE"
echo -e "  sysctl fs.file-max                 # 应显示：$EXPECTED_FS_FILE_MAX"
echo -e "  sysctl net.core.somaxconn          # 应显示：$EXPECTED_SOMAXCONN"
echo -e "  sysctl net.ipv4.tcp_retries2       # 应显示：$EXPECTED_TCP_RETRIES2"
echo -e "  sysctl net.ipv4.tcp_mem            # 应显示：$TCP_MEM_EXPECTED"
if [ $AUTO_CALC_DONE -eq 1 ]; then
echo -e "  sysctl net.ipv4.tcp_rmem          # 应显示：$TCP_RMEM_EXPECTED"
echo -e "  sysctl net.ipv4.tcp_wmem          # 应显示：$TCP_WMEM_EXPECTED"
fi
if [ $BBR_ENABLED -eq 1 ]; then
echo -e "  sysctl net.core.default_qdisc      # 应显示：fq"
echo -e "  sysctl net.ipv4.tcp_congestion_control  # 应显示：bbr"
fi
if [[ "$SCENARIO" == "5" && -n "$CONNTRACK_CONFIG" ]]; then
echo -e "  sysctl net.netfilter.nf_conntrack_max # 连接跟踪表上限"
fi
echo ""
echo -e "${YELLOW}🏗️  应用层配置推荐${NC}"
echo -e "${GREEN}通用场景：${NC}"
echo -e "  Nginx: worker_rlimit_nofile ${NGINX_GENERAL};"
echo -e "  MySQL: open_files_limit = ${MYSQL_GENERAL}"
echo -e "  PHP-FPM: rlimit_files = ${PHP_GENERAL}"
echo -e "  Redis: maxclients ${REDIS_GENERAL}"
echo ""
echo -e "${YELLOW}💡 本次优化核心${NC}"
if [[ "$SCENARIO" == "5" ]]; then
echo -e "  ✅ 转发基础参数全适配，兼容四层/七层代理场景"
echo -e "  ✅ 保守BDP缓冲区，减少中转链路队列积压丢包"
echo -e "  ✅ BBR合理增益，跨运营商链路速度更稳定"
echo -e "  ✅ 动态TCP内存与连接跟踪表，支撑高并发转发"
elif [[ "$SCENARIO" == "6" ]]; then
echo -e "  ✅ 容量类参数拉满，提升并发承载能力"
echo -e "  ✅ 传输参数保守，兼容全国不同地域网络"
echo -e "  ✅ 移除激进优化，优先保证整体稳定性"
echo -e "  ✅ 硬件自动适配，精准控制CPU资源占用"
else
echo -e "  ✅ 硬件自动适配：${TIER_DESC}，CPU开销精准控制"
echo -e "  ✅ 保守BDP缓冲区：降低队列积压，减少丢包重传"
echo -e "  ✅ BBR合理增益：平衡速度与丢包率"
echo -e "  ✅ 队列深度分级：低配减少软中断，降低CPU占用"
fi
echo ""
echo -e "${YELLOW}⚠️  生效说明：${NC}"
echo "1. 文件句柄需【关闭SSH重新登录】生效"
echo "2. 运行中的代理/转发服务必须【重启】才能使用新配置"
echo "3. 建议【重启服务器】确保所有参数完全生效"
echo ""
echo -e "${YELLOW}🔄 一键回滚${NC}"
echo "cp $BACKUP_DIR/limits.conf /etc/security/"
echo "cp $BACKUP_DIR/system.conf /etc/systemd/system.conf"
echo "cp $BACKUP_DIR/sysctl.conf /etc/"
echo "sysctl -p && systemctl daemon-reexec"
