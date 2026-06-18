#!/bin/bash
set -e

echo "🔐 Komari SAFE hardening (process-scoped only)"

SERVICE_NAME="komari-agent"
USER="komari"
GROUP="komari"

# 1. 创建独立用户（只用于 Komari）
if ! id "$USER" &>/dev/null; then
    echo "➜ creating user: $USER"
    useradd --system --no-create-home --shell /usr/sbin/nologin $USER
fi

# 2. 获取 service 文件路径
SERVICE_FILE=$(systemctl show -p FragmentPath $SERVICE_NAME | cut -d= -f2)

if [ -z "$SERVICE_FILE" ]; then
    echo "❌ service not found: $SERVICE_NAME"
    exit 1
fi

echo "➜ found service: $SERVICE_FILE"

# 3. 创建 override（不修改原 service）
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d

cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<'EOF'
[Service]
User=komari
Group=komari

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
EOF

# 4. 只修改 Komari 文件权限（不动系统目录）
KOMARI_PATH="/opt/komari"

if [ -d "$KOMARI_PATH" ]; then
    echo "➜ fixing komari directory permissions"
    chown -R $USER:$GROUP $KOMARI_PATH
    chmod -R u+rwX,g+rX,o-rwx $KOMARI_PATH
fi

# 5. systemd reload & restart
systemctl daemon-reload
systemctl restart $SERVICE_NAME

echo "✅ SAFE hardening applied successfully"
echo "👉 Only Komari is restricted. System services remain untouched."
