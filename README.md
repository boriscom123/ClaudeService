# Claude Service

Переиспользуемый сервис: мост **Telegram ↔ Claude Code CLI** на сервере. Управление
проектом из Telegram — чат с Claude, задачи (создание/приёмка/возврат с фидбеком),
мониторинг VPS, git-операции. Подключается к любому проекту одной командой.

## Установка

Запусти **из корня целевого проекта**:

```bash
curl -fsSL https://raw.githubusercontent.com/boriscom123/ClaudeService/main/install.sh | bash
```

Установщик автоматически:
- копирует `services/devbot/` и `scripts/*.sh` в проект;
- генерирует `scripts/claude-service.conf` (пути, имена контейнеров, tmux, pg) под проект;
- дописывает недостающие переменные в `.env`;
- генерирует `tg-bridge.service` (systemd-юнит).

Затем печатает **ручные шаги** (требуют sudo / правки конфигов): заполнить `.env`,
вставить блок `devbot` в `docker-compose.yml`, добавить `location /devbot/webhook` в
nginx, применить схему БД, поднять `devbot`, установить systemd-мост, запустить
tmux-сессию `claude` с Claude CLI.

## Архитектура (push-модель)

```
Telegram → nginx /devbot/webhook → devbot (Docker) → Redis tg:queue
                                                         |
                            watch-triggers.sh (systemd) инжектит в tmux "claude"
                                                         |
                                              Claude Code CLI
   ^ исходящие: Claude сам шлёт итог через scripts/tg-send.sh / tg-ask.sh / task-done.sh
```

Мост **только доставляет** входящие в Claude и не ждёт/не скрапит ответ — итог
Claude отправляет сам. Это убирает таймауты и хрупкий парсинг экрана.

## Состав

| Путь | Назначение |
|------|-----------|
| `devbot/` | Node-сервис: webhook, кнопки, CRUD задач |
| `scripts/watch-triggers.sh` | мост Redis -> tmux (systemd `tg-bridge`) |
| `scripts/tg-send.sh` | отправка итога пользователю |
| `scripts/tg-ask.sh` | вопрос с inline-кнопками вариантов |
| `scripts/task-done.sh` | результат задачи + «готово к проверке» с кнопками |
| `deploy/` | schema.sql, docker-compose/nginx сниппеты, systemd-шаблон, .env.example |
| `install.sh` | установщик |

## Требования целевого проекта

- Docker Compose с сервисами `postgres` и `redis`;
- nginx с HTTPS-доменом (для webhook);
- tmux на хосте + запущенный Claude Code CLI в сессии `claude`;
- отдельный Telegram-бот (свой `DEVBOT_TOKEN`) на проект.

## Конвенции для Claude (добавить в CLAUDE.md проекта)

- Сообщения из Telegram приходят с префиксом `[TG]`.
- Итог по [TG]-задаче: `scripts/tg-send.sh "…"`; варианты: `scripts/tg-ask.sh "Вопрос?" "в1" "в2"`.
- Задача с тегом → `scripts/task-done.sh "<tag>" "что сделано" "как протестировать"`.
