const { send, clearMessages } = require('../sender');
const { getVpsStatus } = require('./vps');
const { enqueue, redis } = require('../../claude/queue');
const { MAIN_MENU_INLINE, projectMenuInline } = require('../keyboard');

// Справка формируется ДИНАМИЧЕСКИ: список кодов проектов берём из того же
// Redis-хэша cs:projects, что и меню «Проект». Так справка не разъезжается
// при добавлении/удалении проекта (единый источник правды — scripts/projects.sh).
async function buildHelpText() {
  const map = await redis.hGetAll('cs:projects').catch(() => ({}));
  const ids = Object.keys(map || {}).sort();
  const codesLine = ids.length
    ? ids.map(id => `<code>${id}</code> — ${map[id]}`).join(', ')
    : 'см. меню 📁 Проект';
  return (
    `<b>🤖 DevBot — сервисный бот для Claude</b>\n` +
    `Персональный мост к Claude CLI на сервере.\n\n` +
    `<b>💬 Общение с Claude</b>\n` +
    `Просто напиши любой текст — он уйдёт напрямую в Claude, а ответ придёт сюда. ` +
    `Можно прислать и фото/скриншот.\n\n` +
    `<b>➕ Очередь</b>\n` +
    `<code>!текст</code> — в очередь текущего проекта (выполнится по простою).\n` +
    `<code>!!!текст</code> — в приоритет очереди.\n` +
    `<code>!&lt;код&gt; текст</code> — в очередь другого проекта.\n` +
    `Коды проектов: ${codesLine}.\n\n` +
    `<b>🔘 Кнопки меню</b>\n` +
    `💻 Информация о VPS — CPU/RAM/диск/контейнеры\n` +
    `🔀 Фиксация на git — commit + push\n` +
    `📁 Проект — переключить Claude между проектами VPS\n` +
    `📸 Снапшот — снимок документации проекта на VPS + Google Drive\n` +
    `🔄 Перезагрузить VPS — снимок + перезагрузка сервера (Claude вернётся сам)\n` +
    `🗑️ Очистить чат — удалить сообщения бота\n` +
    `❓ Справка — это сообщение\n\n` +
    `<b>Команды</b>\n` +
    `/start — приветствие и клавиатура\n` +
    `/help — эта справка`
  );
}

// Показать главное меню (inline). Опционально гасим нижнюю ReplyKeyboard,
// если она ещё висит в кеше клиента.
async function showMenu(chatId, { dropReplyKeyboard = false } = {}) {
  if (dropReplyKeyboard) {
    await send(chatId, '☰ Меню:', { reply_markup: { remove_keyboard: true } });
    await send(chatId, '👇 Выбери действие:', { reply_markup: MAIN_MENU_INLINE });
  } else {
    await send(chatId, '👇 Выбери действие:', { reply_markup: MAIN_MENU_INLINE });
  }
}

// Единая точка для пунктов меню — вызывается и из inline-callback (m:*),
// и из легаси-нажатий старой нижней клавиатуры (текстовые лейблы).
async function runMenuAction(chatId, action) {
  switch (action) {
    case 'vps':
      try { await send(chatId, await getVpsStatus()); }
      catch (e) { await send(chatId, `❌ Ошибка: ${e.message}`); }
      break;
    case 'git':
      await enqueue(chatId, null,
        '[Фиксация на git] Закоммить в dev незафиксированные изменения, ' +
        'сформируй осмысленный commit message и запушь dev.');
      await send(chatId, '🔀 Отправил Claude: коммит изменений в dev + push.');
      break;
    case 'clear': {
      const n = await clearMessages(chatId);
      await send(chatId, `🗑️ Удалено ${n} сообщений.`);
      break;
    }
    case 'snapshot':
      await enqueue(chatId, null,
        '[Снапшот] Запусти scripts/daily-snapshot.sh (версионированный снапшот документации на VPS) ' +
        'и выгрузи свежий снапшот на Google Drive, затем подтверди через scripts/tg-send.sh.');
      await send(chatId, '📸 Запускаю снапшот документации…');
      break;
    case 'project': {
      const map = await redis.hGetAll('cs:projects').catch(() => ({}));
      const current = await redis.get('cs:current').catch(() => null);
      const menu = await projectMenuInline(redis, current);
      if (!menu) { await send(chatId, '⚠️ Список проектов пуст (мост не запущен?).'); break; }
      const curLine = current && map[current]
        ? `📌 Текущий проект: <b>${map[current]}</b> (<code>${current}</code>)`
        : '📌 Текущий проект: <i>неизвестен</i>';
      await send(chatId,
        `${curLine}\n\n` +
        '📁 <b>Переключить проект</b>\n\n' +
        'Claude перезапустится в выбранном проекте. ' +
        'Контекст текущей сессии будет потерян — не переключайтесь посреди незавершённой задачи.\n\n' +
        'Контейнеры проектов продолжат работать.',
        { reply_markup: menu });
      break;
    }
    case 'reboot':
      // Подтверждение — перезагрузка прерывает работу на ~1–2 минуты
      await send(chatId,
        '🔄 <b>Перезагрузить VPS?</b>\nСохраню снимок проекта, перезагружу сервер, Claude вернётся автоматически после загрузки.',
        { reply_markup: { inline_keyboard: [[
          { text: '✅ Да, перезагрузить', callback_data: 'reboot:yes' },
          { text: '✖️ Отмена', callback_data: 'reboot:cancel' },
        ]] } });
      break;
    case 'help':
      await send(chatId, await buildHelpText());
      break;
  }
}

module.exports = { runMenuAction, showMenu, buildHelpText };
