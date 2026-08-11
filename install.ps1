# Claude Service — установщик для Windows (PowerShell). Запускать ИЗ КОРНЯ ClaudeService:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
# Требуется Docker Desktop (движок WSL2). Поднимает docker-сеть claude-net и redis+devbot.
#
# ВНИМАНИЕ: host-оркестрация (systemd-мост tg-bridge, tmux-сессия 'claude',
# автостарт, симлинки tg-send/tg-ask) — только для Linux/VPS и на Windows НЕ ставится.
# Этот скрипт поднимает контейнерную часть (Redis + devbot) — для локальной разработки
# бота или запуска сервиса под Docker Desktop.

$ErrorActionPreference = 'Stop'

# Каталог скрипта = корень проекта
$CsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $CsDir

Write-Host "> Claude Service -> установка в: $CsDir" -ForegroundColor Cyan

# 0) Docker доступен?
try {
  docker version --format '{{.Server.Version}}' | Out-Null
} catch {
  Write-Host "  x Docker не найден или демон не запущен. Установи Docker Desktop и запусти его." -ForegroundColor Red
  exit 1
}

# 1) .env
if (-not (Test-Path .\.env)) {
  Copy-Item .\deploy\.env.example .\.env
  Write-Host "  + создан .env из шаблона — ЗАПОЛНИ: DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL" -ForegroundColor Yellow
} else {
  Write-Host "  . .env уже есть"
}

# 2) docker-сеть
$netExists = $false
try { docker network inspect claude-net *> $null; if ($LASTEXITCODE -eq 0) { $netExists = $true } } catch {}
if ($netExists) {
  Write-Host "  . сеть claude-net уже есть"
} else {
  docker network create claude-net | Out-Null
  Write-Host "  + создана сеть claude-net"
}

# 3) redis + devbot
Write-Host "> Поднимаю redis + devbot..." -ForegroundColor Cyan
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { Write-Host "  x docker compose завершился с ошибкой" -ForegroundColor Red; exit 1 }
docker compose ps

@"

OK. Контейнерная часть поднята. Дальнейшие шаги зависят от окружения:

1) Заполни .env (если ещё не): DEVBOT_TOKEN, TELEGRAM_ADMIN_CHAT_ID, WEBHOOK_URL,
   затем: docker compose up -d --build
2) Публичный nginx (HTTPS-домен) -> подключи к сети и добавь webhook:
     docker network connect claude-net <nginx-container>
   вставь блок из deploy/nginx.snippet.conf в server{} и перезагрузи nginx
3) Host-оркестрация (мост, автостарт, tmux, симлинки) работает ТОЛЬКО на Linux/VPS.
   На Windows её нет — разворачивай эту часть на самом VPS (см. install.sh и README).
4) Проверь: docker compose logs devbot --tail=5
"@ | Write-Host
