#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=”${1:-komari-agent}”
RUN_USER=“komari”
RUN_GROUP=“komari”

DEFAULT_AGENT=”/opt/komari/agent”

echo “==> Komari Agent 加固脚本开始”
echo “==> 目标服务：${SERVICE_NAME}.service”

if [ “$(id -u)” -ne 0 ]; then
echo “错误：请使用 root 执行此脚本”
exit 1
fi

echo “==> 1. 检查 systemd 服务”

if ! systemctl cat “${SERVICE_NAME}.service” >/dev/null 2>&1; then
echo “错误：没有找到 ${SERVICE_NAME}.service”
echo
echo “请先确认官方 Agent 是否安装成功：”
echo “  systemctl list-unit-files | grep -i komari”
echo “  systemctl status komari-agent”
echo “  ls -l /etc/systemd/system/komari-agent.service”
echo “  ls -l /opt/komari/agent”
echo
echo “如果你安装时自定义过服务名，请这样运行：”
echo “  bash /root/komari-agent-hardening.sh 你的服务名”
exit 1
fi

SERVICE_FILE=”$(systemctl show -p FragmentPath –value “${SERVICE_NAME}.service”)”

if [ -z “$SERVICE_FILE” ] || [ ! -f “$SERVICE_FILE” ]; then
echo “错误：无法找到 systemd service 文件”
exit 1
fi

echo “发现服务文件：$SERVICE_FILE”

echo “==> 2. 读取当前 ExecStart”

CURRENT_EXEC=”$(systemctl cat “${SERVICE_NAME}.service” | awk -F= ‘/^ExecStart=/{print $2}’ | tail -n1)”

if [ -z “$CURRENT_EXEC” ]; then
echo “错误：无法读取 ExecStart”
echo “请执行查看：systemctl cat ${SERVICE_NAME}.service”
exit 1
fi

echo “当前启动命令：$CURRENT_EXEC”

AGENT_BIN=”$(echo “$CURRENT_EXEC” | awk ‘{print $1}’)”

if [ ! -x “$AGENT_BIN” ]; then
if [ -x “$DEFAULT_AGENT” ]; then
AGENT_BIN=”$DEFAULT_AGENT”
else
echo “错误：找不到可执行的 Komari Agent”
echo “当前解析路径：$AGENT_BIN”
echo “默认路径：$DEFAULT_AGENT”
echo
echo “请执行：”
echo “  systemctl cat ${SERVICE_NAME}.service”
echo “  ls -l /opt/komari”
exit 1
fi
fi

INSTALL_DIR=”$(dirname “$AGENT_BIN”)”

echo “Agent 路径：$AGENT_BIN”
echo “安装目录：$INSTALL_DIR”

echo “==> 3. 创建低权限用户”

if ! id “$RUN_USER” >/dev/null 2>&1; then
useradd –system –no-create-home –shell /usr/sbin/nologin “$RUN_USER”
echo “已创建用户：$RUN_USER”
else
echo “用户已存在：$RUN_USER”
fi

echo “==> 4. 修改安装目录权限”

chown -R “$RUN_USER:$RUN_GROUP” “$INSTALL_DIR”
chmod 750 “$INSTALL_DIR”
chmod 750 “$AGENT_BIN”

echo “已授权：$INSTALL_DIR”

echo “==> 5. 给 Agent 添加 ping 所需能力”

if command -v setcap >/dev/null 2>&1; then
setcap cap_net_raw=+ep “$AGENT_BIN” || true
getcap “$AGENT_BIN” || true
else
echo “未找到 setcap，跳过 cap_net_raw。若 ping 功能异常，可安装 libcap2-bin 后重跑。”
fi

echo “==> 6. 生成新的 ExecStart”

NEW_EXEC=”$CURRENT_EXEC”

if ! echo “$NEW_EXEC” | grep -q – “–disable-web-ssh”; then
NEW_EXEC=”$NEW_EXEC –disable-web-ssh”
fi

if ! echo “$NEW_EXEC” | grep -q – “–disable-auto-update”; then
NEW_EXEC=”$NEW_EXEC –disable-auto-update”
fi

echo “新的启动命令：$NEW_EXEC”

echo “==> 7. 写入 systemd override”

mkdir -p “/etc/systemd/system/${SERVICE_NAME}.service.d”

cat > “/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf” <<EOL
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

echo “override 已写入：/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf”

echo “==> 8. 重载并重启服务”

systemctl daemon-reload
systemctl restart “${SERVICE_NAME}.service”

sleep 2

echo
echo “==> 9. 服务状态”
systemctl –no-pager –full status “${SERVICE_NAME}.service” || true

echo
echo “==> 10. 检查进程用户和参数”
ps -eo user,pid,cmd | grep -i komari | grep -v grep || true

echo
echo “==> 11. 检查 Agent 文件能力”
getcap “$AGENT_BIN” 2>/dev/null || true

echo
echo “==> 加固完成”
echo
echo “请确认：”
echo “1. 进程用户是 ${RUN_USER}，不是 root”
echo “2. 参数包含 –disable-web-ssh”
echo “3. 参数包含 –disable-auto-update”
echo
echo “如果启动失败，回滚：”
echo “  rm -rf /etc/systemd/system/${SERVICE_NAME}.service.d”
echo “  systemctl daemon-reload”
echo “  systemctl restart ${SERVICE_NAME}.service”
