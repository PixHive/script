#!/usr/bin/env bash
set -euo pipefail

# Avoid systemctl entering less/pager and looking "stuck".
export SYSTEMD_PAGER=cat
export PAGER=cat

SERVICE_NAME="${1:-komari-agent}"
RUN_USER="komari"
RUN_GROUP="komari"
DEFAULT_AGENT="/opt/komari/agent"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"

echo "==> Komari Agent 加固脚本开始"
echo "==> 目标服务：${SERVICE_NAME}.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 root 用户执行此脚本"
  exit 1
fi

echo "==> 1. 检查 systemd 服务"
if ! systemctl cat "${SERVICE_NAME}.service" --no-pager >/dev/null 2>&1; then
  echo "错误：没有找到 ${SERVICE_NAME}.service"
  echo
  echo "请先确认 Komari Agent 是否已经安装成功："
  echo "  systemctl list-unit-files | grep -i komari"
  echo "  systemctl status komari-agent --no-pager"
  echo "  ls -l /etc/systemd/system/komari-agent.service"
  echo "  ls -l /opt/komari/agent"
  exit 1
fi

SERVICE_FILE="$(systemctl show -p FragmentPath --value "${SERVICE_NAME}.service")"
if [ -z "$SERVICE_FILE" ] || [ ! -f "$SERVICE_FILE" ]; then
  echo "错误：无法找到主 systemd 服务文件"
  exit 1
fi

echo "主服务文件：${SERVICE_FILE}"

echo "==> 2. 停止服务，清理旧 override"
systemctl stop "${SERVICE_NAME}.service" || true

# 删除旧加固脚本留下的 override，避免旧 endpoint/token/参数继续生效
rm -f "${DROPIN_FILE}"

# 如果旧脚本生成过其它同类文件，也一并清理
rm -f "${DROPIN_DIR}/99-komari-hardening.conf" 2>/dev/null || true
rm -f "${DROPIN_DIR}/10-komari-hardening.conf" 2>/dev/null || true

systemctl daemon-reload

echo "==> 3. 只从主 service 文件读取 ExecStart"
CURRENT_EXEC="$(awk -F= '/^ExecStart=/{print substr($0, index($0,$2))}' "$SERVICE_FILE" | tail -n1)"

if [ -z "$CURRENT_EXEC" ]; then
  echo "错误：无法从主服务文件读取 ExecStart"
  echo "请执行查看：cat ${SERVICE_FILE}"
  exit 1
fi

echo "主服务启动命令：${CURRENT_EXEC}"

AGENT_BIN="$(echo "$CURRENT_EXEC" | awk '{print $1}')"
if [ ! -x "$AGENT_BIN" ]; then
  if [ -x "$DEFAULT_AGENT" ]; then
    AGENT_BIN="$DEFAULT_AGENT"
  else
    echo "错误：找不到可执行的 Komari Agent"
    echo "解析到的路径：${AGENT_BIN}"
    echo "默认路径：${DEFAULT_AGENT}"
    exit 1
  fi
fi

INSTALL_DIR="$(dirname "$AGENT_BIN")"
echo "Agent 路径：${AGENT_BIN}"
echo "安装目录：${INSTALL_DIR}"

echo "==> 4. 创建低权限用户和用户组"
if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then
  groupadd --system "$RUN_GROUP"
  echo "已创建用户组：${RUN_GROUP}"
fi

if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$RUN_GROUP" "$RUN_USER"
  echo "已创建用户：${RUN_USER}"
else
  echo "用户已存在：${RUN_USER}"
fi

echo "==> 5. 修改目录归属和权限"
chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"
chmod 750 "$AGENT_BIN"

echo "==> 6. 生成干净 ExecStart"
NEW_EXEC="$CURRENT_EXEC"

if ! echo "$NEW_EXEC" | grep -q -- "--disable-web-ssh"; then
  NEW_EXEC="$NEW_EXEC --disable-web-ssh"
fi

if ! echo "$NEW_EXEC" | grep -q -- "--disable-auto-update"; then
  NEW_EXEC="$NEW_EXEC --disable-auto-update"
fi

echo "新的启动命令：${NEW_EXEC}"

echo "==> 7. 写入全新的 systemd override"
mkdir -p "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<EOF
[Service]
# Reset previous ExecStart from the main unit before setting a clean one.
ExecStart=
ExecStart=${NEW_EXEC}

User=${RUN_USER}
Group=${RUN_GROUP}

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LockPersonality=true

# Allow ICMP ping without running as root.
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
EOF

echo "==> 8. 重载 systemd 并启动服务"
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}.service" || true
systemctl restart "${SERVICE_NAME}.service"

sleep 2

echo
echo "==> 9. 服务状态"
systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

echo
echo "==> 10. 检查实际启动参数"
systemctl cat "${SERVICE_NAME}.service" --no-pager || true
echo
ps -eo user,pid,cmd | grep -i komari | grep -v grep || true

echo
echo "==> 加固完成"
echo
echo "确认点："
echo "1. 进程用户应为 ${RUN_USER}"
echo "2. ExecStart 应该使用主 service 里的最新 endpoint/token"
echo "3. 参数应包含 --disable-web-ssh 和 --disable-auto-update"
echo
echo "回滚命令："
echo "  rm -rf ${DROPIN_DIR}"
echo "  systemctl daemon-reload"
echo "  systemctl restart ${SERVICE_NAME}.service"
