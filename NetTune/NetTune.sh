#!/bin/bash
# ==================== 依赖检查与安装 (新增) ====================
# 仅当 bc 或 iperf3 缺失时触发安装，已安装则静默跳过，不影响原脚本任何逻辑
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


# Linux 生产级智能优化脚本 v3.0.5 (移植成熟BDP缓冲区计算 | 自动BBR版)
# 自动内存适配 | 5种业务场景 | BDP自动计算(取自TCP-Tuning-Simple-Version) | 自动去重 | 自动BBR+fq
# 专为代理网络/视频转发优化，内核支持则自动启用BBR+fq最佳组合
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
# 全局固定安全配置
SYSTEM_MAX_FILE=262144
EXPECTED_SOMAXCONN=65535
FS_FILE_MAX_CEILING=1048576
# 应用分级推荐值
NGINX_GENERAL=65535
NGINX_HIGH=131072
MYSQL_GENERAL=65535
PHP_GENERAL=65535
REDIS_GENERAL=10000
REDIS_HIGH=20000
# 自动检测硬件信息
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
# 自动计算fs.file-max（每1MB内存100个，安全封顶）
EXPECTED_FS_FILE_MAX=$(( TOTAL_MEM_MB * 100 ))
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
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_tw_recycle"
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
echo -e "${BLUE}  Linux 生产级智能优化脚本 v3.0.5 | 自动BBR+fq版${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}📊 服务器硬件检测${NC}"
echo -e "内存总大小：${GREEN}${TOTAL_MEM_MB} MB${NC}"
echo -e "自动计算系统句柄上限：${GREEN}${EXPECTED_FS_FILE_MAX}${NC}"
echo -e "单进程最大句柄：${GREEN}${SYSTEM_MAX_FILE}${NC}"
echo ""
echo -e "${YELLOW}🎯 选择业务场景${NC}"
echo "1. 高并发Web/API/反向代理"
echo "2. 通用业务服务器 (默认)"
echo "3. 数据库/缓存/长连接服务"
echo "4. 批处理/大数据任务"
echo "5. 代理网络/流量转发/视频代理 ✅ 推荐"
read -p "请输入选项(1-5，默认2): " SCENARIO
SCENARIO=${SCENARIO:-2}
# 场景参数初始化
NETDEV_BUDGET_USECS=8000
TCP_KEEPALIVE_TIME=300
case $SCENARIO in
    1)
        EXPECTED_TCP_RETRIES2=5
        TCP_FIN_TIMEOUT=15
        SCENARIO_DESC="高并发Web/API/反向代理"
        ;;
    2)
        EXPECTED_TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=15
        SCENARIO_DESC="通用业务服务器"
        ;;
    3)
        EXPECTED_TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=30
        SCENARIO_DESC="数据库/缓存/长连接服务"
        ;;
    4)
        EXPECTED_TCP_RETRIES2=15
        TCP_FIN_TIMEOUT=60
        SCENARIO_DESC="批处理/大数据任务"
        ;;
    5)
        EXPECTED_TCP_RETRIES2=3
        TCP_FIN_TIMEOUT=10
        TCP_KEEPALIVE_TIME=120
        NETDEV_BUDGET_USECS=4000
        SCENARIO_DESC="代理网络/流量转发/视频代理"
        ;;
    *)
        EXPECTED_TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=15
        SCENARIO_DESC="通用业务服务器"
        ;;
esac
BACKUP_DIR="/etc/optimize_backup_$(date +%Y%m%d_%H%M%S)"
SYSCTL_CONF="/etc/sysctl.conf"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
MARKER_START="# >>> LINUX_HIGH_CONCURRENCY_OPT_START >>>"
MARKER_END="# <<< LINUX_HIGH_CONCURRENCY_OPT_END <<<"
TCP_RMEM_EXPECTED=""
TCP_WMEM_EXPECTED=""
BBR_ENABLED=0
BBR_EXPECTED="bbr"
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
$MARKER_END
EOF
echo -e "${GREEN}✓ 单进程句柄上限：$SYSTEM_MAX_FILE${NC}"
echo -e "${YELLOW}4. 配置systemd全局限制...${NC}"
if command -v systemctl &>/dev/null; then
    sed -i "s/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=$SYSTEM_MAX_FILE/" "$SYSTEMD_CONF"
    if ! grep -q "^DefaultLimitNOFILE=" "$SYSTEMD_CONF"; then
        echo "DefaultLimitNOFILE=$SYSTEM_MAX_FILE" >> "$SYSTEMD_CONF"
    fi
    systemctl daemon-reexec 2>/dev/null
    echo -e "${GREEN}✓ systemd已配置完成${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到systemd，跳过${NC}"
fi
echo ""
echo -e "${YELLOW}5. TCP缓冲区自动计算（移植TCP-Tuning-Simple-Version BDP算法）${NC}"
TCP_BUFFER_CONFIG=""
AUTO_CALC_DONE=0
read -p "是否自动计算TCP缓冲区？(y/n，默认y): " AUTO_CALC
AUTO_CALC=${AUTO_CALC:-y}
if [[ "$AUTO_CALC" == "y" ]]; then
    # 带宽输入校验（支持小数）
    while true; do
        read -p "输入服务器带宽(Mbps): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]*\.?[0-9]+$ ]] && (( $(echo "$BANDWIDTH > 0 && $BANDWIDTH <= 10000" | bc -l) )); then
            break
        fi
        echo -e "${RED}请输入有效带宽数字(0~10000)${NC}"
    done
    # RTT延迟输入校验（支持小数）
    while true; do
        read -p "输入平均延迟(ms): " RTT_MS
        if [[ "$RTT_MS" =~ ^[0-9]*\.?[0-9]+$ ]] && (( $(echo "$RTT_MS > 0 && $RTT_MS <= 1000" | bc -l) )); then
            break
        fi
        echo -e "${RED}请输入有效延迟数字(0~1000)${NC}"
    done
    # 标准BDP计算公式 BDP(KB) = 带宽(Mbps) × RTT(ms) / 8
    bdp_kb=$(echo "scale=2; $BANDWIDTH * $RTT_MS / 8" | bc)
    bdp_mb=$(echo "scale=2; $bdp_kb / 1024" | bc)
    # 安全系数 ×1.5
    recommended_mb=$(echo "scale=2; $bdp_mb * 1.5" | bc)
    final_mb=$(printf "%.0f" "$recommended_mb")
    # 最小限制1MiB
    if [ "$final_mb" -lt 1 ]; then
        final_mb=1
    fi
    value_bytes=$(echo "$final_mb * 1024 * 1024" | bc)
    # 固定三段式 rmem/wmem 模板（和简易调优脚本统一）
    TCP_RMEM_MIN=4096
    TCP_RMEM_DEFAULT=87380
    TCP_RMEM_MAX=$value_bytes
    TCP_WMEM_MIN=4096
    TCP_WMEM_DEFAULT=16384
    TCP_WMEM_MAX=$value_bytes

    TCP_RMEM_EXPECTED="$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX"
    TCP_WMEM_EXPECTED="$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"
    AUTO_CALC_DONE=1
    TCP_BUFFER_CONFIG="# TCP 缓冲区优化 (${BANDWIDTH}Mbps @ ${RTT_MS}ms)
# BDP计算值: ${bdp_mb}MB | 安全放大1.5倍推荐: ${recommended_mb}MB | 最终设置${final_mb}MiB
net.core.rmem_default = $TCP_RMEM_DEFAULT
net.core.wmem_default = $TCP_WMEM_DEFAULT
net.core.rmem_max = $TCP_RMEM_MAX
net.core.wmem_max = $TCP_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_EXPECTED
net.ipv4.tcp_wmem = $TCP_WMEM_EXPECTED"
    echo -e "${GREEN}✓ BDP缓冲区计算完成，最终缓冲区上限：${final_mb}MiB${NC}"
else
    # 手动默认模板（和简易脚本默认值对齐）
    TCP_RMEM_EXPECTED="4096 87380 6291456"
    TCP_WMEM_EXPECTED="4096 16384 4194304"
    TCP_BUFFER_CONFIG="# TCP缓冲区手动默认模板（系统原生基准值）
net.core.rmem_default = 87380
net.core.wmem_default = 16384
net.core.rmem_max = 6291456
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = $TCP_RMEM_EXPECTED
net.ipv4.tcp_wmem = $TCP_WMEM_EXPECTED"
    echo -e "${YELLOW}✓ 使用系统原生TCP缓冲区默认模板${NC}"
fi
echo ""
echo -e "${YELLOW}6. 自动配置BBR+fq拥塞控制...${NC}"
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
BBR_CONFIG=""
if ! kernel_lt "$KERNEL_VERSION" "4.9"; then
    # 自动加载BBR和fq模块
    modprobe tcp_bbr 2>/dev/null
    modprobe sch_fq 2>/dev/null
    if lsmod | grep -q bbr && lsmod | grep -q fq; then
        BBR_CONFIG="# BBR 拥塞控制算法 + fq 队列管理（自动启用）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
        BBR_ENABLED=1
        echo -e "${GREEN}✓ 内核支持，自动启用BBR+fq最佳组合${NC}"
    else
        echo -e "${YELLOW}⚠ BBR或fq模块加载失败，将使用默认拥塞控制${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 内核版本低于4.9，不支持BBR${NC}"
fi
echo ""
echo -e "${YELLOW}7. 写入内核优化配置...${NC}"
cat >> "$SYSCTL_CONF" << EOF
$MARKER_START
# ==============================================
# Linux 生产级智能内核优化
# 业务场景：$SCENARIO_DESC
# 自动生成于：$(date '+%Y-%m-%d %H:%M:%S')
# TCP缓冲区计算逻辑移植自TCP-Tuning-Simple-Version.sh
# ==============================================
# 系统级文件描述符总上限（根据内存自动计算）
fs.file-max = $EXPECTED_FS_FILE_MAX
# 连接队列优化
net.core.somaxconn = $EXPECTED_SOMAXCONN
net.core.netdev_max_backlog = 65535
net.core.netdev_budget = 600
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
# 减少无效重传
net.ipv4.tcp_retries2 = $EXPECTED_TCP_RETRIES2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# 反向路径过滤(宽松模式，兼容Docker/K8s/NAT)
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
$MARKER_END
EOF
# 旧内核兼容处理
if kernel_lt "$KERNEL_VERSION" "4.12"; then
    sed -i "/$MARKER_END/i # 旧内核兼容：禁用tcp_tw_recycle，避免NAT环境下连接重置问题" "$SYSCTL_CONF"
    sed -i "/$MARKER_END/i net.ipv4.tcp_tw_recycle = 0" "$SYSCTL_CONF"
    echo -e "${YELLOW}⚠ 旧内核检测，添加NAT兼容参数${NC}"
fi
# 应用配置
echo -e "${YELLOW}8. 应用内核配置...${NC}"
sysctl -p >/dev/null 2>&1
echo -e "${GREEN}✅ 所有优化已应用完成！${NC}"
echo ""
# ==================== 最终输出 ====================
echo -e "${BLUE}=======================================================${NC}"
echo -e "${GREEN}🎉 生产级智能优化部署成功！${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""
echo -e "${YELLOW}🔍 验证命令${NC}"
echo -e "  ulimit -n                          # 应显示：$SYSTEM_MAX_FILE"
echo -e "  sysctl fs.file-max                 # 应显示：$EXPECTED_FS_FILE_MAX"
echo -e "  sysctl net.core.somaxconn          # 应显示：$EXPECTED_SOMAXCONN"
echo -e "  sysctl net.ipv4.tcp_retries2       # 应显示：$EXPECTED_TCP_RETRIES2"
if [ $AUTO_CALC_DONE -eq 1 ]; then
echo -e "  sysctl net.ipv4.tcp_rmem          # 应显示：$TCP_RMEM_EXPECTED"
echo -e "  sysctl net.ipv4.tcp_wmem          # 应显示：$TCP_WMEM_EXPECTED"
fi
if [ $BBR_ENABLED -eq 1 ]; then
echo -e "  sysctl net.core.default_qdisc      # 应显示：fq"
echo -e "  sysctl net.ipv4.tcp_congestion_control  # 应显示：bbr"
fi
echo ""
echo -e "${YELLOW}🏗️  应用层配置推荐（分级权威版）${NC}"
echo -e "${GREEN}通用场景（99%适用）：${NC}"
echo -e "  Nginx: worker_rlimit_nofile ${NGINX_GENERAL};"
echo -e "  MySQL: open_files_limit = ${MYSQL_GENERAL}"
echo -e "  PHP-FPM: rlimit_files = ${PHP_GENERAL}"
echo -e "  Redis: maxclients ${REDIS_GENERAL}"
echo -e "  Java: 无需额外配置（现代JVM自动适配）"
echo ""
echo -e "${YELLOW}高并发特殊场景：${NC}"
echo -e "  Nginx(CDN/大文件): worker_rlimit_nofile ${NGINX_HIGH};"
echo -e "  Redis(长连接/连接池): maxclients ${REDIS_HIGH}"
echo ""
# 代理场景专属提示
if [[ $SCENARIO -eq 5 ]]; then
    echo -e "${YELLOW}💡 代理网络专属优化已完成：${NC}"
    echo -e "  ✅ 启用激进快速失败策略，连接无响应约10秒自动断开"
    echo -e "  ✅ 优化网络中断处理时间，降低延迟"
    echo -e "  ✅ 禁用NAT环境下有问题的参数"
    if [ $BBR_ENABLED -eq 1 ]; then
    echo -e "  ✅ 自动启用BBR+fq最佳组合，视频流畅度显著提升"
    fi
    echo ""
fi
echo -e "${YELLOW}⚠️  生效说明：${NC}"
echo "1. 文件句柄需【完全关闭SSH重新登录】生效"
echo "2. 运行中的代理服务必须【重启】才能使用新配置"
echo "3. 建议【重启服务器】以确保所有参数完全生效"
echo ""
echo -e "${YELLOW}🔄 一键回滚${NC}"
echo "cp $BACKUP_DIR/limits.conf /etc/security/"
echo "cp $BACKUP_DIR/system.conf /etc/systemd/system.conf"
echo "cp $BACKUP_DIR/sysctl.conf /etc/"
echo "sysctl -p && systemctl daemon-reexec"
