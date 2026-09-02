#!/bin/bash
# Аудит обратной связи Telegram по всем проектам реестра.
#
# Зачем нужен: сообщения из Telegram мост доставляет в любую сессию (ищет её по
# имени), а ответ уходит только если в каталоге проекта есть симлинки
# scripts/tg-send.sh / tg-ask.sh И в CLAUDE.md написано, что итог надо слать ими.
# Добавление проекта в реестр этого не создаёт — отсюда «принимает, но молчит».
#
# Что делает: для каждого проекта из projects.sh проверяет каталог, оба симлинка
# и наличие контракта [TG] в CLAUDE.md. Ничего не чинит — только отчёт.
#
# Где используется: руками после добавления проекта и как проверка фикса
# в scripts/switch-project.sh / start-claude.sh (project_ensure_bridge).
#
#   scripts/check-bridge.sh          # все проекты
#   scripts/check-bridge.sh pt       # один проект
# Код возврата: 0 — всё цело, 1 — есть проблемы.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/projects.sh"

fails=0

check_one() {
  local id="$1" dir problems=()
  dir="$(project_dir "$id")" || { echo "✗ $id — нет в реестре"; return 1; }

  [ -d "$dir" ] || { echo "✗ $id ($dir) — каталога нет"; fails=$((fails + 1)); return 1; }

  local s
  for s in tg-send.sh tg-ask.sh; do
    if [ ! -e "$dir/scripts/$s" ]; then
      problems+=("нет scripts/$s")
    elif [ "$(readlink -f "$dir/scripts/$s")" != "$SCRIPT_DIR/$s" ]; then
      problems+=("scripts/$s ведёт не в ClaudeService")
    fi
  done

  if [ ! -f "$dir/CLAUDE.md" ]; then
    problems+=("нет CLAUDE.md")
  elif ! grep -q 'tg-send.sh' "$dir/CLAUDE.md"; then
    problems+=("в CLAUDE.md нет контракта [TG]")
  fi

  if [ ${#problems[@]} -eq 0 ]; then
    echo "✓ $id — $(project_name "$id")"
    return 0
  fi
  echo "✗ $id — $(project_name "$id"): $(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
  fails=$((fails + 1))
  return 1
}

if [ $# -gt 0 ]; then
  check_one "$1"
else
  for id in $(project_list); do check_one "$id"; done
fi

if [ "$fails" -gt 0 ]; then
  echo "— проблемных проектов: $fails (ответы в Telegram оттуда не уйдут)" >&2
  exit 1
fi
echo "— обратная связь цела во всех проектах"
