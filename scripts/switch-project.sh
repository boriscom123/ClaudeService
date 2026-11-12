#!/bin/bash
# Переключить активную модель на другой проект.
#
#   scripts/switch-project.sh <game|cm|...>
#
# Перезапускает только окно текущей модели (контекст этого окна теряется).
# Окно другой модели не закрывается. Замена единственного окна идёт через
# временную сессию внутри ensure-model.sh — иначе tmux-сервер гаснет.
#
# ВАЖНО: не запускать изнутри того окна, которое как раз перезапускается.
# Запускают мост или человек из другого SSH.
#
# Контейнеры проектов НЕ трогаются.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Использование: $(basename "$0") <$(project_list | tr ' ' '|')>" >&2
  echo "Текущий проект: $(project_current), модель: $(model_current)" >&2
  exit 2
fi

TARGET_DIR=$(project_dir "$TARGET") || {
  echo "Неизвестный проект: '$TARGET'. Доступны: $(project_list)" >&2
  exit 2
}

if [ ! -d "$TARGET_DIR" ]; then
  echo "Каталог проекта не найден: $TARGET_DIR" >&2
  exit 1
fi

MODEL="$(model_current)"
PREV="$(project_current)"

echo "[switch] $MODEL → $(project_name "$TARGET") ($TARGET_DIR)"
if ! "$SCRIPT_DIR/ensure-model.sh" "$MODEL" --restart "$TARGET_DIR"; then
  echo "[switch] ОШИБКА: не переключил, остаюсь на $(project_name "$PREV") / $MODEL" >&2
  exit 1
fi

project_set_current "$TARGET"
echo "[switch] Готово: $(model_name "$MODEL"), $(project_name "$TARGET") ($TARGET_DIR)"
