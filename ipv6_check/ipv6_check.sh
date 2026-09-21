#!/bin/bash
# Debian 12 IPv6 检测脚本（优化版）

echo "==================== IPv6 检测开始 ===================="

# 1. 查看是否存在公网IPv6地址
ipv6_addr_raw=$(ip -6 addr show | grep -v '::1/128' | grep -E 'inet6.*scope.global')

if [[ -n "$ipv6_addr_raw" ]]; then
    # 提取纯净的IPv6地址（去掉 inet6、前缀长度、scope、接口名）
    ipv6_addr_list=$(echo "$ipv6_addr_raw" | awk '{print $2}' | cut -d'/' -f1)
    echo -e "\033[32m[成功] 本机已分配公网IPv6地址\033[0m"
    echo "公网IPv6列表:"
    echo "$ipv6_addr_raw"
    HAS_IPV6_ADDR=1
else
    echo -e "\033[31m[失败] 未检测到公网IPv6地址(排除本地回环::1)\033[0m"
    HAS_IPV6_ADDR=0
fi

# 2. 检测IPv6默认网关
ipv6_gw=$(ip -6 route show default)
if [[ -n "$ipv6_gw" ]]; then
    echo -e "\033[32m[成功] 存在IPv6默认网关\033[0m"
    echo "$ipv6_gw"
    HAS_IPV6_GW=1
else
    echo -e "\033[31m[失败] 无IPv6默认网关\033[0m"
    HAS_IPV6_GW=0
fi

# 3. 外网连通性测试 IPv6 (2400:3200::1 阿里云公共DNS-IPv6)
echo "正在测试IPv6外网连通性(超时5秒)..."
ping6 -c 2 -W 5 2400:3200::1 > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "\033[32m[成功] IPv6外网可以正常连通\033[0m"
    HAS_IPV6_NET=1
else
    echo -e "\033[31m[失败] IPv6外网不通，仅有内网IPv6地址\033[0m"
    HAS_IPV6_NET=0
fi

echo ""
echo "==================== 最终汇总结果 ===================="

if [[ $HAS_IPV6_ADDR -eq 1 && $HAS_IPV6_GW -eq 1 && $HAS_IPV6_NET -eq 1 ]]; then
    echo -e "\033[32m[√] IPv6 状态：全部正常，本机具备完整的公网IPv6访问能力\033[0m"
    echo ""
    echo ">>> 本机IPv6地址："
    echo "$ipv6_addr_list" | while read -r addr; do
        echo -e "    \033[36m$addr\033[0m"
    done
else
    echo -e "\033[31m[×] IPv6 状态：异常，未通过全部检测\033[0m"
    echo ""
    echo "未通过项："
    [[ $HAS_IPV6_ADDR -eq 0 ]] && echo "  - 无公网IPv6地址"
    [[ $HAS_IPV6_GW -eq 0 ]]   && echo "  - 无IPv6默认网关"
    [[ $HAS_IPV6_NET -eq 0 ]]  && echo "  - IPv6外网不通"
fi

echo ""
echo "==================== 检测结束 ===================="
