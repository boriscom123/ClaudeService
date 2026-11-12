#!/bin/bash
# Auto-start the active model (Claude, Grok, or Codex) after VPS boot.
# Called by systemd claude-autostart.service.
# Поднимает tmux-сессию 'agent' в каталоге текущего проекта, если её ещё нет,
# и запускает бинарник модели из ~/.cs-current-model (иначе Claude).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

PROJECT_ID="$(project_current)"
PROJECT_DIR="$(project_dir "$PROJECT_ID")"
PROJECT_DIR="$(readlink -f "$PROJECT_DIR")"
MODEL_ID="$(model_current)"
AGENT_BIN="$(model_launch_cmd "$MODEL_ID" "$PROJECT_DIR")"
AGENT_WIN="$(model_window "$MODEL_ID")"
SESSION="${CLAUDE_SESSION:-agent}"
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

# Обратная связь текущего проекта — на случай, если каталог правили руками
# или проект добавили в реестр между перезагрузками (см. project_ensure_bridge).
project_ensure_bridge "$PROJECT_ID" || true

# Сессии нет — окно активной модели (файл ~/.cs-current-model, иначе Claude).
# Доверие до ввода команды: вопрос в терминале после ребута некому подтвердить.
case "$MODEL_ID" in
  claude) trust_claude_dir "$PROJECT_DIR" || true ;;
  grok) trust_grok_dir "$PROJECT_DIR" || true ;;
  codex) : ;; # Доверие Codex к проектам задаётся глобально в ~/.codex/config.toml.
esac
$TMUX_CMD new-session -d -s "$SESSION" -n "$AGENT_WIN" -c "$PROJECT_DIR"
$TMUX_CMD send-keys -t "${SESSION}:${AGENT_WIN}" "$AGENT_BIN" Enter

# После инициализации — уведомление в Telegram (фоном).
(
  sleep 15
  tg_notify "🤖 $(model_name "$MODEL_ID") запущен
📁 Проект: $(project_name "$PROJECT_ID")"
) &
