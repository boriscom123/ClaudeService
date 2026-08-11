module.exports = {
  token:   process.env.DEVBOT_TOKEN,
  ownerId: parseInt(process.env.TELEGRAM_ADMIN_CHAT_ID),
  webhookUrl: process.env.WEBHOOK_URL || `https://77.91.86.142.nip.io/devbot/webhook`,
  redis: {
    host: process.env.REDIS_HOST || 'redis',
    port: parseInt(process.env.REDIS_PORT || '6379'),
  },
};
