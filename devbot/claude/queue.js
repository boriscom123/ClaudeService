const { createClient } = require('redis');
const config = require('../config');
const { send } = require('../bot/sender');

const redis = createClient({ socket: config.redis });
redis.on('error', err => console.error('[Redis]', err.message));
redis.connect().catch(err => console.error('[Redis] connect:', err.message));

async function enqueue(chatId, msgId, text, attachmentPath = null, attachmentType = null) {
  const payload = JSON.stringify({
    chat_id: chatId,
    msg_id: msgId,
    text: text || '',
    ...(attachmentPath && { attachment_path: attachmentPath, attachment_type: attachmentType }),
  });
  await redis.rPush('tg:queue', payload);

  const busy = await redis.get('tg:busy');
  if (busy) {
    const len = await redis.lLen('tg:queue');
    await send(chatId, `⏳ Claude занят, запрос #${len} в очереди.`);
  }
}

module.exports = { redis, enqueue };
