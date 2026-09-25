const { send, apiCall } = require('../sender');
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
  '💻 Информация о VPS': 'vps', '💻 Статус VPS': 'vps',
  '🔀 Фиксация на git': 'git', '🔀 Фиксировать git': 'git',
  '🗑️ Очистить чат': 'clear',
  '🔄 Перезагрузить VPS': 'reboot',
  '📁 Проект': 'project',
  '❓ Справка': 'help', '❓ Помощь': 'help',
};

// Известные коды проектов — из cs:projects (пишет мост из scripts/projects.sh).
async function knownProjects() {
  return (await redis.hGetAll('cs:projects').catch(() => ({}))) || {};
}

// Разбор ведущих '!' → tier + очистка текста + опц. код проекта.
//   '!!!' (3+) → prio, '!'/'!!' → hold, иначе → now.
//   Первый токен после '!' считается кодом проекта, только если он ∈ projects.
function classify(text, projects) {
  const m = text.match(/^(!+)\s*/);
  if (!m) return { tier: 'now', text, target: null };
  const tier = m[1].length >= 3 ? 'prio' : 'hold';
  let rest = text.slice(m[0].length);
  let target = null;
  const tok = rest.match(/^(\S+)\s+/);
  if (tok && projects[tok[1]]) { target = tok[1]; rest = rest.slice(tok[0].length); }
  return { tier, text: rest.trim(), target };
}

// Отправить сообщение с нижней клавиатурой WELCOME_KEYBOARD и закрепить его.
// Зачем: закреплённое сообщение пропускает «🗑️ Очистить чат» (clearMessages),
// поэтому клавиатура переживает очистку; предыдущее такое сообщение удаляем
// (id в Redis tg:welcome:<chatId>), чтобы в чате не копились дубли.
// Используется командами /start, /menu и /keyboard_update.
async function sendWelcome(chatId, text) {
  const key = `tg:welcome:${chatId}`;
  const prev = await redis.get(key).catch(() => null);
  const wid = await send(chatId, text, { reply_markup: WELCOME_KEYBOARD });
  if (!wid) return;
  await redis.set(key, String(wid)).catch(() => {});
  if (prev && prev !== String(wid)) {
    await apiCall('deleteMessage', { chat_id: chatId, message_id: Number(prev) }).catch(() => {});
  }
  await apiCall('unpinAllChatMessages', { chat_id: chatId }).catch(() => {});
  await apiCall('pinChatMessage', { chat_id: chatId, message_id: wid, disable_notification: true }).catch(() => {});
}

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
      await enqueue(chatId, message.message_id, `[Свой вариант] ${text}`,
        { attachmentPath: mPath, attachmentType: mediaType(message) });
      await send(chatId, '✍️ Принял твой вариант — передал Claude.');
      return;
    }
  }

  // Префикс ! / !!! → очередь / приоритет (+ опц. код проекта для кросс-проекта)
  if (text.startsWith('!')) {
    const projects = await knownProjects();
    const { tier, text: body, target } = classify(text, projects);
    const mPath = hasPhoto ? await downloadPhoto(message) : null;
    const finalText = body || (mPath ? '[вложение]' : '');
    if (!finalText) { await send(chatId, '❌ Напиши текст после <code>!</code>'); return; }
    await enqueue(chatId, message.message_id, finalText, {
      tier, targetProject: target, attachmentPath: mPath, attachmentType: mediaType(message),
    });
    const name = target ? ` проекта <b>${projects[target]}</b>` : '';
    await send(chatId, tier === 'prio' ? `⏫ В приоритет${name}.` : `➕ В очередь${name}.`);
    return;
  }

  // /start, /menu — приветствие + клавиатура (кнопка ❓ Помощь).
  if (text === '/start' || text === '/menu') {
    // Успешную обработку тоже логируем: раньше в лог попадали только отказы,
    // и по молчанию нельзя было отличить «команда не дошла» от «дошла и
    // отработала» — разбор жалобы на пропавшую клавиатуру упёрся именно в это.
    console.log(`[devbot] ${text} от ${message.from?.id} — отправляю клавиатуру`);
    await sendWelcome(chatId,
      '👋 <b>DevBot на связи.</b>\nПиши любой текст — отвечу через Claude.\nНажми <b>❓ Помощь</b> для справки.');
    return;
  }
  // /keyboard_update — переотправить нижнюю клавиатуру после изменения
  // WELCOME_KEYBOARD (и пересборки devbot): клиент Telegram держит старую
  // клавиатуру, пока бот не пришлёт новую. Старое сообщение-носитель удаляется.
  if (text === '/keyboard_update') {
    console.log(`[devbot] /keyboard_update от ${message.from?.id} — обновляю клавиатуру`);
    await sendWelcome(chatId, '⌨️ <b>Клавиатура обновлена.</b>');
    return;
  }
  if (text === '/help') { await runMenuAction(chatId, 'help'); return; }

  // Нажатия кнопок нижней клавиатуры
  if (MENU_LABELS[text]) { await runMenuAction(chatId, MENU_LABELS[text]); return; }

  // Всё остальное → Claude немедленно (инжект в активную сессию)
  const mPath = hasPhoto ? await downloadPhoto(message) : null;
  await enqueue(chatId, message.message_id, text,
    { attachmentPath: mPath, attachmentType: mPath ? mediaType(message) : null });
}

module.exports = { handleMessage };
