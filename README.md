# Claude Service

Центральный сервис-мост **Telegram ↔ Claude Code CLI** на сервере. Живёт **рядом с
проектами** (`/home/boris/projects/ClaudeService`), а не внутри какого-либо из них, и
обслуживает их все: чат с Claude, очередь задач с приоритетом, переключение проектов,
мониторинг VPS, git-операции, снапшоты.

## Архитектура (push-модель)

```
Telegram → nginx /devbot/webhook → devbot (Docker) → Redis tg:queue
                                                        │
                          watch-triggers.sh (systemd tg-bridge) маршрутизирует:
                            now  → инжект в tmux "claude" сразу
                            hold → tg:hold:<project>        (по простою сессии)
                            prio → tg:hold:prio:<project>   (раньше обычных)
                                                        │
                                             Claude Code CLI (tmux)
   ^ исходящие: Claude сам шлёт итог через scripts/tg-send.sh / tg-ask.sh
```

Мост **только доставляет** входящие и не ждёт/не скрапит ответ — итог Claude отправляет сам.
Свой **Redis**, **без Postgres** (весь стейт в Redis). Публичный nginx проекта проксирует
webhook в devbot по общей docker-сети `claude-net`.

## Очередь и префиксы

| Ввод | Поведение |
|------|-----------|
| обычный текст | инжектится в активную сессию **сразу** |
| `!текст` | в очередь **текущего** проекта (доставится по простою) |
| `!!!текст` | в **приоритет** очереди текущего проекта |
| `!<код> текст` | в очередь **другого** проекта (`код` ∈ реестр: game, cm, uq) |
| `!!!<код> текст` | в приоритет очереди другого проекта |

У каждого проекта **своя очередь**: живёт только сессия текущего проекта, поэтому
кросс-проектная задача ждёт в очереди своего проекта и вливается при переключении на него.
Первый токен после `!` считается кодом проекта, только если совпадает с id из реестра —
иначе это обычный текст.

## Проекты (реестр)

Единый источник правды — `scripts/projects.sh` (`PROJECT_DIRS` + `PROJECT_NAMES`). Мост при
старте публикует реестр в Redis `cs:projects` (HASH id→имя); оттуда devbot строит меню
«📁 Проект» и валидирует коды. **Добавить проект = 2 шага:**
1. Строка в `PROJECT_DIRS` + `PROJECT_NAMES` (`scripts/projects.sh`).
2. Перезапустить мост: `sudo systemctl restart tg-bridge` (он перечитает реестр и обновит
   `cs:projects`). Пересобирать devbot **не нужно** — меню строится динамически.

Переключение: кнопка «📁 Проект» в боте или `scripts/switch-project.sh <id>`. Скрипт убивает
tmux-сессию и поднимает новую под тем же именем `claude` в каталоге проекта, **проверяя**, что
процесс `claude` реально стартовал; `~/.claude-current-project` пишется только после успеха
(при провале — откат и внятная ошибка в Telegram).

## Состав

| Путь | Назначение |
|------|-----------|
| `docker-compose.yml` | devbot + Redis (сеть claude-net) |
| `devbot/` | Node-сервис: webhook, кнопки меню, очередь |
| `scripts/watch-triggers.sh` | мост Redis→tmux (systemd `tg-bridge`) |
| `scripts/switch-project.sh` | переключение проекта с верификацией |
| `scripts/start-claude.sh` | автостарт сессии после ребута (`claude-autostart`) |
| `scripts/projects.sh` | реестр проектов (единый источник правды) |
| `scripts/tg-send.sh` | отправка итога пользователю |
| `scripts/tg-ask.sh` | вопрос с inline-кнопками вариантов |
| `scripts/reboot-vps.sh` | снапшот + перезагрузка VPS |
| `scripts/systemd/` | юниты `tg-bridge`, `claude-autostart` |
| `deploy/` | nginx-сниппет, `.env.example` |

## Установка / развёртывание

Разово на сервере:

```bash
cd /home/boris/projects/ClaudeService
cp deploy/.env.example .env        # заполни DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL
docker network create claude-net   # разово
docker compose up -d --build       # redis + devbot

# nginx проекта (публичный HTTPS) → подключить к сети и добавить webhook-локацию:
docker network connect claude-net <nginx-container>
#   вставь блок из deploy/nginx.snippet.conf в server{} и перезагрузи nginx

# systemd-мост и автостарт:
sudo bash scripts/install-systemd.sh

# запусти tmux-сессию 'claude' с Claude CLI на хосте (её слушает мост)
```

Или одной командой: `bash install.sh` (Linux/VPS).

**Перенос на другой VPS** (кросс-проектный чеклист — все проекты + этот сервис):
`docs/vps-migration.md`.

**Windows (Docker Desktop):** контейнерную часть (redis + devbot) поднимает
`powershell -ExecutionPolicy Bypass -File .\install.ps1`. Host-оркестрация
(systemd-мост, tmux-сессия `claude`, автостарт, симлинки) — только Linux/VPS;
на Windows её нет, разворачивай эту часть на самом сервере.

Проверка: `docker compose logs devbot --tail=5` и `systemctl is-active tg-bridge`.

### Смена секретов без перезапуска

`.env` монтируется в devbot каталогом (`./ → /cs-root:ro`), а `config.js`
перечитывает `DEVBOT_TOKEN`, `TELEGRAM_ADMIN_CHAT_ID` и `WEBHOOK_URL` из файла
на лету (кэш по mtime). Поэтому смена этих значений в `.env` подхватывается
**без пересоздания контейнера** — правки применяются со следующего запроса.
Исключения: `REDIS_HOST`/`REDIS_PORT` (соединение живёт с запуска) и сам
`WEBHOOK_URL` в части регистрации вебхука (setWebhook вызывается на старте).

> Один раз после обновления на эту схему контейнер нужно пересоздать
> (`docker compose up -d` подхватит новый mount), дальше рестарт не требуется.

## Подключение проекта

Проекту нужны лишь симлинки на скрипты обратной связи (Claude шлёт ими итог):

```bash
cd <project>/scripts
ln -sf /home/boris/projects/ClaudeService/scripts/tg-send.sh tg-send.sh
ln -sf /home/boris/projects/ClaudeService/scripts/tg-ask.sh  tg-ask.sh
```

Скрипты резолвят свой реальный путь через `readlink`, поэтому `.env` и Redis берут из
ClaudeService независимо от того, из какого проекта их вызвали.

## Конвенции для Claude (добавить в CLAUDE.md проекта)

- Сообщения из Telegram приходят с префиксом `[TG]`.
- Итог: `scripts/tg-send.sh "…"`; варианты: `scripts/tg-ask.sh "Вопрос?" "в1" "в2"`.
- Долгие задачи не обрезаются — шли итог, когда реально закончил.
