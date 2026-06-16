const pool = require('../../db/pool');
const { send, answerCallback, apiCall } = require('../sender');
const { enqueue, redis } = require('../../claude/queue');
const { runMenuAction } = require('./actions');

async function handleCallback(callbackQuery) {
  const chatId = callbackQuery.message.chat.id;
  const msgId = callbackQuery.message.message_id;
  const parts = callbackQuery.data.split(':');
  const [action, tag] = parts;

  // ask:<id>:<idx|own> — быстрый выбор варианта из tg-ask.sh
  if (action === 'ask') {
    const askId = parts[1];
    const choice = parts[2];
    if (choice === 'own') {
      await redis.set(`tg:askown:${chatId}`, '1', { EX: 3600 });
      await answerCallback(callbackQuery.id, '✍️ Напиши свой вариант');
      await send(chatId, '✍️ Опиши свой вариант — следующим сообщением.');
      return;
    }
    const raw = await redis.get(`tg:ask:${askId}`);
    const opts = raw ? JSON.parse(raw) : [];
    const chosen = opts[Number(choice)] ?? '(вариант не найден)';
    await answerCallback(callbackQuery.id, '✅ Принято');
    await apiCall('editMessageReplyMarkup', { chat_id: chatId, message_id: msgId, reply_markup: { inline_keyboard: [] } });
    await send(chatId, `✅ Выбрано: <b>${chosen}</b>`);
    await enqueue(chatId, null, `[Выбор пользователя] ${chosen}`);
    return;
  }

  // m:<пункт> — главное inline-меню
  if (action === 'm') {
    await answerCallback(callbackQuery.id, '');
    await runMenuAction(chatId, tag);
    return;
  }

  if (action === 'ok') {
    await pool.query(`UPDATE dev_tasks SET status='done', updated_at=NOW() WHERE tag=$1`, [tag]);
    await pool.query(
      `INSERT INTO dev_feedback (task_tag, feedback, from_chat_id) VALUES ($1, $2, $3)`,
      [tag, 'Принято', chatId]
    );
    await answerCallback(callbackQuery.id, '✅ Задача закрыта');
    await apiCall('deleteMessage', { chat_id: chatId, message_id: msgId });
    await send(chatId, `✅ Задача <code>#${tag}</code> закрыта. Вливаю ветку в dev…`);
    // Ветка задачи вливается в dev и пушится Claude'ом (git — на хосте в его сессии).
    await enqueue(chatId, null, `[Закрыть задачу] #${tag}: влей ветку task/${tag} в dev, запушь dev, удали ветку задачи.`);

  } else if (action === 'take') {
    const r = await pool.query(`SELECT title, description FROM dev_tasks WHERE tag=$1 AND status='pending'`, [tag]);
    if (r.rowCount === 0) {
      await answerCallback(callbackQuery.id, '⚠️ Задача уже взята или не найдена');
      return;
    }
    const { description } = r.rows[0];
    await answerCallback(callbackQuery.id, '🔧 Берём в работу...');
    await apiCall('deleteMessage', { chat_id: chatId, message_id: msgId });
    await enqueue(chatId, null, `Берём задачу #${tag} в работу: ${description}`);

  } else if (action === 'reject') {
    // Включаем режим сбора фидбека: следующее сообщение пользователя
    // (текст + опц. фото/видео) станет описанием «что не так».
    // Состояние в Redis → переживает рестарт devbot. TTL 1 час.
    await redis.set(`tg:feedback:${chatId}`, tag, { EX: 3600 });
    await answerCallback(callbackQuery.id, '🔄 Опиши, что не так');
    await apiCall('deleteMessage', { chat_id: chatId, message_id: msgId });
    await send(chatId,
      `🔄 Возвращаю <code>#${tag}</code> в работу.\n` +
      `Опиши, <b>что именно не так</b> — следующим сообщением. Можно приложить фото/видео.`);
  }
}

module.exports = { handleCallback };
