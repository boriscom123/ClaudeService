#!/bin/bash
# Переключить Claude-сессию на другой проект.
#
#   scripts/switch-project.sh <game|cm>
#
# Убивает tmux-сессию и поднимает новую ПОД ТЕМ ЖЕ ИМЕНЕМ в каталоге проекта —
# поэтому мост (watch-triggers.sh) ничего не замечает: он ищет сессию по имени.
#
# ВАЖНО: не запускать изнутри самой сессии Claude — скрипт убьёт себя вместе
# с ней и не успеет поднять новую. Запускают: мост или человек из SSH.
#
# Контейнеры проектов НЕ трогаются: переключается только рабочий каталог.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

CLAUDE_BIN="/home/boris/.local/bin/claude"
SESSION="${CLAUDE_SESSION:-claude}"
TMUX_SOCKET="/tmp/tmux-1000/default"
TMUX_CMD="tmux -S $TMUX_SOCKET"

# Есть ли в дереве процессов tmux-сессии реально запущенный процесс `claude`.
# Проверяем факт запуска процесса (а не UI в панели) — надёжнее и без ложных срабатываний.
session_has_claude() {
  local pane_pid
  pane_pid=$($TMUX_CMD list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1) || return 1
  [ -n "$pane_pid" ] || return 1
  local pids="$pane_pid" depth=0
  while [ -n "${pids// }" ] && [ "$depth" -lt 6 ]; do
    local next=""
    for p in $pids; do
      if ps -o comm= -p "$p" 2>/dev/null | grep -qx claude; then return 0; fi
      next="$next $(pgrep -P "$p" 2>/dev/null || true)"
    done
    pids="$next"; depth=$((depth + 1))
  done
  return 1
}

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Использование: $(basename "$0") <$(project_list | tr ' ' '|')>" >&2
  echo "Текущий проект: $(project_current)" >&2
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

mkdir -p "$(dirname "$TMUX_SOCKET")"
chmod 700 "$(dirname "$TMUX_SOCKET")"

# Запоминаем прежний проект для отката: current-project пишем ТОЛЬКО после
# успешной верификации запуска — иначе рассинхрон (файл на новый, сессия на старый).
PREV="$(project_current)"

if $TMUX_CMD has-session -t "$SESSION" 2>/dev/null; then
  echo "[switch] Гашу сессию '$SESSION'…"
  $TMUX_CMD kill-session -t "$SESSION"
fi

echo "[switch] Поднимаю '$SESSION' в $TARGET_DIR…"
$TMUX_CMD new-session -d -s "$SESSION" -c "$TARGET_DIR"
$TMUX_CMD send-keys -t "$SESSION" "$CLAUDE_BIN" Enter

# Верификация: ждём (до ~10с), что сессия существует И процесс claude реально поднялся.
ok=1
for _ in $(seq 1 20); do
  if $TMUX_CMD has-session -t "$SESSION" 2>/dev/null && session_has_claude; then ok=0; break; fi
  sleep 0.5
done

if [ "$ok" -ne 0 ]; then
  echo "[switch] ОШИБКА: сессия/процесс claude не поднялись в $TARGET_DIR" >&2
  # Откат: если сессия всё же жива, вернём указатель на прежний проект.
  project_set_current "$PREV" 2>/dev/null || true
  exit 1
fi

project_set_current "$TARGET"
echo "[switch] Готово: $(project_name "$TARGET") ($TARGET_DIR)"
