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
)

# Человекочитаемые имена — для сообщений в Telegram.
declare -A PROJECT_NAMES=(
  [game]="World Tycoon Idle"
  [cm]="Cross Messenger"
  [uq]="Uzbek Queue"
  [cs]="Claude Service"
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
