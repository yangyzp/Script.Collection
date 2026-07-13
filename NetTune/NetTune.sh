#!/bin/bash
# ==================================================================
# NetTune.sh v3.6.0 — Linux 生产级智能网络优化脚本
# ==================================================================
# v3.6.0 更新日志：
#   [新增] 优化力度选择器（省内存/均衡/激进），三档 tcp_mem 上限可调
#          - 省内存：tcp_mem high = 总内存/8  （原 v3.5 默认值）
#          - 均衡  ：tcp_mem high = 总内存/6  （新默认，内存换吞吐）
#          - 激进  ：tcp_mem high = 总内存/4  （晚高峰更快、重传更低）
#          解决 "内存富余但晚高峰跑不满" 的典型痛点
#   [新增] 均衡/激进档位自动提升 netdev_max_backlog / netdev_budget
#          吸收晚高峰包突发，降低 softirq 丢包
#   [调整] 代理场景5 tcp_slow_start_after_idle 0→1
#          空闲连接重发不再保持满 cwnd，晚高峰拥塞链路突发丢包更少
#   [新增] 部署摘要输出 优化力度 / netdev / slow_start 验证项
#
# v3.5.0 更新日志：
#   [修复] 移除无效参数 tcp_bbr_cwnd_gain / tcp_bbr_bw_gain
#          (主线内核不存在这两个 sysctl，原脚本写入了但 sysctl -p 报错被吞)
#   [修复] tcp_early_retrans 2→3 (原值关闭了 TLP，降低性能)
#   [修复] tcp_notsent_lowat 场景6不再写 -1 (改为不设置，用内核默认)
#   [修复] sysctl -p 错误不再被 >/dev/null 2>&1 静默吞掉
#   [修复] 清理 /etc/sysctl.d/ 中的历史 marker 块 + 冲突参数告警
#   [修复] nf_conntrack_max 公式 *8→*64 (原值比内核默认低 8 倍)
#   [修复] BBR 检测改用 tcp_available_congestion_control (兼容内置内核)
#   [修复] busy_read/busy_poll 写入前检查 /proc/sys 存在性
#   [优化] tcp_rmem/tcp_wmem 重写：BDP×2.0，兼容 tcp_adv_win_scale=1
#   [优化] 缓冲区 default 回归内核默认 (87KB/16KB)，由自动调优扩展
#   [优化] SAFE_FACTOR 统一 2.0，不再随带宽递增 (防 bufferbloat)
#   [优化] 场景6 改用 BDP 计算 (假设 200ms RTT)，替代固定 4/8/16MB
#   [优化] 代理场景增加 tcp_mtu_probing=1 (防跨境 MTU 黑洞)
#   [优化] tcp_retries2 代理场景 4→6 (原值 15~30s 就断连，跨境太激进)
#   [优化] tcp_keepalive_time 代理场景 100→180 (避免误杀抖动中的连接)
#   [优化] 移除 bc 依赖，改用 awk (几乎所有 Linux 自带)
#   [优化] 增加 tcp_window_scaling / tcp_sack / tcp_timestamps 显式声明
#   [优化] ip_local_port_range 起点 1024→10000 (避免与服务端口冲突)
#   [优化] 回滚指令补全 marker 块清理
#   [优化] 备份失败时中止脚本 (防配置损坏无备份可恢复)
# ==================================================================
export LC_NUMERIC=C

# ==================== Root 权限检查 ====================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m错误：必须以 root 权限运行\033[0m"
    exit 1
fi

# 中断保护
trap 'echo -e "\n\033[0;31m脚本被中断，配置可能不完整，请检查或回滚\033[0m"; exit 1' INT TERM

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 硬件信息检测 ====================
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)

# ==================== 硬件档位自动判定 ====================
# 低配：1核及以下 或 内存≤1G   → 极致降CPU，优先稳定性
# 中配：2核 或 1G<内存≤2G      → 平衡性能与CPU占用
# 高配：4核及以上 且 内存>2G   → 全性能模式
if [ $CPU_CORES -le 1 ] || [ $TOTAL_MEM_MB -le 1024 ]; then
    HARDWARE_TIER="low"
    TIER_DESC="低配模式 (低CPU优先)"
    SYSTEM_MAX_FILE=131072
    EXPECTED_SOMAXCONN=32768
    FS_FILE_MAX_CEILING=524288
    NETDEV_BUDGET=150
    NETDEV_MAX_BACKLOG=2048
    BUSY_POLL_ENABLE=0
elif [ $CPU_CORES -le 2 ] || [ $TOTAL_MEM_MB -le 2048 ]; then
    HARDWARE_TIER="mid"
    TIER_DESC="中配模式 (性能平衡)"
    SYSTEM_MAX_FILE=262144
    EXPECTED_SOMAXCONN=65535
    FS_FILE_MAX_CEILING=1048576
    NETDEV_BUDGET=300
    NETDEV_MAX_BACKLOG=4096
    BUSY_POLL_ENABLE=0
else
    HARDWARE_TIER="high"
    TIER_DESC="高配模式 (满速优先)"
    SYSTEM_MAX_FILE=524288
    EXPECTED_SOMAXCONN=131072
    FS_FILE_MAX_CEILING=2097152
    NETDEV_BUDGET=600
    NETDEV_MAX_BACKLOG=8192
    BUSY_POLL_ENABLE=1
fi

# 应用分级推荐值
NGINX_GENERAL=$EXPECTED_SOMAXCONN
NGINX_HIGH=$(( EXPECTED_SOMAXCONN * 2 ))
MYSQL_GENERAL=$EXPECTED_SOMAXCONN
PHP_GENERAL=$EXPECTED_SOMAXCONN
REDIS_GENERAL=10000
REDIS_HIGH=20000

# 自动计算 fs.file-max（按档位适配系数）
FILE_MAX_FACTOR=100
[ "$HARDWARE_TIER" = "mid" ] && FILE_MAX_FACTOR=150
[ "$HARDWARE_TIER" = "high" ] && FILE_MAX_FACTOR=200
EXPECTED_FS_FILE_MAX=$(( TOTAL_MEM_MB * FILE_MAX_FACTOR ))
if [ $EXPECTED_FS_FILE_MAX -gt $FS_FILE_MAX_CEILING ]; then
    EXPECTED_FS_FILE_MAX=$FS_FILE_MAX_CEILING
fi

# ==================== 核心函数 ====================
# 内核版本比较：kernel_lt A B → A < B 返回 0(true)
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

# 清理 sysctl.conf 中所有重复的内核参数（含旧脚本写入的无效参数）
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
        sed -i "/^[#]*\s*$param\s*=/d" "$1"
    done
}

# ==================== 主程序开始 ====================
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  NetTune.sh v3.6.0 | Linux 智能网络优化${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}📊 服务器硬件检测${NC}"
echo -e "CPU核心数：${GREEN}${CPU_CORES} 核${NC}"
echo -e "内存总大小：${GREEN}${TOTAL_MEM_MB} MB${NC}"
echo -e "内核版本：${GREEN}${KERNEL_VERSION}${NC}"
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

# ==================== 场景参数初始化 ====================
NETDEV_BUDGET_USECS=4000
TCP_KEEPALIVE_TIME=200
TCP_EARLY_RETRANS=3
TCP_REORDERING=8
TCP_SLOW_START=0
TCP_NOTSENT_LOWAT=16384
case $SCENARIO in
    1)
        EXPECTED_TCP_RETRIES2=6
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
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=8
        TCP_KEEPALIVE_TIME=180
        TCP_REORDERING=8
        TCP_SLOW_START=1
        TCP_NOTSENT_LOWAT=16384
        SCENARIO_DESC="代理网络/流量转发/视频代理"
        ;;
    6)
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=12
        TCP_KEEPALIVE_TIME=180
        TCP_REORDERING=5
        TCP_SLOW_START=1
        TCP_NOTSENT_LOWAT=""
        BUSY_POLL_ENABLE=0
        SCENARIO_DESC="全国多用户公网接入/通用Web服务"
        ;;
    *)
        EXPECTED_TCP_RETRIES2=6
        TCP_FIN_TIMEOUT=12
        SCENARIO_DESC="通用业务服务器"
        ;;
esac

# ==================== 优化力度选择 ====================
# tcp_mem 是全局 TCP 内存上限（单位：页，1页=4KB）。
# 当并发连接的缓冲区总和触及 high 水位，内核停止扩展单连接缓冲区 → 吞吐被限。
# 用户服务器若内存有富余但晚高峰跑不满，通常就是 high 水位偏低导致。
# 这里提供三档力度，让用户按 "内存富余度 vs 速度需求" 自行权衡。
echo ""
echo -e "${YELLOW}⚡ 选择优化力度${NC}"
echo "1. 省内存 (保守，TCP内存上限约总内存 1/8，适合资源紧张或小内存VPS)"
echo "2. 均衡 (默认，TCP内存上限约总内存 1/6，兼顾性能与内存)"
echo "3. 激进 (大内存占用，TCP内存上限约总内存 1/4，晚高峰更快、重传更低)"
read -p "请输入选项(1-3，默认2): " PERF_MODE
PERF_MODE=${PERF_MODE:-2}

case $PERF_MODE in
    1)
        PERF_DESC="省内存"
        TCP_MEM_DIV_LOW=16
        TCP_MEM_DIV_PRESSURE=12
        TCP_MEM_DIV_HIGH=8
        # 省内存：沿用硬件档位原值，不强制提升 netdev 队列
        ;;
    2)
        PERF_DESC="均衡"
        TCP_MEM_DIV_LOW=12
        TCP_MEM_DIV_PRESSURE=8
        TCP_MEM_DIV_HIGH=6
        # 均衡：低配档位提升至中配水准，吸收中等突发
        [ $NETDEV_MAX_BACKLOG -lt 4096 ] && NETDEV_MAX_BACKLOG=4096
        [ $NETDEV_BUDGET -lt 300 ] && NETDEV_BUDGET=300
        ;;
    3)
        PERF_DESC="激进"
        TCP_MEM_DIV_LOW=8
        TCP_MEM_DIV_PRESSURE=6
        TCP_MEM_DIV_HIGH=4
        # 激进：低/中配档位提升至高配水准，最大化吸收晚高峰突发
        [ $NETDEV_MAX_BACKLOG -lt 8192 ] && NETDEV_MAX_BACKLOG=8192
        [ $NETDEV_BUDGET -lt 600 ] && NETDEV_BUDGET=600
        ;;
    *)
        PERF_DESC="均衡"
        TCP_MEM_DIV_LOW=12
        TCP_MEM_DIV_PRESSURE=8
        TCP_MEM_DIV_HIGH=6
        [ $NETDEV_MAX_BACKLOG -lt 4096 ] && NETDEV_MAX_BACKLOG=4096
        [ $NETDEV_BUDGET -lt 300 ] && NETDEV_BUDGET=300
        ;;
esac

# ==================== 配置文件路径与标记 ====================
BACKUP_DIR="/etc/optimize_backup_$(date +%Y%m%d_%H%M%S)"
SYSCTL_CONF="/etc/sysctl.conf"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
MARKER_START="# >>> NETTUNE_START >>>"
MARKER_END="# <<< NETTUNE_END <<<"
TCP_RMEM_EXPECTED=""
TCP_WMEM_EXPECTED=""
TCP_MEM_EXPECTED=""
BBR_ENABLED=0
PROXY_EXTRA_CONFIG=""
BUSY_POLL_CONFIG=""
CONNTRACK_CONFIG=""

# ==================== 1. 备份原始配置 ====================
echo ""
echo -e "${YELLOW}1. 备份原始配置...${NC}"
mkdir -p "$BACKUP_DIR"
cp "$LIMITS_CONF" "$BACKUP_DIR/" 2>/dev/null || echo -e "${YELLOW}⚠ limits.conf 不存在，跳过${NC}"
cp "$SYSTEMD_CONF" "$BACKUP_DIR/" 2>/dev/null || echo -e "${YELLOW}⚠ system.conf 不存在，跳过${NC}"
cp "$SYSCTL_CONF" "$BACKUP_DIR/" 2>/dev/null || { echo -e "${RED}✗ sysctl.conf 备份失败，中止脚本${NC}"; exit 1; }
echo -e "${GREEN}✓ 备份完成：$BACKUP_DIR${NC}"

# ==================== 2. 深度清理历史配置 ====================
echo ""
echo -e "${YELLOW}2. 深度清理历史配置（自动去重）...${NC}"
# 清理 sysctl.conf 中的旧 marker 块
sed -i "/$MARKER_START/,/$MARKER_END/d" "$SYSCTL_CONF"
# 清理 sysctl.conf 中的重复参数
clean_sysctl_params "$SYSCTL_CONF"
# 清理 /etc/sysctl.d/ 中的旧 marker 块（防止历史残留）
shopt -s nullglob
for f in /etc/sysctl.d/*.conf; do
    if grep -q "$MARKER_START" "$f" 2>/dev/null; then
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$f"
        echo -e "  清理 $f 中的历史 marker 块"
    fi
done
# 检查 /etc/sysctl.d/ 中的冲突参数（仅告警，不修改发行版文件）
CONFLICT_PARAMS="fs.file-max|net.core.somaxconn|net.ipv4.tcp_congestion_control|net.core.default_qdisc|net.ipv4.tcp_rmem|net.ipv4.tcp_wmem"
for f in /etc/sysctl.d/*.conf; do
    if grep -qE "^\s*${CONFLICT_PARAMS}\s*=" "$f" 2>/dev/null; then
        echo -e "${YELLOW}⚠ $f 中存在冲突参数，可能覆盖本脚本设置，请手动检查${NC}"
    fi
done
shopt -u nullglob
# 删除已知冲突文件
[ -f "/etc/sysctl.d/99-high-concurrency.conf" ] && rm -f "/etc/sysctl.d/99-high-concurrency.conf" && echo -e "  已删除 99-high-concurrency.conf"
echo -e "${GREEN}✓ 所有历史配置已清理${NC}"

# ==================== 3. 设置文件句柄上限 ====================
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

# ==================== 4. 配置 systemd 全局限制 ====================
echo ""
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

# ==================== 5. TCP 缓冲区自动计算 ====================
echo ""
echo -e "${YELLOW}5. TCP缓冲区自动计算${NC}"
# ------------------------------------------------------------------
# BDP 计算公式：
#   BDP(bytes) = BANDWIDTH(Mbps) × RTT(ms) × 125
#   其中 125 = 10^6 / (10^3 × 8)  (Mbps·ms → bytes)
#
# 缓冲区 max 设为 BDP × 2.0 的原因：
#   内核默认 tcp_adv_win_scale = 1，此时接收端通告窗口 = 缓冲区 / 2
#   要让通告窗口达到 BDP（填满管道），缓冲区 max 需 ≥ 2 × BDP
#   若 max < 2×BDP，通告窗口永远达不到 BDP，吞吐被限制
#
# default 保持内核默认 (rmem=87380 / wmem=16384) 的原因：
#   TCP 自动调优会按需从 default 扩展到 max（1-3 RTT 内完成）
#   小 default 节省空闲/短连接内存，不影响吞吐
#
# SAFE_FACTOR 恒定 2.0（不再随带宽递增）：
#   需要的余量取决于 RTT 抖动，与带宽无关
#   恒定系数避免高带宽场景的 bufferbloat
# ------------------------------------------------------------------
SAFE_FACTOR=2.0
TCP_RMEM_MIN=4096
TCP_WMEM_MIN=4096
TCP_RMEM_DEFAULT=87380
TCP_WMEM_DEFAULT=16384

if [[ "$SCENARIO" == "6" ]]; then
    # 场景6：多用户公网接入，用户不输入 RTT
    # 假设 200ms 覆盖国内+近海国际链路
    RTT_MS="自适应"
    CALC_RTT=200
    RTT_DISPLAY="自适应(${CALC_RTT}ms)"
    # 输入带宽
    while true; do
        read -p "输入服务器带宽(Mbps，如70/100/500): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$(awk "BEGIN{print ($BANDWIDTH>0 && $BANDWIDTH<=10000)?1:0}")" = "1" ]; then
            break
        fi
        echo -e "${RED}请输入有效带宽数字(0~10000)${NC}"
    done
    # 多用户场景更保守的封顶（每连接内存预算更小）
    if [ "$HARDWARE_TIER" = "low" ]; then
        MAX_BUFFER_BYTES=$(( 4 * 1024 * 1024 ))
    elif [ "$HARDWARE_TIER" = "mid" ]; then
        MAX_BUFFER_BYTES=$(( 8 * 1024 * 1024 ))
    else
        MAX_BUFFER_BYTES=$(( 16 * 1024 * 1024 ))
    fi
    echo -e "${BLUE}  多用户场景：假设 RTT=${CALC_RTT}ms，内核自动适配各地区链路${NC}"
else
    # 场景1-5：用户输入带宽和 RTT
    while true; do
        read -p "输入服务器带宽(Mbps，如70/100/500): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$(awk "BEGIN{print ($BANDWIDTH>0 && $BANDWIDTH<=10000)?1:0}")" = "1" ]; then
            break
        fi
        echo -e "${RED}请输入有效带宽数字(0~10000)${NC}"
    done
    while true; do
        read -p "输入平均延迟(ms，如50/100/200): " RTT_MS
        if [[ "$RTT_MS" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$(awk "BEGIN{print ($RTT_MS>0 && $RTT_MS<=1000)?1:0}")" = "1" ]; then
            break
        fi
        echo -e "${RED}请输入有效延迟数字(0~1000)${NC}"
    done
    CALC_RTT="$RTT_MS"
    RTT_DISPLAY="${RTT_MS}ms"
    # 标准场景封顶（按硬件档位）
    if [ "$HARDWARE_TIER" = "low" ]; then
        MAX_BUFFER_BYTES=$(( 8 * 1024 * 1024 ))
    elif [ "$HARDWARE_TIER" = "mid" ]; then
        MAX_BUFFER_BYTES=$(( 16 * 1024 * 1024 ))
    else
        MAX_BUFFER_BYTES=$(( 32 * 1024 * 1024 ))
    fi
fi

# 计算 BDP 和最终缓冲区 max
bdp_bytes=$(awk "BEGIN{printf \"%.0f\", $BANDWIDTH * $CALC_RTT * 125}")
value_bytes=$(awk "BEGIN{printf \"%.0f\", $bdp_bytes * $SAFE_FACTOR}")
# 硬件档位封顶
if [ "$value_bytes" -gt "$MAX_BUFFER_BYTES" ]; then
    value_bytes=$MAX_BUFFER_BYTES
fi
# 下限保护：确保 max ≥ default（否则三段式 min/default/max 无效）
if [ "$value_bytes" -lt $TCP_RMEM_DEFAULT ]; then
    value_bytes=$TCP_RMEM_DEFAULT
fi

# 最终三段式缓冲区（收发对称，代理场景双向都需要大缓冲）
TCP_RMEM_MAX=$value_bytes
TCP_WMEM_MAX=$value_bytes
TCP_RMEM_EXPECTED="$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX"
TCP_WMEM_EXPECTED="$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"

final_mb=$(awk "BEGIN{printf \"%.1f\", $value_bytes / 1048576}")
bdp_mb=$(awk "BEGIN{printf \"%.2f\", $bdp_bytes / 1048576}")
echo -e "${BLUE}  BDP = ${bdp_mb} MiB (${BANDWIDTH}Mbps × ${RTT_DISPLAY})${NC}"
echo -e "${BLUE}  缓冲区 max = ${final_mb} MiB (BDP × ${SAFE_FACTOR}, 含 adv_win_scale 余量)${NC}"
echo -e "${BLUE}  缓冲区 default = 87KB(rmem)/16KB(wmem) [内核默认, 自动调优扩展]${NC}"

# 构建缓冲区配置字符串
TCP_BUFFER_CONFIG="# TCP 缓冲区优化 (${SCENARIO_DESC} | ${BANDWIDTH}Mbps @ ${RTT_DISPLAY})
# BDP=${bdp_mb}MiB | max=${final_mb}MiB (BDP×${SAFE_FACTOR}, 兼容 tcp_adv_win_scale=1)
# default 保持内核默认, 由 TCP 自动调优按需扩展到 max
net.core.rmem_max = $TCP_RMEM_MAX
net.core.wmem_max = $TCP_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_EXPECTED
net.ipv4.tcp_wmem = $TCP_WMEM_EXPECTED
# 窗口缩放与选择性确认（高BDP链路必备）
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
# MTU 探测（防跨境/隧道 MTU 黑洞）
net.ipv4.tcp_mtu_probing = 1
# 重传与乱序优化
net.ipv4.tcp_early_retrans = $TCP_EARLY_RETRANS
net.ipv4.tcp_reordering = $TCP_REORDERING
net.ipv4.tcp_slow_start_after_idle = $TCP_SLOW_START"

# tcp_notsent_lowat（场景6不设置，用内核默认）
if [ -n "$TCP_NOTSENT_LOWAT" ]; then
    TCP_BUFFER_CONFIG="$TCP_BUFFER_CONFIG
net.ipv4.tcp_notsent_lowat = $TCP_NOTSENT_LOWAT"
fi

# ==================== 全局 TCP 内存限制（tcp_mem） ====================
# 单位：页，1页=4KB；按系统总内存 + 优化力度动态计算
# low/pressure/high 三水位含义：
#   < low       : 空闲，无限制
#   low~pressure: 开始施加压力，限制新建连接缓冲区增长
#   pressure~high: 强制收缩已有连接缓冲区
#   > high      : 拒绝扩展，单连接吞吐被压住
# 除数由 "优化力度" 选择决定（PERF_MODE）：
#   省内存 /16 /12 /8   均衡 /12 /8 /6   激进 /8 /6 /4
total_pages=$(( TOTAL_MEM_MB * 1024 / 4 ))
tcp_mem_low=$(( total_pages / TCP_MEM_DIV_LOW ))
tcp_mem_pressure=$(( total_pages / TCP_MEM_DIV_PRESSURE ))
tcp_mem_high=$(( total_pages / TCP_MEM_DIV_HIGH ))
TCP_MEM_EXPECTED="$tcp_mem_low $tcp_mem_pressure $tcp_mem_high"
# 500M以上大带宽额外放宽10%（大带宽场景并发流多，缓冲区需求更高）
if [ "$(awk "BEGIN{print ($BANDWIDTH>=500)?1:0}")" = "1" ]; then
    tcp_mem_low=$(awk "BEGIN{printf \"%d\", int($tcp_mem_low * 1.1)}")
    tcp_mem_pressure=$(awk "BEGIN{printf \"%d\", int($tcp_mem_pressure * 1.1)}")
    tcp_mem_high=$(awk "BEGIN{printf \"%d\", int($tcp_mem_high * 1.1)}")
    TCP_MEM_EXPECTED="$tcp_mem_low $tcp_mem_pressure $tcp_mem_high"
fi
TCP_BUFFER_CONFIG="$TCP_BUFFER_CONFIG
net.ipv4.tcp_mem = $TCP_MEM_EXPECTED"

# ==================== busy_poll（仅高配，写入前检查存在性） ====================
if [ $BUSY_POLL_ENABLE -eq 1 ]; then
    BUSY_POLL_CONFIG="# 高配低延迟优化（CPU占用较高，仅局域网推荐）"
    if [ -f /proc/sys/net/core/busy_read ]; then
        BUSY_POLL_CONFIG="$BUSY_POLL_CONFIG
net.core.busy_read = 512"
    fi
    if [ -f /proc/sys/net/core/busy_poll ]; then
        BUSY_POLL_CONFIG="$BUSY_POLL_CONFIG
net.core.busy_poll = 512"
    fi
    # 如果两个参数都不存在，清空配置
    if ! [ -f /proc/sys/net/core/busy_read ] && ! [ -f /proc/sys/net/core/busy_poll ]; then
        BUSY_POLL_CONFIG=""
        echo -e "${YELLOW}⚠ 内核不支持 busy_read/busy_poll，跳过${NC}"
    fi
fi

# ==================== 代理场景专属参数 ====================
if [[ "$SCENARIO" == "5" ]]; then
    PROXY_EXTRA_CONFIG="# 代理中转专属优化
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1"

    # 自动检测并配置 conntrack 连接跟踪表
    # 尝试加载模块（如果已内置则 modprobe 无害）
    if command -v modprobe &>/dev/null; then
        modprobe nf_conntrack 2>/dev/null
    fi
    # 检查 conntrack 是否可用（模块加载或内置）
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        # 连接跟踪表上限：按内存配比
        # 公式：TOTAL_MEM_MB × 64（与内核默认一致，确保不低于默认）
        # 每条约 300 字节，16GB→约 100 万条→约 300MB 内存
        conntrack_max=$(( TOTAL_MEM_MB * 64 ))
        [ $conntrack_max -lt 65536 ] && conntrack_max=65536
        CONNTRACK_CONFIG="# 连接跟踪表优化（四层转发/代理必备）
net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120"
        echo -e "${GREEN}✓ 已检测到 nf_conntrack，连接跟踪表上限：$conntrack_max${NC}"
    else
        echo -e "${YELLOW}⚠ nf_conntrack 不可用，跳过连接跟踪优化${NC}"
    fi
fi

# ==================== 6. 自动配置 BBR+fq 拥塞控制 ====================
echo ""
echo -e "${YELLOW}6. 自动配置BBR+fq拥塞控制${NC}"
BBR_CONFIG=""
if ! kernel_lt "$KERNEL_VERSION" "4.9"; then
    # 尝试加载模块（如果已内置则无害）
    if command -v modprobe &>/dev/null; then
        modprobe tcp_bbr 2>/dev/null
        modprobe sch_fq 2>/dev/null
    fi
    # 检查内核是否支持 BBR（兼容模块加载和内置两种方式）
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_CONFIG="# BBR 拥塞控制 + fq 队列（${TIER_DESC}）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
        BBR_ENABLED=1
        echo -e "${GREEN}✓ 内核支持，已启用BBR+fq${NC}"
    else
        echo -e "${YELLOW}⚠ 内核不支持 BBR，使用默认拥塞控制${NC}"
        echo -e "${YELLOW}  建议升级到 4.9+ 内核以启用 BBR${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 内核版本低于4.9，不支持BBR，建议升级内核${NC}"
fi

# ==================== 7. 写入内核优化配置 ====================
echo ""
echo -e "${YELLOW}7. 写入内核优化配置...${NC}"
cat >> "$SYSCTL_CONF" << EOF
$MARKER_START
# ==============================================
# NetTune.sh 内核优化配置
# 业务场景：$SCENARIO_DESC
# 硬件档位：$TIER_DESC
# 优化力度：$PERF_DESC
# 带宽适配：${BANDWIDTH}Mbps | 延迟适配：${RTT_DISPLAY}
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
# 端口范围扩展（起点10000，避免与服务端口冲突）
net.ipv4.ip_local_port_range = 10000 65535
# 重传控制
net.ipv4.tcp_retries2 = $EXPECTED_TCP_RETRIES2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# 反向路径过滤（宽松模式，兼容Docker/NAT/转发）
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# ==============================================
# TCP 缓冲区配置
# ==============================================
$TCP_BUFFER_CONFIG
$BUSY_POLL_CONFIG
# ==============================================
# BBR 拥塞控制配置
# ==============================================
$BBR_CONFIG
$PROXY_EXTRA_CONFIG
$CONNTRACK_CONFIG
$MARKER_END
EOF

# 旧内核兼容处理（tcp_tw_recycle 在 4.12 被移除，仅旧内核需要显式禁用）
if kernel_lt "$KERNEL_VERSION" "4.12"; then
    sed -i "/$MARKER_END/i # 旧内核兼容：禁用 tcp_tw_recycle（NAT场景下有害）
net.ipv4.tcp_tw_recycle = 0" "$SYSCTL_CONF"
    echo -e "${YELLOW}⚠ 旧内核检测，已添加 tcp_tw_recycle=0 兼容参数${NC}"
fi

# ==================== 8. 应用内核配置（显示错误，不再静默吞掉） ====================
echo ""
echo -e "${YELLOW}8. 应用内核配置...${NC}"
sysctl_output=$(sysctl -p 2>&1)
sysctl_errors=$(echo "$sysctl_output" | grep -iE "cannot stat|permission denied|invalid argument")
if [ -n "$sysctl_errors" ]; then
    echo -e "${YELLOW}⚠ 以下参数应用失败（内核不支持，不影响其他参数）：${NC}"
    echo "$sysctl_errors" | while IFS= read -r line; do
        echo -e "  ${RED}$line${NC}"
    done
    echo -e "${YELLOW}  以上错误可忽略（对应内核版本不支持该参数）${NC}"
else
    echo -e "${GREEN}✓ 所有参数已成功应用${NC}"
fi

# ==================== 最终输出 ====================
echo ""
echo -e "${BLUE}=======================================================${NC}"
echo -e "${GREEN}🎉 优化部署成功！${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}� 部署摘要${NC}"
echo -e "  业务场景：${GREEN}$SCENARIO_DESC${NC}"
echo -e "  硬件档位：${GREEN}$TIER_DESC${NC}"
echo -e "  优化力度：${GREEN}$PERF_DESC${NC}"
echo -e "  带宽/延迟：${GREEN}${BANDWIDTH}Mbps @ ${RTT_DISPLAY}${NC}"
echo ""
echo -e "${YELLOW}� 验证命令${NC}"
echo -e "  ulimit -n                          # 应显示：$SYSTEM_MAX_FILE"
echo -e "  sysctl fs.file-max                 # 应显示：$EXPECTED_FS_FILE_MAX"
echo -e "  sysctl net.core.somaxconn          # 应显示：$EXPECTED_SOMAXCONN"
echo -e "  sysctl net.core.netdev_max_backlog # 应显示：$NETDEV_MAX_BACKLOG"
echo -e "  sysctl net.core.netdev_budget      # 应显示：$NETDEV_BUDGET"
echo -e "  sysctl net.ipv4.tcp_retries2       # 应显示：$EXPECTED_TCP_RETRIES2"
echo -e "  sysctl net.ipv4.tcp_mem            # 应显示：$TCP_MEM_EXPECTED"
echo -e "  sysctl net.ipv4.tcp_rmem           # 应显示：$TCP_RMEM_EXPECTED"
echo -e "  sysctl net.ipv4.tcp_wmem           # 应显示：$TCP_WMEM_EXPECTED"
echo -e "  sysctl net.ipv4.tcp_mtu_probing    # 应显示：1"
echo -e "  sysctl net.ipv4.tcp_slow_start_after_idle  # 应显示：$TCP_SLOW_START"
if [ $BBR_ENABLED -eq 1 ]; then
echo -e "  sysctl net.core.default_qdisc      # 应显示：fq"
echo -e "  sysctl net.ipv4.tcp_congestion_control  # 应显示：bbr"
fi
if [[ "$SCENARIO" == "5" && -n "$CONNTRACK_CONFIG" ]]; then
echo -e "  sysctl net.netfilter.nf_conntrack_max # 应显示：$conntrack_max"
fi
echo ""
echo -e "${YELLOW}📡 带宽测试建议（测回程，即用户实际下载方向）${NC}"
echo -e "  iperf3 -c <对端IP> -R -t 30 -P 4    # 测回程带宽（重点）"
echo -e "  iperf3 -c <对端IP> -R -t 30 -i 1    # 看重传率（目标<0.3%）"
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
echo -e "  ✅ BDP×2 缓冲区计算，通告窗口可达满速（修复原版 75% 限速问题）"
echo -e "  ✅ MTU 探测开启，防跨境/隧道黑洞"
echo -e "  ✅ BBR+fq 拥塞控制，跨境链路重传率更低"
echo -e "  ✅ conntrack 表适配内存，支撑高并发转发"
echo -e "  ✅ tcp_slow_start_after_idle=1，晚高峰空闲连接重发更温和，降低突发丢包"
echo -e "  ✅ 优化力度【${PERF_DESC}】：tcp_mem 上限 $tcp_mem_high 页 (~$(( tcp_mem_high * 4 / 1024 ))MB)，netdev_backlog=$NETDEV_MAX_BACKLOG"
elif [[ "$SCENARIO" == "6" ]]; then
echo -e "  ✅ BDP×2 缓冲区（假设 200ms RTT），兼容全国各地区链路"
echo -e "  ✅ 容量类参数拉满，提升并发承载能力"
echo -e "  ✅ 传输参数保守，优先保证整体稳定性"
echo -e "  ✅ 硬件自动适配，精准控制CPU资源占用"
echo -e "  ✅ 优化力度【${PERF_DESC}】：tcp_mem 上限 $tcp_mem_high 页 (~$(( tcp_mem_high * 4 / 1024 ))MB)"
else
echo -e "  ✅ 硬件自动适配：${TIER_DESC}，CPU开销精准控制"
echo -e "  ✅ BDP×2 缓冲区：通告窗口可达满速，修复原版 75% 限速问题"
echo -e "  ✅ MTU 探测：防黑洞连接"
echo -e "  ✅ BBR+fq：平衡速度与丢包率"
echo -e "  ✅ 队列深度分级：低配减少软中断，降低CPU占用"
echo -e "  ✅ 优化力度【${PERF_DESC}】：tcp_mem 上限 $tcp_mem_high 页 (~$(( tcp_mem_high * 4 / 1024 ))MB)"
fi
echo ""
echo -e "${YELLOW}⚠️  生效说明：${NC}"
echo "1. 文件句柄需【关闭SSH重新登录】生效"
echo "2. 运行中的代理/转发服务必须【重启】才能使用新配置"
echo "3. 建议【重启服务器】确保所有参数完全生效"
echo ""
echo -e "${YELLOW}🔄 一键回滚${NC}"
echo "# 1. 恢复备份的配置文件"
echo "cp $BACKUP_DIR/sysctl.conf /etc/"
echo "cp $BACKUP_DIR/limits.conf /etc/security/ 2>/dev/null"
echo "cp $BACKUP_DIR/system.conf /etc/systemd/ 2>/dev/null"
echo "# 2. 清理可能残留的 marker 块"
echo "sed -i '/# >>> NETTUNE_START >>>/,/# <<< NETTUNE_END <<</d' /etc/sysctl.conf"
echo "sed -i '/# >>> NETTUNE_START >>>/,/# <<< NETTUNE_END <<</d' /etc/security/limits.conf"
echo "# 3. 重新加载配置"
echo "sysctl -p && systemctl daemon-reexec"
echo ""
echo -e "${BLUE}备份目录：${BACKUP_DIR}${NC}"
