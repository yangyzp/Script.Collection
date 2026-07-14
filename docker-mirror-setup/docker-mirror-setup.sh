#!/bin/bash
# Docker 镜像加速一键配置脚本
# 数据源: https://status.anye.xyz/ (实时监控 Docker Hub 镜像站可用性)

set -e

API_URL="https://status.anye.xyz/status/hub"
DAEMON_FILE="/etc/docker/daemon.json"

echo "=========================================="
echo "  Docker 镜像加速一键配置脚本"
echo "  数据源: status.anye.xyz (实时可用地址)"
echo "  筛选: 仅公开免费 / 无需登录 / 在线可用"
echo "=========================================="
echo ""

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 权限运行此脚本 (sudo bash $0)"
    exit 1
fi

# 检查 docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "[错误] 未检测到 Docker，请先安装 Docker 后再运行此脚本"
    exit 1
fi

# 拉取镜像站数据
echo "[1/4] 正在从 status.anye.xyz 获取实时可用镜像列表..."
RAW_DATA=$(curl -s -H "Accept: application/json" "$API_URL")

if [ -z "$RAW_DATA" ] || [ "$RAW_DATA" = "[]" ]; then
    echo "[错误] 获取镜像列表失败，请检查网络连接"
    exit 1
fi

# 解析 JSON 并筛选（双重保险：access=public + 标签不含付费/登录）
# 筛选条件: 在线 + 公开 + 可选 + 非官方 + 标签不含"付费/登录/登陆"
if command -v jq &> /dev/null; then
    MIRRORS=$(echo "$RAW_DATA" | jq -r '
        .[] |
        select(.status=="online") |
        select(.access=="public") |
        select(.selectable==true) |
        select(.official==false) |
        select([.tags[].name] | all(contains("付费") or contains("登录") or contains("登陆") | not)) |
        .url
    ')
elif command -v python3 &> /dev/null; then
    MIRRORS=$(echo "$RAW_DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data:
    tags = [t['name'] for t in m.get('tags', [])]
    has_pay_or_login = any(('付费' in t) or ('登录' in t) or ('登陆' in t) for t in tags)
    if (m.get('status') == 'online'
        and m.get('access') == 'public'
        and m.get('selectable') == True
        and m.get('official') == False
        and not has_pay_or_login):
        print(m['url'])
")
else
    echo "[错误] 未找到 jq 或 python3，请先安装其中一个: apt install jq"
    exit 1
fi

if [ -z "$MIRRORS" ]; then
    echo "[错误] 未筛选到可用的公开镜像站"
    exit 1
fi

# 统计数量并展示
MIRROR_COUNT=$(echo "$MIRRORS" | wc -l)
echo ""
echo "[2/4] 获取成功，共筛选到 ${MIRROR_COUNT} 个实时可用的公开免费镜像站："
echo "----------------------------------------"
i=1
while IFS= read -r url; do
    echo "  $i. $url"
    i=$((i + 1))
done <<< "$MIRRORS"
echo "----------------------------------------"
echo ""

# 生成 registry-mirrors JSON 数组
MIRROR_JSON=$(echo "$MIRRORS" | awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"", $0} END{print "]"}')

# 备份原有 daemon.json（如果存在）
if [ -f "$DAEMON_FILE" ]; then
    BACKUP_FILE="${DAEMON_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DAEMON_FILE" "$BACKUP_FILE"
    echo "[3/4] 已备份原有配置到: $BACKUP_FILE"
else
    echo "[3/4] 原有配置不存在，将新建配置文件"
fi

# 创建目录并写入新配置
mkdir -p /etc/docker

# 如果原有 daemon.json 存在且包含其他配置，合并 registry-mirrors 字段而不是覆盖
if [ -f "$DAEMON_FILE" ] && command -v python3 &> /dev/null; then
    python3 -c "
import json

mirrors = $MIRROR_JSON

try:
    with open('$DAEMON_FILE', 'r') as f:
        config = json.load(f)
except:
    config = {}

config['registry-mirrors'] = mirrors

with open('$DAEMON_FILE', 'w') as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write('\n')
"
    echo "       已合并 registry-mirrors 到现有 daemon.json"
else
    cat > "$DAEMON_FILE" <<EOF
{
    "registry-mirrors": $MIRROR_JSON
}
EOF
    echo "       已写入新的 daemon.json"
fi

echo ""
echo "[4/4] 正在重启 Docker 服务..."
systemctl daemon-reload
systemctl restart docker

echo ""
echo "=========================================="
echo "  配置完成！"
echo "=========================================="
echo ""
echo "当前生效的镜像加速配置："
docker info 2>/dev/null | grep -A 10 "Registry Mirrors" || cat "$DAEMON_FILE"
echo ""
echo "测试拉取: docker pull hello-world"