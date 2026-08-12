#!/bin/bash
set -eo pipefail
# ==================== 配置区 ====================
TOTAL_SPEED="15M"          # 总带宽（aria2原生总限速）
CONCURRENCY=5             # 并发数
DURATION=14400             # 运行时长（秒）
CONNECT_TIMEOUT=5          # 连接超时
LOWEST_SPEED="200K"        # 低速阈值：低于此速度算异常
SPEED_TIMEOUT=30           # 低速持续秒数：超过则断开切换
SLEEP_MIN_FLOAT=1.0        # 微休眠下限（下载完一个后）
SLEEP_MAX_FLOAT=1.5        # 微休眠上限
DOWNLOAD_DIR="/var/tmp/ai_traffic"   # 下载目录（下载完自动删除，需足够磁盘空间）
CC_CRAWLS=(                # Common Crawl 爬取ID（6个，约30万条WARC）
    "CC-MAIN-2024-26"
    "CC-MAIN-2024-22"
    "CC-MAIN-2024-18"
    "CC-MAIN-2024-10"
    "CC-MAIN-2023-50"
)
# ==============================================

# ==================== 互斥清理 ====================
echo ""
echo "============================================"
echo " 互斥检查：清理旧任务残留进程..."
echo "============================================"
pkill -9 -f "aria2c.*ai_traffic"  2>/dev/null || true
pkill -9 -f "aria2c.*input-file"  2>/dev/null || true
pkill -9 -f "limit-rate"          2>/dev/null || true
pkill -9 -f "timeout.*curl"       2>/dev/null || true
OLD_PIDS=$(pgrep -f "ai_traffic.*\.sh" 2>/dev/null | grep -v "^$$$" || true)
if [ -n "$OLD_PIDS" ]; then
    echo "$OLD_PIDS" | xargs kill -9 2>/dev/null || true
    echo "  已结束旧脚本 PID: $OLD_PIDS"
fi
sleep 2
REMAIN=$(pgrep -f "aria2c" 2>/dev/null || true)
[ -z "$REMAIN" ] && echo "✅ 旧任务已彻底清理干净" || echo "⚠️  仍有残留: $REMAIN"

# ==================== 环境检查 ====================
if ! command -v aria2c &>/dev/null; then
    echo "检测到未安装 aria2，正在安装..."
    apt update -qq && apt install -y -qq aria2
fi

mkdir -p "$DOWNLOAD_DIR"

# 临时文件路径
URL_FILE="/tmp/aria2_urls_$$.txt"
HOOK_FILE="/tmp/aria2_hook_$$.sh"

# ==================== 创建下载完成钩子（微休眠+自动删除）====================
cat > "$HOOK_FILE" << 'HOOKEOF'
#!/bin/bash
# aria2 钩子参数：$1=GID $2=文件数 $3=文件路径
sleep $(awk -v min="$SLEEP_MIN" -v max="$SLEEP_MAX" -v seed="$RANDOM" \
    'BEGIN{srand(seed); print min+rand()*(max-min)}')
rm -f "$3"
HOOKEOF
chmod +x "$HOOK_FILE"

# ==================== 构建 URL 池 ====================
URL_LIST=()

# ---- 1. Common Crawl（主力）----
echo ""
echo "正在从 Common Crawl 获取 WARC 文件列表..."
for crawl in "${CC_CRAWLS[@]}"; do
    echo "  下载 ${crawl}/warc.paths.gz ..."
    paths_file="/tmp/${crawl}-warc.paths.gz"
    if curl -s -L --fail --connect-timeout 15 --max-time 60 \
        "https://data.commoncrawl.org/crawl-data/${crawl}/warc.paths.gz" \
        -o "$paths_file" 2>/dev/null; then
        count=$(zcat "$paths_file" 2>/dev/null | wc -l)
        echo "  ✅ 成功，解析出 ${count} 个 WARC 路径"
        while IFS= read -r path; do
            [ -n "$path" ] && URL_LIST+=("https://data.commoncrawl.org/${path}")
        done < <(zcat "$paths_file" 2>/dev/null)
        rm -f "$paths_file"
    else
        echo "  ❌ 下载失败，跳过 ${crawl}"
        rm -f "$paths_file"
    fi
done

# ---- 2. OpenAlex 学术图谱 ----
echo ""
echo "添加 OpenAlex 学术数据链接..."
for days_ago in $(seq 1 30); do
    day_date=$(date -d "$days_ago days ago" '+%Y-%m-%d')
    for part in $(seq -w 0 9); do
        URL_LIST+=("https://openalex.s3.amazonaws.com/data/works/updated_date=${day_date}/part_00${part}.gz")
    done
done
echo "  ✅ 添加 300 条 OpenAlex 链接"

# ---- 3. 备用大文件 ----
URL_LIST+=(
    "https://repo.huaweicloud.com/rockylinux/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso"
    "https://repo.huaweicloud.com/rockylinux/8/isos/x86_64/Rocky-8-latest-x86_64-dvd1.iso"
    "https://repo.huaweicloud.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    "https://repo.huaweicloud.com/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
    "https://developer.download.nvidia.com/compute/cuda/12.5.1/local_installers/cuda_12.5.1_555.42.06_linux.run"
    "https://developer.download.nvidia.com/compute/cuda/12.4.1/local_installers/cuda_12.4.1_550.54.15_linux.run"
    "https://repo.anaconda.com/archive/Anaconda3-2024.06-1-Linux-x86_64.sh"
)

if [ "${#URL_LIST[@]}" -eq 0 ]; then
    echo "【致命错误】URL池为空"
    exit 1
fi

# 写入 URL 列表文件
printf '%s\n' "${URL_LIST[@]}" > "$URL_FILE"
echo ""
echo "URL池构建完成，共 ${#URL_LIST[@]} 条，已写入 $URL_FILE"
echo ""
echo "域名分布："
printf '%s\n' "${URL_LIST[@]}" | awk -F/ '{print $3}' | sort | uniq -c | sort -rn

# ==================== 启动横幅 ====================
START_TIME=$(date +%s)
END_TIME=$(( START_TIME + DURATION ))
echo ""
echo "============================================"
echo " AI数据集流量生成器（aria2版）"
echo " URL总数：${#URL_LIST[@]} 条 | 全部公开无需token"
echo " 总限速: $TOTAL_SPEED（aria2原生总限速）"
echo " 并发: $CONCURRENCY | 低速检测: <${LOWEST_SPEED}持续${SPEED_TIMEOUT}s自动断开"
echo " 微休眠: ${SLEEP_MIN_FLOAT}~${SLEEP_MAX_FLOAT}s（下载完自动删除文件）"
echo " 下载目录: $DOWNLOAD_DIR（峰值占用约$((CONCURRENCY))GB）"
echo " 运行时长: $((DURATION/3600))小时，到点自动停止"
echo " 开始: $(date '+%Y-%m-%d %H:%M:%S')"
echo " 截止: $(date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# ==================== 启动 aria2 ====================
export SLEEP_MIN="$SLEEP_MIN_FLOAT"
export SLEEP_MAX="$SLEEP_MAX_FLOAT"

set +e
timeout --signal=TERM --kill-after=10 "${DURATION}s" aria2c \
    --input-file="$URL_FILE" \
    --max-concurrent-downloads="$CONCURRENCY" \
    --max-overall-download-limit="$TOTAL_SPEED" \
    --lowest-speed-limit="$LOWEST_SPEED" \
    --timeout="$SPEED_TIMEOUT" \
    --connect-timeout="$CONNECT_TIMEOUT" \
    --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36" \
    --dir="$DOWNLOAD_DIR" \
    --file-allocation=none \
    --on-download-complete="$HOOK_FILE" \
    --on-download-error="$HOOK_FILE" \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --max-tries=1 \
    --retry-wait=0 \
    --max-file-not-found=0 \
    --continue=false \
    --remote-time=false \
    --summary-interval=0 \
    --download-result=hide \
    --console-log-level=warn \
    --show-console-readout=false \
    2>&1
ARIA2_EXIT=$?
set -e

# ==================== 清理 ====================
echo ""
echo "正在清理临时文件..."
pkill -9 -f "aria2c.*$$" 2>/dev/null || true
rm -rf "$DOWNLOAD_DIR" "$URL_FILE" "$HOOK_FILE" 2>/dev/null || true

echo ""
echo "============================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束（aria2退出码: $ARIA2_EXIT）"
echo "============================================"
