#!/bin/bash
# Реестр проектов VPS — ЕДИНСТВЕННЫЙ источник правды о том, где что лежит.
# Подключается через source из start-claude.sh, switch-project.sh, watch-triggers.sh.
# Сам ничего не выполняет.
#
# Добавить проект: одна строка в PROJECT_DIRS.

CURRENT_PROJECT_FILE="${CURRENT_PROJECT_FILE:-$HOME/.claude-current-project}"
DEFAULT_PROJECT="game"

declare -A PROJECT_DIRS=(
  [game]="/home/boris/projects/game_world_tycoon_idle"
  [cm]="/home/boris/projects/cross_messenger"
  [uq]="/home/boris/projects/uzbek_queue"
  [cs]="/home/boris/projects/ClaudeService"
  [mp]="/home/boris/projects/myproject"
  [pt]="/home/boris/projects/my_portal"
)

# Человекочитаемые имена — для сообщений в Telegram.
declare -A PROJECT_NAMES=(
  [game]="World Tycoon Idle"
  [cm]="Cross Messenger"
  [uq]="Uzbek Queue"
  [cs]="Claude Service"
  [mp]="MyProject"
  [pt]="Портал уроков"
)

# Путь к проекту. Печатает пусто и возвращает 1, если id неизвестен.
project_dir() {
  local id="${1:-}"
  [ -n "$id" ] && [ -n "${PROJECT_DIRS[$id]:-}" ] || return 1
  printf '%s' "${PROJECT_DIRS[$id]}"
}

project_name() {
  local id="${1:-}"
  printf '%s' "${PROJECT_NAMES[$id]:-$id}"
}

# Список id через пробел. Через printf '%s' нельзя: с несколькими аргументами
# он повторяет формат без разделителя и склеивает id в одно слово.
project_list() {
  printf '%s\n' "${!PROJECT_DIRS[@]}" | sort | tr '\n' ' ' | sed 's/ *$//'
}

# Текущий проект. Если файла нет или в нём мусор — DEFAULT_PROJECT.
project_current() {
  local id=""
  [ -f "$CURRENT_PROJECT_FILE" ] && id=$(tr -d '[:space:]' < "$CURRENT_PROJECT_FILE")
  if [ -z "$id" ] || [ -z "${PROJECT_DIRS[$id]:-}" ]; then
    id="$DEFAULT_PROJECT"
  fi
  printf '%s' "$id"
}

project_set_current() {
  local id="${1:-}"
  project_dir "$id" >/dev/null || return 1
  printf '%s\n' "$id" > "$CURRENT_PROJECT_FILE"
}

# Каталог самих скриптов ClaudeService (файл сорсится, поэтому резолвим свой
# реальный путь, а не путь вызывающего). Нужен для симлинков обратной связи.
CS_SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Блок контракта [TG] для CLAUDE.md проекта. Без него свежая сессия не знает,
# что итог надо отправлять скриптом, — сообщения принимаются, ответов нет.
_tg_contract_block() {
  cat <<'BLOCK'

<!-- claude-service:tg-contract -->
## Обратная связь в Telegram

Сообщения из Telegram приходят с префиксом `[TG]`. Мост только инжектит их в
сессию — ответ с экрана он НЕ читает. Итог пользователю отправляешь ты сам:

```bash
scripts/tg-send.sh "краткий итог 1-2 предложения"
```

- Варианты действий — через `scripts/tg-ask.sh "Вопрос?" "Вариант 1" "Вариант 2"`
  (inline-кнопки + «✍️ Свой вариант»); выбор вернётся как `[Выбор пользователя] …`.
- Долгие задачи не обрезаются — шли итог, когда действительно закончил.
- Можно слать промежуточный статус и финал разными сообщениями.
<!-- /claude-service:tg-contract -->
BLOCK
}

# Идемпотентно чинит обратную связь в каталоге проекта: симлинки на tg-send.sh
# и tg-ask.sh + контракт [TG] в CLAUDE.md.
#
# Зачем: добавление проекта в PROJECT_DIRS само по себе даёт только доставку
# сообщений В сессию. Ответы уходят лишь из проекта, где лежат эти симлинки и
# описан контракт. Раньше это делалось руками по README и забывалось на новых
# проектах (mp, pt) — переключение выглядело как «бот оглох».
#
# Где используется: switch-project.sh и start-claude.sh — перед запуском сессии.
# Проверить состояние всех проектов: scripts/check-bridge.sh
project_ensure_bridge() {
  local id="${1:-}" dir
  dir="$(project_dir "$id")" || return 1
  [ -d "$dir" ] || return 1

  mkdir -p "$dir/scripts" || return 1
  local s
  for s in tg-send.sh tg-ask.sh; do
    if [ "$(readlink -f "$dir/scripts/$s" 2>/dev/null)" != "$CS_SCRIPTS_DIR/$s" ]; then
      ln -sfn "$CS_SCRIPTS_DIR/$s" "$dir/scripts/$s" || return 1
      echo "[bridge] $id: создан симлинк scripts/$s" >&2
    fi
  done

  # CLAUDE.md: дописываем блок, если про tg-send.sh там ничего нет.
  # Проверяем по имени скрипта, а не по маркеру: в game/uq контракт написан
  # вручную и своими словами — переписывать его нечего.
  if ! grep -q 'tg-send.sh' "$dir/CLAUDE.md" 2>/dev/null; then
    _tg_contract_block >> "$dir/CLAUDE.md" || return 1
    echo "[bridge] $id: контракт [TG] дописан в CLAUDE.md" >&2
  fi
  return 0
}
