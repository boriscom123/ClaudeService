#!/bin/bash
# Auto-start Claude Code session after VPS boot.
# Called by systemd claude-autostart.service.
# Поднимает tmux-сессию 'claude' в каталоге текущего проекта и уведомляет в Telegram.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

CLAUDE_BIN="/home/boris/.local/bin/claude"
PROJECT_ID="$(project_current)"
PROJECT_DIR="$(project_dir "$PROJECT_ID")"
SESSION="${CLAUDE_SESSION:-claude}"
TMUX_SOCKET="/tmp/tmux-1000/default"
TMUX_CMD="tmux -S $TMUX_SOCKET"
BOT_TOKEN="8916100099:AAHivhMP_6nUHKE-KLA6JVUn4V825F-ixV8"
CHAT_ID="941953678"

tg_notify() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$CHAT_ID" --arg text "$1" \
          '{chat_id: $chat_id, text: $text}')" \
    > /dev/null 2>&1
}

# Ensure tmux socket directory exists (not present on fresh boot)
mkdir -p "$(dirname "$TMUX_SOCKET")"
chmod 700 "$(dirname "$TMUX_SOCKET")"

# Already running — nothing to do
if $TMUX_CMD has-session -t "$SESSION" 2>/dev/null; then
  exit 0
fi

# Create detached tmux session and start Claude
$TMUX_CMD new-session -d -s "$SESSION" -c "$PROJECT_DIR"
$TMUX_CMD send-keys -t "$SESSION" "$CLAUDE_BIN" Enter

# После инициализации Claude — уведомление в Telegram (фоном).
(
  sleep 15
  tg_notify "🤖 Claude запущен
📁 Проект: $(project_name "$PROJECT_ID")"
) &
