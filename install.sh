#!/usr/bin/env bash
# Claude Service — установщик. Запускать ИЗ КОРНЯ целевого проекта:
#   curl -fsSL https://raw.githubusercontent.com/boriscom123/ClaudeService/main/install.sh | bash
# Копирует сервис и скрипты, генерирует конфиг и systemd-юнит, печатает ручные шаги.
set -euo pipefail

REPO="https://github.com/boriscom123/ClaudeService.git"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
COMPOSE_PREFIX="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"

echo "▶ Claude Service → установка в: $PROJECT_DIR"
[ -f "$PROJECT_DIR/docker-compose.yml" ] || echo "  ⚠️ docker-compose.yml не найден в текущей папке — это точно корень проекта?"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "▶ Скачиваю пакет…"
git clone --depth 1 "$REPO" "$TMP/cs" >/dev/null 2>&1
SRC="$TMP/cs"

# 1) Сервис и скрипты
mkdir -p "$PROJECT_DIR/services" "$PROJECT_DIR/scripts"
rm -rf "$PROJECT_DIR/services/devbot"
cp -r "$SRC/devbot" "$PROJECT_DIR/services/devbot"
cp "$SRC/scripts/"*.sh "$PROJECT_DIR/scripts/"
chmod +x "$PROJECT_DIR/scripts/"*.sh
echo "  ✓ services/devbot + scripts/*.sh"

# 2) Значения конфигурации (из .env проекта, если есть)
get_env() { grep -E "^$1=" "$PROJECT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'\r"; }
PG_USER="$(get_env DB_USER)"; PG_USER="${PG_USER:-postgres}"
PG_DB="$(get_env DB_NAME)";   PG_DB="${PG_DB:-postgres}"
TMUX_SOCK="/tmp/tmux-$(id -u)/default"

# 3) claude-service.conf (его читают host-скрипты)
cat > "$PROJECT_DIR/scripts/claude-service.conf" <<CONF
# Claude Service — конфиг целевого проекта (сгенерировано install.sh). ПРОВЕРЬ значения!
PROJECT_DIR="$PROJECT_DIR"
ENV_FILE="\$PROJECT_DIR/.env"
TMUX_SOCK="$TMUX_SOCK"
TMUX_SESSION="claude"
REDIS_CONTAINER="${COMPOSE_PREFIX}-redis-1"
POSTGRES_CONTAINER="${COMPOSE_PREFIX}-postgres-1"
PG_USER="$PG_USER"
PG_DB="$PG_DB"
CONF
echo "  ✓ scripts/claude-service.conf (контейнеры: ${COMPOSE_PREFIX}-redis-1 / -postgres-1)"

# 4) Недостающие переменные → .env
touch "$PROJECT_DIR/.env"
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  key="${line%%=*}"
  if ! grep -qE "^${key}=" "$PROJECT_DIR/.env"; then
    echo "$line" >> "$PROJECT_DIR/.env"; echo "  + .env: $key"
  fi
done < "$SRC/deploy/.env.example"

# 5) systemd-юнит (не устанавливаем — печатаем команду ниже)
sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" -e "s|__USER__|$(id -un)|g" \
  "$SRC/deploy/tg-bridge.service.template" > "$PROJECT_DIR/tg-bridge.service"
echo "  ✓ tg-bridge.service (сгенерирован в корне проекта)"

cp "$SRC/deploy/schema.sql" "$PROJECT_DIR/scripts/claude-service-schema.sql"
cp "$SRC/deploy/docker-compose.snippet.yml" "$SRC/deploy/nginx.snippet.conf" "$PROJECT_DIR/scripts/" 2>/dev/null || true

cat <<STEPS

✅ Файлы установлены. Осталось вручную (требуют sudo / правки конфигов):

1) .env — заполни: DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL
2) docker-compose.yml — добавь сервис devbot (см. scripts/docker-compose.snippet.yml)
3) nginx — добавь location /devbot/webhook (см. scripts/nginx.snippet.conf), затем reload
4) Схема БД:
   docker compose exec -T postgres psql -U $PG_USER -d $PG_DB < scripts/claude-service-schema.sql
5) Собери и подними devbot:
   docker compose up -d --build devbot
6) systemd-мост:
   sudo cp tg-bridge.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tg-bridge
7) Запусти tmux-сессию '$( echo claude )' с Claude CLI на хосте (её слушает мост).
8) Проверь: docker compose logs devbot --tail=5  и  systemctl is-active tg-bridge

⚠️ Проверь scripts/claude-service.conf — имена контейнеров и pg user/db должны
совпадать с твоим docker compose.
STEPS
