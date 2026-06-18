#!/bin/bash
set -e

echo "🔐 Safe Systemd Isolation Installer (NO system impact)"

SERVICE_NAME="komari-agent"
USER="komari"
GROUP="komari"

echo "👉 Target service: $SERVICE_NAME"

# =========================
# 1. Create user (service-level only)
# =========================
if ! id "$USER" &>/dev/null; then
    echo "➜ Creating service user: $USER"
    useradd --system --no-create-home --shell /usr/sbin/nologin $USER
fi

# =========================
# 2. Create systemd override (SAFE SCOPE ONLY)
# =========================
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d

cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<EOF
[Service]
User=$USER
Group=$GROUP

# 🔐 Safe isolation (NO system/network changes)
NoNewPrivileges=true
PrivateTmp=true

ProtectSystem=full
ProtectHome=true

RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

LockPersonality=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
EOF

echo "✔ systemd override created"

# =========================
# 3. Reload systemd
# =========================
systemctl daemon-reload
systemctl restart $SERVICE_NAME

echo "✔ service restarted"

# =========================
# 4. Status check
# =========================
systemctl status $SERVICE_NAME --no-pager || true

# =========================
# 5. Rollback instructions
# =========================
echo ""
echo "================= 回滚方案 ================="
echo "如果出现问题，请执行："
echo ""
echo "1) 删除隔离配置"
echo "   rm -rf /etc/systemd/system/komari-agent.service.d"
echo ""
echo "2) 重载 systemd"
echo "   systemctl daemon-reload"
echo ""
echo "3) 重启服务"
echo "   systemctl restart komari-agent"
echo ""
echo "==========================================="
