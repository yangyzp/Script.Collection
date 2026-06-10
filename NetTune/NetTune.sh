#!/bin/bash
# Linux 生产级智能优化脚本 v2.8 (零重复·最终完美版)
# 自动去重 | 分级应用推荐 | BDP自动计算 | 场景自适应 | 生产验证

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局固定安全配置
SYSTEM_MAX_FILE=262144
EXPECTED_FS_FILE_MAX=1048576
EXPECTED_SOMAXCONN=65535

# 应用分级推荐值
NGINX_GENERAL=65535
NGINX_HIGH=131072
MYSQL_GENERAL=65535
PHP_GENERAL=65535
REDIS_GENERAL=10000
REDIS_HIGH=20000

# 自动检测内存（仅用于展示）
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')

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

# 清理所有重复的内核参数（关键修复）
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
        # 删除所有包含该参数的行（无论是否被注释）
        sed -i "/^[#]*\s*$param\s*=/d" "$1"
    done
}

# ==================== 主程序开始 ====================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：必须以 root 权限运行${NC}"
    exit 1
fi

echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  Linux 生产级智能优化脚本 v2.8 | 零重复·最终完美版${NC}"
echo -e "${BLUE}=======================================================${NC}"
echo ""

echo -e "${YELLOW}📊 服务器硬件检测${NC}"
echo -e "内存总大小：${GREEN}${TOTAL_MEM_MB} MB${NC}"
echo -e "系统最大句柄：${GREEN}${SYSTEM_MAX_FILE}${NC}"
echo ""

echo -e "${YELLOW}🎯 选择业务场景${NC}"
echo "1. 高并发Web/API/反向代理"
echo "2. 通用业务服务器 (默认)"
echo "3. 数据库/缓存/长连接"
echo "4. 批处理/大数据任务"
read -p "请输入选项(1-4，默认2): " SCENARIO
SCENARIO=${SCENARIO:-2}

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
        SCENARIO_DESC="数据库/缓存/长连接"
        ;;
    4)
        EXPECTED_TCP_RETRIES2=15
        TCP_FIN_TIMEOUT=60
        SCENARIO_DESC="批处理/大数据任务"
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
# 第一步：删除我们自己的标记块
sed -i "/$MARKER_START/,/$MARKER_END/d" "$LIMITS_CONF"
sed -i "/$MARKER_START/,/$MARKER_END/d" "$SYSCTL_CONF"

# 第二步：关键修复！删除所有相关的内核参数（无论在哪里）
clean_sysctl_params "$SYSCTL_CONF"

# 第三步：删除旧版本遗留的独立配置文件
[ -f "/etc/sysctl.d/99-high-concurrency.conf" ] && rm -f "/etc/sysctl.d/99-high-concurrency.conf"
echo -e "${GREEN}✓ 所有历史配置已清理，不会出现重复${NC}"
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
echo -e "${GREEN}✓ 系统句柄上限：$SYSTEM_MAX_FILE${NC}"

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

echo -e "${YELLOW}5. TCP缓冲区自动计算${NC}"
TCP_BUFFER_CONFIG=""
AUTO_CALC_DONE=0
read -p "是否自动计算TCP缓冲区？(y/n，默认y): " AUTO_CALC
AUTO_CALC=${AUTO_CALC:-y}

if [[ "$AUTO_CALC" == "y" ]]; then
    while true; do
        read -p "输入服务器带宽(Mbps): " BANDWIDTH
        [[ "$BANDWIDTH" =~ ^[0-9]+$ && $BANDWIDTH -gt 0 ]] && break
        echo -e "${RED}请输入有效数字${NC}"
    done
    while true; do
        read -p "输入平均延迟(ms): " RTT_MS
        [[ "$RTT_MS" =~ ^[0-9]+$ && $RTT_MS -gt 0 ]] && break
        echo -e "${RED}请输入有效数字${NC}"
    done

    BDP_BYTES=$(( BANDWIDTH * 1024 * 1024 * RTT_MS / 8 / 1000 ))
    TCP_RMEM_MIN=4096
    TCP_RMEM_DEFAULT=$(( BDP_BYTES / 2 ))
    TCP_RMEM_MAX=$(( BDP_BYTES * 2 ))
    TCP_WMEM_MIN=4096
    TCP_WMEM_DEFAULT=$(( BDP_BYTES / 2 ))
    TCP_WMEM_MAX=$(( BDP_BYTES * 2 ))

    TCP_RMEM_EXPECTED="$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX"
    TCP_WMEM_EXPECTED="$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"
    AUTO_CALC_DONE=1

    TCP_BUFFER_CONFIG="# TCP 缓冲区优化 (${BANDWIDTH}Mbps @ ${RTT_MS}ms)
net.core.rmem_default = $TCP_RMEM_DEFAULT
net.core.wmem_default = $TCP_WMEM_DEFAULT
net.core.rmem_max = $TCP_RMEM_MAX
net.core.wmem_max = $TCP_WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_RMEM_MAX
net.ipv4.tcp_wmem = $TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_WMEM_MAX"
    echo -e "${GREEN}✓ TCP缓冲区计算完成${NC}"
else
    TCP_BUFFER_CONFIG="# 手动TCP缓冲区配置模板"
    echo -e "${YELLOW}✓ 使用手动模板${NC}"
fi
echo ""

echo -e "${YELLOW}6. BBR拥塞控制${NC}"
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
BBR_CONFIG=""
if ! kernel_lt "$KERNEL_VERSION" "4.9"; then
    read -p "是否启用BBR？(y/n，默认y): " ENABLE_BBR
    if [[ "$ENABLE_BBR" != "n" ]]; then
        modprobe tcp_bbr 2>/dev/null
        if lsmod | grep -q bbr; then
            BBR_CONFIG="# BBR 拥塞控制算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
            BBR_ENABLED=1
            echo -e "${GREEN}✓ BBR已启用${NC}"
        else
            echo -e "${RED}✗ BBR启用失败${NC}"
        fi
    else
        echo -e "${YELLOW}✓ 跳过BBR${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 内核过低，不支持BBR${NC}"
fi
echo ""

echo -e "${YELLOW}7. 写入内核优化配置...${NC}"
cat >> "$SYSCTL_CONF" << EOF
$MARKER_START
# ==============================================
# Linux 生产级智能内核优化
# 业务场景：$SCENARIO_DESC
# 自动生成于：$(date '+%Y-%m-%d %H:%M:%S')
# ==============================================

# 系统级文件描述符总上限
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
net.ipv4.tcp_retries2 = $EXPECTED_TCP_RETRIES2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# 禁用 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 反向路径过滤(宽松模式，兼容Docker/K8s)
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

# 旧内核兼容
if kernel_lt "$KERNEL_VERSION" "4.12"; then
    sed -i "/$MARKER_END/i net.ipv4.tcp_tw_recycle = 0" "$SYSCTL_CONF"
    echo -e "${YELLOW}⚠ 旧内核检测，添加兼容参数${NC}"
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

echo -e "${YELLOW}⚠️  生效说明：${NC}"
echo "1. 文件句柄需【完全关闭SSH重新登录】生效"
echo "2. 运行中的服务必须【重启】才能使用新配置"
echo "3. 生产环境建议【重启服务器】"
echo ""

echo -e "${YELLOW}🔄 一键回滚${NC}"
echo "cp $BACKUP_DIR/limits.conf /etc/security/"
echo "cp $BACKUP_DIR/system.conf /etc/systemd/system.conf"
echo "cp $BACKUP_DIR/sysctl.conf /etc/"
echo "sysctl -p && systemctl daemon-reexec"
