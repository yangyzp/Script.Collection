```
if ! command -v curl &> /dev/null; then apt update && apt install curl -y; fi; rm -f tc-shaper.sh; curl -L -o ./tc-shaper.sh "https://v4.gh-proxy.org/https://raw.githubusercontent.com/yangyzp/Script.Collection/master/tc-shaper/tc-shaper.sh"; chmod +x ./tc-shaper.sh && ./tc-shaper.sh
```


==================== TC 出站限速管理工具 ====================
  1. 对指定 IP 设置独立出站限速
  2. 设置全局所有 IP 出站限速
  3. 新增 IP 独立限速（保留现有规则）
  4. 删除单个 IP 的限速规则
  5. 查看当前规则与流量统计
  6. 清空所有限速规则
  7. 保存当前规则为开机自启
  8. 取消开机自启
  0. 退出脚本
