# Сборка ClaudeService с нуля через сессию Claude (плейбук промптов)

> Сценарий: **чистый VPS**. Вы по SSH запускаете свежую сессию Claude Code и **по очереди**
> даёте ей промпты из этого файла. Claude пишет код и разворачивает сервис; вы параллельно
> делаете то, что за Claude сделать нельзя (пометка **🖐 Вручную**). Цель — прийти к текущей
> реализации: devbot + Redis в Docker, host-мост Telegram→tmux, systemd-автостарт, домен + TLS.
>
> Инструкция **универсальна**: имя пользователя, домашний каталог, uid, путь к `claude` и
> каталог установки нигде не зашиты — они выводятся из окружения (`$HOME`, `id -u`,
> `command -v claude`, текущий каталог), а systemd-юниты параметризуются при установке.
> Вам нужно подставить только своё: **токен бота**, **свой chat_id** и **домен**.
>
> Как читать шаг: **🖐 Вручную** — действия человека; **📋 Промпт** — вставляете Claude
> дословно; **🤖 Claude сделает** — что произойдёт; **✅ Проверка** — как убедиться.
>
> Каждый промпт — отдельная реплика: вставили → дождались, что Claude закончил и показал
> результат → только потом следующий. Не вываливайте всё разом.
>
> Реконструкция «по описанию поведения» не обязана быть байт-в-байт. Эталон — этот
> репозиторий; если где-то Claude отклонится, сверяйтесь с оригинальными файлами.

---

## Фаза 0 — Бутстрап (полностью вручную, Claude ещё нет)

**🖐 Вручную** на свежем VPS, под тем пользователем, от которого будет жить сервис
(не root; далее он называется «рабочий пользователь»):

```bash
# 1. Базовые пакеты и Docker
sudo apt update
sudo apt install -y docker.io docker-compose-plugin git tmux jq curl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"        # ВАЖНО: затем выйти и зайти заново (relogin)

# 2. Фаервол под вебхук/ACME
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw --force enable

# 3. Claude Code CLI (нужен на хосте — в нём и работаем, и позже его слушает мост)
curl -fsSL https://claude.ai/install.sh | bash    # обычно ставит в ~/.local/bin/claude
command -v claude || echo "проверь, что claude в PATH"
claude                                             # разово: логин + доверие к каталогу

# 4. Каталог проекта и рабочая tmux-сессия для СБОРКИ.
#    Каталог — любой; в примерах ~/projects/ClaudeService. Имя сессии — 'build'
#    (НЕ 'claude': имя 'claude' позже займёт мост).
mkdir -p ~/projects/ClaudeService
tmux new -s build
cd ~/projects/ClaudeService
claude
```

Дальше все промпты вставляете в этот запущенный Claude. Подготовьте заранее:

- **Токен бота** — у @BotFather: `/newbot` → имя → username → скопировать токен.
- **Свой chat_id** — написать @userinfobot, он ответит числом.
- **Домен** — либо `A`-запись `bot.example.com → <IP VPS>`, либо бесплатный `<IP>.nip.io`
  (резолвит IP без регистрации; Let's Encrypt для него выпускается штатно).

> Первым делом сообщите Claude контекст окружения — так он подставит правильные значения
> в скрипты. **📋 Промпт:**
> ```
> Прежде чем начнём: зафиксируй параметры окружения этого VPS и используй их дальше во всех
> скриптах и юнитах вместо любых констант. Выполни и запомни вывод:
>   whoami ; echo "HOME=$HOME" ; id -u ; command -v claude ; pwd
> Каталог pwd — это корень установки ClaudeService. Нигде не хардкодь конкретное имя
> пользователя, домашний путь, uid или путь к claude — бери их из этих значений
> (или вычисляй в самих скриптах: $HOME, id -u, command -v claude).
> ```

---

## Фаза 1 — Скелет проекта

**📋 Промпт**
```
Мы с нуля собираем сервис ClaudeService — мост между Telegram-ботом и Claude Code CLI
на этом сервере. Стек: Node-сервис devbot + Redis в Docker, плюс host-скрипты и systemd.
Postgres НЕ используем — весь стейт в Redis.

Инициализируй git-репозиторий в текущем каталоге и создай скелет:
- .gitignore: node_modules/, .env, *.log
- каталоги: devbot/, devbot/bot/, devbot/bot/handlers/, devbot/claude/, scripts/,
  scripts/systemd/, deploy/, docs/
- deploy/.env.example с переменными и комментариями:
    DEVBOT_TOKEN=            (токен Telegram-бота от @BotFather)
    TELEGRAM_ADMIN_CHAT_ID=  (chat_id единственного владельца, кому бот отвечает)
    WEBHOOK_URL=https://ВАШ-ДОМЕН/devbot/webhook
    REDIS_HOST=redis
    REDIS_PORT=6379
  и закомментированные необязательные: CLAUDE_SESSION, CS_REDIS_CONTAINER, CS_ENV_FILE,
  CURRENT_PROJECT_FILE, DEFAULT_PROJECT.
Пока только структура и эти файлы, код добавим дальше.
```

**🤖 Claude сделает**: `git init`, дерево каталогов, `.gitignore`, `deploy/.env.example`.

---

## Фаза 2 — devbot (Node-сервис)

Собираем по модулям — так проще проверять. Давайте промпты по одному.

### 2.1 Конфиг с горячим перечитыванием `.env`

**📋 Промпт**
```
Создай devbot/config.js. Секреты НЕ хардкодим и НЕ читаем через env_file: .env будет
примонтирован в контейнер как каталог, а config читает его в рантайме по пути из
переменной CS_ENV_FILE (иначе ./ .env рядом с файлом).

Требования:
- token, ownerId, webhookUrl — это ГЕТТЕРЫ (get token() и т.д.): при каждом обращении
  берут значение из .env-файла, но с кэшем по mtime — перечитывают файл только если он
  менялся (fs.statSync → сравнить mtimeMs; readFileSync лишь при изменении). Парсинг:
  строки вида KEY=VALUE, снять кавычки и \r.
- token → DEVBOT_TOKEN; ownerId → parseInt(TELEGRAM_ADMIN_CHAT_ID); webhookUrl → WEBHOOK_URL
  (без «личного» дефолта — только из .env/окружения).
- Значение: сперва из файла, потом process.env, потом дефолт.
- redis — статикой (не геттер): { host: REDIS_HOST||'redis', port: REDIS_PORT||6379 },
  из process.env, потому что TCP-соединение живёт с запуска и на лету не переключается.
Прокомментируй, ПОЧЕМУ монтируется каталог, а не файл (редакторы/sed меняют inode).
```

### 2.2 Redis-очередь

**📋 Промпт**
```
Создай devbot/claude/queue.js: подключение к Redis (пакет redis, createClient с socket из
config.redis, лог ошибок, connect с catch) и функцию enqueue(chatId, msgId, text, opts).
opts: { tier='now', targetProject=null, attachmentPath=null, attachmentType=null }.
enqueue делает rPush в список 'tg:queue' JSON-объекта:
{ chat_id, msg_id, text, tier, target_project?(если задан), attachment_path?+attachment_type?(если есть) }.
Экспортируй { redis, enqueue }.
```

### 2.3 Отправка сообщений

**📋 Промпт**
```
Создай devbot/bot/sender.js — работа с Telegram Bot API (token из config).
- apiCall(method, body): POST на api.telegram.org, вернуть json.
- send(chatId, text, extra={}): sendMessage с parse_mode:'HTML'. При успехе трекать
  message_id в Redis-списке cs:msgids:<chatId> (rPush + lTrim до последних 500) — это нужно
  для «очистить чат». Вернуть msgId.
- sendChunked(chatId, text, replyTo=0): если text > 4000 символов — резать по строкам на
  куски ~3600, слать по очереди с паузой 300мс; reply_to_message_id только на первом куске.
- react(chatId, msgId, emoji): setMessageReaction.
- answerCallback(id, text): answerCallbackQuery.
- clearMessages(chatId): получить getChat, узнать pinned_message; пройти по cs:msgids:<chatId>
  и deleteMessage каждое, КРОМЕ закреплённого; затем очистить список, но вернуть в него id
  закреплённого. Вернуть число удалённых.
```

### 2.4 Клавиатуры и меню

**📋 Промпт**
```
Создай devbot/bot/keyboard.js.
- MAIN_MENU_INLINE — inline-меню (callback_data): ряды
  [💻 Статус VPS → m:vps, 🔀 Фиксировать git → m:git], [🗑️ Очистить чат → m:clear],
  [📁 Проект → m:project, 🔄 Перезагрузить VPS → m:reboot], [❓ Помощь → m:help].
  Используем INLINE, а не нижнюю ReplyKeyboard, потому что нажатие ReplyKeyboard клиент шлёт
  как reply и каждое сообщение бота выглядит «отвеченным».
- PROJECT_ICONS = { game:'🎮', cm:'💬', uq:'🎫', cs:'🤖' } (дефолт 📁) — иконки по коду проекта.
- projectMenuInline(redis, current): читает Redis-хэш cs:projects (id→имя), сортирует id,
  строит по кнопке на проект с callback_data proj:<id>, текст «[✅ если current] иконка имя · id».
  Если хэш пуст — вернуть null.
- WELCOME_KEYBOARD — нижняя ReplyKeyboard приветствия: [['💻 Информация о VPS','🔄 Перезагрузить VPS'],
  ['📁 Проект','❓ Справка']], resize_keyboard, is_persistent.
```

### 2.5 Статус VPS и загрузчик вложений

**📋 Промпт**
```
Создай два модуля.

devbot/bot/handlers/vps.js — getVpsStatus(): собрать без внешних утилит, где можно:
uptime и loadavg из /proc/uptime и /proc/loadavg; RAM из /proc/meminfo (MemTotal-MemAvailable);
диск через `df -h /`; список контейнеров — HTTP-запросом к /var/run/docker.sock
(/containers/json?all=true), каждый 🟢/🔴 по State. Вернуть HTML-строку со сводкой.

devbot/bot/downloader.js — downloadPhoto(message): если есть photo/video/document —
getFile у Telegram, скачать в каталог /attachments (создать), имя из хвоста file_id + ext
(jpg/mp4/или из имени документа). Вернуть путь или null.
```

### 2.6 Обработчик сообщений

**📋 Промпт**
```
Создай devbot/bot/handlers/messages.js — handleMessage(message).
text = message.text || message.caption, trimmed. hasPhoto = photo|video|document.

Логика по порядку:
1) Режим «свой вариант»: если в Redis есть tg:askown:<chatId> — снять ключ; если это НЕ
   команда и не лейбл меню, то enqueue текста как «[Свой вариант] …» (+вложение) и ответить
   «✍️ Принял твой вариант — передал Claude.»; иначе просто выйти из режима.
2) Если text начинается с '!': разобрать префикс — '!!!'(3+)→tier prio, '!'/'!!'→hold, задать
   тело без '!'. Первый токен после '!' считать КОДОМ проекта, только если он есть в хэше
   cs:projects (кросс-проектная адресация) — тогда target=этот код, убрать его из тела.
   enqueue(tier, targetProject, вложение). Ответить «⏫ В приоритет[ проекта X].» либо
   «➕ В очередь[ проекта X].». Пустой текст без вложения — ошибка «напиши текст после !».
3) '/start' или '/menu': отправить приветствие с WELCOME_KEYBOARD, затем unpinAll + pinChatMessage
   этого приветствия (чтобы «очистить чат» его не трогал, см. clearMessages).
4) '/help' → runMenuAction(chatId,'help').
5) Лейблы нижних кнопок (карта: '💻 Информация о VPS'/'💻 Статус VPS'→vps,
   '🔀 Фиксация на git'/'🔀 Фиксировать git'→git, '🗑️ Очистить чат'→clear,
   '🔄 Перезагрузить VPS'→reboot, '📁 Проект'→project, '❓ Справка'/'❓ Помощь'→help;
   держи и старые алиасы) → runMenuAction.
6) Иначе — обычный текст: enqueue немедленно (tier now, +вложение) для инжекта в активную
   сессию Claude.
```

### 2.7 Обработчик callback-кнопок

**📋 Промпт**
```
Создай devbot/bot/handlers/callbacks.js — handleCallback(cb). data разбирается по ':'.
- 'ask:<id>:<idx|own>': own → выставить tg:askown:<chat> EX 3600, попросить свой вариант;
  число → взять сохранённый вариант из tg:ask:<id> (JSON-массив), убрать клавиатуру, ответить
  «✅ Выбрано: …» и enqueue «[Выбор пользователя] …».
- 'm:<пункт>' → answerCallback + runMenuAction(chatId, пункт).
- 'proj:<id>' → answerCallback «🔄 Переключаю…», убрать клавиатуру, enqueue «[Переключить проект] id».
  (Эту строку заберёт МОСТ, не Claude — switch убивает сессию Claude.)
- 'reboot:yes|cancel' → удалить сообщение; yes → enqueue «[Перезагрузка VPS] запусти
  scripts/reboot-vps.sh …»; cancel → answerCallback «Отменено».
```

### 2.8 Действия меню и динамическая справка

**📋 Промпт**
```
Создай devbot/bot/handlers/actions.js — runMenuAction(chatId, action) + buildHelpText().
BUTTON_HELP: карта лейбл→краткое описание (для всех лейблов WELCOME_KEYBOARD и алиасов).

buildHelpText(): справка строится ДИНАМИЧЕСКИ, чтобы не расходиться с реальностью:
- коды проектов — из хэша cs:projects (id — имя, через запятую);
- список кнопок — из WELCOME_KEYBOARD.keyboard.flat(), каждая как «лейбл — описание из BUTTON_HELP».
Текст: заголовок, блок «Общение с Claude», блок «Очередь» (!текст, !!!текст, !<код> текст,
строка с кодами), блок «Кнопки клавиатуры», блок «Команды» (/start, /help). parse_mode HTML.

runMenuAction switch:
- 'vps' → send(getVpsStatus()).
- 'git' → enqueue «[Фиксация на git] закоммить незафиксированное в dev, осмысленный message,
  push dev», ответить пользователю.
- 'clear' → clearMessages, ответить «🗑️ Удалено N сообщений.»
- 'project' → взять cs:projects и cs:current, построить projectMenuInline; если пусто —
  «список проектов пуст (мост не запущен?)»; иначе показать текущий проект + меню-кнопки с
  предупреждением, что контекст сессии потеряется.
- 'reboot' → сообщение с подтверждением и инлайн-кнопками reboot:yes / reboot:cancel.
- 'help' → send(buildHelpText()).
```

### 2.9 Точка входа, Dockerfile, package.json

**📋 Промпт**
```
Собери devbot воедино:
- devbot/index.js: express, JSON, POST /webhook (сразу res.sendStatus(200), затем обработка;
  если callback_query → handleCallback; авторизация: обрабатывать только если
  message.from.id === config.ownerId, иначе лог «Unauthorized» и выход; иначе handleMessage).
  GET /health → {status:'ok'}. Слушать порт 3002 и на старте вызвать setWebhook на config.webhookUrl.
- devbot/package.json: зависимости express и redis.
- devbot/Dockerfile: FROM node:20-alpine, WORKDIR /app, COPY package*.json + npm install,
  COPY ., EXPOSE 3002, CMD node index.js.
Затем проверь синтаксис всех файлов devbot (`node -c` по каждому .js) и что require резолвятся.
```

**✅ Проверка**: `node -c devbot/index.js` и по остальным файлам — синтаксис без ошибок.

---

## Фаза 3 — docker-compose (redis + devbot)

**📋 Промпт**
```
Создай docker-compose.yml в корне:
- сервис redis: image redis:7-alpine, restart unless-stopped, volume redis_data:/data,
  сеть claude-net, container_name claudeservice-redis-1.
- сервис devbot: build ./devbot, container_name claudeservice-devbot-1, restart unless-stopped,
  depends_on redis, сеть claude-net. .env НЕ через env_file, а bind-mount каталогом:
  volumes ./:/cs-root:ro, /tmp/devbot-attachments:/attachments, /var/run/docker.sock:/var/run/docker.sock.
  environment: REDIS_HOST=redis, REDIS_PORT=6379, CS_ENV_FILE=/cs-root/.env.
- volume redis_data; сеть claude-net как external: true.
Прокомментируй, что порт 3002 наружу НЕ публикуется — доступ через внешний nginx/Caddy по claude-net.
```

---

## Фаза 4 — Host-скрипты (мост, реестр, обратная связь)

> Во всех host-скриптах пути НЕ зашивать: tmux-сокет — `/tmp/tmux-$(id -u)/default`,
> путь к claude — `$(command -v claude || echo "$HOME/.local/bin/claude")`, каталог установки —
> самолокацией скрипта (`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`).

### 4.1 Реестр проектов

**📋 Промпт**
```
Создай scripts/projects.sh — единственный источник правды о проектах (подключается через source).
Ассоциативные массивы PROJECT_DIRS (id→абсолютный путь) и PROJECT_NAMES (id→имя). Пока внеси
только запись [cs] с именем "Claude Service" и путём = абсолютный путь к корню этой установки
(текущий каталог проекта). Остальные проекты добавим, когда/если они появятся на этом VPS.
Функции: project_dir, project_name, project_list (id через пробел, отсортированы),
project_current (из файла ${CURRENT_PROJECT_FILE:-$HOME/.claude-current-project}, дефолт
DEFAULT_PROJECT=cs при пустом/битом), project_set_current. Ничего сам не выполняет.
```

> **🖐 Вручную** позже: если на VPS появятся другие проекты — добавите их строками в этот файл
> и перезапустите мост.

### 4.2 Мост Telegram→tmux (главный скрипт)

**📋 Промпт**
```
Создай scripts/watch-triggers.sh — inbound-only мост (bash). Запускается на хосте под рабочим
пользователем, слушает Redis и инжектит в tmux-сессию Claude; ответы НЕ ждёт и не скрапит
(итог Claude шлёт сам). Пути из окружения: REDIS_CONTAINER=claudeservice-redis-1,
TMUX_SOCK=/tmp/tmux-$(id -u)/default, SESSION=${CLAUDE_SESSION:-claude}.
redis_cmd() = docker exec redis redis-cli; tmux_cmd() = tmux -S сокет. source projects.sh.

Функции:
- publish_projects: DEL cs:projects, HSET cs:projects из project_list/project_name, SET cs:current=project_current.
- tg_send(chat_id,text): sendMessage через curl (токен DEVBOT_TOKEN из окружения systemd), parse_mode HTML.
- handle_switch_project(chat_id,text): если text начинается с «[Переключить проект]» — вынуть код,
  проверить project_dir; если неизвестен/текущий — сообщить; иначе сбросить claude:resume_at/resume_cmd,
  вызвать switch-project.sh <код> и отчитаться (успех/ошибка с хвостом вывода). Вернуть 0, если обработал.
- session_busy: в capture-pane текущей панели есть строка «esc to interrupt» → занят.
- inject_message(msg): распарсить jq (chat_id/text/attachment_path/attachment_type); сперва
  handle_switch_project; если tmux-сессии нет — сообщить «Claude не запущен, запустите по SSH»;
  иначе собрать текст (для вложения строка «[Telegram: пользователь прислал <тип> → <путь>]»),
  добавить префикс «[TG] », инжектить безопасно: printf | tmux load-buffer - ; paste-buffer ; send-keys Enter.
- (опционально, можно добавить позже) check_session_limit и maybe_resume — детект баннера
  «hit your session limit · resets <время>»: одно уведомление в TG + запись claude:resume_at (epoch),
  и авто-реинжект claude:resume_cmd после сброса при простое.

main(): publish_projects; бесконечный цикл каждые ~2с: LPOP tg:queue. Если сообщение есть —
tier=now → inject сразу; tier=hold → RPUSH tg:hold:<проект>; tier=prio → RPUSH tg:hold:prio:<проект>,
где проект = валидный target_project или project_current. Если очередь пуста — считать простой
(idle_streak по session_busy); при простое ≥2 подряд и живой сессии достать ОДНО из tg:hold:prio:<текущий>,
иначе из tg:hold:<текущий>, и inject. У каждого проекта своя hold-очередь.
```

### 4.3 Переключение проекта и автозапуск

**📋 Промпт**
```
Создай два скрипта. Пути к claude и tmux-сокету — из окружения (command -v claude / id -u), не хардкодь.

scripts/switch-project.sh <id>: source projects.sh. CLAUDE_BIN=$(command -v claude || echo
"$HOME/.local/bin/claude"), SESSION=${CLAUDE_SESSION:-claude}, TMUX_SOCKET=/tmp/tmux-$(id -u)/default.
Убить tmux-сессию SESSION и поднять новую под ТЕМ ЖЕ именем в каталоге проекта, запустить в ней claude.
Верифицировать (до ~10с), что сессия существует И в дереве её процессов реально есть процесс `claude`
(обход pane_pid → потомки). current-project (project_set_current) писать ТОЛЬКО после успешной
верификации; при провале — откат на прежний проект и exit 1. НЕ запускать изнутри самой сессии Claude.

scripts/start-claude.sh: для systemd-автостарта после ребута. source projects.sh, те же CLAUDE_BIN/
SESSION/сокет из окружения. Если tmux-сессии 'claude' нет — создать detached в каталоге project_current
и запустить claude; затем фоном через 15с отправить в Telegram уведомление «🤖 Claude запущен, проект …»
(токен/chat_id читать ровно нужными ключами из .env, не сорсить весь файл). Создать каталог сокета, если нет.
```

### 4.4 Обратная связь (исходящие) и ребут

**📋 Промпт**
```
Создай три скрипта. Они живут в scripts/ и будут симлинкаться в проекты — реальный путь и .env
рядом резолвить через readlink -f. ENV_FILE=${CS_ENV_FILE:-<scripts>/../.env},
REDIS_CONTAINER=${CS_REDIS_CONTAINER:-claudeservice-redis-1}. get_env() читает один ключ из .env.

scripts/tg-send.sh "<текст>" [chat_id]: отправить сообщение владельцу (sendMessage, parse_mode HTML),
при успехе трекать msg_id в cs:msgids:<chat> (RPUSH + LTRIM -500 -1) через docker exec redis-cli.

scripts/tg-ask.sh "<вопрос>" "<в1>" "<в2>"…: сохранить массив вариантов в tg:ask:<id> (EX 3600),
отправить вопрос с ПОЛНЫМ нумерованным списком в тексте и inline-кнопками: ряд коротких номерных
(callback ask:<id>:<idx>) + отдельная кнопка «✍️ Свой вариант» (ask:<id>:own). Трекать msg_id как выше.

scripts/reboot-vps.sh: source projects.sh; сначала tg-send.sh уведомление, затем sudo -n reboot
(несколько путей: systemctl reboot / /sbin/reboot / /usr/sbin/reboot); при отказе — сообщить, что
нужен NOPASSWD sudoers. В шапке скрипта — команда установки sudoers для reboot, где имя пользователя
берётся из $(id -un), а не зашивается.

Проставь chmod +x на все host-скрипты.
```

---

## Фаза 5 — systemd (мост + автостарт)

**📋 Промпт**
```
Нужны systemd-юниты, но БЕЗ зашитых путей/пользователя — их должен подставлять установщик под
текущее окружение. Сделай так:

- scripts/systemd/claude-autostart.service и scripts/systemd/tg-bridge.service — как ШАБЛОНЫ с
  плейсхолдерами __USER__ и __CSDIR__ (каталог установки).
  claude-autostart: oneshot, RemainAfterExit=yes, After network+docker, User=__USER__,
    ExecStart=__CSDIR__/scripts/start-claude.sh, WantedBy multi-user.target.
  tg-bridge: Type=simple, After docker + claude-autostart, User=__USER__,
    EnvironmentFile=__CSDIR__/.env, ExecStart=__CSDIR__/scripts/watch-triggers.sh,
    Restart=always RestartSec=5, вывод в journal, WantedBy multi-user.target.

- scripts/install-systemd.sh: определить USER=$(id -un) и CSDIR=корень установки; chmod +x скриптов;
  подставить __USER__/__CSDIR__ (sed) при копировании обоих юнитов в /etc/systemd/system/;
  daemon-reload; enable --now обоих; показать статус. Запускать через sudo.
```

Также попросите Claude собрать `install.sh` (создать .env из шаблона, `docker network create claude-net`,
`docker compose up -d --build`, печать ручных шагов) и заполнить `README.md`.

---

> **Актуально с 2026-09-02:** точка входа сервера больше не собирается внутри
> проекта. Общий слой (nginx, общие postgres и redis, portainer) вынесен в
> отдельный репозиторий ClaudeDocker: github.com/boriscom123/ClaudeDocker.
> На чистом VPS порядок такой — создать сети `web`, `claude-net`, `shared-data`,
> поднять ClaudeDocker, затем проекты. Каждый проект при этом имеет
> самодостаточный compose (профиль `standalone`) и оверлей под VPS в
> `ClaudeDocker/projects/`. Фаза ниже описывает прежнюю схему и оставлена
> как справка по TLS.

## Фаза 6 — Домен, обратный прокси и TLS (Caddy)

**🖐 Вручную** заранее: домен указывает на IP VPS (A-запись или `<IP>.nip.io`), порты 80/443 открыты.

**📋 Промпт** (подставьте свой домен в реплике)
```
Наружу вебхук отдаём через контейнер-обратный-прокси в сети claude-net; devbot слушает :3002
и наружу не публикуется. Возьмём Caddy — он сам выпускает и продлевает сертификат Let's Encrypt.
Создай deploy/proxy/Caddyfile для домена <DOMAIN>: путь /devbot/webhook переписывать в /webhook и
reverse_proxy на claudeservice-devbot-1:3002; остальное отдавать 404. И deploy/proxy/docker-compose.yml:
сервис caddy (caddy:2-alpine), ports 80:80 и 443:443, монтаж Caddyfile + тома caddy_data и caddy_config,
сеть claude-net (external). Также создай deploy/nginx.snippet.conf на случай, если позже будет nginx:
location /devbot/webhook → proxy_pass http://claudeservice-devbot-1:3002/webhook.
```

---

## Фаза 7 — Заполнить секреты и поднять контейнеры

**🖐 Вручную**: теперь у вас есть токен бота, chat_id и домен.

**📋 Промпт**
```
Создай .env из deploy/.env.example и впиши в него:
DEVBOT_TOKEN=<я дам>  TELEGRAM_ADMIN_CHAT_ID=<я дам>  WEBHOOK_URL=https://<DOMAIN>/devbot/webhook.
Проверь, что .env в .gitignore. Затем: docker network create claude-net (если нет),
docker compose up -d --build (redis+devbot), и в deploy/proxy — docker compose up -d (caddy).
Покажи docker compose ps и логи devbot и caddy; дождись в логах Caddy успешного выпуска сертификата,
а в логах devbot — строки об успешном setWebhook.
```
> Токен и chat_id вставьте в реплику при отправке (или впишите в `.env` руками — devbot подхватит по mtime).

**✅ Проверка**: `docker compose ps` — оба Up; Caddy выпустил сертификат; devbot залогировал `✅ setWebhook`.

---

## Фаза 8 — Host-оркестрация и финальная проверка

**🖐 Вручную** (нужен sudo — Claude сам его не выполнит):
```bash
# systemd-мост и автостарт (install-systemd.sh подставит текущего пользователя и пути сам)
sudo bash scripts/install-systemd.sh

# NOPASSWD sudo на reboot (для кнопки «Перезагрузить VPS») — имя пользователя берётся автоматически
echo "$(id -un) ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /sbin/reboot, /usr/sbin/reboot" \
  | sudo tee /etc/sudoers.d/reboot-vps && sudo chmod 440 /etc/sudoers.d/reboot-vps
```

**🖐 Вручную**: запустите каноническую сессию (мост слушает именно её). Сейчас Claude работает в
сессии `build`; каноническую `claude` создаёт `start-claude.sh` отдельно:
```bash
scripts/start-claude.sh
tmux -S /tmp/tmux-$(id -u)/default attach -t claude   # убедиться, что Claude поднялся; Ctrl-b d — отцепиться
```

**📋 Промпт** (можно дать в build-сессии — Claude проверит со стороны сервиса)
```
Финальная самопроверка сервиса: покажи `docker compose ps`, `systemctl is-active tg-bridge`,
и getWebhookInfo бота (url и что last_error_message пуст). Затем перечисли, что мне осталось
проверить руками в Telegram.
```

**✅ Проверка вручную**: напишите боту `/start` → приходит приветствие с клавиатурой; отправьте любой
текст → он появляется в сессии `claude`; нажмите «💻 Информация о VPS» → приходит статус.

---

## Приложение — карта ручных действий (то, что Claude сделать не может)

| Где | Действие |
|-----|----------|
| Фаза 0 | apt/Docker/tmux/jq/curl, `usermod -aG docker` + relogin, ufw 22/80/443 |
| Фаза 0 | Установка и логин Claude CLI, запуск build-сессии |
| Фаза 0 | @BotFather — токен, @userinfobot — chat_id, домен/DNS (A-запись или nip.io) |
| Фаза 7 | Передать Claude токен и chat_id (или вписать в `.env` руками) |
| Фаза 8 | `sudo bash scripts/install-systemd.sh`, sudoers для reboot |
| Фаза 8 | `scripts/start-claude.sh` и проверка сессии `claude` |
| Фаза 8 | Тест бота в Telegram |

## Что важно не забыть (иначе «соберётся, но не заведётся»)

- Никаких зашитых путей/пользователя: сокет — `/tmp/tmux-$(id -u)/default`, claude —
  `command -v claude`, каталог установки — самолокацией скрипта, systemd-юниты — через
  плейсхолдеры и подстановку в `install-systemd.sh`. Если Claude где-то вписал константу —
  попросите заменить на вычисление из окружения.
- devbot исполняет код **из образа**: после правок JS — `docker compose up -d --build devbot`,
  не `restart`.
- Мост читает `DEVBOT_TOKEN` из `.env` через `EnvironmentFile` — после смены токена перезапустите
  `tg-bridge`. Сам devbot токен/webhook перечитывает по mtime без пересоздания (кроме setWebhook
  на старте).
- Добавление проекта = строка в `scripts/projects.sh` + `sudo systemctl restart tg-bridge`.
- Рабочий пользователь должен быть в группе `docker` (иначе мост и статус VPS не достучатся до
  docker.sock), а сессия сборки и каноническая `claude` — под одним и тем же пользователем
  (tmux-сокет привязан к его uid).
```