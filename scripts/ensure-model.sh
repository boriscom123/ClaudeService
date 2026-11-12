#!/bin/bash
# Запустить модель в единственном окне tmux-сессии agent либо заменить процесс.
#
#   scripts/ensure-model.sh <claude|grok> [--restart] [каталог]
#
# Без --restart: если в окне уже эта модель — ничего не убивать.
# Если там другая модель — отказ (её заменяет только --restart).
# Сессии нет — создать окно main и запустить бинарник в каталоге.
#
# --restart: заменить процесс в каталоге. Контекст текущего чата теряется.
# Каталог задаёт вызывающий: смена модели передаёт текущий каталог (проект
# тот же), смена проекта — новый каталог и ту же модель.
# Замена идёт через временную сессию: окно одно, убийство последней сессии
# гасит tmux-сервер, поэтому сначала поднимаем новую и только потом гасим старую.
#
# Не запускать --restart изнутри того же окна: скрипт убьёт вызывающий процесс.
# Мост зовёт его со стороны.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/projects.sh"

SESSION="${CLAUDE_SESSION:-agent}"
WIN="${AGENT_WINDOW:-main}"
TMUX_SOCK="/tmp/tmux-1000/default"
TMUX_SOCKET="$TMUX_SOCK"
TMUX_CMD="tmux -S $TMUX_SOCK"

MODEL="${1:-}"
shift || true
RESTART=0
if [ "${1:-}" = "--restart" ]; then
  RESTART=1
  shift || true
fi
DIR="${1:-}"

if [ -z "$MODEL" ] || [ -z "${MODEL_NAMES[$MODEL]:-}" ]; then
  echo "Использование: $(basename "$0") <$(model_list | tr ' ' '|')> [--restart] [каталог]" >&2
  exit 2
fi

if [ -z "$DIR" ]; then
  DIR="$(project_dir "$(project_current)")" || {
    echo "Не задан каталог и нет текущего проекта" >&2
    exit 1
  }
fi
if [ ! -d "$DIR" ]; then
  echo "Каталог не найден: $DIR" >&2
  exit 1
fi
DIR="$(readlink -f "$DIR")"

BIN="$(model_bin "$MODEL")"
LAUNCH="$(model_launch_cmd "$MODEL" "$DIR")"
PROC="$(model_proc "$MODEL")"
TARGET="${SESSION}:${WIN}"

if [ ! -x "$BIN" ]; then
  echo "Бинарник не найден: $BIN" >&2
  exit 1
fi

mkdir -p "$(dirname "$TMUX_SOCK")"
chmod 700 "$(dirname "$TMUX_SOCK")"

proj_id="$(project_by_dir "$DIR" 2>/dev/null || true)"
if [ -n "$proj_id" ]; then
  project_ensure_bridge "$proj_id" || echo "[model] ВНИМАНИЕ: обратная связь в $DIR не настроена" >&2
fi

wait_proc() {
  local target="$1" i
  for i in $(seq 1 20); do
    if pane_proc_pid "$target" "$PROC" >/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Старый Claude при выходе переписывает ~/.claude.json и может стереть флаг
# доверия. Пока он остановлен, обработчик выхода не выполняется.
OLD_CLAUDE=""

freeze_old_claude() {
  [ "$MODEL" = "claude" ] || return 0
  OLD_CLAUDE="$(pane_proc_pid "$TARGET" claude 2>/dev/null || true)"
  [ -n "$OLD_CLAUDE" ] || return 0
  if ! kill -STOP "$OLD_CLAUDE" 2>/dev/null; then
    OLD_CLAUDE=""
  fi
}

thaw_old_claude() {
  [ -n "$OLD_CLAUDE" ] || return 0
  kill -CONT "$OLD_CLAUDE" 2>/dev/null || true
  OLD_CLAUDE=""
}

bury_old_claude() {
  [ -n "$OLD_CLAUDE" ] || return 0
  kill -KILL "$OLD_CLAUDE" 2>/dev/null || true
  OLD_CLAUDE=""
}

# Доверие — в последнюю секунду перед стартом и ещё раз после смерти старого
# процесса. Только каталог из реестра; чужой путь функции сами отклоняют.
prepare_trust() {
  case "$MODEL" in
    claude)
      trust_claude_dir "$DIR" || echo "[model] ВНИМАНИЕ: доверие Claude для $DIR не записано" >&2
      ;;
    grok)
      trust_grok_dir "$DIR" || echo "[model] ВНИМАНИЕ: доверие Grok для $DIR не записано" >&2
      ;;
  esac
}

start_keys() {
  local target="$1"
  prepare_trust
  $TMUX_CMD send-keys -t "$target" "$LAUNCH" Enter
}

# Уже нужная модель и замена не просилась — процесс не трогаем.
if [ "$RESTART" -eq 0 ] && pane_proc_pid "$TARGET" "$PROC" >/dev/null 2>&1; then
  echo "[model] $MODEL уже запущен ($TARGET), контекст сохранён"
  exit 0
fi

# В окне сидит другая модель. Без --restart её не гасим.
if [ "$RESTART" -eq 0 ] && $TMUX_CMD has-session -t "=$SESSION" 2>/dev/null; then
  echo "[model] ОШИБКА: в $TARGET другой процесс. Замена только с --restart" >&2
  exit 1
fi

# Сессии ещё нет — первое окно.
if ! $TMUX_CMD has-session -t "=$SESSION" 2>/dev/null; then
  echo "[model] Создаю сессию '$SESSION', окно '$WIN' в $DIR"
  $TMUX_CMD new-session -d -s "$SESSION" -n "$WIN" -c "$DIR" || exit 1
  start_keys "$TARGET"
  if ! wait_proc "$TARGET"; then
    echo "[model] ОШИБКА: процесс $PROC не поднялся" >&2
    $TMUX_CMD kill-session -t "=$SESSION" 2>/dev/null || true
    exit 1
  fi
  echo "[model] Готово: $MODEL в $DIR"
  exit 0
fi

# Замена единственного окна. Старую сессию гасим только после проверки новой.
NEW="${SESSION}-switch-$$"
echo "[model] Заменяю процесс на $MODEL в $DIR (контекст текущего чата теряется)"
freeze_old_claude
if ! $TMUX_CMD new-session -d -s "$NEW" -n "$WIN" -c "$DIR"; then
  echo "[model] ОШИБКА: tmux не создал сессию" >&2
  thaw_old_claude
  exit 1
fi
start_keys "${NEW}:${WIN}"
if ! wait_proc "${NEW}:${WIN}"; then
  echo "[model] ОШИБКА: процесс $PROC не поднялся — старую сессию не трогаю" >&2
  $TMUX_CMD kill-session -t "=$NEW" 2>/dev/null || true
  thaw_old_claude
  exit 1
fi
bury_old_claude
$TMUX_CMD set-option -t "=$SESSION:" detach-on-destroy off 2>/dev/null || true
$TMUX_CMD kill-session -t "=$SESSION"
prepare_trust
$TMUX_CMD rename-session -t "=$NEW" "$SESSION"
echo "[model] Готово: $MODEL в $DIR"
exit 0
