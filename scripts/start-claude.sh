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

# Токен/chat_id — только из .env рядом со скриптами (в .gitignore, не в репозитории).
# Не хардкодим секреты в коде. Читаем ровно нужные ключи, не сорся весь .env.
ENV_FILE="${CS_ENV_FILE:-$SCRIPT_DIR/../.env}"
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'; }
BOT_TOKEN="$(get_env DEVBOT_TOKEN)"
CHAT_ID="$(get_env TELEGRAM_ADMIN_CHAT_ID)"

tg_notify() {
  [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || return 0
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
