#!/bin/bash
# Отправить осмысленный итог пользователю в Telegram через сервисный бот.
# Claude вызывает это ПОСЛЕ выполнения задачи, пришедшей с префиксом [TG].
# Мост (watch-triggers.sh) больше не ждёт и не скрапит ответ — доставка только тут.
#
# Скрипт живёт в ClaudeService/scripts и симлинкается в проекты — реальный путь
# (и .env рядом) резолвится через readlink, поэтому работает через симлинк.
#
# Использование:
#   scripts/tg-send.sh "Готово: исправил X, проверил Y."
#   scripts/tg-send.sh "<текст>" <chat_id>     # необязательный явный chat_id
#
# Текст идёт с parse_mode=HTML — экранируй < > & или используй простой текст.
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ENV_FILE="${CS_ENV_FILE:-$SCRIPT_DIR/../.env}"
REDIS_CONTAINER="${CS_REDIS_CONTAINER:-claudeservice-redis-1}"
TEXT="${1:?usage: tg-send.sh <text> [chat_id]}"

# Безопасно читаем только нужные ключи (не сорсим весь .env)
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'; }

TOKEN="$(get_env DEVBOT_TOKEN)"
CHAT="${2:-$(get_env TELEGRAM_ADMIN_CHAT_ID)}"

if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
  echo "tg-send: нет DEVBOT_TOKEN или TELEGRAM_ADMIN_CHAT_ID в $ENV_FILE" >&2
  exit 1
fi

resp=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --argjson chat_id "$CHAT" --arg text "$TEXT" \
        '{chat_id:$chat_id, text:$text, parse_mode:"HTML"}')")

if [ "$(echo "$resp" | jq -r '.ok' 2>/dev/null)" = "true" ]; then
  # Трекаем msg_id в Redis (cs:msgids:<chat>), чтобы «🗑️ Очистить чат»
  # удалял и эти исходящие (devbot.clearMessages читает этот список).
  msg_id=$(echo "$resp" | jq -r '.result.message_id')
  if [ -n "$msg_id" ] && [ "$msg_id" != "null" ]; then
    docker exec -i "$REDIS_CONTAINER" redis-cli RPUSH "cs:msgids:${CHAT}" "$msg_id" >/dev/null 2>&1
    docker exec -i "$REDIS_CONTAINER" redis-cli LTRIM "cs:msgids:${CHAT}" -500 -1 >/dev/null 2>&1
  fi
  echo "tg-send: ok (msg ${msg_id})"
else
  echo "tg-send: FAIL → $resp" >&2
  exit 1
fi
