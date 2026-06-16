#!/bin/bash
# Telegram→Claude tmux bridge — ТОЛЬКО ВХОДЯЩИЕ (inbound-only).
# Runs on host as user boris (docker group + tmux socket access).
#
# Архитектура (push):
#   - Берёт сообщения из Redis tg:queue и инжектит в tmux-сессию "claude".
#   - Ответы НЕ ждёт и НЕ скрапит с экрана.
#   - Итог пользователю Claude отправляет сам через scripts/tg-send.sh.
#
# Это убирает таймауты ожидания, дампы транскрипта CLI и парсинг TG_REPLY.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-service.conf"   # PROJECT_DIR, ENV_FILE, контейнеры, tmux, pg
# DEVBOT_TOKEN — из systemd EnvironmentFile (.env)

redis_cmd() { docker exec "$REDIS_CONTAINER" redis-cli "$@" 2>/dev/null; }
tmux_cmd()  { tmux -S "$TMUX_SOCK" "$@"; }

# Системное уведомление пользователю (например, Claude не запущен).
tg_send() {
  local chat_id="$1" text="$2"
  curl -s -X POST "https://api.telegram.org/bot${DEVBOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --argjson chat_id "$chat_id" --arg text "$text" \
          '{chat_id:$chat_id, text:$text, parse_mode:"HTML"}')" \
    > /dev/null 2>&1
}

# Детект лимита сессии Claude (#remote-mqc0jofn): ловим в панели строку
# "You've hit your session limit · resets <время>" и шлём ОДНО уведомление с
# временем продолжения. Дедуп — через Redis tg:limit_notified; при исчезновении
# строки маркер сбрасываем, чтобы следующий лимит снова уведомил.
check_session_limit() {
  local pane line reset last
  pane=$(tmux_cmd capture-pane -p -J -t "$SESSION" -S -40 2>/dev/null || echo "")
  # Точная фраза реального сообщения Claude Code (не просто "session limit" —
  # иначе ловит упоминания/исходник скрипта в самой панели).
  line=$(echo "$pane" | grep -iE "hit your session limit" | grep -iF "resets" | tail -1)
  if [ -n "$line" ]; then
    reset=$(echo "$line" | sed -E 's/.*resets +//I' | sed 's/[[:space:]]*$//')
    # Принимаем только если после "resets" реально время (напр. 11:30am).
    if echo "$reset" | grep -qiE "[0-9]{1,2}(:[0-9]{2})? ?(am|pm)"; then
      last=$(redis_cmd GET tg:limit_notified 2>/dev/null)
      if [ "$last" != "$reset" ]; then
        redis_cmd SET tg:limit_notified "$reset" EX 86400 >/dev/null 2>&1
        [ -n "${TELEGRAM_ADMIN_CHAT_ID:-}" ] && tg_send "$TELEGRAM_ADMIN_CHAT_ID" \
          "⏳ <b>Достигнут лимит сессии Claude.</b> Работа приостановлена — продолжу автоматически после сброса: <b>${reset}</b>."
        echo "[tg-bridge] session limit detected → notified (resets ${reset})"
      fi
    fi
  else
    redis_cmd DEL tg:limit_notified >/dev/null 2>&1
  fi
}

inject_message() {
  local msg="$1"
  local chat_id text attachment att_type
  chat_id=$(echo "$msg" | jq -r '.chat_id // empty')
  text=$(echo "$msg" | jq -r '.text // ""')
  attachment=$(echo "$msg" | jq -r '.attachment_path // ""')
  att_type=$(echo "$msg" | jq -r '.attachment_type // ""')

  if [ -z "$chat_id" ]; then
    echo "[tg-bridge] WARN: invalid message (no chat_id), skipping"
    return
  fi

  if ! tmux_cmd has-session -t "$SESSION" 2>/dev/null; then
    tg_send "$chat_id" "❌ Claude не запущен на сервере. Запустите его через SSH."
    return
  fi

  # Собрать текст для инъекции
  local inject_text=""
  if [ -n "$attachment" ]; then
    inject_text="[Telegram: пользователь прислал ${att_type} → ${attachment}]"$'\n'
  fi
  if [ -n "$text" ]; then
    inject_text="${inject_text}${text}"
  elif [ -z "$attachment" ]; then
    inject_text="(пустое сообщение из Telegram)"
  fi
  inject_text="[TG] ${inject_text}"

  echo "[tg-bridge] Injecting: ${inject_text:0:100}..."

  # Безопасная инъекция: load-buffer корректно обрабатывает кавычки, $, backtick.
  printf '%s' "$inject_text" | tmux_cmd load-buffer -
  tmux_cmd paste-buffer -t "$SESSION"
  tmux_cmd send-keys -t "$SESSION" Enter
}

main() {
  echo "[tg-bridge] Started (inbound-only). Polling Redis tg:queue every 2s..."
  echo "[tg-bridge] tmux socket: $TMUX_SOCK | session: $SESSION"

  while true; do
    # Проверка лимита сессии Claude на каждой итерации (~каждые 2с).
    check_session_limit

    local msg
    msg=$(redis_cmd LPOP tg:queue 2>/dev/null || echo "")

    if [ -z "$msg" ] || [ "$msg" = "(nil)" ]; then
      sleep 2
      continue
    fi

    echo "[tg-bridge] Dequeued: ${msg:0:120}"
    inject_message "$msg" || echo "[tg-bridge] ERROR in inject_message"

    # Дать Claude Code принять ввод перед следующим сообщением.
    sleep 1
  done
}

main
