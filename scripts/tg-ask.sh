#!/bin/bash
# Отправить вопрос с inline-кнопками быстрого выбора вариантов + «✍️ Свой вариант».
# Нажатие варианта → выбор возвращается Claude в очередь (tg:queue).
# «Свой вариант» → бот ждёт свободный текст и тоже отдаёт его Claude.
#
# Использование:
#   scripts/tg-ask.sh "Вопрос?" "Вариант 1" "Вариант 2" "Вариант 3"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-service.conf"   # PROJECT_DIR, ENV_FILE, контейнеры, tmux, pg
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'; }
TOKEN="$(get_env DEVBOT_TOKEN)"
CHAT="$(get_env TELEGRAM_ADMIN_CHAT_ID)"

QUESTION="${1:?usage: tg-ask.sh <question> <opt1> [opt2...]}"
shift
[ "$#" -ge 1 ] || { echo "tg-ask: нужен хотя бы один вариант" >&2; exit 1; }

ASK_ID="$(date +%s%N)"

# Сохранить варианты (JSON-массив) в Redis, TTL 1ч — для разбора callback.
OPTS_JSON=$(printf '%s\n' "$@" | jq -R . | jq -s .)
docker exec -i "${REDIS_CONTAINER}" \
  redis-cli SET "tg:ask:${ASK_ID}" "$OPTS_JSON" EX 3600 >/dev/null

# Номер-эмодзи: для нумерации в тексте и коротких кнопок (кнопки обрезаются — текст нет).
emoji_num() {
  case "$1" in
    1) echo "1️⃣";; 2) echo "2️⃣";; 3) echo "3️⃣";; 4) echo "4️⃣";; 5) echo "5️⃣";;
    6) echo "6️⃣";; 7) echo "7️⃣";; 8) echo "8️⃣";; 9) echo "9️⃣";; 10) echo "🔟";;
    *) echo "$1";;
  esac
}

# Текст: вопрос + ПОЛНЫЙ нумерованный список вариантов (на кнопках они обрезаются).
text="$QUESTION"$'\n'
i=0
for opt in "$@"; do
  text="${text}"$'\n'"$(emoji_num $((i + 1))) ${opt}"
  i=$((i + 1))
done

# Кнопки — короткие (только номер) в один ряд + «Свой вариант» отдельной строкой.
# Выбор резолвится по индексу (callbacks.js берёт текст варианта из Redis).
numbers="[]"
i=0
for opt in "$@"; do
  btn=$(jq -n --arg t "$(emoji_num $((i + 1)))" --arg cb "ask:${ASK_ID}:$i" '{text:$t, callback_data:$cb}')
  numbers=$(echo "$numbers" | jq --argjson b "$btn" '. + [$b]')
  i=$((i + 1))
done
buttons=$(jq -n --argjson nums "$numbers" --arg cb "ask:${ASK_ID}:own" \
  '[$nums, [{text:"✍️ Свой вариант", callback_data:$cb}]]')

resp=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --argjson chat_id "$CHAT" --arg text "$text" --argjson kb "$buttons" \
        '{chat_id:$chat_id, text:$text, parse_mode:"HTML", reply_markup:{inline_keyboard:$kb}}')")

# Трекаем msg_id, чтобы «🗑️ Очистить чат» его удалял.
msg_id=$(echo "$resp" | jq -r '.result.message_id')
if [ -n "$msg_id" ] && [ "$msg_id" != "null" ]; then
  docker exec -i "${POSTGRES_CONTAINER}" \
    psql -U "${PG_USER}" -d "${PG_DB}" \
    -c "INSERT INTO telegram_bot_messages (chat_id, message_id) VALUES (${CHAT}, ${msg_id});" >/dev/null 2>&1
fi

if [ "$(echo "$resp" | jq -r '.ok')" = "true" ]; then
  echo "tg-ask: ok (id=${ASK_ID})"
else
  echo "tg-ask: FAIL → $resp" >&2
  exit 1
fi
