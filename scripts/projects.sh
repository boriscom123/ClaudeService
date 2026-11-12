#!/bin/bash
# Реестр проектов VPS — ЕДИНСТВЕННЫЙ источник правды о том, где что лежит.
# Подключается через source из start-claude.sh, switch-project.sh, watch-triggers.sh.
# Сам ничего не выполняет.
#
# Добавить проект: строка в PROJECT_DIRS и доверенный/записываемый путь в ~/.codex/config.toml.

CURRENT_PROJECT_FILE="${CURRENT_PROJECT_FILE:-$HOME/.claude-current-project}"
# Выбранная модель моста. Пишет мост при переключении; читают инжект и автостарт.
CURRENT_MODEL_FILE="${CURRENT_MODEL_FILE:-$HOME/.cs-current-model}"
DEFAULT_PROJECT="game"
DEFAULT_MODEL="claude"

declare -A PROJECT_DIRS=(
  [game]="/home/boris/projects/game_world_tycoon_idle"
  [cm]="/home/boris/projects/cross_messenger"
  [uq]="/home/boris/projects/uzbek_queue"
  [cs]="/home/boris/projects/ClaudeService"
  [mp]="/home/boris/projects/myproject"
  [pt]="/home/boris/projects/my_portal"
  [sk]="/home/boris/projects/skat"
  [sbd]="/home/boris/projects/skat_bd"
  [s21]="/home/boris/projects/21"
)

# Одна tmux-сессия agent, одно окно main. В нём работает выбранный CLI-агент.
# Смена модели заменяет процесс в том же каталоге, смена проекта — тот же
# процесс в другом каталоге. Контекст предыдущего процесса при замене теряется.
declare -A MODEL_NAMES=(
  [claude]="Claude"
  [grok]="Grok"
  [codex]="ChatGPT (Codex)"
)
AGENT_WINDOW="${AGENT_WINDOW:-main}"

# Человекочитаемые имена — для сообщений в Telegram.
declare -A PROJECT_NAMES=(
  [game]="World Tycoon Idle"
  [cm]="Cross Messenger"
  [uq]="Uzbek Queue"
  [cs]="Claude Service"
  [mp]="MyProject"
  [pt]="Портал уроков"
  [sk]="СКАТ"
  [sbd]="СКАТ БД"
  [s21]="School 21"
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

# id проекта, в каталоге (или подкаталоге) которого лежит путь DIR.
# Печатает пусто и возвращает 1, если путь вне подключённых проектов
# (например, сессию увели руками в ~/projects/skat).
# Где используется: watch-triggers.sh — определение реального проекта сессии.
project_by_dir() {
  local path="${1:-}" id dir
  [ -n "$path" ] || return 1
  path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  for id in "${!PROJECT_DIRS[@]}"; do
    dir="${PROJECT_DIRS[$id]}"
    if [ "$path" = "$dir" ] || [ "${path#"$dir"/}" != "$path" ]; then
      printf '%s' "$id"; return 0
    fi
  done
  return 1
}

# Реальный каталог окна АКТИВНОЙ модели (cwd панели). Пусто, если окна нет.
# Раньше брался текущий видимый pane сессии: при двух окнах это не та модель,
# куда мост кладёт сообщения.
project_session_dir() {
  local sock dir target
  sock="$(_tmux_sock)"
  target="$(agent_target 2>/dev/null || true)"
  if [ -n "$target" ]; then
    dir=$(tmux -S "$sock" display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$dir" ]; then
      printf '%s' "$dir"
      return 0
    fi
  fi
  tmux -S "$sock" display-message -p \
    -t "${CLAUDE_SESSION:-agent}" '#{pane_current_path}' 2>/dev/null || true
}

# Проект, в котором РЕАЛЬНО работает сессия. Файл current-project для этого
# не годится: сессию могут увести в неподключённый каталог (cd ~/projects/skat),
# а файл так и останется на последнем подключённом проекте — кнопка этого
# проекта отвечала «Уже на проекте», хотя переключиться было нужно.
# Печатает id или пусто (сессия вне проектов). Без сессии — id из файла.
# Где используется: watch-triggers.sh (переключение, очереди), history-log.sh.
project_live() {
  local dir
  dir="$(project_session_dir)"
  if [ -z "$dir" ]; then project_current; return; fi
  project_by_dir "$dir" || true
}

project_set_current() {
  local id="${1:-}"
  project_dir "$id" >/dev/null || return 1
  printf '%s\n' "$id" > "$CURRENT_PROJECT_FILE"
}

# --- Модели (Claude / Grok / ChatGPT Codex) --------------------------------
# Оба агента по очереди занимают одно окно ${CLAUDE_SESSION:-agent}:${AGENT_WINDOW:-main}.
# Мост вставляет текст туда. В сессии нет второго окна с другой моделью.

_tmux_sock() {
  printf '%s' "${TMUX_SOCK:-${TMUX_SOCKET:-/tmp/tmux-1000/default}}"
}

model_name() {
  local id="${1:-}"
  printf '%s' "${MODEL_NAMES[$id]:-$id}"
}

model_list() {
  printf '%s\n' "${!MODEL_NAMES[@]}" | sort | tr '\n' ' ' | sed 's/ *$//'
}

# Единственное окно сессии. Аргумент модели игнорируется: окно не зависит от неё.
model_window() {
  [ -n "${1:-}" ] && [ -z "${MODEL_NAMES[$1]:-}" ] && return 1
  printf '%s' "${AGENT_WINDOW:-main}"
}

# comm процесса. Совпадает с id модели (claude / grok / codex).
model_proc() {
  case "${1:-}" in
    claude|grok|codex) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# Бинарник. Пути как в start-claude.sh: systemd не всегда имеет ~/.local/bin в PATH.
model_bin() {
  case "${1:-}" in
    claude) printf '%s' "${CLAUDE_BIN:-/home/boris/.local/bin/claude}" ;;
    grok) printf '%s' "${GROK_BIN:-/home/boris/.local/bin/grok}" ;;
    codex) printf '%s' "${CODEX_BIN:-/home/boris/.local/bin/codex}" ;;
    *) return 1 ;;
  esac
}

# Команда, которую tmux вводит в окно.
# Grok в каталоге из реестра — с --trust-folder: флаг сам пишет доверие и не
# показывает вопрос. В документации тот же флаг называется --trust.
# Чужой каталог запускается без флага: доверяем только свой реестр.
# Где: ensure-model.sh, start-claude.sh.
model_launch_cmd() {
  local id="${1:-}" dir="${2:-}" bin
  bin="$(model_bin "$id")" || return 1
  if [ "$id" = "codex" ]; then
    printf '%s --no-alt-screen' "$bin"
    return 0
  fi
  if [ "$id" = "grok" ] && [ -n "$dir" ] && project_by_dir "$dir" >/dev/null 2>&1; then
    printf '%s --trust-folder' "$bin"
    return 0
  fi
  printf '%s' "$bin"
}

# Каталог из реестра, канонический путь. Пусто и код 1, если это не наш проект.
_trust_registry_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  dir="$(readlink -f "$dir")"
  project_by_dir "$dir" >/dev/null || return 1
  printf '%s' "$dir"
}

# Поставить Claude hasTrustDialogAccepted для каталога из реестра.
# Диалог «доверяете проекту?» виден только в терминале — из Telegram на него
# не ответить, сессия так и висит. Чужой каталог не трогаем.
# Писать непосредственно перед запуском и ещё раз после смерти старого
# процесса: тот при выходе переписывает ~/.claude.json из своей памяти.
# Где: ensure-model.sh, start-claude.sh.
trust_claude_dir() {
  local dir
  dir="$(_trust_registry_dir "${1:-}")" || {
    echo "[trust] отказ: Claude не отмечаю «${1:-}» — каталог не из реестра" >&2
    return 1
  }
  local result
  result="$(CLAUDE_CONFIG_FILE="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}" python3 - "$dir" << 'PY'
import json, os, sys, tempfile
path = os.environ["CLAUDE_CONFIG_FILE"]
directory = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
projects = data.get("projects")
if not isinstance(projects, dict):
    projects = {}
    data["projects"] = projects
entry = projects.get(directory)
if not isinstance(entry, dict):
    entry = {}
    projects[directory] = entry
if entry.get("hasTrustDialogAccepted") is True:
    print("unchanged")
    sys.exit(0)
entry["hasTrustDialogAccepted"] = True
parent = os.path.dirname(path) or "."
os.makedirs(parent, exist_ok=True)
mode = 0o600
if os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=parent, prefix=".claude.json.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("updated")
PY
)" || return 1
  if [ "$result" = "updated" ]; then
    echo "[trust] Claude: доверие записано для $dir" >&2
  fi
}

# Записать каталог из реестра в ~/.grok/trusted_folders.toml.
# Вместе с --trust-folder при запуске: вопрос в терминале не появляется,
# а решение остаётся после выхода старого процесса, который может
# переписать файл из своей памяти.
# Где: ensure-model.sh, start-claude.sh.
trust_grok_dir() {
  local dir
  dir="$(_trust_registry_dir "${1:-}")" || {
    echo "[trust] отказ: Grok не отмечаю «${1:-}» — каталог не из реестра" >&2
    return 1
  }
  local result
  result="$(GROK_TRUST_FILE="${GROK_TRUST_FILE:-$HOME/.grok/trusted_folders.toml}" python3 - "$dir" << 'PY'
import os, re, sys, tempfile, time
path = os.environ["GROK_TRUST_FILE"]
directory = sys.argv[1]
text = ""
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
header = '[folders."' + directory + '"]'
pattern = re.compile(
    r'(?ms)^\[folders\."' + re.escape(directory) + r'"\]\s*$.*?(?=^\[|\Z)'
)
match = pattern.search(text)
if match and re.search(r'(?m)^trusted\s*=\s*true\s*$', match.group(0)):
    print("unchanged")
    sys.exit(0)
block = header + "\ntrusted = true\ndecided_at = " + str(int(time.time())) + "\n"
if match:
    text = text[:match.start()] + block + text[match.end():]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += block
parent = os.path.dirname(path) or "."
os.makedirs(parent, exist_ok=True)
mode = 0o600
if os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=parent, prefix=".trusted_folders.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("updated")
PY
)" || return 1
  if [ "$result" = "updated" ]; then
    echo "[trust] Grok: доверие записано для $dir" >&2
  fi
}

# id из файла. Мусор и пустой файл → DEFAULT_MODEL (claude).
# Автоопределение по переднему плану делает мост один раз при старте и записывает файл.
model_current() {
  local id=""
  if [ -f "$CURRENT_MODEL_FILE" ]; then
    id=$(tr -d '[:space:]' < "$CURRENT_MODEL_FILE")
  fi
  if [ -z "$id" ] || [ -z "${MODEL_NAMES[$id]:-}" ]; then
    id="$DEFAULT_MODEL"
  fi
  printf '%s' "$id"
}

model_set() {
  local id="${1:-}"
  [ -n "${MODEL_NAMES[$id]:-}" ] || return 1
  printf '%s\n' "$id" > "$CURRENT_MODEL_FILE"
}

# tmux-target единственного окна: «сессия:окно». Аргумент модели не меняет цель.
agent_target() {
  printf '%s:%s' "${CLAUDE_SESSION:-agent}" "${AGENT_WINDOW:-main}"
}

# pid процесса с comm=$2 в дереве pane target ($1). Пусто и код 1, если нет.
# Grok часто внук bash, поэтому pane_current_command недостаточен — обходим дерево.
# Где используется: мост (куда инжектить, занят ли ход) и ensure-model.sh.
pane_proc_pid() {
  local target="${1:-}" want="${2:-}" sock pane_pid
  [ -n "$target" ] && [ -n "$want" ] || return 1
  sock="$(_tmux_sock)"
  pane_pid=$(tmux -S "$sock" list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -1) || return 1
  [ -n "$pane_pid" ] || return 1
  local pids="$pane_pid" depth=0 p next comm
  while [ -n "${pids// }" ] && [ "$depth" -lt 8 ]; do
    next=""
    for p in $pids; do
      comm=$(ps -o comm= -p "$p" 2>/dev/null | tr -d '[:space:]' || true)
      if [ "$comm" = "$want" ]; then
        printf '%s' "$p"
        return 0
      fi
      next="$next $(pgrep -P "$p" 2>/dev/null || true)"
    done
    pids="$next"
    depth=$((depth + 1))
  done
  return 1
}

# 0, если в единственном окне уже есть процесс этой модели.
agent_proc_running() {
  local id="${1:-}" proc
  proc="$(model_proc "$id")" || return 1
  pane_proc_pid "$(agent_target)" "$proc" >/dev/null
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

- **Сразу после получения задачи**, до любых других действий, шли короткое
  уведомление о старте: `scripts/tg-send.sh "🛠 Взял в работу: <суть задачи>"` —
  иначе непонятно, пошла задача в работу или нет.
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
