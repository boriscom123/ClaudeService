const express = require('express');
const config = require('./config');
const { handleMessage } = require('./bot/handlers/messages');
const { handleCallback } = require('./bot/handlers/callbacks');

const app = express();
app.use(express.json());

app.post('/webhook', async (req, res) => {
  res.sendStatus(200);
  try {
    const { message, callback_query } = req.body;
    if (callback_query) { await handleCallback(callback_query); return; }
    if (!message) return;

    // Авторизация: только owner (роли — следующая итерация)
    if (message.from?.id !== config.ownerId) {
      console.log(`[devbot] Unauthorized: ${message.from?.id}`);
      return;
    }

    await handleMessage(message);
  } catch (e) {
    console.error('[devbot] webhook error:', e.message);
  }
});

app.get('/health', (_, res) => res.json({ status: 'ok' }));

async function registerWebhook() {
  try {
    const r = await fetch(
      `https://api.telegram.org/bot${config.token}/setWebhook`,
      { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: config.webhookUrl }) }
    );
    const d = await r.json();
    console.log('[devbot] Webhook:', d.ok ? `✅ ${config.webhookUrl}` : `❌ ${d.description}`);
  } catch (e) {
    console.error('[devbot] Webhook registration failed:', e.message);
  }
}

app.listen(3002, async () => {
  console.log('[devbot] Running on port 3002');
  await registerWebhook();
});
