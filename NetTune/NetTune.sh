#!/bin/bash
# Linux 生产环境高并发网络与系统优化脚本 v2.4
# 适用：Debian 9+/Ubuntu 16.04+/CentOS 7+/RHEL 7+/Alpine 3.10+
# 支持内核：3.10+ (纯bash内核版本检测，无任何外部依赖)
# 新增功能：业务场景选择，自动调整tcp_retries2参数
# 配置写入：/etc/sysctl.conf 主文件
# 注意：必须以 root 权限运行

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
BACKUP_DIR="/etc/optimize_backup_$(date +%Y%m%d_%H%M%S)"
SYSCTL_CONF="/etc/sysctl.conf"
LIMITS_CONF="/etc/security/limits.conf"
SYSTEMD_CONF="/etc/systemd/system.conf"
MARKER_START="# >>> LINUX_HIGH_CONCURRENCY_OPT_START >>>"
MARKER_END="# <<< LINUX_HIGH_CONCURRENCY_OPT_END <<<"

# 全局配置变量（用于动态生成验证提示）
EXPECTED_NOFILE=262144
EXPECTED_FS_FILE_MAX=1048576
EXPECTED_SOMAXCONN=65535
EXPECTED_TCP_RETRIES2=8
TCP_RMEM_EXPECTED=""
TCP_WMEM_EXPECTED=""
BBR_ENABLED=0
BBR_EXPECTED="bbr"

# 纯bash内核版本比较函数（无需bc依赖）
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

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：必须以 root 用户运行此脚本${NC}"
    exit 1
fi

# 打印标题
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}    Linux 生产环境高并发优化脚本 v2.4          ${NC}"
echo -e "${BLUE}    业务场景自适应 | 生产就绪版                ${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# 业务场景选择
echo -e "${YELLOW}0. 选择业务场景（将自动调整相关参数）${NC}"
echo "1. 高并发Web/API/反向代理 (推荐)"
echo "2. 通用业务服务器 (默认)"
echo "3. 数据库/缓存/长连接服务"
echo "4. 批处理/大数据/科学计算"
read -p "请输入选项(1-4，默认2): " SCENARIO
SCENARIO=${SCENARIO:-2}

case $SCENARIO in
    1)
        EXPECTED_TCP_RETRIES2=5
        TCP_FIN_TIMEOUT=15
        echo -e "${GREEN}✓ 已选择【高并发Web/API/反向代理】场景${NC}"
        echo -e "${YELLOW}将使用激进的快速失败策略${NC}"
        ;;
    2)
        EXPECTED_TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=15
        echo -e "${GREEN}✓ 已选择【通用业务服务器】场景${NC}"
        echo -e "${YELLOW}将使用平衡的参数配置${NC}"
        ;;
    3)
        EXPECTED_TCP_RETRIES2=12
        TCP_FIN_TIMEOUT=30
        echo -e "${GREEN}✓ 已选择【数据库/缓存/长连接服务】场景${NC}"
        echo -e "${YELLOW}将使用保守的连接保持策略${NC}"
        ;;
    4)
        EXPECTED_TCP_RETRIES2=15
        TCP_FIN_TIMEOUT=60
        echo -e "${GREEN}✓ 已选择【批处理/大数据/科学计算】场景${NC}"
        echo -e "${YELLOW}将使用系统默认的最保守策略${NC}"
        ;;
    *)
        EXPECTED_TCP_RETRIES2=8
        TCP_FIN_TIMEOUT=15
        echo -e "${YELLOW}⚠ 无效选项，使用默认【通用业务服务器】场景${NC}"
        ;;
esac
echo ""

# 备份原始配置
echo -e "${YELLOW}1. 备份原始配置...${NC}"
mkdir -p "$BACKUP_DIR"
cp "$LIMITS_CONF" "$BACKUP_DIR/"
cp "$SYSTEMD_CONF" "$BACKUP_DIR/"
cp "$SYSCTL_CONF" "$BACKUP_DIR/"
echo -e "${GREEN}✓ 所有原始配置已备份至：$BACKUP_DIR${NC}"
echo ""

# 清理旧的优化配置(使用标记块，安全无侵入)
echo -e "${YELLOW}2. 清理历史优化残留...${NC}"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$LIMITS_CONF"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$SYSCTL_CONF"
# 删除可能存在的旧独立配置文件，避免优先级冲突
[ -f "/etc/sysctl.d/99-high-concurrency.conf" ] && rm -f "/etc/sysctl.d/99-high-concurrency.conf"
echo -e "${GREEN}✓ 已清理历史优化配置${NC}"
echo ""

# 配置文件句柄限制(生产安全值262144)
echo -e "${YELLOW}3. 配置文件描述符限制...${NC}"
cat >> "$LIMITS_CONF" << EOF
$MARKER_START
# 单进程最大文件描述符数(生产安全值)
* soft nofile $EXPECTED_NOFILE
* hard nofile $EXPECTED_NOFILE
root soft nofile $EXPECTED_NOFILE
root hard nofile $EXPECTED_NOFILE
$MARKER_END
EOF
echo -e "${GREEN}✓ 已设置单进程最大句柄数为 $EXPECTED_NOFILE${NC}"

# 配置 systemd 全局限制(幂等操作，无竞态风险)
echo -e "${YELLOW}4. 配置 systemd 全局资源限制...${NC}"
if command -v systemctl &> /dev/null; then
    # 一行完成：匹配带#或不带#的行，统一替换为目标值
    sed -i "s/^#*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=$EXPECTED_NOFILE/" "$SYSTEMD_CONF"
    # 如果不存在则追加
    if ! grep -q "^DefaultLimitNOFILE=" "$SYSTEMD_CONF"; then
        echo "DefaultLimitNOFILE=$EXPECTED_NOFILE" >> "$SYSTEMD_CONF"
    fi
    # 重新加载 systemd 配置
    systemctl daemon-reexec 2>/dev/null
    echo -e "${GREEN}✓ 已设置 systemd 全局句柄限制${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到 systemd，跳过 systemd 配置${NC}"
fi
echo ""

# TCP缓冲区自动计算
echo -e "${YELLOW}5. TCP缓冲区配置...${NC}"
TCP_BUFFER_CONFIG=""
AUTO_CALC_DONE=0

read -p "是否自动计算TCP缓冲区参数？(y/n，默认y): " AUTO_CALC
AUTO_CALC=${AUTO_CALC:-y}

if [[ "$AUTO_CALC" == "y" || "$AUTO_CALC" == "Y" ]]; then
    # 输入验证
    while true; do
        read -p "请输入服务器实际带宽(Mbps): " BANDWIDTH
        if [[ "$BANDWIDTH" =~ ^[0-9]+$ && "$BANDWIDTH" -gt 0 ]]; then
            break
        else
            echo -e "${RED}请输入有效的正整数${NC}"
        fi
    done

    while true; do
        read -p "请输入平均往返延迟(ms): " RTT_MS
        if [[ "$RTT_MS" =~ ^[0-9]+$ && "$RTT_MS" -gt 0 ]]; then
            break
        else
            echo -e "${RED}请输入有效的正整数${NC}"
        fi
    done

    # 计算BDP (带宽延迟乘积)
    BDP_BYTES=$(( BANDWIDTH * 1024 * 1024 * RTT_MS / 8 / 1000 ))

    # 计算TCP缓冲区参数
    TCP_RMEM_MIN=4096
    TCP_RMEM_DEFAULT=$(( BDP_BYTES / 2 ))
    TCP_RMEM_MAX=$(( BDP_BYTES * 2 ))

    TCP_WMEM_MIN=4096
    TCP_WMEM_DEFAULT=$(( BDP_BYTES / 2 ))
    TCP_WMEM_MAX=$(( BDP_BYTES * 2 ))

    # 计算全局core参数（和TCP对齐）
    CORE_RMEM_DEFAULT=$TCP_RMEM_DEFAULT
    CORE_WMEM_DEFAULT=$TCP_WMEM_DEFAULT
    CORE_RMEM_MAX=$TCP_RMEM_MAX
    CORE_WMEM_MAX=$TCP_WMEM_MAX

    # 保存用于验证提示
    TCP_RMEM_EXPECTED="$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX"
    TCP_WMEM_EXPECTED="$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"
    AUTO_CALC_DONE=1

    # 生成配置
    TCP_BUFFER_CONFIG="# TCP 缓冲区优化 (${BANDWIDTH}Mbps @ ${RTT_MS}ms，自动计算)
net.core.rmem_default = $CORE_RMEM_DEFAULT
net.core.wmem_default = $CORE_WMEM_DEFAULT
net.core.rmem_max = $CORE_RMEM_MAX
net.core.wmem_max = $CORE_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX
net.ipv4.tcp_wmem = $TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"

    echo -e "${GREEN}✓ TCP缓冲区参数计算完成${NC}"
    echo -e "${BLUE}BDP(带宽延迟乘积)：${BDP_BYTES} 字节${NC}"
else
    TCP_BUFFER_CONFIG="# --- 手动配置TCP缓冲区 ---
# 取消注释并修改以下参数
# net.core.rmem_default = 65536
# net.core.wmem_default = 65536
# net.core.rmem_max = 262144
# net.core.wmem_max = 262144
# net.ipv4.tcp_rmem = 4096 32768 262144
# net.ipv4.tcp_wmem = 4096 32768 262144"
    echo -e "${YELLOW}✓ 将使用手动配置模板${NC}"
fi
echo ""

# BBR配置
echo -e "${YELLOW}6. BBR拥塞控制配置...${NC}"
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
echo -e "${BLUE}检测到内核版本：$KERNEL_VERSION${NC}"
BBR_CONFIG=""

if kernel_lt "$KERNEL_VERSION" "4.9"; then
    echo -e "${YELLOW}⚠ 内核版本低于4.9，不支持BBR拥塞控制${NC}"
else
    read -p "是否启用BBR拥塞控制？(y/n，默认y): " ENABLE_BBR
    ENABLE_BBR=${ENABLE_BBR:-y}

    if [[ "$ENABLE_BBR" == "y" || "$ENABLE_BBR" == "Y" ]]; then
        modprobe tcp_bbr 2>/dev/null
        if lsmod | grep -q tcp_bbr; then
            BBR_CONFIG="# BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
            BBR_ENABLED=1
            echo -e "${GREEN}✓ 已启用BBR拥塞控制${NC}"
        else
            echo -e "${RED}✗ BBR模块加载失败，将使用默认拥塞控制${NC}"
        fi
    else
        echo -e "${YELLOW}✓ 跳过BBR配置${NC}"
    fi
fi
echo ""

# 生成内核网络优化配置(写入主sysctl.conf)
echo -e "${YELLOW}7. 生成内核网络优化配置...${NC}"
cat >> "$SYSCTL_CONF" << EOF
$MARKER_START
# ==============================================
# Linux 生产环境高并发内核优化
# 业务场景：$SCENARIO_DESC
# 自动生成，请勿手动修改自动生成部分
# ==============================================

# 系统级文件描述符总上限(单进程的4倍，留出足够系统余量)
fs.file-max = $EXPECTED_FS_FILE_MAX

# 连接队列优化
net.core.somaxconn = $EXPECTED_SOMAXCONN
net.core.netdev_max_backlog = 65535
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# TCP 基础优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $TCP_FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# 端口范围扩展
net.ipv4.ip_local_port_range = 1024 65534

# 减少无效重传
# tcp_retries2 = $EXPECTED_TCP_RETRIES2 对应总超时时间约 $RETRIES2_TIMEOUT
net.ipv4.tcp_retries2 = $EXPECTED_TCP_RETRIES2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 反向路径过滤(宽松模式2，兼容Docker/K8s/多网卡)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# ==============================================
# 自动计算的TCP缓冲区配置
# ==============================================

$TCP_BUFFER_CONFIG

# ==============================================
# BBR拥塞控制配置
# ==============================================

$BBR_CONFIG

$MARKER_END
EOF

# 计算超时时间用于注释
case $EXPECTED_TCP_RETRIES2 in
    5) RETRIES2_TIMEOUT="25秒" ;;
    8) RETRIES2_TIMEOUT="1分钟" ;;
    12) RETRIES2_TIMEOUT="5分钟" ;;
    15) RETRIES2_TIMEOUT="15分钟" ;;
    *) RETRIES2_TIMEOUT="未知" ;;
esac

# 添加场景描述到配置文件
case $SCENARIO in
    1) SCENARIO_DESC="高并发Web/API/反向代理" ;;
    2) SCENARIO_DESC="通用业务服务器" ;;
    3) SCENARIO_DESC="数据库/缓存/长连接服务" ;;
    4) SCENARIO_DESC="批处理/大数据/科学计算" ;;
    *) SCENARIO_DESC="通用业务服务器" ;;
esac

# 替换配置文件中的场景描述和超时时间
sed -i "s/\$SCENARIO_DESC/$SCENARIO_DESC/" "$SYSCTL_CONF"
sed -i "s/\$RETRIES2_TIMEOUT/$RETRIES2_TIMEOUT/" "$SYSCTL_CONF"

# 仅在 4.12 以下内核添加已废弃参数
if kernel_lt "$KERNEL_VERSION" "4.12"; then
    # 在标记块末尾添加兼容参数
    sed -i "/$MARKER_END/i net.ipv4.tcp_tw_recycle = 0" "$SYSCTL_CONF"
    echo -e "${YELLOW}⚠ 旧内核检测，添加 tcp_tw_recycle=0 兼容${NC}"
fi
echo ""

# 应用内核配置
echo -e "${YELLOW}8. 应用内核配置...${NC}"
if sysctl -p; then
    echo -e "${GREEN}✓ 所有内核配置已成功加载${NC}"
else
    echo -e "${RED}✗ 部分内核配置加载失败，请检查错误信息${NC}"
    echo -e "${YELLOW}⚠ 不影响已成功加载的配置${NC}"
fi
echo ""

# 完成提示
echo -e "${BLUE}=============================================${NC}"
echo -e "${GREEN}✅ 生产级高并发优化已完成！${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""
echo -e "${YELLOW}重要生效说明：${NC}"
echo -e "1. 文件句柄限制需要${RED}完全关闭SSH窗口重新登录${NC}才能生效"
echo -e "2. 已运行的服务需要${RED}手动重启${NC}才能应用新的句柄限制"
echo -e "3. 建议${RED}重启服务器${NC}以确保所有配置完全生效"
echo ""
echo -e "${YELLOW}验证命令：${NC}"
echo -e "  ulimit -n                          # 验证单进程句柄数(应显示 $EXPECTED_NOFILE)"
echo -e "  sysctl fs.file-max                 # 验证系统级句柄上限(应显示 $EXPECTED_FS_FILE_MAX)"
echo -e "  sysctl net.core.somaxconn          # 验证连接队列长度(应显示 $EXPECTED_SOMAXCONN)"
echo -e "  sysctl net.ipv4.tcp_retries2       # 验证TCP重传次数(应显示 $EXPECTED_TCP_RETRIES2)"

# 动态添加TCP缓冲区验证提示
if [[ $AUTO_CALC_DONE -eq 1 ]]; then
    echo -e "  sysctl net.ipv4.tcp_rmem          # 验证TCP接收缓冲区(应显示 $TCP_RMEM_EXPECTED)"
    echo -e "  sysctl net.ipv4.tcp_wmem          # 验证TCP发送缓冲区(应显示 $TCP_WMEM_EXPECTED)"
fi

# 动态添加BBR验证提示
if [[ $BBR_ENABLED -eq 1 ]]; then
    echo -e "  sysctl net.ipv4.tcp_congestion_control  # 验证BBR是否启用(应显示 $BBR_EXPECTED)"
fi

echo ""
echo -e "${YELLOW}一键回滚命令：${NC}"
echo -e "cp $BACKUP_DIR/limits.conf /etc/security/"
echo -e "cp $BACKUP_DIR/system.conf /etc/systemd/system.conf"
echo -e "cp $BACKUP_DIR/sysctl.conf /etc/"
echo -e "sysctl -p && systemctl daemon-reexec"
echo ""
echo -e "${YELLOW}应用层配套配置：${NC}"
echo -e "- Nginx: http 块添加 worker_rlimit_nofile $EXPECTED_NOFILE;"
echo -e "- MySQL: my.cnf 添加 open_files_limit = $EXPECTED_NOFILE"
echo -e "- Redis: redis.conf 添加 maxclients 65535"
echo -e "- PHP: php-fpm.conf 添加 rlimit_files = $EXPECTED_NOFILE"
echo -e "- Java: 启动参数添加 -XX:-MaxFDLimit"
echo ""
echo -e "${YELLOW}特别说明：${NC}"
if [[ $SCENARIO -eq 1 ]]; then
    echo -e "已启用快速失败策略，连接无响应${RETRIES2_TIMEOUT}后将自动断开"
    echo -e "适合Nginx、API网关、反向代理等对延迟敏感的服务"
elif [[ $SCENARIO -eq 3 ]]; then
    echo -e "已启用保守连接保持策略，连接无响应${RETRIES2_TIMEOUT}后才会断开"
    echo -e "适合MySQL、PostgreSQL、Redis等长连接服务"
elif [[ $SCENARIO -eq 4 ]]; then
    echo -e "已使用系统默认最保守策略，连接无响应${RETRIES2_TIMEOUT}后才会断开"
    echo -e "适合批处理、大数据计算等长时间运行的任务"
fi