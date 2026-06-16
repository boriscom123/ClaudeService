const { send, clearMessages } = require('../sender');
const { listTasks, listTesting } = require('./tasks');
const { getVpsStatus } = require('./vps');
const { enqueue } = require('../../claude/queue');
const { MAIN_MENU_INLINE } = require('../keyboard');

const HELP_TEXT =
  `<b>🤖 DevBot — сервисный бот для Claude</b>\n` +
  `Персональный мост к Claude CLI на сервере.\n\n` +
  `<b>💬 Общение с Claude</b>\n` +
  `Просто напиши любой текст — он уйдёт напрямую в Claude, а ответ придёт сюда. ` +
  `Можно прислать и фото/скриншот.\n\n` +
  `<b>📌 Создание задач</b>\n` +
  `Начни сообщение с <code>!</code> — оно станет задачей:\n` +
  `<code>!Исправить баг с картой</code>\n` +
  `К задаче можно приложить скриншот (фото + подпись, начинающаяся с <code>!</code>).\n\n` +
  `<b>🔘 Кнопки меню</b>\n` +
  `📋 Задачи — список активных задач\n` +
  `💻 Информация о VPS — CPU/RAM/диск/контейнеры\n` +
  `🔀 Фиксация на git — commit + push\n` +
  `🗑️ Очистить чат — удалить сообщения бота\n` +
  `❓ Справка — это сообщение\n\n` +
  `<b>Команды</b>\n` +
  `/start — приветствие и клавиатура\n` +
  `/help — эта справка`;

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
    case 'tasks':
      await listTasks(chatId);
      break;
    case 'testing':
      await listTesting(chatId);
      break;
    case 'vps':
      try { await send(chatId, await getVpsStatus()); }
      catch (e) { await send(chatId, `❌ Ошибка: ${e.message}`); }
      break;
    case 'git':
      await enqueue(chatId, null,
        '[Фиксация на git] Закоммить в dev изменения, НЕ привязанные к незакрытым задачам ' +
        '(ветки task/* не трогай), сформируй осмысленный commit message и запушь dev.');
      await send(chatId, '🔀 Отправил Claude: коммит незадачных изменений в dev + push.');
      break;
    case 'clear': {
      const n = await clearMessages(chatId);
      await send(chatId, `🗑️ Удалено ${n} сообщений.`);
      break;
    }
    case 'help':
      await send(chatId, HELP_TEXT);
      break;
  }
}

module.exports = { runMenuAction, showMenu, HELP_TEXT };
