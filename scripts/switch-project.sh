#!/bin/bash
# Переключить Claude-сессию на другой проект.
#
#   scripts/switch-project.sh <game|cm>
#
# Поднимает новую tmux-сессию в каталоге проекта, гасит старую и переименовывает
# новую в прежнее имя — поэтому мост (watch-triggers.sh) ничего не замечает:
# он ищет сессию по имени.
#
# Порядок «сначала новая, потом kill» обязателен: если убить ПОСЛЕДНЮЮ сессию,
# tmux-сервер завершается (exit-empty), и new-session, успевший подключиться
# к умирающему серверу, падает с «server exited unexpectedly» — сессий не
# остаётся вовсе. Заодно при сбое запуска старая сессия остаётся жива.
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

# Есть ли в дереве процессов tmux-сессии $1 реально запущенный процесс `claude`.
# Проверяем факт запуска процесса (а не UI в панели) — надёжнее и без ложных срабатываний.
# Где используется: верификация новой сессии ниже.
session_has_claude() {
  local sess="$1" pane_pid
  pane_pid=$($TMUX_CMD list-panes -t "=$sess:" -F '#{pane_pid}' 2>/dev/null | head -1) || return 1
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

# Обратная связь в целевом проекте: симлинки tg-send.sh/tg-ask.sh и контракт
# [TG] в CLAUDE.md. Без этого новая сессия принимает сообщения, но ответить
# ей нечем — снаружи это выглядит как «бот замолчал после переключения».
if ! project_ensure_bridge "$TARGET"; then
  echo "[switch] ВНИМАНИЕ: не удалось настроить обратную связь в $TARGET_DIR" >&2
fi

# Запоминаем прежний проект для отката: current-project пишем ТОЛЬКО после
# успешной верификации запуска — иначе рассинхрон (файл на новый, сессия на старый).
PREV="$(project_current)"

# Новая сессия под временным именем; старая пока жива, сервер не пустеет.
NEW_SESSION="${SESSION}-switch-$$"
echo "[switch] Поднимаю '$NEW_SESSION' в $TARGET_DIR…"
if ! $TMUX_CMD new-session -d -s "$NEW_SESSION" -c "$TARGET_DIR"; then
  echo "[switch] ОШИБКА: tmux не создал сессию в $TARGET_DIR" >&2
  exit 1
fi
$TMUX_CMD send-keys -t "=$NEW_SESSION:" "$CLAUDE_BIN" Enter

# Верификация: ждём (до ~10с), что процесс claude реально поднялся.
ok=1
for _ in $(seq 1 20); do
  if session_has_claude "$NEW_SESSION"; then ok=0; break; fi
  sleep 0.5
done

if [ "$ok" -ne 0 ]; then
  echo "[switch] ОШИБКА: процесс claude не поднялся в $TARGET_DIR — остаюсь на $(project_name "$PREV")" >&2
  $TMUX_CMD kill-session -t "=$NEW_SESSION" 2>/dev/null || true
  exit 1
fi

if $TMUX_CMD has-session -t "=$SESSION" 2>/dev/null; then
  echo "[switch] Гашу сессию '$SESSION'…"
  # Подключённый клиент (SSH) не выкидывается, а переезжает в новую сессию.
  $TMUX_CMD set-option -t "=$SESSION:" detach-on-destroy off 2>/dev/null || true
  $TMUX_CMD kill-session -t "=$SESSION"
fi
$TMUX_CMD rename-session -t "=$NEW_SESSION" "$SESSION"

project_set_current "$TARGET"
echo "[switch] Готово: $(project_name "$TARGET") ($TARGET_DIR)"
