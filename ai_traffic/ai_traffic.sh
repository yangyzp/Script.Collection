#!/bin/bash
set -eo pipefail

# ==================== 配置区 ====================
TOTAL_SPEED="20M"          # 总带宽
CONCURRENCY=5              # 并发数
DURATION=7200              # 运行时长（秒）
CONNECT_TIMEOUT=8          # 连接超时
SLEEP_MIN_FLOAT=0.3        # 微休眠下限
SLEEP_MAX_FLOAT=1.5        # 微休眠上限
MAX_SAME_DOMAIN=5          # 单线程连续命中同一站点上限
CC_CRAWLS=(                # Common Crawl 爬取ID（永久保存在S3，可自行增减）
    "CC-MAIN-2024-26"
    "CC-MAIN-2024-22"
)
# ==============================================

# 自动均分带宽
SPEED_NUM=$(echo "$TOTAL_SPEED" | sed 's/[^0-9]//g')
SPEED_UNIT=$(echo "$TOTAL_SPEED" | sed 's/[0-9]//g')
PER_WORKER_NUM=$(( SPEED_NUM / CONCURRENCY ))
PER_WORKER_SPEED="${PER_WORKER_NUM}${SPEED_UNIT}"
ACTUAL_TOTAL=$(( PER_WORKER_NUM * CONCURRENCY ))

if [ "$PER_WORKER_NUM" -le 0 ]; then
    echo "【致命错误】带宽分配为0，请修改 TOTAL_SPEED/CONCURRENCY"
    exit 1
fi
if [ "$ACTUAL_TOTAL" -ne "$SPEED_NUM" ]; then
    echo "⚠️ 警告：无法整除，实际总限速仅 ${ACTUAL_TOTAL}${SPEED_UNIT}"
else
    echo "✅ 带宽均分正常，精准达到 $TOTAL_SPEED"
fi

# ==================== 构建 URL 池 ====================
URL_LIST=()

# ---- 1. Common Crawl（主力，约10万个WARC文件，每个~1GB，完全公开无需token）----
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

# ---- 2. Wikimedia 最新数据库备份（latest 永久链接，单文件10~20GB）----
echo ""
echo "添加 Wikimedia Dumps 链接..."
WIKI_DUMPS=(
    "enwiki/latest/enwiki-latest-pages-articles-multistream.xml.bz2"
    "enwiki/latest/enwiki-latest-pages-articles.xml.bz2"
    "enwiki/latest/enwiki-latest-pages-logging.xml.bz2"
    "enwiki/latest/enwiki-latest-stub-articles.xml.bz2"
    "enwiki/latest/enwiki-latest-abstract.xml.gz"
    "zhwiki/latest/zhwiki-latest-pages-articles-multistream.xml.bz2"
    "zhwiki/latest/zhwiki-latest-pages-articles.xml.bz2"
    "zhwiki/latest/zhwiki-latest-pages-logging.xml.bz2"
    "dewiki/latest/dewiki-latest-pages-articles-multistream.xml.bz2"
    "frwiki/latest/frwiki-latest-pages-articles-multistream.xml.bz2"
    "jawiki/latest/jawiki-latest-pages-articles-multistream.xml.bz2"
    "eswiki/latest/eswiki-latest-pages-articles-multistream.xml.bz2"
    "ruwiki/latest/ruwiki-latest-pages-articles-multistream.xml.bz2"
    "commonswiki/latest/commonswiki-latest-pages-articles-multistream.xml.bz2"
    "wikidatawiki/latest/wikidatawiki-latest-pages-articles-multistream.xml.bz2"
)
for path in "${WIKI_DUMPS[@]}"; do
    URL_LIST+=("https://dumps.wikimedia.org/${path}")
done

# ---- 3. 备用大文件（镜像ISO等，防止前两个源都出问题）----
URL_LIST+=(
    "https://repo.huaweicloud.com/rockylinux/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso"
    "https://repo.huaweicloud.com/rockylinux/8/isos/x86_64/Rocky-8-latest-x86_64-dvd1.iso"
    "https://repo.huaweicloud.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    "https://repo.huaweicloud.com/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
    "https://developer.download.nvidia.com/compute/cuda/12.5.1/local_installers/cuda_12.5.1_555.42.06_linux.run"
    "https://developer.download.nvidia.com/compute/cuda/12.4.1/local_installers/cuda_12.4.1_550.54.15_linux.run"
    "https://repo.anaconda.com/archive/Anaconda3-2024.06-1-Linux-x86_64.sh"
)

# 检查URL池是否为空
if [ "${#URL_LIST[@]}" -eq 0 ]; then
    echo "【致命错误】URL池为空，所有数据源均获取失败，请检查网络"
    exit 1
fi

echo ""
echo "URL池构建完成，共 ${#URL_LIST[@]} 条"
echo ""
echo "域名分布："
printf '%s\n' "${URL_LIST[@]}" | awk -F/ '{print $3}' | sort | uniq -c | sort -rn

# ==================== UA 列表 ====================
UA_LIST=(
"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
"Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0"
"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
"Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0"
)

# ==================== 工具函数 ====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
}

get_domain() {
    echo "$1" | awk -F/ '{print $3}'
}

# 【修复】递归杀死整个进程树（worker → timeout → curl 三层全部杀光）
kill_tree() {
    local pid="$1"
    # 校验pid合法性
    [ -z "$pid" ] && return
    [ "$pid" -le 0 ] 2>/dev/null && return

    # 先递归杀所有子进程（孙子进程也会被递归到）
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
        kill_tree "$child"
    done

    # 再杀自己
    kill -9 "$pid" 2>/dev/null || true
}

# 【新增】全局兜底清理：杀掉所有带 --limit-rate 的 curl 和 timeout
global_cleanup() {
    # 精准匹配脚本启动的下载进程（带 limit-rate 参数，不会误杀系统其他curl）
    pkill -9 -f "limit-rate" 2>/dev/null || true
    pkill -9 -f "timeout.*curl" 2>/dev/null || true
}

# ==================== Worker 下载循环 ====================
worker_loop() {
    local worker_id="$1"
    local end_time="$2"

    # 关闭 set -e，curl 失败不会导致 worker 退出
    set +e

    local last_domain=""
    local same_domain_count=0

    while [ "$(date +%s)" -lt "$end_time" ]; do
        local remaining=$(( end_time - $(date +%s) ))
        [ "$remaining" -le 0 ] && break

        # 选URL：同域名连续命中超过上限则重选
        local rand_url=""
        local rand_domain=""
        for attempt in 1 2 3 4 5; do
            rand_url="${URL_LIST[$RANDOM % ${#URL_LIST[@]}]}"
            rand_domain=$(get_domain "$rand_url")
            if [ "$rand_domain" != "$last_domain" ]; then
                same_domain_count=0
                break
            fi
            same_domain_count=$((same_domain_count + 1))
            if [ "$same_domain_count" -ge "$MAX_SAME_DOMAIN" ]; then
                continue
            fi
            break
        done
        last_domain="$rand_domain"

        local rand_ua="${UA_LIST[$RANDOM % ${#UA_LIST[@]}]}"
        log "W$worker_id" "拉取 [$rand_domain]: $(basename "$rand_url")"

        timeout "${remaining}s" curl -S -L --fail \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$remaining" \
            -A "$rand_ua" \
            --limit-rate "$PER_WORKER_SPEED" \
            --retry 0 \
            "$rand_url" -o /dev/null

        local exit_code="$?"
        case "$exit_code" in
            0)   log "W$worker_id" "下载完成" ;;
            124) log "W$worker_id" "超时终止（正常）" ;;
            137) log "W$worker_id" "被定时杀死（正常）" ;;
            22)  log "W$worker_id" "HTTP错误(404/403/429)，跳过" ;;
            *)   log "W$worker_id" "异常码:$exit_code，切换链接" ;;
        esac

        # 微休眠：用 $RANDOM 做种子，避免同秒重复
        local sleep_float=$(awk -v min="$SLEEP_MIN_FLOAT" -v max="$SLEEP_MAX_FLOAT" -v seed="$RANDOM" \
            'BEGIN{srand(seed); print min+rand()*(max-min)}')
        sleep "$sleep_float"
    done
    log "W$worker_id" "运行时长耗尽，线程退出"
}

# ==================== 主程序 ====================
START_TIME=$(date +%s)
END_TIME=$(( START_TIME + DURATION ))

echo ""
echo "============================================"
echo " AI数据集流量生成器（Common Crawl + Wikimedia）"
echo " URL总数：${#URL_LIST[@]} 条 | 全部公开无需token"
echo " 总限速: $TOTAL_SPEED | 并发: $CONCURRENCY | 单线程: $PER_WORKER_SPEED"
echo " 同站连续上限: ${MAX_SAME_DOMAIN}次 | 微休眠: ${SLEEP_MIN_FLOAT}~${SLEEP_MAX_FLOAT}s"
echo " 运行时长: $((DURATION/3600))小时，到点强制清理全部进程"
echo " 开始: $(date '+%Y-%m-%d %H:%M:%S')"
echo " 截止: $(date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# 启动并发 worker
pids=()
for i in $(seq 1 "$CONCURRENCY"); do
    worker_loop "$i" "$END_TIME" &
    pids+=("$!")
    log "MAIN" "线程$i 启动 PID=${pids[-1]}"
done

# 后台计时器：到点递归杀所有进程树 + 全局兜底
(
    sleep "$DURATION"
    log "MAIN" "⏰ 时长到期，递归杀死所有进程树..."
    for pid in "${pids[@]}"; do
        kill_tree "$pid"
    done
    global_cleanup
    log "MAIN" "全部进程清理完毕"
) &
TIMER_PID="$!"

# Ctrl+C / 终止信号 清理
cleanup() {
    echo ""
    log "MAIN" "收到停止信号，递归清理全部进程树..."
    for pid in "${pids[@]}"; do
        kill_tree "$pid"
    done
    global_cleanup
    kill "$TIMER_PID" 2>/dev/null || true
    log "MAIN" "全部进程清理完毕"
    exit 130
}
trap cleanup INT TERM

# 等待所有 worker 结束
wait "${pids[@]}" 2>/dev/null
kill "$TIMER_PID" 2>/dev/null || true
wait "$TIMER_PID" 2>/dev/null

# 正常结束也做一次全局兜底
global_cleanup

echo ""
echo "============================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 全部线程清理完毕，任务结束"
echo "============================================"