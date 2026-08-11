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
source "$SCRIPT_DIR/projects.sh"

REDIS_CONTAINER="claudeservice-redis-1"
TMUX_SOCK="/tmp/tmux-1000/default"
SESSION="${CLAUDE_SESSION:-claude}"
# DEVBOT_TOKEN — из systemd EnvironmentFile (.env)

redis_cmd() { docker exec "$REDIS_CONTAINER" redis-cli "$@" 2>/dev/null; }
tmux_cmd()  { tmux -S "$TMUX_SOCK" "$@"; }

# Публикация реестра проектов в Redis (HASH cs:projects id→имя). Отсюда devbot
# строит меню «Проект», валидирует коды кросс-проектной адресации и показывает имена.
# Единый источник правды — projects.sh; добавление проекта не требует пересборки devbot.
publish_projects() {
  local args=() id
  for id in $(project_list); do args+=("$id" "$(project_name "$id")"); done
  redis_cmd DEL cs:projects >/dev/null 2>&1
  [ ${#args[@]} -gt 0 ] && redis_cmd HSET cs:projects "${args[@]}" >/dev/null 2>&1
}

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
  local pane line reset last reset_epoch
  pane=$(tmux_cmd capture-pane -p -J -t "$SESSION" -S -40 2>/dev/null || echo "")
  # Точная фраза реального сообщения Claude Code (не просто "session limit" —
  # иначе ловит упоминания/исходник скрипта в самой панели).
  line=$(echo "$pane" | grep -iE "hit your session limit" | grep -iF "resets" | tail -1)
  if [ -n "$line" ]; then
    reset=$(echo "$line" | sed -E 's/.*resets +//I' | sed 's/[[:space:]]*$//')
    # Принимаем только если после "resets" реально время (напр. 11:30am).
    if echo "$reset" | grep -qiE "[0-9]{1,2}(:[0-9]{2})? ?(am|pm)"; then
      # Remember when to auto-resume (epoch). Rolls to tomorrow if that time already passed today.
      reset_epoch=$(date -d "$reset" +%s 2>/dev/null || true)
      if [ -n "$reset_epoch" ]; then
        # Roll to tomorrow ONLY if the clock time is far in the past (>12h) — a genuine next-day
        # reset (e.g. "00:30am" seen at 11pm). A reset that just passed (within 12h) must NOT be
        # pushed a full day, or auto-resume would wait ~24h and never fire today.
        [ "$reset_epoch" -lt "$(( $(date +%s) - 43200 ))" ] && reset_epoch=$((reset_epoch + 86400))
        redis_cmd SET claude:resume_at "$reset_epoch" EX 172800 >/dev/null 2>&1
      fi
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

# Авто-возобновление после сброса лимита. Если задан claude:resume_at (epoch времени
# сброса) и claude:resume_cmd (команда для реинжекта, ставит её сам Claude при запуске
# loop), то по наступлении времени, при ОТСУТСТВИИ баннера лимита и простое сессии —
# реинжектим команду и уведомляем. Generic: без этих ключей ничего не делает (game/cm не затронуты).
maybe_resume() {
  local resume_at pane cmd
  resume_at=$(redis_cmd GET claude:resume_at 2>/dev/null)
  if [ -z "$resume_at" ] || [ "$resume_at" = "(nil)" ]; then
    return
  fi
  if [ "$(date +%s)" -lt "$resume_at" ]; then
    return  # время сброса ещё не наступило
  fi
  if ! tmux_cmd has-session -t "$SESSION" 2>/dev/null; then
    return
  fi
  pane=$(tmux_cmd capture-pane -p -J -t "$SESSION" -S -40 2>/dev/null || echo "")
  if echo "$pane" | grep -iqE "hit your session limit"; then
    return  # лимит ещё висит
  fi
  if echo "$pane" | grep -qiF "esc to interrupt"; then
    return  # сессия занята
  fi
  cmd=$(redis_cmd GET claude:resume_cmd 2>/dev/null)
  if [ -z "$cmd" ] || [ "$cmd" = "(nil)" ]; then
    redis_cmd DEL claude:resume_at >/dev/null 2>&1
    return
  fi
  echo "[tg-bridge] Limit reset reached → re-injecting resume command"
  printf '%s' "$cmd" | tmux_cmd load-buffer -
  tmux_cmd paste-buffer -t "$SESSION"
  tmux_cmd send-keys -t "$SESSION" Enter
  redis_cmd DEL claude:resume_at >/dev/null 2>&1
  [ -n "${TELEGRAM_ADMIN_CHAT_ID:-}" ] && tg_send "$TELEGRAM_ADMIN_CHAT_ID" \
    "▶️ Лимит сброшен — автоматически возобновил работу."
}

# Занят ли Claude прямо сейчас. Маркер: в видимой панели есть "esc to interrupt"
# (footer Claude Code во время генерации/выполнения инструментов). Нет строки → простой.
session_busy() {
  local pane
  pane=$(tmux_cmd capture-pane -p -t "$SESSION" 2>/dev/null || echo "")
  echo "$pane" | grep -qiF "esc to interrupt"
}

# Переключение проекта выполняет МОСТ, а не Claude: switch-project.sh убивает
# сессию, в которой запущен, — Claude не пережил бы собственную команду.
# Возвращает 0, если сообщение обработано здесь и инжектить его не нужно.
handle_switch_project() {
  local chat_id="$1" text="$2"
  local target label

  case "$text" in
    "[Переключить проект]"*) ;;
    *) return 1 ;;
  esac

  target=$(printf '%s' "$text" | sed -E 's/^\[Переключить проект\][[:space:]]*//' | tr -d '[:space:]')

  if ! project_dir "$target" >/dev/null; then
    tg_send "$chat_id" "❌ Неизвестный проект: <b>${target}</b>. Доступны: $(project_list)"
    return 0
  fi

  if [ "$target" = "$(project_current)" ]; then
    tg_send "$chat_id" "📁 Уже на проекте <b>$(project_name "$target")</b> — переключать нечего."
    return 0
  fi

  label=$(project_name "$target")
  echo "[tg-bridge] Switching project → $target"
  # Сбрасываем авто-резюм: он привязан к прошлому проекту/сессии.
  redis_cmd DEL claude:resume_at claude:resume_cmd >/dev/null 2>&1
  tg_send "$chat_id" "🔄 Переключаю на <b>${label}</b>… Контекст текущей сессии будет потерян."

  # Вывод НЕ гасим: при провале показываем пользователю реальную причину.
  local out
  if out=$("$SCRIPT_DIR/switch-project.sh" "$target" 2>&1); then
    publish_projects   # реестр мог измениться — обновим для меню/валидации
    tg_send "$chat_id" "📁 Проект: <b>${label}</b>
Claude перезапущен, контекст чистый."
  else
    local tail_out
    tail_out=$(printf '%s' "$out" | tail -3 | sed 's/[<>&]//g')
    tg_send "$chat_id" "❌ Не удалось переключиться на <b>${label}</b>:
<code>${tail_out}</code>"
  fi
  return 0
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

  # Переключение проекта — до проверки сессии: оно обязано работать,
  # даже если сессия мертва или Claude завис.
  if handle_switch_project "$chat_id" "$text"; then
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

# Маршрутизация входящих (tier задаёт devbot в payload):
#   now  → инжектим сразу в активную сессию;
#   hold → в очередь проекта tg:hold:<проект> (доставим по простою);
#   prio → в приоритетную очередь проекта tg:hold:prio:<проект>.
# Проект: payload.target_project (кросс-проект) или текущий. У каждого проекта
# СВОЯ очередь — сообщения других проектов ждут переключения на них.
main() {
  echo "[tg-bridge] Started (per-project tier-queue). Polling Redis tg:queue every 2s..."
  echo "[tg-bridge] tmux socket: $TMUX_SOCK | session: $SESSION"
  publish_projects
  local idle_streak=0

  while true; do
    # Проверка лимита сессии Claude на каждой итерации (~каждые 2с).
    check_session_limit
    maybe_resume

    local msg tier target proj
    msg=$(redis_cmd LPOP tg:queue 2>/dev/null || echo "")

    if [ -n "$msg" ] && [ "$msg" != "(nil)" ]; then
      tier=$(echo "$msg" | jq -r '.tier // "now"')
      target=$(echo "$msg" | jq -r '.target_project // ""')

      if [ "$tier" = "now" ]; then
        echo "[tg-bridge] Dequeued (now): ${msg:0:120}"
        inject_message "$msg" || echo "[tg-bridge] ERROR in inject_message"
        idle_streak=0
      else
        # Цель: валидный target_project (кросс-проект) либо текущий проект.
        proj="$target"
        if [ -z "$proj" ] || ! project_dir "$proj" >/dev/null; then proj="$(project_current)"; fi
        if [ "$tier" = "prio" ]; then
          redis_cmd RPUSH "tg:hold:prio:$proj" "$msg" >/dev/null 2>&1
          echo "[tg-bridge] Queued PRIORITY → $proj"
        else
          redis_cmd RPUSH "tg:hold:$proj" "$msg" >/dev/null 2>&1
          echo "[tg-bridge] Queued → $proj"
        fi
      fi

      sleep 1
      continue
    fi

    # Входящих нет. Оцениваем простой и, если стабилен, доставляем ОДНО из очереди
    # ТЕКУЩЕГО проекта (приоритетную — раньше обычной).
    if session_busy; then
      idle_streak=0
    else
      idle_streak=$((idle_streak + 1))
    fi

    if [ "$idle_streak" -ge 2 ] && tmux_cmd has-session -t "$SESSION" 2>/dev/null; then
      local P held
      P="$(project_current)"
      held=$(redis_cmd LPOP "tg:hold:prio:$P" 2>/dev/null)
      if [ -z "$held" ] || [ "$held" = "(nil)" ]; then
        held=$(redis_cmd LPOP "tg:hold:$P" 2>/dev/null)
      fi
      if [ -n "$held" ] && [ "$held" != "(nil)" ]; then
        echo "[tg-bridge] Idle[$P] → flush: ${held:0:120}"
        inject_message "$held" || echo "[tg-bridge] ERROR in inject_message (flush)"
        idle_streak=0
      fi
    fi

    sleep 2
  done
}

main
