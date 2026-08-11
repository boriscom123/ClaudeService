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

  // proj:<id> — переключение проекта. Строку забирает МОСТ (watch-triggers.sh),
  // а не Claude: switch-project.sh убивает сессию, в которой запущен.
  if (action === 'proj') {
    await answerCallback(callbackQuery.id, '🔄 Переключаю…');
    await apiCall('editMessageReplyMarkup', {
      chat_id: chatId, message_id: msgId, reply_markup: { inline_keyboard: [] },
    });
    await enqueue(chatId, null, `[Переключить проект] ${tag}`);
    return;
  }

  // reboot:yes|cancel — подтверждение перезагрузки VPS
  if (action === 'reboot') {
    await apiCall('deleteMessage', { chat_id: chatId, message_id: msgId }).catch(() => {});
    if (tag === 'yes') {
      await answerCallback(callbackQuery.id, '🔄 Перезагружаю…');
      await send(chatId, '🔄 Сохраняю снимок проекта и перезагружаю VPS…');
      // Claude (на хосте) выполняет снапшот + reboot; после загрузки поднимется сам.
      await enqueue(chatId, null,
        '[Перезагрузка VPS] Запусти scripts/reboot-vps.sh — он сделает снапшот проекта и перезагрузит VPS. ' +
        'После перезагрузки claude-autostart.service поднимет сессию заново.');
    } else {
      await answerCallback(callbackQuery.id, 'Отменено');
    }
    return;
  }
}

module.exports = { handleCallback };
