#!/bin/bash
set -eo pipefail
# ==================== 配置区 ====================
TOTAL_SPEED="15M"          # 总带宽（aria2原生总限速）
CONCURRENCY=4              # 并发数
DURATION=14400             # 运行时长（秒）
CONNECT_TIMEOUT=5          # 连接超时
LOWEST_SPEED="200K"        # 低速阈值：低于此速度算异常
SPEED_TIMEOUT=30           # 低速持续秒数：超过则断开切换
SLEEP_MIN_FLOAT=0.3        # 微休眠下限（下载完一个后）
SLEEP_MAX_FLOAT=1.5        # 微休眠上限
DOWNLOAD_DIR="/dev/shm/ai_traffic"   # ← 内存文件系统

# hf-mirror 公开模型（无需授权，脚本自动拉取文件列表）
HF_MODELS=(
    "Qwen/Qwen2.5-0.5B"
    "Qwen/Qwen2.5-1.5B"
    "Qwen/Qwen2.5-7B"
    "Qwen/Qwen2.5-14B"
    "Qwen/Qwen2.5-32B"
    "Qwen/Qwen2.5-72B"
    "Qwen/Qwen2.5-72B-Instruct"
    "Qwen/Qwen2-72B"
    "Qwen/Qwen2-57B-A14B"
    "Qwen/Qwen2-VL-7B"
    "Qwen/Qwen2-VL-72B"
    "mistralai/Mistral-7B-v0.1"
    "mistralai/Mixtral-8x7B-v0.1"
    "mistralai/Mixtral-8x22B-v0.1"
    "bigscience/bloom-1b7"
    "bigscience/bloom-3b"
    "bigscience/bloom-7b1"
    "bigscience/bloomz-7b1"
    "facebook/opt-2.7b"
    "facebook/opt-6.7b"
    "facebook/opt-13b"
    "facebook/opt-30b"
    "facebook/opt-66b"
    "EleutherAI/gpt-j-6b"
    "EleutherAI/gpt-neo-2.7B"
    "EleutherAI/gpt-neox-20b"
    "EleutherAI/pythia-6.9b"
    "EleutherAI/pythia-12b"
    "stabilityai/stable-diffusion-xl-base-1.0"
    "Salesforce/codegen-6B-mono"
    "Salesforce/codegen-16B-mono"
)
# ==============================================

# ==================== 内存检查 ====================
SHM_TOTAL=$(df -k /dev/shm | awk 'NR==2 {print $2}')
SHM_AVAIL=$(df -k /dev/shm | awk 'NR==2 {print $4}')
SHM_TOTAL_GB=$(( SHM_TOTAL / 1024 / 1024 ))
SHM_AVAIL_GB=$(( SHM_AVAIL / 1024 / 1024 ))
NEED_GB=$(( CONCURRENCY * 16 ))

echo ""
echo "============================================"
echo " 内存检查：/dev/shm 总计 ${SHM_TOTAL_GB}GB，可用 ${SHM_AVAIL_GB}GB"
echo " 并发 ${CONCURRENCY}，峰值约需 ${NEED_GB}GB（大文件场景）"
echo "============================================"

if [ "$SHM_AVAIL" -lt "$(( NEED_GB * 1024 * 1024 ))" ]; then
    echo ""
    echo "⚠️  可用内存不足！"
    echo "   /dev/shm 可用: ${SHM_AVAIL_GB}GB"
    echo "   需要至少: ${NEED_GB}GB"
    echo ""
    echo "解决方案："
    echo "   1. 减少 CONCURRENCY（如改成 2，需 ~32GB）"
    echo "   2. 改用磁盘版（下载到 /var/tmp/ai_traffic）"
    echo "   3. 增大 /dev/shm：mount -o remount,size=100G /dev/shm"
    echo ""
    exit 1
fi
echo "✅ 内存充足"

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

URL_FILE="/tmp/aria2_urls_$$.txt"
HOOK_FILE="/tmp/aria2_hook_$$.sh"

# ==================== 下载完成钩子（微休眠+即时删除）====================
cat > "$HOOK_FILE" << 'HOOKEOF'
#!/bin/bash
sleep $(awk -v min="$SLEEP_MIN" -v max="$SLEEP_MAX" -v seed="$RANDOM" \
    'BEGIN{srand(seed); print min+rand()*(max-min)}')
rm -f "$3"
HOOKEOF
chmod +x "$HOOK_FILE"

# ==================== 构建 URL 池 ====================
URL_LIST=()

# ---------- 主力：hf-mirror 公开大模型 ----------
echo ""
echo "正在从 hf-mirror 获取公开大模型文件列表..."
for model in "${HF_MODELS[@]}"; do
    echo "  解析 ${model} ..."
    resp=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://hf-mirror.com/api/models/${model}" 2>/dev/null || true)
    if [ -z "$resp" ]; then
        echo "    ❌ API 请求失败，跳过"
        continue
    fi
    files=$(echo "$resp" | grep -o '"rfilename":"[^"]*"' | sed 's/"rfilename":"//;s/"//' || true)
    count=0
    for file in $files; do
        if [[ "$file" =~ \.(safetensors|bin|gguf)$ ]]; then
            URL_LIST+=("https://hf-mirror.com/${model}/resolve/main/${file}")
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt 0 ]; then
        echo "    ✅ 添加 ${count} 个大文件"
    else
        echo "    ⚠️  未找到大文件（可能模型名有误或需授权）"
    fi
done

# ---------- 补充：腾讯云镜像 ISO ----------
echo ""
echo "添加腾讯云镜像 ISO..."

TENCENT_FIXED=(
    "https://mirrors.cloud.tencent.com/tencentos/2.4/iso/x86_64/TencentOS-Server-2.4-TK4-x86_64-everything-20251020.0.iso"
    "https://mirrors.cloud.tencent.com/tencentos/2.4/iso/x86_64/TencentOS-Server-2.4-TK4-x86_64-minimal-20250605.0.iso"
    "https://mirrors.cloud.tencent.com/tencentos/2.4/iso/aarch64/TencentOS-Server-2.4-TK4-aarch64-everything-20251020.1.iso"
    "https://mirrors.cloud.tencent.com/tencentos/2.4/iso/aarch64/TencentOS-Server-2.4-TK4-aarch64-minimal-20250605.0.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/aarch64/TencentOS-Server-3.1-20240925.0-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/aarch64/TencentOS-Server-3.1-20240925.0-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/aarch64/TencentOS-Server-3.1-20250521.0-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/aarch64/TencentOS-Server-3.1-20250521.0-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/x86_64/TencentOS-Server-3.1-20240925.0-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/x86_64/TencentOS-Server-3.1-20240925.0-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/x86_64/TencentOS-Server-3.1-20250521.0-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.1/isos/x86_64/TencentOS-Server-3.1-20250521.0-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20240624.0/TencentOS-Server-3.3-20240624.0-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20240624.0/TencentOS-Server-3.3-20240624.0-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20240829.1/TencentOS-Server-3.3-20240829.1-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20240829.1/TencentOS-Server-3.3-20240829.1-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/baseline/TencentOS-Server-3.3-TK4-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/baseline/TencentOS-Server-3.3-TK4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/aarch64/baseline/TencentOS-Server-3.3-TK4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240624.0/TencentOS-Server-3.3-20240624.0-TK4-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240624.0/TencentOS-Server-3.3-20240624.0-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240624.0/TencentOS-Server-3.3-20240624.0-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240829.1/TencentOS-Server-3.3-20240829.1-TK4-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240829.1/TencentOS-Server-3.3-20240829.1-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20240829.1/TencentOS-Server-3.3-20240829.1-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20241220.2/TencentOS-Server-3.3-20241220.2-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250320.0/TencentOS-Server-3.3-20250320.0-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250512.1/TencentOS-Server-3.3-20250512.1-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20250808.2/TencentOS-Server-3.3-20250808.2-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20251223.2/TencentOS-Server-3.3-20251223.2-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260423.2/TencentOS-Server-3.3-20260423.2-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260525.1/TencentOS-Server-3.3-20260525.1-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/20260709.2/TencentOS-Server-3.3-20260709.2-5.4.241-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/baseline/TencentOS-Server-3.3-TK4-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/baseline/TencentOS-Server-3.3-TK4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/3.3/isos/x86_64/baseline/TencentOS-Server-3.3-TK4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260409.0/TencentOS-Server-4.6-20260409.0-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260409.0/TencentOS-Server-4.6-20260409.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260409.0/TencentOS-Server-4.6-20260409.0-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260524.2/TencentOS-Server-4.6-20260524.2-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260524.2/TencentOS-Server-4.6-20260524.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260524.2/TencentOS-Server-4.6-20260524.2-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260625.4/TencentOS-Server-4.6-20260625.4-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260625.4/TencentOS-Server-4.6-20260625.4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260625.4/TencentOS-Server-4.6-20260625.4-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260727.2/TencentOS-Server-4.6-20260727.2-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260727.2/TencentOS-Server-4.6-20260727.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/20260727.2/TencentOS-Server-4.6-20260727.2-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/baseline/TencentOS-Server-4.6-aarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/baseline/TencentOS-Server-4.6-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/aarch64/baseline/TencentOS-Server-4.6-aarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260409.0/TencentOS-Server-4.6-20260409.0-loongarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260409.0/TencentOS-Server-4.6-20260409.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260409.0/TencentOS-Server-4.6-20260409.0-loongarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260524.2/TencentOS-Server-4.6-20260524.2-loongarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260524.2/TencentOS-Server-4.6-20260524.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260524.2/TencentOS-Server-4.6-20260524.2-loongarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260625.4/TencentOS-Server-4.6-20260625.4-loongarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260625.4/TencentOS-Server-4.6-20260625.4-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260625.4/TencentOS-Server-4.6-20260625.4-loongarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260727.2/TencentOS-Server-4.6-20260727.2-loongarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260727.2/TencentOS-Server-4.6-20260727.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/20260727.2/TencentOS-Server-4.6-20260727.2-loongarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/baseline/TencentOS-Server-4.6-loongarch64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/baseline/TencentOS-Server-4.6-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/loongarch64/baseline/TencentOS-Server-4.6-loongarch64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260409.0/TencentOS-Server-4.6-20260409.0-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260409.0/TencentOS-Server-4.6-20260409.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260409.0/TencentOS-Server-4.6-20260409.0-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260524.2/TencentOS-Server-4.6-20260524.2-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260524.2/TencentOS-Server-4.6-20260524.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260524.2/TencentOS-Server-4.6-20260524.2-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260625.4/TencentOS-Server-4.6-20260625.4-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260625.4/TencentOS-Server-4.6-20260625.4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260625.4/TencentOS-Server-4.6-20260625.4-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260727.2/TencentOS-Server-4.6-20260727.2-x86_64-boot.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260727.2/TencentOS-Server-4.6-20260727.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/20260727.2/TencentOS-Server-4.6-20260727.2-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4/isos/x86_64/baseline/TencentOS-Server-4.6-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.0/isos/aarch64/TencentOS-Server-4.0-everything-aarch64.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.0/isos/x86_64/TencentOS-Server-4.0-everything-x86_64.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20240515.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20240619.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20240729.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20240902.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20241018.1-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20241126.1-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-20241227.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/TencentOS-Server-4.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20240515.0/TencentOS-Server-4.2-20240515.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20240619.0/TencentOS-Server-4.2-20240619.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20240729.2/TencentOS-Server-4.2-20240729.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20240902.0/TencentOS-Server-4.2-20240902.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20241018.1/TencentOS-Server-4.2-20241018.1-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20241126.1/TencentOS-Server-4.2-20241126.1-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20241227.0/TencentOS-Server-4.2-20241227.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/20250227.0/TencentOS-Server-4.2-20250227.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/aarch64/baseline/TencentOS-Server-4.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20240515.0/TencentOS-Server-4.2-20240515.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20240619.0/TencentOS-Server-4.2-20240619.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20240729.2/TencentOS-Server-4.2-20240729.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20240902.0/TencentOS-Server-4.2-20240902.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20241018.1/TencentOS-Server-4.2-20241018.1-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20241126.1/TencentOS-Server-4.2-20241126.1-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20241227.0/TencentOS-Server-4.2-20241227.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/20250227.0/TencentOS-Server-4.2-20250227.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/baseline/TencentOS-Server-4.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20240515.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20240619.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20240729.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20240902.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20241018.1-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20241126.1-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-20241227.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.2/isos/x86_64/TencentOS-Server-4.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20250331.0/TencentOS-Server-4.4-20250331.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20250423.0/TencentOS-Server-4.4-20250423.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20250520.0/TencentOS-Server-4.4-20250520.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20250626.0/TencentOS-Server-4.4-20250626.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20250805.0/TencentOS-Server-4.4-20250805.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20251119.2/TencentOS-Server-4.4-20251119.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20260205.2/TencentOS-Server-4.4-20260205.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20260409.0/TencentOS-Server-4.4-20260409.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20260524.2/TencentOS-Server-4.4-20260524.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/20260625.4/TencentOS-Server-4.4-20260625.4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/aarch64/baseline/TencentOS-Server-4.4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20250331.0/TencentOS-Server-4.4-20250331.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20250423.0/TencentOS-Server-4.4-20250423.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20250520.0/TencentOS-Server-4.4-20250520.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20250626.0/TencentOS-Server-4.4-20250626.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20250805.0/TencentOS-Server-4.4-20250805.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20251119.2/TencentOS-Server-4.4-20251119.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20260205.2/TencentOS-Server-4.4-20260205.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20260409.0/TencentOS-Server-4.4-20260409.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20260524.2/TencentOS-Server-4.4-20260524.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/20260625.4/TencentOS-Server-4.4-20260625.4-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/loongarch64/baseline/TencentOS-Server-4.4-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20250331.0/TencentOS-Server-4.4-20250331.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20250423.0/TencentOS-Server-4.4-20250423.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20250520.0/TencentOS-Server-4.4-20250520.0-x86_64-minimal.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20250626.0/TencentOS-Server-4.4-20250626.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20250805.0/TencentOS-Server-4.4-20250805.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20251119.2/TencentOS-Server-4.4-20251119.2.1-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20260205.2/TencentOS-Server-4.4-20260205.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20260409.0/TencentOS-Server-4.4-20260409.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20260524.2/TencentOS-Server-4.4-20260524.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/20260625.4/TencentOS-Server-4.4-20260625.4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.4/isos/x86_64/baseline/TencentOS-Server-4.4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/aarch64/20260409.0/TencentOS-Server-4.6-20260409.0-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/aarch64/20260524.2/TencentOS-Server-4.6-20260524.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/aarch64/20260625.4/TencentOS-Server-4.6-20260625.4-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/aarch64/20260727.2/TencentOS-Server-4.6-20260727.2-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/aarch64/baseline/TencentOS-Server-4.6-aarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/loongarch64/20260409.0/TencentOS-Server-4.6-20260409.0-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/loongarch64/20260524.2/TencentOS-Server-4.6-20260524.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/loongarch64/20260625.4/TencentOS-Server-4.6-20260625.4-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/loongarch64/20260727.2/TencentOS-Server-4.6-20260727.2-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/loongarch64/baseline/TencentOS-Server-4.6-loongarch64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/x86_64/20260409.0/TencentOS-Server-4.6-20260409.0-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/x86_64/20260524.2/TencentOS-Server-4.6-20260524.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/x86_64/20260625.4/TencentOS-Server-4.6-20260625.4-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/x86_64/20260727.2/TencentOS-Server-4.6-20260727.2-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/tencentos/4.6/isos/x86_64/baseline/TencentOS-Server-4.6-x86_64-everything.iso"
    "https://mirrors.cloud.tencent.com/centos-stream/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-dvd1.iso"
    "https://mirrors.cloud.tencent.com/almalinux/9/isos/x86_64/AlmaLinux-9-latest-x86_64-dvd.iso"    
    "https://mirrors.cloud.tencent.com/almalinux/8/isos/x86_64/AlmaLinux-8-latest-x86_64-dvd.iso"
    "https://mirrors.cloud.tencent.com/fedora/releases/40/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-40-1.14.iso"
    "https://mirrors.cloud.tencent.com/fedora/releases/39/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-39-1.5.iso"
)
for url in "${TENCENT_FIXED[@]}"; do
    URL_LIST+=("$url")
done
echo "  ✅ 固定 ISO: ${#TENCENT_FIXED[@]} 个"

DEBIAN_DIR=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://mirrors.cloud.tencent.com/debian-cd/current/amd64/iso-dvd/" 2>/dev/null || true)
DEBIAN_FILES=$(echo "$DEBIAN_DIR" | grep -oE 'debian-[0-9.]+-amd64-DVD-[0-9]+\.iso' | sort -u || true)
debian_count=0
for f in $DEBIAN_FILES; do
    URL_LIST+=("https://mirrors.cloud.tencent.com/debian-cd/current/amd64/iso-dvd/${f}")
    debian_count=$((debian_count + 1))
done
[ "$debian_count" -gt 0 ] && echo "  ✅ Debian DVD: ${debian_count} 个" || echo "  ⚠️  Debian ISO 获取失败"

# ---------- 补充：网易镜像 ISO ----------
echo ""
echo "添加网易镜像 ISO..."

NETEASE_FIXED=(
    "https://mirrors.163.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    "https://mirrors.163.com/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
    "https://mirrors.163.com/ubuntu-releases/20.04/ubuntu-20.04.6-desktop-amd64.iso"
    "https://mirrors.163.com/centos/7/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso"
    "https://mirrors.163.com/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso"
    "https://mirrors.163.com/almalinux/9/isos/x86_64/AlmaLinux-9-latest-x86_64-dvd.iso"
    "https://mirrors.163.com/fedora/releases/40/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-40-1.14.iso"
    "https://mirrors.163.com/fedora/releases/39/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-39-1.5.iso"
    "https://mirrors.163.com/opensuse/distribution/leap/15.6/iso/openSUSE-Leap-15.6-DVD-x86_64.iso"
)
for url in "${NETEASE_FIXED[@]}"; do
    URL_LIST+=("$url")
done
echo "  ✅ 固定 ISO: ${#NETEASE_FIXED[@]} 个"

DEBIAN_DIR2=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://mirrors.163.com/debian-cd/current/amd64/iso-dvd/" 2>/dev/null || true)
DEBIAN_FILES2=$(echo "$DEBIAN_DIR2" | grep -oE 'debian-[0-9.]+-amd64-DVD-[0-9]+\.iso' | sort -u || true)
debian_count2=0
for f in $DEBIAN_FILES2; do
    URL_LIST+=("https://mirrors.163.com/debian-cd/current/amd64/iso-dvd/${f}")
    debian_count2=$((debian_count2 + 1))
done
[ "$debian_count2" -gt 0 ] && echo "  ✅ Debian DVD: ${debian_count2} 个" || echo "  ⚠️  Debian ISO 获取失败"

ARCH_DIR=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://mirrors.163.com/archlinux/iso/latest/" 2>/dev/null || true)
ARCH_FILE=$(echo "$ARCH_DIR" | grep -oE 'archlinux-[0-9.]+-x86_64\.iso' | head -1 || true)
if [ -n "$ARCH_FILE" ]; then
    URL_LIST+=("https://mirrors.163.com/archlinux/iso/latest/${ARCH_FILE}")
    echo "  ✅ Arch Linux: 1 个"
else
    echo "  ⚠️  Arch ISO 获取失败"
fi

# ---------- 补充：搜狐镜像 ISO ----------
echo ""
echo "添加搜狐镜像 ISO..."

SOHU_FIXED=(
    "https://mirrors.sohu.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    "https://mirrors.sohu.com/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
    "https://mirrors.sohu.com/ubuntu-releases/20.04/ubuntu-20.04.6-desktop-amd64.iso"
    "https://mirrors.sohu.com/centos/7/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso"
    "https://mirrors.sohu.com/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso"
    "https://mirrors.sohu.com/fedora/releases/40/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-40-1.14.iso"
)
for url in "${SOHU_FIXED[@]}"; do
    URL_LIST+=("$url")
done
echo "  ✅ 固定 ISO: ${#SOHU_FIXED[@]} 个"

DEBIAN_DIR3=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://mirrors.sohu.com/debian-cd/current/amd64/iso-dvd/" 2>/dev/null || true)
DEBIAN_FILES3=$(echo "$DEBIAN_DIR3" | grep -oE 'debian-[0-9.]+-amd64-DVD-[0-9]+\.iso' | sort -u || true)
debian_count3=0
for f in $DEBIAN_FILES3; do
    URL_LIST+=("https://mirrors.sohu.com/debian-cd/current/amd64/iso-dvd/${f}")
    debian_count3=$((debian_count3 + 1))
done
[ "$debian_count3" -gt 0 ] && echo "  ✅ Debian DVD: ${debian_count3} 个" || echo "  ⚠️  Debian ISO 获取失败（搜狐可能无此目录）"

# ---------- 兜底：华为云镜像 ISO ----------
echo ""
echo "添加华为云镜像 ISO（兜底）..."

HUAWEI_FIXED=(
    "https://repo.huaweicloud.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    "https://repo.huaweicloud.com/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
    "https://repo.huaweicloud.com/centos/7/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso"
    "https://repo.huaweicloud.com/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso"
    "https://repo.huaweicloud.com/rocky/8/isos/x86_64/Rocky-8-latest-x86_64-dvd1.iso"
    "https://repo.huaweicloud.com/fedora/releases/40/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-40-1.14.iso"
    "https://repo.huaweicloud.com/openeuler/openEuler-22.03-LTS-SP3/ISO/x86_64/openEuler-22.03-LTS-SP3-x86_64-dvd.iso"
)
for url in "${HUAWEI_FIXED[@]}"; do
    URL_LIST+=("$url")
done
echo "  ✅ 固定 ISO: ${#HUAWEI_FIXED[@]} 个"

DEBIAN_DIR4=$(curl -s --connect-timeout 10 --max-time 30 \
    "https://repo.huaweicloud.com/debian-cd/current/amd64/iso-dvd/" 2>/dev/null || true)
DEBIAN_FILES4=$(echo "$DEBIAN_DIR4" | grep -oE 'debian-[0-9.]+-amd64-DVD-[0-9]+\.iso' | sort -u || true)
debian_count4=0
for f in $DEBIAN_FILES4; do
    URL_LIST+=("https://repo.huaweicloud.com/debian-cd/current/amd64/iso-dvd/${f}")
    debian_count4=$((debian_count4 + 1))
done
[ "$debian_count4" -gt 0 ] && echo "  ✅ Debian DVD: ${debian_count4} 个" || echo "  ⚠️  Debian ISO 获取失败"

# ==================== URL 池汇总 ====================
if [ "${#URL_LIST[@]}" -eq 0 ]; then
    echo "【致命错误】URL池为空"
    exit 1
fi

printf '%s\n' "${URL_LIST[@]}" > "$URL_FILE"
echo ""
echo "URL池构建完成，共 ${#URL_LIST[@]} 条"
echo "域名分布："
printf '%s\n' "${URL_LIST[@]}" | awk -F/ '{print $3}' | sort | uniq -c | sort -rn

# ==================== 启动横幅 ====================
START_TIME=$(date +%s)
END_TIME=$(( START_TIME + DURATION ))
echo ""
echo "============================================"
echo " AI流量生成器（国内版·内存版）"
echo " 主力: hf-mirror 公开大模型（33个仓库）"
echo " 补充: 腾讯云/网易/搜狐/华为云 镜像 ISO"
echo " URL总数：${#URL_LIST[@]} 条 | 估算总体积 ~1.7TB"
echo " 总限速: $TOTAL_SPEED | 并发: $CONCURRENCY"
echo " 低速检测: <${LOWEST_SPEED}持续${SPEED_TIMEOUT}s自动断开"
echo " 微休眠: ${SLEEP_MIN_FLOAT}~${SLEEP_MAX_FLOAT}s | 下载完即时删除"
echo " 下载目录: $DOWNLOAD_DIR（内存，峰值约${NEED_GB}GB）"
echo " RPC: 127.0.0.1:6800（支持动态限速脚本）"
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
    --enable-rpc \
    --rpc-listen-all=false \
    --rpc-listen-port=6800 \
    --rpc-secret=ai_traffic_2024 \
    2>&1
ARIA2_EXIT=$?
set -e

# ==================== 清理 ====================
echo ""
echo "正在清理内存临时文件..."
pkill -9 -f "aria2c.*$$" 2>/dev/null || true
rm -rf "$DOWNLOAD_DIR" "$URL_FILE" "$HOOK_FILE" 2>/dev/null || true

echo ""
echo "============================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 任务结束（aria2退出码: $ARIA2_EXIT）"
echo "============================================"