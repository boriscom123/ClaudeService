const config = require('../config');
const pool = require('../db/pool');

async function apiCall(method, body) {
  const r = await fetch(`https://api.telegram.org/bot${config.token}/${method}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

async function send(chatId, text, extra = {}) {
  // Не прикрепляем ReplyKeyboard по умолчанию: её нажатие клиент шлёт как
  // reply на сообщение-владельца. Меню — отдельным inline-сообщением (showMenu).
  const data = await apiCall('sendMessage', {
    chat_id: chatId,
    text,
    parse_mode: 'HTML',
    ...extra,
  });
  if (data.ok) {
    const msgId = data.result.message_id;
    pool.query(
      'INSERT INTO telegram_bot_messages (chat_id, message_id) VALUES ($1, $2)',
      [chatId, msgId]
    ).catch(() => {});
    return msgId;
  }
  return null;
}

async function sendChunked(chatId, text, replyTo = 0) {
  if (text.length <= 4000) { await send(chatId, text, replyTo > 0 ? { reply_to_message_id: replyTo } : {}); return; }
  let chunk = '';
  let first = true;
  for (const line of text.split('\n')) {
    if (chunk.length + line.length > 3600 && chunk) {
      await send(chatId, chunk, first && replyTo > 0 ? { reply_to_message_id: replyTo } : {});
      first = false; chunk = '';
      await new Promise(r => setTimeout(r, 300));
    }
    chunk += line + '\n';
  }
  if (chunk.trim()) await send(chatId, chunk, first && replyTo > 0 ? { reply_to_message_id: replyTo } : {});
}

async function react(chatId, msgId, emoji) {
  await apiCall('setMessageReaction', {
    chat_id: chatId,
    message_id: msgId,
    reaction: [{ type: 'emoji', emoji }],
  }).catch(() => {});
}

async function answerCallback(id, text) {
  await apiCall('answerCallbackQuery', { callback_query_id: id, text });
}

async function clearMessages(chatId) {
  const chatInfo = await apiCall('getChat', { chat_id: chatId });
  // message_id из pg (BIGINT) приходит строкой, из Telegram — числом → сравниваем строками.
  const pinnedId = chatInfo.ok && chatInfo.result.pinned_message
    ? String(chatInfo.result.pinned_message.message_id) : null;
  const { rows } = await pool.query(
    'SELECT message_id FROM telegram_bot_messages WHERE chat_id=$1 ORDER BY message_id ASC',
    [chatId]
  );
  let deleted = 0;
  for (const row of rows) {
    if (pinnedId && String(row.message_id) === pinnedId) continue; // закреплённое не трогаем
    const r = await apiCall('deleteMessage', { chat_id: chatId, message_id: row.message_id });
    if (r.ok) deleted++;
  }
  // Таблицу чистим, но запись о закреплённом сообщении сохраняем.
  if (pinnedId) {
    await pool.query('DELETE FROM telegram_bot_messages WHERE chat_id=$1 AND message_id <> $2', [chatId, pinnedId]);
  } else {
    await pool.query('DELETE FROM telegram_bot_messages WHERE chat_id=$1', [chatId]);
  }
  return deleted;
}

module.exports = { apiCall, send, sendChunked, react, answerCallback, clearMessages };
