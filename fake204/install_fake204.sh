#!/usr/bin/env bash
set -Eeuo pipefail

app_dir=/opt/fake204
binary_path="$app_dir/fake204"
download_url="https://raw.githubusercontent.com/yangyzp/Script.Collection/master/fake204/fake204"
service_path=/etc/systemd/system/fake204.service
temp_path="$app_dir/fake204.download"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root." >&2
    exit 1
fi

show_help() {
    echo
    echo "Docker 后端记得添加："
    echo "--add-host=www.gstatic.com:127.0.0.1"
    echo "--add-host=cp.cloudflare.com:127.0.0.1"
    echo
    echo "如需检查服务："
    echo "systemctl status fake204 --no-pager"
    echo "journalctl -u fake204 -f"
    echo
}

install_fake204() {
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *)
            echo "Unsupported architecture: $(uname -m). Expected x86_64/amd64." >&2
            exit 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1 || ! command -v file >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl file
    fi

    mkdir -p "$app_dir"
    trap 'rm -f "$temp_path"' EXIT
    curl --fail --location --retry 3 --connect-timeout 15 \
        --output "$temp_path" "$download_url"

    if ! file "$temp_path" | grep -q 'ELF 64-bit.*x86-64'; then
        echo "Downloaded file is not an x86-64 Linux ELF executable." >&2
        exit 1
    fi

    chmod 700 "$temp_path"
    systemctl stop fake204.service 2>/dev/null || true
    mv -f "$temp_path" "$binary_path"

    cat > "$service_path" <<'EOF'
[Unit]
Description=Local Clash generate_204 responder
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=/opt/fake204
ExecStart=/opt/fake204/fake204
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now fake204.service
    sleep 1
    if ! systemctl is-active --quiet fake204.service; then
        echo "fake204 启动失败，可能是 80 或 443 端口已被占用：" >&2
        if command -v ss >/dev/null 2>&1; then
            ss -ltnp '( sport = :80 or sport = :443 )' >&2 || true
        fi
        journalctl -u fake204.service -n 15 --no-pager >&2 || true
        systemctl disable --now fake204.service >/dev/null 2>&1 || true
        exit 1
    fi
    systemctl --no-pager --full status fake204.service
    echo "fake204 安装并启动成功。"
}

uninstall_fake204() {
    systemctl disable --now fake204.service 2>/dev/null || true
    rm -f "$service_path" "$binary_path"
    systemctl daemon-reload
    echo "fake204 已停止运行并关闭开机自启。"
}

echo "=============================="
echo " fake204 管理菜单"
echo "=============================="
echo "1. 安装 fake204 并运行"
echo "2. 卸载 fake204"
echo "=============================="
read -r -p "请输入选项 [1-2]: " choice

case "$choice" in
    1)
        install_fake204
        show_help
        ;;
    2)
        uninstall_fake204
        show_help
        ;;
    *)
        echo "无效选项。"
        exit 1
        ;;
esac
