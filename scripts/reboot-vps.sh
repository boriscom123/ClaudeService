#!/bin/bash
# Перезагрузка VPS с сохранением состояния (кнопка бота «🔄 Перезагрузить VPS»).
# Шаги: 1) уведомление в Telegram; 2) reboot. После загрузки claude-autostart.service
# сам поднимает tmux-сессию Claude, а tg-bridge.service — мост Telegram→Claude.
#
# ТРЕБУЕТСЯ разовая настройка на хосте (иначе reboot запросит пароль и повиснет):
#   echo 'boris ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /sbin/reboot, /usr/sbin/reboot' \
#     | sudo tee /etc/sudoers.d/reboot-vps && sudo chmod 440 /etc/sudoers.d/reboot-vps
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

# 1) Уведомление пользователю
"$SCRIPT_DIR/tg-send.sh" "🔄 Перезагружаю VPS… Claude вернётся автоматически после загрузки (~1–2 мин)." 2>/dev/null || true

# 2) Перезагрузка (нужен NOPASSWD sudo, см. шапку). Пробуем несколько путей.
sleep 2
sudo -n systemctl reboot 2>/dev/null \
  || sudo -n /sbin/reboot 2>/dev/null \
  || sudo -n /usr/sbin/reboot 2>/dev/null \
  || {
    "$SCRIPT_DIR/tg-send.sh" "⚠️ Не удалось перезагрузить VPS: нет прав sudo на reboot. Нужна разовая настройка sudoers (см. scripts/reboot-vps.sh)." 2>/dev/null
    exit 1
  }
