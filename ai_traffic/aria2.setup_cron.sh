#!/bin/bash
# ============================================================
# AI 流量脚本 - 定时任务配置器
# 功能：交互式输入白天/黑夜开始时间，创建2个 cron 任务
# ============================================================

set -eo pipefail

# ---------- 前置检查 ----------
if [ "$EUID" -ne 0 ]; then
    echo "【错误】请用 root 用户运行（sudo -i 后再执行）"
    exit 1
fi

DAY_SCRIPT="/usr/local/bin/aria2.ai_traffic.day.sh"
NIGHT_SCRIPT="/usr/local/bin/aria2.ai_traffic.night.sh"
DAY_LOG="/usr/local/bin/aria2.ai_traffic.day.log"
NIGHT_LOG="/usr/local/bin/aria2.ai_traffic.night.log"

# 检查脚本是否存在
[ ! -x "$DAY_SCRIPT" ] && echo "【警告】$DAY_SCRIPT 不存在或不可执行"
[ ! -x "$NIGHT_SCRIPT" ] && echo "【警告】$NIGHT_SCRIPT 不存在或不可执行"

# 检查 cron
if ! command -v crontab &>/dev/null; then
    echo "检测到未安装 cron，正在安装..."
    apt update -qq && apt install -y -qq cron
    systemctl enable --now cron
fi

# ---------- 工具函数 ----------
prompt() {
    local _hint="$1" _default="$2" _varname="$3" _input
    read -rp "$_hint [$_default]: " _input
    _input="${_input:-$_default}"
    eval "$_varname=\"\$_input\""
}

# ---------- 交互式输入 ----------
clear
echo "============================================"
echo "  AI 流量脚本 - 定时任务配置器"
echo "============================================"
echo ""
echo "白天脚本：$DAY_SCRIPT"
echo "黑夜脚本：$NIGHT_SCRIPT"
echo ""

prompt "白天任务 - 每天几点开始（0-23，整数小时）" "8" DAY_HOUR
prompt "黑夜任务 - 每天几点开始（0-23，整数小时）" "23" NIGHT_HOUR

# 校验
if ! [[ "$DAY_HOUR" =~ ^[0-9]+$ ]] || [ "$DAY_HOUR" -lt 0 ] || [ "$DAY_HOUR" -gt 23 ]; then
    echo "【错误】白天时间必须是 0-23 的整数"
    exit 1
fi
if ! [[ "$NIGHT_HOUR" =~ ^[0-9]+$ ]] || [ "$NIGHT_HOUR" -lt 0 ] || [ "$NIGHT_HOUR" -gt 23 ]; then
    echo "【错误】黑夜时间必须是 0-23 的整数"
    exit 1
fi

# ---------- 确认 ----------
echo ""
echo "============================================"
echo "  请确认："
echo "  白天：每天 $DAY_HOUR:00 启动 $DAY_SCRIPT"
echo "  黑夜：每天 $NIGHT_HOUR:00 启动 $NIGHT_SCRIPT"
echo "============================================"
read -rp "确认创建定时任务？(y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# ---------- 设置 cron ----------
echo ""
echo "正在配置定时任务..."

# 删除旧的 AI_TRAFFIC 任务（用标记精准匹配）
crontab -l 2>/dev/null | grep -v "#AI_TRAFFIC_DAY" | grep -v "#AI_TRAFFIC_NIGHT" | crontab -

# 添加新任务
(
    crontab -l 2>/dev/null
    echo "0 $DAY_HOUR * * * $DAY_SCRIPT >> $DAY_LOG 2>&1 #AI_TRAFFIC_DAY"
    echo "0 $NIGHT_HOUR * * * $NIGHT_SCRIPT >> $NIGHT_LOG 2>&1 #AI_TRAFFIC_NIGHT"
) | crontab -

echo "✅ 定时任务已创建"

# ---------- 最终展示 ----------
echo ""
echo "============================================"
echo "  配置完成！"
echo "============================================"
echo ""
echo "当前所有 crontab："
crontab -l
echo ""
echo "日志文件："
echo "  白天：$DAY_LOG"
echo "  黑夜：$NIGHT_LOG"
echo ""
echo "常用命令："
echo "  查看定时任务：crontab -l"
echo "  查看白天日志：tail -f $DAY_LOG"
echo "  手动停止下载：pkill -9 -f limit-rate"
echo "  删除所有任务：crontab -l | grep -v AI_TRAFFIC | crontab -"
echo "============================================"