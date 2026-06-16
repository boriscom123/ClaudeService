const pool = require('../../db/pool');
const { send } = require('../sender');
const { taskInlineKeyboard } = require('../keyboard');
const { enqueue } = require('../../claude/queue');

const STATUS_EMOJI = { pending: '🕐', in_progress: '🔧', testing: '🧪', rejected: '❌', done: '✅' };

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function listTasks(chatId) {
  const r = await pool.query(
    `SELECT tag, title, status, result, test_steps FROM dev_tasks WHERE status != 'done' ORDER BY created_at DESC LIMIT 15`
  );
  if (r.rowCount === 0) { await send(chatId, '📭 Активных задач нет.'); return; }
  await send(chatId, `<b>📋 Активные задачи: ${r.rowCount}</b>`);
  // Каждую задачу — отдельным сообщением с inline-кнопками [Закрыть] [Вернуть]
  for (const t of r.rows) {
    const emoji = STATUS_EMOJI[t.status] || '•';
    let msg = `${emoji} <b>${esc(t.title)}</b>\n<code>#${t.tag}</code> · ${t.status}`;
    msg += `\n\n📝 <b>Что сделано:</b>\n${t.result ? esc(t.result) : '—'}`;
    msg += `\n\n🧪 <b>Как протестировать:</b>\n${t.test_steps ? esc(t.test_steps) : '—'}`;
    await send(chatId, msg, { reply_markup: taskInlineKeyboard(t.tag) });
  }
}

async function listTesting(chatId) {
  const r = await pool.query(
    `SELECT tag, title FROM dev_tasks WHERE status='testing' ORDER BY updated_at DESC LIMIT 15`
  );
  if (r.rowCount === 0) { await send(chatId, '📭 Задач на тестировании нет.'); return; }
  for (const t of r.rows) {
    await send(chatId, `🧪 <b>${esc(t.title)}</b>\n<code>#${t.tag}</code>`);
  }
}

async function createTask(chatId, description, msgId = null, attachmentPath = null) {
  if (!description || !description.trim()) {
    await send(chatId, '❌ Описание задачи не может быть пустым.');
    return null;
  }
  description = description.trim();
  const tag = 'remote-' + Date.now().toString(36);
  await pool.query(
    `INSERT INTO dev_tasks (tag, title, description, status) VALUES ($1, $2, $3, 'pending')`,
    [tag, description.slice(0, 255), description]
  );
  console.log(`[devbot] Новая задача #${tag}: ${description.slice(0, 80)}`);
  await send(chatId, `📋 Задача принята [<code>#${tag}</code>]\n<b>${esc(description.slice(0, 255))}</b>`);
  await enqueue(chatId, msgId, `Берём задачу #${tag} в работу: ${description}`, attachmentPath, attachmentPath ? 'photo' : null);
  return tag;
}

module.exports = { listTasks, listTesting, createTask };
