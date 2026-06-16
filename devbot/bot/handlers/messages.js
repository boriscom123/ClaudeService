const pool = require('../../db/pool');
const { send, apiCall } = require('../sender');
const { createTask } = require('./tasks');
const { enqueue, redis } = require('../../claude/queue');
const { downloadPhoto } = require('../downloader');
const { runMenuAction } = require('./actions');
const { WELCOME_KEYBOARD } = require('../keyboard');

function mediaType(message) {
  if (message.photo) return 'photo';
  if (message.video) return 'video';
  if (message.document) return 'document';
  return null;
}

// Лейблы кнопок нижней клавиатуры → пункт меню (+ алиасы старых лейблов из кеша).
const MENU_LABELS = {
  '📋 Задачи': 'tasks', '📋 Список задач': 'tasks',
  '💻 Информация о VPS': 'vps', '💻 Статус VPS': 'vps',
  '🔀 Фиксация на git': 'git', '🔀 Фиксировать git': 'git',
  '🗑️ Очистить чат': 'clear',
  '❓ Справка': 'help', '❓ Помощь': 'help',
};

async function handleMessage(message) {
  const chatId = message.chat.id;
  const text = (message.text || message.caption || '').trim();
  const hasPhoto = !!(message.photo || message.video || message.document);

  // Режим «свой вариант» (после кнопки ✍️ Свой вариант в tg-ask.sh):
  // следующее сообщение уходит Claude как пользовательский вариант.
  const askOwn = await redis.get(`tg:askown:${chatId}`);
  if (askOwn) {
    if (text.startsWith('/') || MENU_LABELS[text]) {
      await redis.del(`tg:askown:${chatId}`);
    } else {
      const mPath = hasPhoto ? await downloadPhoto(message) : null;
      await redis.del(`tg:askown:${chatId}`);
      await enqueue(chatId, message.message_id, `[Свой вариант] ${text}`, mPath, mediaType(message));
      await send(chatId, '✍️ Принял твой вариант — передал Claude.');
      return;
    }
  }

  // Режим фидбека по возвращённой задаче (после «🔄 Вернуть»):
  // следующее сообщение = описание «что не так» (+ опц. фото/видео).
  const fbTag = await redis.get(`tg:feedback:${chatId}`);
  if (fbTag) {
    // Команда или кнопка меню → отменяем режим фидбека, обрабатываем как обычно
    if (text.startsWith('/') || MENU_LABELS[text]) {
      await redis.del(`tg:feedback:${chatId}`);
    } else {
      const mPath = hasPhoto ? await downloadPhoto(message) : null;
      const mType = mediaType(message);
      await pool.query(
        `INSERT INTO dev_feedback (task_tag, feedback, from_chat_id) VALUES ($1, $2, $3)`,
        [fbTag, text || '(вложение)', chatId]);
      await pool.query(`UPDATE dev_tasks SET status='in_progress', updated_at=NOW() WHERE tag=$1`, [fbTag]);
      await redis.del(`tg:feedback:${chatId}`);
      const fb = `Задача #${fbTag} возвращена на доработку. Что не так: ${text || '(см. вложение)'}`;
      await enqueue(chatId, message.message_id, fb, mPath, mType);
      await send(chatId, `🔄 Принял фидбек по <code>#${fbTag}</code> — передал Claude в работу.`);
      return;
    }
  }

  // ! в начале → создать задачу
  if (text.startsWith('!')) {
    const photoPath = hasPhoto ? await downloadPhoto(message) : null;
    const desc = text.slice(1).trim();
    const fullDesc = photoPath
      ? (desc ? `${desc} [+ скриншот]` : '[скриншот]')
      : desc;
    if (!fullDesc) {
      await send(chatId, '❌ Напиши описание после !');
      return;
    }
    await createTask(chatId, fullDesc, message.message_id, photoPath);
    return;
  }

  // /start, /menu — приветствие + клавиатура (кнопка ❓ Помощь).
  // Закрепляем сообщение: «🗑️ Очистить чат» пропускает закреплённое
  // (clearMessages), поэтому приветствие с клавиатурой переживает очистку.
  if (text === '/start' || text === '/menu') {
    const wid = await send(chatId,
      '👋 <b>DevBot на связи.</b>\nПиши любой текст — отвечу через Claude.\nНажми <b>❓ Помощь</b> для справки.',
      { reply_markup: WELCOME_KEYBOARD });
    if (wid) {
      await apiCall('unpinAllChatMessages', { chat_id: chatId }).catch(() => {});
      await apiCall('pinChatMessage', { chat_id: chatId, message_id: wid, disable_notification: true }).catch(() => {});
    }
    return;
  }
  if (text === '/help') { await runMenuAction(chatId, 'help'); return; }

  // Легаси: «📌 Создать задачу» из старой клавиатуры
  if (text === '📌 Создать задачу') {
    await send(chatId, 'Чтобы создать задачу, начни сообщение с <code>!</code>\n\nПример: <code>!Исправить баг с картой</code>');
    return;
  }

  // Нажатия кнопок нижней клавиатуры
  if (MENU_LABELS[text]) { await runMenuAction(chatId, MENU_LABELS[text]); return; }

  // /задача [описание] — legacy
  const taskMatch = text.match(/^\/(?:задача|task)\s+(.+)/si);
  if (taskMatch) { await createTask(chatId, taskMatch[1].trim()); return; }

  // Всё остальное → Claude
  const mPath = hasPhoto ? await downloadPhoto(message) : null;
  await enqueue(chatId, message.message_id, text, mPath, mPath ? mediaType(message) : null);
}

module.exports = { handleMessage };
