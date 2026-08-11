#!/bin/bash
# Install and enable claude-autostart.service and tg-bridge.service.
# Run once: sudo bash scripts/install-systemd.sh

set -e
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

chmod +x "$SCRIPTS_DIR/start-claude.sh"
chmod +x "$SCRIPTS_DIR/watch-triggers.sh"

cp "$SCRIPTS_DIR/systemd/claude-autostart.service" /etc/systemd/system/
cp "$SCRIPTS_DIR/systemd/tg-bridge.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now claude-autostart.service
systemctl enable --now tg-bridge.service

echo "✅ Установлено:"
systemctl status claude-autostart.service --no-pager | head -4
echo "---"
systemctl status tg-bridge.service --no-pager | head -4
