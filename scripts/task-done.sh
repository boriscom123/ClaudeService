#!/bin/bash
# Завершение [TG]-задачи: записать «что сделано»/«как протестировать», перевести в
# testing и прислать пользователю сообщение «готово к проверке» с inline-кнопками
# [✅ Закрыть] [🔄 Вернуть] (как в списке задач). Claude вызывает после задачи с тегом.
#
# Использование:
#   scripts/task-done.sh <tag> "<что сделано>" "<как протестировать>"
#
# psql :'var' сам экранирует кавычки/спецсимволы в значениях.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-service.conf"   # PROJECT_DIR, ENV_FILE, контейнеры, tmux, pg
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'; }
TOKEN="$(get_env DEVBOT_TOKEN)"
CHAT="$(get_env TELEGRAM_ADMIN_CHAT_ID)"

TAG="${1:?usage: task-done.sh <tag> <result> <test_steps>}"
RESULT="${2:-}"
TEST="${3:-}"
TAG="${TAG#\#}"   # tag может прийти с ведущим '#'

# 1) Записать результат и перевести задачу в testing
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_USER}" -d "${PG_DB}" \
  -v tag="$TAG" -v result="$RESULT" -v test="$TEST" \
  -f - <<'SQL'
UPDATE dev_tasks
   SET result = :'result', test_steps = :'test', status = 'testing', updated_at = NOW()
 WHERE tag = :'tag';
SQL

# 2) Заголовок задачи для сообщения
TITLE=$(docker exec -i "${POSTGRES_CONTAINER}" \
  psql -U "${PG_USER}" -d "${PG_DB}" -t -A -c "SELECT title FROM dev_tasks WHERE tag='${TAG}';" \
  2>/dev/null | head -1)
[ -z "$TITLE" ] && TITLE="$TAG"

# 3) Сообщение «готово к проверке» + inline-кнопки приёмки (callbacks.js: ok/reject)
payload=$(jq -n \
  --argjson chat_id "$CHAT" \
  --arg text "🧪 Готово к проверке: <b>${TITLE}</b>
<code>#${TAG}</code>

📝 <b>Что сделано:</b>
${RESULT:-—}

🧪 <b>Как протестировать:</b>
${TEST:-—}" \
  --arg ok "ok:${TAG}" --arg rej "reject:${TAG}" \
  '{chat_id:$chat_id, text:$text, parse_mode:"HTML",
    reply_markup:{inline_keyboard:[[
      {text:"✅ Закрыть", callback_data:$ok},
      {text:"🔄 Вернуть", callback_data:$rej}
    ]]}}')

resp=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" -d "$payload")

# 4) Трек msg_id для «🗑️ Очистить чат»
msg_id=$(echo "$resp" | jq -r '.result.message_id')
if [ -n "$msg_id" ] && [ "$msg_id" != "null" ]; then
  docker exec -i "${POSTGRES_CONTAINER}" \
    psql -U "${PG_USER}" -d "${PG_DB}" \
    -c "INSERT INTO telegram_bot_messages (chat_id, message_id) VALUES (${CHAT}, ${msg_id});" >/dev/null 2>&1
fi

echo "task-done: $(echo "$resp" | jq -r '.ok') (#${TAG} → testing)"
