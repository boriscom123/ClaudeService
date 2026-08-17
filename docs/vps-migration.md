# Перенос VPS (меняется только сервер и IP)

> Кросс-проектный runbook: охватывает все проекты на VPS (game_world_tycoon_idle,
> cross_messenger, uzbek_queue) и этот сервис. Живёт в ClaudeService как в
> оркестраторе; пути к файлам проектов даны относительно `/home/boris/projects/`.

Все проекты на этом VPS используют домены `<IP>.nip.io` (nip.io резолвит любой IP),
поэтому при переезде меняется **только IP**. Токены, пароли, данные и настройки
сохраняются. `game_world_tycoon_idle` — хост общей инфраструктуры (центральный nginx,
Postgres, сети `web` и `game_world_tycoon_idle_default`); от него зависят cross_messenger
и uzbek_queue. ClaudeService держит devbot + Redis (сеть `claude-net`).

## Что где хардкодит IP

| Проект | Файлы с IP | Как менять |
|---|---|---|
| **game_world_tycoon_idle** | `.env` (`DOMAIN`/`CM_DOMAIN` → nginx server_name/cert), `public/twa-manifest.json`, `server/index.js` | `game_world_tycoon_idle/scripts/set-vps-ip.sh <new-ip>` |
| **cross_messenger** | функционального IP в коде нет — домен из его `.env` `APP_URL`, nginx-блок cm живёт в game_world | правка `.env` + сертификат |
| **uzbek_queue** | `.env`, `deploy/nginx/uq.conf` | `uzbek_queue/deploy/set-domain.sh <new-ip>` |
| **ClaudeService** (мост) | `.env` `WEBHOOK_URL` (домен → nginx игры `/devbot/webhook`) | правка `.env` + пересоздать devbot |

## Порядок (на НОВОМ VPS)

1. **Данные.** Перенести БД каждого проекта:
   - game_world Postgres (`game_db`): `pg_dump`/`pg_restore` (роль `game_user`).
   - uzbek_queue (`uq`, в том же Postgres): `pg_dump -Fc` → `pg_restore --clean` (см. uzbek_queue/docs/deploy.md).
   - cross_messenger (свой MySQL `cm-mysql`): `mysqldump` → import.
   Redis не переносим (кэш/очереди/сессии — перелогин, незавершённые задачи теряются).
2. **Инфраструктура.** Поднять сети + общий Postgres + nginx игры
   (`cd game_world_tycoon_idle && docker compose up -d`). Сети `web` и
   `game_world_tycoon_idle_default` создаются здесь.
3. **Сменить IP:**
   ```sh
   (cd game_world_tycoon_idle && scripts/set-vps-ip.sh <NEW_IP>)   # .env DOMAIN/CM_DOMAIN, manifest, server/index.js
   (cd uzbek_queue && deploy/set-domain.sh <NEW_IP>)               # uzbek_queue
   # cross_messenger: APP_URL=https://cm.<NEW_IP>.nip.io в его .env
   # ClaudeService: WEBHOOK_URL=https://<NEW_IP>.nip.io/devbot/webhook в .env
   ```
4. **TLS** для всех доменов (`<IP>.nip.io`, `cm.<IP>.nip.io`, `uq.<IP>.nip.io`) через certbot,
   затем перезагрузить/пересоздать nginx.
5. **Контейнеры/ассеты** каждого проекта: `docker compose up -d --build`, миграции, сборка фронта.
6. **Оркестрация.** Поднять ClaudeService (`docker compose up -d --build` → redis + devbot,
   сеть `claude-net`), подключить nginx игры к `claude-net` и добавить webhook-локацию
   (см. README этого сервиса + `deploy/nginx.snippet.conf`), запустить systemd-мост.
   devbot при старте регистрирует новый `WEBHOOK_URL`.
7. **Telegram.** Игровой бот — переустановить webhook на новый домен (setWebhook); для
   uzbek_queue — `artisan telegram:set-webhook` + BotFather `/setdomain` для @uzqueue_bot на `uq.<IP>.nip.io`.
8. **CI.** Обновить секрет(ы) `DEPLOY_HOST` на новый IP.
9. **Проверка.** `/api/health` (game), `cm.<IP>.nip.io` (cm), `uq.<IP>.nip.io/up` (uq) → 200.

Единая точка правки IP в каждом проекте — соответствующий скрипт из таблицы выше.
