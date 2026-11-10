#!/bin/bash
# TC 出站限速管理脚本 (HTB + fq_codel + flower)
# 限速单位固定为 Mbps（mbit），仅需输入数字
# 功能：按目标 IP 设置独立出站限速 / 全局限速 / 查看 / 删除 / 清空 / 开机自启
#
# 用法（必须 root）：
#   chmod +x tc-shaper.sh && ./tc-shaper.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 配置文件路径
IP_MAP_FILE="/var/lib/tc-shaper/ip_map.conf"
SERVICE_FILE="/etc/systemd/system/tc-shaper.service"
NIC=""
TC_BIN=""
# flower 过滤器使用的优先级（pref）。同一 pref 下只能存在一种 filter kind，
# 所以要先探测，避开别的工具/旧脚本留下的 u32、matchall 等
FILTER_PRIO="1"
FILTER_PRIO_CANDIDATES="1 2 3 4 5 10 20 50 100"

# 检查 root 权限与依赖
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
        exit 1
    fi
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${RED}错误：未找到 tc 命令，请先安装 iproute2${NC}"
        exit 1
    fi
    TC_BIN=$(command -v tc)
    mkdir -p /var/lib/tc-shaper
    [ -f "$IP_MAP_FILE" ] || : > "$IP_MAP_FILE"
}

# 自动检测出口网卡
detect_nic() {
    DEFAULT_NIC=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -n "$DEFAULT_NIC" ]; then
        read -rp "检测到默认出口网卡为 [$DEFAULT_NIC]，是否使用？(Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            read -rp "请手动输入出口网卡名: " NIC
        else
            NIC="$DEFAULT_NIC"
        fi
    else
        read -rp "无法自动检测网卡，请手动输入出口网卡名: " NIC
    fi

    if ! ip link show "$NIC" &>/dev/null; then
        echo -e "${RED}错误：网卡 $NIC 不存在，请检查后重试${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 当前使用网卡：$NIC${NC}"
}

# 从 tc class 行中提取 rate
get_rate_from_line() {
    echo "$1" | sed 's/.*rate \([^ ]*\).*/\1/'
}

# 从 tc class 行中提取 ceil
get_ceil_from_line() {
    echo "$1" | sed 's/.*ceil \([^ ]*\).*/\1/'
}

# 判断内核里是否已存在某个 IP 的 flower 过滤规则
# 兼容两种输出格式： dst_ip 1.2.3.4(/32)  和  match ip dst 1.2.3.4/32
_ip_filter_exists() {
    local ip="$1"
    tc filter show dev "$NIC" parent 1: 2>/dev/null \
        | grep -Eq "(dst_ip[[:space:]]+${ip}(/32)?([[:space:]]|$))|(match ip dst ${ip}(/32)?([[:space:]]|$))"
}

# 取某个 prio 上（protocol ip）已存在的 filter kind，没有则输出空
# 同一 (parent, protocol, prio) 下只能有一种 kind，混用会报
# "Specified filter kind does not match existing one"
filter_prio_kind() {
    local p="$1"
    tc filter show dev "$NIC" parent 1: 2>/dev/null | awk -v p="$p" '
        /^filter / {
            pref = ""; proto = ""; kind = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "protocol") proto = $(i+1)
                if ($i == "pref") { pref = $(i+1); kind = $(i+2) }
            }
            if (pref == p && proto == "ip" && kind != "") { print kind; exit }
        }'
}

# 挑选一个能挂 flower 的 prio；首选 prio 被 u32/matchall 等占用时可提示清理
ensure_filter_prio() {
    local quiet="$1" p kind
    for p in $FILTER_PRIO_CANDIDATES; do
        kind=$(filter_prio_kind "$p")
        if [ -n "$kind" ] && [ "$kind" != "flower" ] && [ "$p" = "1" ] && [ "$quiet" != "quiet" ]; then
            echo -e "${YELLOW}⚠️  prio 1 上已经有 $kind 类型的过滤器（不是 flower）${NC}"
            echo -e "${YELLOW}    一般是旧版脚本或别的工具留下的，会挡住本脚本按 IP 分类的规则${NC}"
            read -rp "    是否删除 prio 1 上的这些 $kind 过滤器？(y/N): " clean_ans
            if [[ "$clean_ans" =~ ^[Yy]$ ]]; then
                if tc filter del dev "$NIC" parent 1: protocol ip prio 1 "$kind" 2>/dev/null; then
                    echo -e "${GREEN}    已删除 prio 1 上的 $kind 过滤器${NC}"
                else
                    echo -e "${RED}    删除失败，请先手动执行：tc filter show dev $NIC parent 1:${NC}"
                fi
                kind=$(filter_prio_kind "$p")
            else
                echo -e "${YELLOW}    已跳过清理：prio 1 上的旧规则仍可能先于本脚本的规则生效${NC}"
            fi
        fi
        if [ -z "$kind" ] || [ "$kind" = "flower" ]; then
            FILTER_PRIO=$p
            return 0
        fi
    done
    # 全部候选都被占用：用最大的 prio，至少不和别人抢
    FILTER_PRIO=100
    return 0
}

# 删除某个 IP 的 flower 过滤规则（历史上可能挂在不同的 prio 上）
del_ip_filters() {
    local ip="$1" p
    for p in $FILTER_PRIO_CANDIDATES; do
        tc filter del dev "$NIC" parent 1: protocol ip prio "$p" flower dst_ip "$ip" 2>/dev/null
    done
}

# 把内核里出现的 10Mbit / 1Gbit 之类统一成 Mbps 数字
to_mbps() {
    local s="$1"
    case "$s" in
        *[Gg]bit) s=${s%[Gg]bit}; echo $((s * 1000)) ;;
        *[Mm]bit) echo "${s%[Mm]bit}" ;;
        *[Kk]bit) s=${s%[Kk]bit}; echo $((s / 1000)) ;;
        *[0-9]) echo "$s" ;;
        *) echo "$s" ;;
    esac
}

# 某个 IP + 类 是否已经写进开机自启服务（决定“自启”列显示）
systemd_has_ip() {
    local ip="$1" cid="$2"
    [ -f "$SERVICE_FILE" ] && grep -qF "dst_ip ${ip} flowid 1:${cid}" "$SERVICE_FILE" 2>/dev/null
}

# 检查并初始化 HTB 根队列
check_root_qdisc() {
    if ! tc qdisc show dev "$NIC" 2>/dev/null | grep -q "htb 1:"; then
        echo "初始化HTB根队列..."
        # replace 可覆盖默认的 pfifo_fast / mq 等根队列
        tc qdisc replace dev "$NIC" root handle 1: htb default 20
        tc class add dev "$NIC" parent 1: classid 1:20 htb rate 1000mbit ceil 1000mbit
        tc qdisc add dev "$NIC" parent 1:20 handle 20: fq_codel
        : > "$IP_MAP_FILE"
        echo -e "${GREEN}✅ 根队列初始化完成${NC}"
    else
        # 根队列已存在：映射文件以本脚本的记录为准，不再从内核反推
        # （tc filter show 的文本格式各版本不一致，靠它配对 IP 与类会出错）
        :
    fi
}

# 获取下一个可用的单 IP classid (10-19)
get_next_classid() {
    local existing i
    existing=$(tc class show dev "$NIC" 2>/dev/null \
        | awk '$1=="class" && $2=="htb" {print $3}' \
        | cut -d: -f2 | sort -n)
    for i in $(seq 10 19); do
        if ! echo "$existing" | grep -qx "$i"; then
            echo "$i"
            return 0
        fi
    done
    echo -e "${RED}错误：单IP限速数量已达上限（10个）${NC}" >&2
    return 1
}

# 找“孤儿类”：class 还在、但没有任何 filter 指向它
# 用于 class 建了却 filter 丢了的情况，复用它而不是再新建一个重复的类
find_orphan_classid() {
    local i used
    used=$(tc filter show dev "$NIC" parent 1: 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="flowid"||$i=="classid") print $(i+1)}')
    for i in $(seq 10 19); do
        tc class show dev "$NIC" classid "1:$i" 2>/dev/null | grep -q "1:$i" || continue
        echo "$used" | grep -qx "1:$i" && continue
        echo "$i"
        return 0
    done
    return 1
}

# 从内核 filter 里直接取出某个 IP 对应的 class 编号（不依赖映射文件）
get_classid_by_ip() {
    local ip="$1"
    tc filter show dev "$NIC" parent 1: 2>/dev/null | awk -v ip="$ip" '
        $0 ~ ("dst_ip[ \t]+" ip "(/32)?([ \t]|$)") || $0 ~ ("match ip dst " ip "(/32)?([ \t]|$)") { hit = 1 }
        hit && /(flowid|classid)/ {
            for (i = 1; i <= NF; i++)
                if ($i == "flowid" || $i == "classid") { cid = $(i+1); sub(/.*:/, "", cid); print cid; exit }
        }'
}

# 某个 classid（只传后半段，如 10）是否真实存在
class_exists() {
    tc class show dev "$NIC" 2>/dev/null | grep -q "^class htb 1:$1 "
}

# 1/3. 新增或修改指定 IP 限速
add_ip_limit() {
    check_root_qdisc
    read -rp "请输入目标IP地址: " TARGET_IP

    if ! [[ "$TARGET_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ IP格式不正确，请输入合法的IPv4地址${NC}"
        return
    fi

    # 已有记录就沿用原来的类，避免同一个 IP 建出两个类
    local old_cid map_speed
    old_cid=$(grep "^$TARGET_IP " "$IP_MAP_FILE" 2>/dev/null | awk '{print $2}')
    map_speed=$(grep "^$TARGET_IP " "$IP_MAP_FILE" 2>/dev/null | awk '{print $3}')
    [ -z "$old_cid" ] && old_cid=$(get_classid_by_ip "$TARGET_IP")

    if [ -n "$old_cid" ]; then
        CLASSID="$old_cid"
        echo -e "${YELLOW}ℹ️  该IP已有规则（类 1:$CLASSID，当前 ${map_speed:-未记录}），将更新为新的限速值${NC}"
    else
        # 优先复用“孤儿类”（class 建了但 filter 丢了），避免留下重复的类
        if ! CLASSID=$(find_orphan_classid); then
            if ! CLASSID=$(get_next_classid); then return; fi
        fi
    fi

    read -rp "请输入限速值（单位：Mbps，直接输入数字，例如 100）: " SPEED_NUM
    if ! [[ "$SPEED_NUM" =~ ^[0-9]+$ ]] || [ "$SPEED_NUM" -le 0 ]; then
        echo -e "${RED}❌ 限速值格式错误，请输入大于 0 的纯数字${NC}"
        return
    fi
    SPEED="${SPEED_NUM}mbit"

    # 先确认能挂 flower 的 prio，避开别的 kind 占用的优先级
    ensure_filter_prio

    # 先清掉这个 IP 的旧 filter，保证一个 IP 只有一条过滤规则
    del_ip_filters "$TARGET_IP"

    if class_exists "$CLASSID"; then
        tc class change dev "$NIC" parent 1: classid "1:$CLASSID" htb rate "$SPEED" ceil "$SPEED" \
            || { echo -e "${RED}❌ 修改现有类失败${NC}"; return; }
    else
        tc class add dev "$NIC" parent 1: classid "1:$CLASSID" htb rate "$SPEED" ceil "$SPEED" \
            || { echo -e "${RED}❌ 创建限速类失败${NC}"; return; }
    fi

    if ! tc qdisc show dev "$NIC" 2>/dev/null | grep -q "parent 1:$CLASSID "; then
        tc qdisc add dev "$NIC" parent "1:$CLASSID" handle "$CLASSID:" fq_codel
    fi

    if ! tc filter add dev "$NIC" protocol ip parent 1: prio "$FILTER_PRIO" flower dst_ip "$TARGET_IP" flowid "1:$CLASSID"; then
        echo -e "${RED}❌ 过滤规则添加失败，该 IP 实际不会走这条限速${NC}"
        echo -e "${YELLOW}   现有过滤器（prio $FILTER_PRIO）：${NC}"
        tc filter show dev "$NIC" parent 1: 2>/dev/null | head -20
        echo -e "${YELLOW}   若提示 filter kind does not match，说明该 prio 被别的类型占用${NC}"
        return
    fi

    sed -i "/^$TARGET_IP /d" "$IP_MAP_FILE" 2>/dev/null
    echo "$TARGET_IP $CLASSID $SPEED_NUM" >> "$IP_MAP_FILE"

    echo -e "${GREEN}✅ 操作完成：IP $TARGET_IP 出站限速已设置为 ${SPEED_NUM} Mbps（类 1:$CLASSID）${NC}"
    if [ -f "$SERVICE_FILE" ] && ! systemd_has_ip "$TARGET_IP" "$CLASSID"; then
        echo -e "${YELLOW}⚠️  该 IP 还没写进开机自启服务，需要重新选择菜单 7 才能在重启后保留${NC}"
    fi
}

# 2. 设置全局所有 IP 限速
set_global_limit() {
    check_root_qdisc
    read -rp "请输入全局限速值（单位：Mbps，直接输入数字，例如 110）: " SPEED_NUM
    if ! [[ "$SPEED_NUM" =~ ^[0-9]+$ ]] || [ "$SPEED_NUM" -le 0 ]; then
        echo -e "${RED}❌ 限速值格式错误，请输入大于 0 的纯数字${NC}"
        return
    fi
    SPEED="${SPEED_NUM}mbit"

    tc class change dev "$NIC" parent 1: classid 1:20 htb rate "$SPEED" ceil "$SPEED"
    echo -e "${GREEN}✅ 全局出站限速已设置为 ${SPEED_NUM} Mbps${NC}"
    echo -e "${YELLOW}ℹ️  已配置独立限速的IP，走各自的限速规则，不受全局值影响${NC}"
    echo -e "${YELLOW}ℹ️  选 5 可在「全局限速」一栏看到当前值${NC}"
}

# 4-1. 删除单个 IP 限速
del_single_ip() {
    read -rp "请输入要删除限速的目标IP: " TARGET_IP
    CLASSID=$(grep "^$TARGET_IP " "$IP_MAP_FILE" 2>/dev/null | awk '{print $2}')
    [ -z "$CLASSID" ] && CLASSID=$(get_classid_by_ip "$TARGET_IP")
    if [ -z "$CLASSID" ] && ! _ip_filter_exists "$TARGET_IP"; then
        echo -e "${RED}❌ 该IP没有限速规则${NC}"
        return
    fi

    del_ip_filters "$TARGET_IP"
    [ -n "$CLASSID" ] && tc class del dev "$NIC" classid "1:$CLASSID" 2>/dev/null
    sed -i "/^$TARGET_IP /d" "$IP_MAP_FILE" 2>/dev/null

    echo -e "${GREEN}✅ 已删除 IP $TARGET_IP 的限速规则${NC}"
}

# 5. 查看当前所有规则与统计
show_status() {
    check_root_qdisc
    echo -e "\n${YELLOW}========== 网卡 $NIC 当前限速规则 ==========${NC}"
    echo -e "${GREEN}--- 流量类统计（含速率、发送量、丢包）---${NC}"
    tc -s class show dev "$NIC"
    echo ""
    echo -e "${GREEN}--- 全局限速（类 1:20，对所有 IP 生效）---${NC}"
    local g_line g_rate
    g_line=$(tc class show dev "$NIC" classid 1:20 2>/dev/null)
    g_rate=$(get_rate_from_line "$g_line")
    if [ -n "$g_rate" ]; then
        echo -e "  全局限速：${YELLOW}$(to_mbps "$g_rate") Mbps${NC}   （未单独限速的 IP 全部走这条，菜单 2 修改）"
    else
        echo "  全局限速：未设置（只有下面单独列出的 IP 受限速）"
    fi
    echo ""
    echo -e "${GREEN}--- IP 限速规则（单独限速，优先级高于全局）---${NC}"

    local total=0 active=0 selfstart state
    printf "%-18s %-8s %-11s %-10s %s\n" "目标IP" "类ID" "限速值" "开机自启" "状态"
    echo "--------------------------------------------------------------"
    if [ -f "$IP_MAP_FILE" ] && [ -s "$IP_MAP_FILE" ]; then
        while read -r ip cid speed; do
            [ -n "$ip" ] || continue
            total=$((total + 1))
            selfstart="否"
            state="未生效"
            systemd_has_ip "$ip" "$cid" && selfstart="是"
            if _ip_filter_exists "$ip" && class_exists "$cid"; then
                state="生效"
                active=$((active + 1))
            fi
            printf "%-18s %-8s %-11s %-10s %s\n" "$ip" "1:$cid" "$(to_mbps "$speed") Mbps" "$selfstart" "$state"
        done < "$IP_MAP_FILE"
    fi

    if [ "$total" -eq 0 ]; then
        echo "暂无单独限速的 IP（当前只靠上面的全局限速）"
    elif [ "$active" -lt "$total" ]; then
        echo ""
        echo -e "${YELLOW}ℹ️  有 $((total - active)) 条规则当前没在内核里生效${NC}"
        echo -e "${YELLOW}ℹ️  重新选 1 输入对应 IP 即可自动补齐（会沿用原来的类）${NC}"
    fi
    echo ""
    echo -e "${YELLOW}ℹ️  [开机自启=是] 表示该 IP 已写入 $SERVICE_FILE${NC}"
    echo -e "${YELLOW}ℹ️  新加的规则需要重新选 7 才会写进服务文件${NC}"

    echo ""
    echo -e "${GREEN}--- 队列状态（fq_codel丢包统计）---${NC}"
    tc -s qdisc show dev "$NIC"
    echo -e "${YELLOW}==========================================${NC}\n"
}

# 4-2. 清空所有限速规则
clear_all_rules() {
    read -rp "⚠️  确定要清空所有限速规则吗？此操作不可恢复 (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        tc qdisc del dev "$NIC" root 2>/dev/null
        : > "$IP_MAP_FILE"
        # 规则清空后若还留着开机自启服务，重启会把旧规则又建回来，这里一并删掉
        if [ -f "$SERVICE_FILE" ]; then
            systemctl disable tc-shaper.service &>/dev/null
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload &>/dev/null
            echo -e "${YELLOW}ℹ️  已同时移除开机自启服务 $SERVICE_FILE${NC}"
        fi
        echo -e "${GREEN}✅ 所有限速规则已清空${NC}"
    else
        echo "已取消操作"
    fi
}

# 7. 保存当前规则为开机自启
save_systemd() {
    if ! tc qdisc show dev "$NIC" 2>/dev/null | grep -q "htb 1:"; then
        echo -e "${RED}❌ 当前没有生效的TC规则，无法保存${NC}"
        return
    fi

    # 丢掉 class 已经不存在的过期记录，避免写进服务后起不来
    local tmp_map ip cid speed
    if [ -s "$IP_MAP_FILE" ]; then
        tmp_map=$(mktemp)
        while read -r ip cid speed; do
            [ -n "$ip" ] || continue
            class_exists "$cid" && echo "$ip $cid $speed" >> "$tmp_map"
        done < "$IP_MAP_FILE"
        mv "$tmp_map" "$IP_MAP_FILE"
    fi

    echo "生成 systemd 服务文件..."

    # 开机时根队列是新建的，选一个不会被别的 kind 占用的 prio
    ensure_filter_prio quiet

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=TC Outbound Traffic Shaper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-$TC_BIN qdisc add dev $NIC root handle 1: htb default 20
EOF

    # 写入所有 class（正则提取 rate 和 ceil，不依赖字段位置）
    tc class show dev "$NIC" | grep "class htb" | while read -r line; do
        CLASSID=$(echo "$line" | awk '{print $3}')
        RATE=$(get_rate_from_line "$line")
        CEIL=$(get_ceil_from_line "$line")
        echo "ExecStart=-$TC_BIN class add dev $NIC parent 1: classid $CLASSID htb rate $RATE ceil $CEIL" >> "$SERVICE_FILE"
    done

    # 写入所有子队列（fq_codel）
    tc qdisc show dev "$NIC" | grep -v "htb 1:" | awk '{print $2, $3, $5}' | while read -r qtype qhandle qparent; do
        echo "ExecStart=-$TC_BIN qdisc add dev $NIC parent $qparent handle $qhandle $qtype" >> "$SERVICE_FILE"
    done

    # 写入所有 IP 过滤器
    if [ -f "$IP_MAP_FILE" ]; then
        while read -r ip cid speed; do
            [ -n "$ip" ] && echo "ExecStart=-$TC_BIN filter add dev $NIC protocol ip parent 1: prio $FILTER_PRIO flower dst_ip $ip flowid 1:$cid" >> "$SERVICE_FILE"
        done < "$IP_MAP_FILE"
    fi

    # 停止时清理
    echo "ExecStop=-$TC_BIN qdisc del dev $NIC root" >> "$SERVICE_FILE"

    cat >> "$SERVICE_FILE" << EOF

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tc-shaper.service &>/dev/null
    echo -e "${GREEN}✅ 规则已保存并开启开机自启，服务文件：$SERVICE_FILE${NC}"
    if [ -s "$IP_MAP_FILE" ]; then
        echo -e "${YELLOW}已写入的 IP 规则：${NC}"
        awk '{printf "   - %s  类 1:%s  %s Mbps\n", $1, $2, $3}' "$IP_MAP_FILE"
    fi
    echo -e "${YELLOW}ℹ️  可执行 systemctl status tc-shaper.service 验证服务状态${NC}"
}

# 8. 取消开机自启
disable_systemd() {
    systemctl disable tc-shaper.service &>/dev/null
    rm -f /etc/systemd/system/tc-shaper.service
    systemctl daemon-reload
    echo -e "${GREEN}✅ 已取消开机自启并删除服务文件${NC}"
}

# 主菜单
main_menu() {
    clear
    echo "==================== TC 出站限速管理工具 ===================="
    echo "  1. 对指定 IP 设置独立出站限速"
    echo "  2. 设置全局所有 IP 出站限速"
    echo "  3. 新增 IP 独立限速（保留现有规则）"
    echo "  4. 删除单个 IP 的限速规则"
    echo "  5. 查看当前规则与流量统计"
    echo "  6. 清空所有限速规则"
    echo "  7. 保存当前规则为开机自启"
    echo "  8. 取消开机自启"
    echo "  0. 退出脚本"
    echo "============================================================"
    echo -e "${YELLOW}ℹ️  所有限速均为 本机出站方向，单位固定为 Mbps${NC}"
    read -rp "请输入选项 [0-8]: " choice

    case $choice in
        1|3) add_ip_limit ;;
        2) set_global_limit ;;
        4) del_single_ip ;;
        5) show_status ;;
        6) clear_all_rules ;;
        7) save_systemd ;;
        8) disable_systemd ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo -e "${RED}❌ 无效选项${NC}" ;;
    esac

    echo ""
    read -rp "按回车键返回主菜单..." -n1 -s
    main_menu
}

# 脚本入口
check_root
detect_nic
main_menu
