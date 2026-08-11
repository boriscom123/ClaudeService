const config = require('../config');
const { redis } = require('../claude/queue');

const MSGIDS_KEY = chatId => `cs:msgids:${chatId}`;
const MSGIDS_LIMIT = 500;

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
    redis.rPush(MSGIDS_KEY(chatId), String(msgId))
      .then(() => redis.lTrim(MSGIDS_KEY(chatId), -MSGIDS_LIMIT, -1))
      .catch(() => {});
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
  const pinnedId = chatInfo.ok && chatInfo.result.pinned_message
    ? String(chatInfo.result.pinned_message.message_id) : null;
  // id сообщений бота трекаются в Redis-списке (замена telegram_bot_messages).
  const ids = await redis.lRange(MSGIDS_KEY(chatId), 0, -1).catch(() => []);
  let deleted = 0;
  for (const id of ids) {
    if (pinnedId && String(id) === pinnedId) continue; // закреплённое не трогаем
    const r = await apiCall('deleteMessage', { chat_id: chatId, message_id: Number(id) });
    if (r.ok) deleted++;
  }
  // Список чистим; запись о закреплённом сообщении сохраняем.
  await redis.del(MSGIDS_KEY(chatId)).catch(() => {});
  if (pinnedId) await redis.rPush(MSGIDS_KEY(chatId), pinnedId).catch(() => {});
  return deleted;
}

module.exports = { apiCall, send, sendChunked, react, answerCallback, clearMessages };
