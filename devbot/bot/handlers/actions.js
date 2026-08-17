const { send, clearMessages } = require('../sender');
const { getVpsStatus } = require('./vps');
const { enqueue, redis } = require('../../claude/queue');
const { MAIN_MENU_INLINE, WELCOME_KEYBOARD, projectMenuInline } = require('../keyboard');

// Описания кнопок по их лейблу. Раздел «Кнопки» в справке строится из самой
// нижней клавиатуры (WELCOME_KEYBOARD), поэтому справка не расходится с ней при
// изменении набора кнопок. Держим здесь и лейблы, которых сейчас нет на
// клавиатуре — если кнопку вернут, описание подхватится автоматически.
const BUTTON_HELP = {
  '💻 Информация о VPS': 'CPU/RAM/диск/контейнеры',
  '💻 Статус VPS': 'CPU/RAM/диск/контейнеры',
  '🔀 Фиксация на git': 'commit + push',
  '🔀 Фиксировать git': 'commit + push',
  '📁 Проект': 'переключить Claude между проектами VPS',
  '🔄 Перезагрузить VPS': 'перезагрузка сервера (Claude вернётся сам)',
  '🗑️ Очистить чат': 'удалить сообщения бота',
  '❓ Справка': 'это сообщение',
  '❓ Помощь': 'это сообщение',
};

// Справка формируется ДИНАМИЧЕСКИ: коды проектов — из Redis-хэша cs:projects
// (тот же источник, что и меню «Проект»), а список кнопок — из WELCOME_KEYBOARD.
// Так справка не разъезжается ни при добавлении проекта, ни при смене кнопок.
async function buildHelpText() {
  const map = await redis.hGetAll('cs:projects').catch(() => ({}));
  const ids = Object.keys(map || {}).sort();
  const codesLine = ids.length
    ? ids.map(id => `<code>${id}</code> — ${map[id]}`).join(', ')
    : 'см. меню 📁 Проект';
  const buttonsSection = WELCOME_KEYBOARD.keyboard
    .flat()
    .map(label => (BUTTON_HELP[label] ? `${label} — ${BUTTON_HELP[label]}` : label))
    .join('\n');
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
    `<b>🔘 Кнопки клавиатуры</b>\n` +
    `${buttonsSection}\n\n` +
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
