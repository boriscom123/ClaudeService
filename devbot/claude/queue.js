const { createClient } = require('redis');
const config = require('../config');

const redis = createClient({ socket: config.redis });
redis.on('error', err => console.error('[Redis]', err.message));
redis.connect().catch(err => console.error('[Redis] connect:', err.message));

// tier: 'now' | 'hold' | 'prio'. targetProject — код проекта для кросс-проектной очереди.
async function enqueue(chatId, msgId, text, opts = {}) {
  const { tier = 'now', targetProject = null, attachmentPath = null, attachmentType = null } = opts;
  const payload = JSON.stringify({
    chat_id: chatId,
    msg_id: msgId,
    text: text || '',
    tier,
    ...(targetProject && { target_project: targetProject }),
    ...(attachmentPath && { attachment_path: attachmentPath, attachment_type: attachmentType }),
  });
  await redis.rPush('tg:queue', payload);
}

module.exports = { redis, enqueue };
