// Конфиг devbot с ГОРЯЧИМ перечитыванием .env — менять токен/админа/webhook
// можно без пересоздания контейнера.
//
// Как это работает:
//   - .env монтируется в контейнер как каталог (см. docker-compose.yml,
//     ./ → /cs-root:ro) и читается по пути CS_ENV_FILE в рантайме;
//   - token/ownerId/webhookUrl — ГЕТТЕРЫ: значение берётся из файла при каждом
//     обращении (с кэшем по mtime, чтобы не читать файл на каждый вызов API);
//   - Redis остаётся статикой: TCP-соединение поднимается один раз на старте,
//     на лету его не переключить — эти значения задаёт compose (environment:).
//
// Монтируем именно КАТАЛОГ, а не одиночный файл: редакторы и `sed -i` заменяют
// inode (пишут временный файл и переименовывают), и bind-mount одного файла
// продолжил бы показывать старое содержимое. Каталог отдаёт актуальный inode.
const fs = require('fs');
const path = require('path');

const ENV_PATH = process.env.CS_ENV_FILE || path.join(__dirname, '.env');

let _cache = { mtimeMs: -1, vars: {} };

// Перечитываем .env только если файл менялся (сравниваем mtime). statSync —
// дешёвый сисколл; readFileSync срабатывает лишь после реального изменения.
function envVars() {
  try {
    const st = fs.statSync(ENV_PATH);
    if (st.mtimeMs !== _cache.mtimeMs) {
      const vars = {};
      for (const line of fs.readFileSync(ENV_PATH, 'utf8').split('\n')) {
        const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/);
        if (m) vars[m[1]] = m[2].replace(/\r$/, '').replace(/^["']|["']$/g, '');
      }
      _cache = { mtimeMs: st.mtimeMs, vars };
    }
  } catch {
    // Файла нет (локальный запуск без mount) — падаем на process.env ниже.
  }
  return _cache.vars;
}

// Значение: сперва из файла, затем из окружения процесса, затем дефолт.
function val(key, fallback) {
  const v = envVars()[key];
  return (v !== undefined && v !== '') ? v : (process.env[key] ?? fallback);
}

module.exports = {
  get token()      { return val('DEVBOT_TOKEN'); },
  get ownerId()    { return parseInt(val('TELEGRAM_ADMIN_CHAT_ID')); },
  get webhookUrl() { return val('WEBHOOK_URL', 'https://77.91.86.142.nip.io/devbot/webhook'); },
  redis: {
    host: process.env.REDIS_HOST || 'redis',
    port: parseInt(process.env.REDIS_PORT || '6379'),
  },
};
