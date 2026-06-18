#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-komari-agent}"
RUN_USER="komari"
RUN_GROUP="komari"

DEFAULT_AGENT="/opt/komari/agent"

echo "==> Komari Agent hardening start"
echo "==> Target service: ${SERVICE_NAME}.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run this script as root"
  exit 1
fi

echo "==> 1. Checking systemd service"

if ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  echo "ERROR: ${SERVICE_NAME}.service not found"
  echo
  echo "Please check whether Komari Agent was installed successfully:"
  echo "  systemctl list-unit-files | grep -i komari"
  echo "  systemctl status komari-agent"
  echo "  ls -l /etc/systemd/system/komari-agent.service"
  echo "  ls -l /opt/komari/agent"
  echo
  echo "If you used a custom service name, run:"
  echo "  bash /root/komari-agent-hardening.sh your-service-name"
  exit 1
fi

SERVICE_FILE="$(systemctl show -p FragmentPath --value "${SERVICE_NAME}.service")"

if [ -z "$SERVICE_FILE" ] || [ ! -f "$SERVICE_FILE" ]; then
  echo "ERROR: Cannot find systemd service file"
  exit 1
fi

echo "Service file: $SERVICE_FILE"

echo "==> 2. Reading current ExecStart"

CURRENT_EXEC="$(systemctl cat "${SERVICE_NAME}.service" | awk -F= '/^ExecStart=/{print $2}' | tail -n1)"

if [ -z "$CURRENT_EXEC" ]; then
  echo "ERROR: Cannot read ExecStart"
  echo "Please run: systemctl cat ${SERVICE_NAME}.service"
  exit 1
fi

echo "Current ExecStart: $CURRENT_EXEC"

AGENT_BIN="$(echo "$CURRENT_EXEC" | awk '{print $1}')"

if [ ! -x "$AGENT_BIN" ]; then
  if [ -x "$DEFAULT_AGENT" ]; then
    AGENT_BIN="$DEFAULT_AGENT"
  else
    echo "ERROR: Cannot find executable Komari Agent"
    echo "Parsed path: $AGENT_BIN"
    echo "Default path: $DEFAULT_AGENT"
    echo
    echo "Please run:"
    echo "  systemctl cat ${SERVICE_NAME}.service"
    echo "  ls -l /opt/komari"
    exit 1
  fi
fi

INSTALL_DIR="$(dirname "$AGENT_BIN")"

echo "Agent path: $AGENT_BIN"
echo "Install dir: $INSTALL_DIR"

echo "==> 3. Creating low-privilege user"

if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  echo "Created user: $RUN_USER"
else
  echo "User already exists: $RUN_USER"
fi

echo "==> 4. Updating ownership and permissions"

chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
chmod 750 "$AGENT_BIN"

echo "Updated permissions for: $INSTALL_DIR"

echo "==> 5. Granting ping capability"

if command -v setcap >/dev/null 2>&1; then
  setcap cap_net_raw=+ep "$AGENT_BIN" || true
  getcap "$AGENT_BIN" || true
else
  echo "setcap not found. Skipping cap_net_raw."
  echo "If ping does not work, install libcap2-bin and rerun this script."
fi

echo "==> 6. Building new ExecStart"

NEW_EXEC="$CURRENT_EXEC"

if ! echo "$NEW_EXEC" | grep -q -- "--disable-web-ssh"; then
  NEW_EXEC="$NEW_EXEC --disable-web-ssh"
fi

if ! echo "$NEW_EXEC" | grep -q -- "--disable-auto-update"; then
  NEW_EXEC="$NEW_EXEC --disable-auto-update"
fi

echo "New ExecStart: $NEW_EXEC"

echo "==> 7. Writing systemd override"

mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"

cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf" <<EOL
[Service]
User=${RUN_USER}
Group=${RUN_GROUP}

ExecStart=
ExecStart=${NEW_EXEC}

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native

Restart=always
RestartSec=5
EOL

echo "Override written to: /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf"

echo "==> 8. Reloading and restarting service"

systemctl daemon-reload
systemctl restart "${SERVICE_NAME}.service"

sleep 2

echo
echo "==> 9. Service status"
systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

echo
echo "==> 10. Process user and arguments"
ps -eo user,pid,cmd | grep -i komari | grep -v grep || true

echo
echo "==> 11. Agent file capabilities"
getcap "$AGENT_BIN" 2>/dev/null || true

echo
echo "==> Hardening complete"
echo
echo "Please confirm:"
echo "1. Process user is ${RUN_USER}, not root"
echo "2. Arguments include --disable-web-ssh"
echo "3. Arguments include --disable-auto-update"
echo
echo "Rollback command:"
echo "  rm -rf /etc/systemd/system/${SERVICE_NAME}.service.d"
echo "  systemctl daemon-reload"
echo "  systemctl restart ${SERVICE_NAME}.service"
