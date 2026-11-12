#!/bin/bash
# Telegram→tmux bridge — ТОЛЬКО ВХОДЯЩИЕ (inbound-only).
# Runs on host as user boris (docker group + tmux socket access).
#
# Архитектура (push):
#   - Берёт сообщения из Redis tg:queue и инжектит в tmux-сессию "agent"
#     (окно main, в нём один процесс выбранной модели).
#   - Ответы НЕ ждёт и НЕ скрапит с экрана.
#   - Итог пользователю агент отправляет сам через scripts/tg-send.sh.
#
# Это убирает таймауты ожидания, дампы транскрипта CLI и парсинг TG_REPLY.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

REDIS_CONTAINER="claudeservice-redis-1"
TMUX_SOCK="/tmp/tmux-1000/default"
SESSION="${CLAUDE_SESSION:-agent}"
# DEVBOT_TOKEN — из systemd EnvironmentFile (.env)

redis_cmd() { docker exec "$REDIS_CONTAINER" redis-cli "$@" 2>/dev/null; }
tmux_cmd()  { tmux -S "$TMUX_SOCK" "$@"; }

# Публикация реестра проектов в Redis (HASH cs:projects id→имя) и текущего
# проекта (cs:current). Отсюда devbot строит меню «Проект», валидирует коды
# кросс-проектной адресации, показывает имена и текущий проект.
# Единый источник правды — projects.sh; добавление проекта не требует пересборки devbot.
publish_projects() {
  local args=() id
  for id in $(project_list); do args+=("$id" "$(project_name "$id")"); done
  redis_cmd DEL cs:projects >/dev/null 2>&1
  [ ${#args[@]} -gt 0 ] && redis_cmd HSET cs:projects "${args[@]}" >/dev/null 2>&1
  # Меню «Модель» строится так же, из реестра, а не из картинки в devbot.
  redis_cmd DEL cs:models >/dev/null 2>&1
  redis_cmd HSET cs:models claude "$(model_name claude)" grok "$(model_name grok)" codex "$(model_name codex)" >/dev/null 2>&1
  LAST_PUBLISH_KEY=""   # форсируем публикацию cs:current / cs:model
  publish_current
}

# cs:current — проект окна активной модели ("" — каталог вне реестра),
# cs:current_dir — сам каталог, cs:model — claude|grok|codex.
# Пишем в Redis только при смене каталога или модели.
LAST_PUBLISH_KEY=""
publish_current() {
  local dir model key
  dir="$(project_session_dir)"
  model="$(model_current)"
  key="${model}|${dir:--}"
  [ "$key" = "$LAST_PUBLISH_KEY" ] && return
  LAST_PUBLISH_KEY="$key"
  redis_cmd SET cs:current "$(project_live)" >/dev/null 2>&1
  redis_cmd SET cs:current_dir "$dir" >/dev/null 2>&1
  redis_cmd SET cs:model "$model" >/dev/null 2>&1
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
  local pane line reset last reset_epoch target
  # Лимит Claude смотрим только когда в единственном окне именно Claude.
  # Панель Grok нельзя сканировать: в переписке та же фраза.
  [ "$(model_current)" = "claude" ] || return 0
  target="$(agent_target)"
  tmux_cmd list-panes -t "$target" >/dev/null 2>&1 || return 0
  pane=$(tmux_cmd capture-pane -p -J -t "$target" -S -40 2>/dev/null || echo "")
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
  local resume_at pane cmd target
  # Команда резюме писалась для Claude. В окно Grok её не вставляем.
  [ "$(model_current)" = "claude" ] || return 0
  target="$(agent_target)"
  resume_at=$(redis_cmd GET claude:resume_at 2>/dev/null)
  if [ -z "$resume_at" ] || [ "$resume_at" = "(nil)" ]; then
    return
  fi
  if [ "$(date +%s)" -lt "$resume_at" ]; then
    return  # время сброса ещё не наступило
  fi
  if ! tmux_cmd list-panes -t "$target" >/dev/null 2>&1; then
    return
  fi
  pane=$(tmux_cmd capture-pane -p -J -t "$target" -S -40 2>/dev/null || echo "")
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
  tmux_cmd paste-buffer -t "$target"
  tmux_cmd send-keys -t "$target" Enter
  redis_cmd DEL claude:resume_at >/dev/null 2>&1
  [ -n "${TELEGRAM_ADMIN_CHAT_ID:-}" ] && tg_send "$TELEGRAM_ADMIN_CHAT_ID" \
    "▶️ Лимит сброшен — автоматически возобновил работу."
}

# Занята ли активная модель. Claude — footer «esc to interrupt».
# Grok footer другой: на время хода он держит дочерний systemd-inhibit
# с причиной «agent turn in progress». Нет маркера → простой.
session_busy() {
  local model pane target gpid
  model="$(model_current)"
  if [ "$model" = "grok" ]; then
    gpid="$(pane_proc_pid "$(agent_target grok)" grok 2>/dev/null || true)"
    [ -n "$gpid" ] || return 1
    ps -o args= --ppid "$gpid" 2>/dev/null | grep -q "agent turn in progress"
    return
  fi
  if [ "$model" = "codex" ]; then
    target="$(agent_target codex)"
    pane=$(tmux_cmd capture-pane -p -J -t "$target" -S -8 2>/dev/null || echo "")
    echo "$pane" | tail -8 | grep -qiE "working|thinking|esc to interrupt"
    return
  fi
  target="$(agent_target claude)"
  pane=$(tmux_cmd capture-pane -p -t "$target" 2>/dev/null || echo "")
  echo "$pane" | grep -qiF "esc to interrupt"
}

# Переключение проекта выполняет МОСТ, а не агент в окне: --restart единственного
# окна убивает процесс, который вызвал бы скрипт сам. Возвращает 0, если
# сообщение обработано здесь и инжектить его не нужно.
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

  # Сравниваем с реальным каталогом сессии, а не с файлом current-project:
  # из неподключённого каталога (skat и т.п.) переключение на любой проект
  # реестра должно работать. Мёртвую сессию тоже поднимаем заново.
  if [ "$target" = "$(project_live)" ] && agent_proc_running "$(model_current)"; then
    tg_send "$chat_id" "📁 Уже на проекте <b>$(project_name "$target")</b> — переключать нечего."
    return 0
  fi

  label=$(project_name "$target")
  echo "[tg-bridge] Switching project → $target"
  # Сбрасываем авто-резюм: он привязан к прошлому проекту/сессии.
  redis_cmd DEL claude:resume_at claude:resume_cmd >/dev/null 2>&1
  tg_send "$chat_id" "🔄 Переключаю на <b>${label}</b>…
Модель <b>$(model_name "$(model_current)")</b> та же. Контекст чата будет потерян."

  # Вывод НЕ гасим: при провале показываем пользователю реальную причину.
  local out
  if out=$("$SCRIPT_DIR/switch-project.sh" "$target" 2>&1); then
    publish_projects   # реестр мог измениться — обновим для меню/валидации
    tg_send "$chat_id" "📁 Проект: <b>${label}</b>
$(model_name "$(model_current)") перезапущен в этом каталоге. Модель не менялась."
  else
    local tail_out
    tail_out=$(printf '%s' "$out" | tail -3 | sed 's/[<>&]//g')
    tg_send "$chat_id" "❌ Не удалось переключиться на <b>${label}</b>:
<code>${tail_out}</code>"
  fi
  return 0
}

# Смена модели заменяет процесс в том же каталоге. Контекст чата теряется.
# Файл модели пишем только после успеха, иначе сообщения уедут не туда.
handle_switch_model() {
  local chat_id="$1" text="$2"
  local target label out dir live

  case "$text" in
    "[Переключить модель]"*) ;;
    *) return 1 ;;
  esac

  target=$(printf '%s' "$text" | sed -E 's/^\[Переключить модель\][[:space:]]*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

  if [ -z "${MODEL_NAMES[$target]:-}" ]; then
    tg_send "$chat_id" "❌ Неизвестная модель: <b>${target}</b>. Доступны: $(model_list)"
    return 0
  fi

  label=$(model_name "$target")
  if [ "$target" = "$(model_current)" ] && agent_proc_running "$target"; then
    tg_send "$chat_id" "🧠 Уже на <b>${label}</b> — сообщения из бота идут в эту сессию."
    return 0
  fi

  # Проект не меняется: новый процесс встаёт в каталог текущей сессии.
  dir="$(project_session_dir)"
  if [ -z "$dir" ]; then
    dir="$(project_dir "$(project_current)" 2>/dev/null || true)"
  fi
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    tg_send "$chat_id" "❌ Не вижу каталог текущей сессии — модель не меняю."
    return 0
  fi

  echo "[tg-bridge] Switching model → $target (dir $dir)"
  tg_send "$chat_id" "🔄 Переключаю модель на <b>${label}</b>…
Проект тот же. Контекст текущего чата будет потерян."

  if out=$("$SCRIPT_DIR/ensure-model.sh" "$target" --restart "$dir" 2>&1); then
    model_set "$target"
    live=$(project_by_dir "$dir" 2>/dev/null || true)
    [ -n "$live" ] && project_set_current "$live"
    LAST_PUBLISH_KEY=""
    publish_current
    tg_send "$chat_id" "🧠 Модель: <b>${label}</b>
📁 Проект: <b>$(project_name "$(project_live)")</b>
Контекст предыдущей модели не сохранён."
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
  if handle_switch_model "$chat_id" "$text"; then
    return
  fi

  local model target_pane
  model="$(model_current)"
  target_pane="$(agent_target "$model")"
  if ! agent_proc_running "$model"; then
    tg_send "$chat_id" "❌ <b>$(model_name "$model")</b> не запущен. Откройте меню «🧠 Модель» и выберите её ещё раз — подниму окно."
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

  # Сообщение пользователя — в историю проекта. Пишем текст как он есть,
  # без служебного префикса [TG]: в файле истории он только мешает.
  "$SCRIPT_DIR/history-log.sh" in "${text:-$inject_text}" 2>/dev/null || true

  echo "[tg-bridge] Injecting into ${target_pane}: ${inject_text:0:100}..."

  # Безопасная инъекция: load-buffer корректно обрабатывает кавычки, $, backtick.
  # Цель — окно модели, а не «текущее видимое» окно сессии.
  printf '%s' "$inject_text" | tmux_cmd load-buffer -
  tmux_cmd paste-buffer -t "$target_pane"
  sleep 0.3
  tmux_cmd send-keys -t "$target_pane" Enter
}

# Маршрутизация входящих (tier задаёт devbot в payload):
#   now  → инжектим сразу в активную сессию;
#   hold → в очередь проекта tg:hold:<проект> (доставим по простою);
#   prio → в приоритетную очередь проекта tg:hold:prio:<проект>.
# Проект: payload.target_project (кросс-проект) или текущий. У каждого проекта
# СВОЯ очередь — сообщения других проектов ждут переключения на них.

# Пустой файл модели: один раз смотрим, кто на переднем плане сессии.
# Сейчас это Grok в окне grok — так сообщения пойдут сюда без ручного клика.
seed_model_file() {
  [ -s "$CURRENT_MODEL_FILE" ] && return 0
  # Окно grok может быть внуком bash: смотрим дерево процессов, не только
  # pane_current_command. Иначе файл останется пустым и мост решит, что модель Claude.
  if pane_proc_pid "$(agent_target)" codex >/dev/null 2>&1; then
    printf 'codex\n' > "$CURRENT_MODEL_FILE"
    echo "[tg-bridge] model file seeded: Codex is running"
    return 0
  fi
  if pane_proc_pid "$(agent_target)" grok >/dev/null 2>&1; then
    printf 'grok\n' > "$CURRENT_MODEL_FILE"
    echo "[tg-bridge] model file seeded: Grok is running"
    return 0
  fi
  if pane_proc_pid "$(agent_target)" claude >/dev/null 2>&1; then
    printf 'claude\n' > "$CURRENT_MODEL_FILE"
    echo "[tg-bridge] model file seeded: claude is running"
    return 0
  fi
}

main() {
  echo "[tg-bridge] Started (per-project tier-queue, model-aware). Polling Redis tg:queue every 2s..."
  echo "[tg-bridge] tmux socket: $TMUX_SOCK | session: $SESSION"
  seed_model_file
  echo "[tg-bridge] model: $(model_current) target: $(agent_target 2>/dev/null || echo '?')"
  publish_projects
  local idle_streak=0

  while true; do
    # Проверка лимита сессии Claude на каждой итерации (~каждые 2с).
    check_session_limit
    maybe_resume
    publish_current

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
        if [ -z "$proj" ] || ! project_dir "$proj" >/dev/null; then proj="$(project_live)"; fi
        [ -n "$proj" ] || proj="$(project_current)"
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

    # Очередь не снимаем, пока процесс модели не поднят: иначе сообщение
    # пропадёт из Redis и пользователь получит только «не запущен».
    if [ "$idle_streak" -ge 2 ] && agent_proc_running "$(model_current)"; then
      local P held
      # Очередь проекта доставляем только в сессию, которая реально в нём:
      # в чужом каталоге (skat) задачи проекта выполнились бы не там.
      P="$(project_live)"
      held=""
      [ -n "$P" ] && held=$(redis_cmd LPOP "tg:hold:prio:$P" 2>/dev/null)
      if [ -n "$P" ] && { [ -z "$held" ] || [ "$held" = "(nil)" ]; }; then
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
