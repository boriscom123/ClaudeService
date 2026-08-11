#!/usr/bin/env bash
# Claude Service — установщик центрального сервиса. Запускать ИЗ КОРНЯ ClaudeService:
#   bash install.sh
# Создаёт docker-сеть, поднимает redis+devbot, печатает ручные шаги (nginx, systemd, tmux).
set -euo pipefail

CS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CS_DIR"

echo "▶ Claude Service → установка в: $CS_DIR"

# 1) .env
if [ ! -f .env ]; then
  cp deploy/.env.example .env
  echo "  ✓ создан .env из шаблона — ЗАПОЛНИ: DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL"
else
  echo "  · .env уже есть"
fi

# 2) docker-сеть
if docker network inspect claude-net >/dev/null 2>&1; then
  echo "  · сеть claude-net уже есть"
else
  docker network create claude-net >/dev/null
  echo "  ✓ создана сеть claude-net"
fi

# 3) redis + devbot
echo "▶ Поднимаю redis + devbot…"
docker compose up -d --build
docker compose ps

cat <<STEPS

✅ Сервис поднят. Осталось вручную (требуют доступа к nginx / sudo):

1) Заполни .env (если ещё не): DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL,
   затем: docker compose up -d --build
2) Публичный nginx (HTTPS-домен) → подключи к сети и добавь webhook:
     docker network connect claude-net <nginx-container>
   вставь блок из deploy/nginx.snippet.conf в server{} и перезагрузи nginx
3) systemd-мост и автостарт:
     sudo bash scripts/install-systemd.sh
4) Запусти tmux-сессию 'claude' с Claude CLI на хосте (её слушает мост).
5) Подключи проекты симлинками scripts/tg-send.sh и scripts/tg-ask.sh (см. README).
6) Проверь: docker compose logs devbot --tail=5  и  systemctl is-active tg-bridge
STEPS
