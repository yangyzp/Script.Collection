## 定时消耗流量



#### 下载aria2.ai_traffic.day.sh到/usr/local/bin

```
#!/bin/bash
# 检测并安装curl
if ! command -v curl &> /dev/null; then
    apt update && apt install curl -y
fi

# 切换到/usr/local/bin目录，统一管理脚本
cd /usr/local/bin
# 清理旧文件
rm -f aria2.ai_traffic.day.sh
# 下载脚本到当前目录(/usr/local/bin)
curl -L -o ./aria2.ai_traffic.day.sh "https://v4.gh-proxy.org/https://raw.githubusercontent.com/yangyzp/Script.Collection/master/ai_traffic/aria2.ai_traffic.day.sh"
# 添加执行权限并运行
chmod +x aria2.ai_traffic.day.sh
```

#### 下载aria2.ai_traffic.night.sh到/usr/local/bin

```
#!/bin/bash
# 检测并安装curl
if ! command -v curl &> /dev/null; then
    apt update && apt install curl -y
fi

# 切换到/usr/local/bin目录，统一管理脚本
cd /usr/local/bin
# 清理旧文件
rm -f aria2.ai_traffic.night.sh
# 下载脚本到当前目录(/usr/local/bin)
curl -L -o ./aria2.ai_traffic.night.sh "https://v4.gh-proxy.org/https://raw.githubusercontent.com/yangyzp/Script.Collection/master/ai_traffic/aria2.ai_traffic.night.sh"
# 添加执行权限并运行
chmod +x aria2.ai_traffic.night.sh
```

#### 配置计划任务

```
#!/bin/bash
# 检测并安装curl
if ! command -v curl &> /dev/null; then
    apt update && apt install curl -y
fi

# 切换到/usr/local/bin目录，统一管理脚本
cd /usr/local/bin
# 清理旧文件
rm -f aria2.setup_cron.sh
# 下载脚本到当前目录(/usr/local/bin)
curl -L -o ./aria2.setup_cron.sh "https://v4.gh-proxy.org/https://raw.githubusercontent.com/yangyzp/Script.Collection/master/ai_traffic/aria2.setup_cron.sh"
# 添加执行权限并运行
chmod +x aria2.setup_cron.sh && ./aria2.setup_cron.sh
```
