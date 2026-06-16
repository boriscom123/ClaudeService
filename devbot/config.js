module.exports = {
  token:   process.env.DEVBOT_TOKEN,
  ownerId: parseInt(process.env.TELEGRAM_ADMIN_CHAT_ID),
  webhookUrl: process.env.WEBHOOK_URL,
  db: {
    host:     process.env.DB_HOST,
    port:     parseInt(process.env.DB_PORT || '5432'),
    database: process.env.DB_NAME,
    user:     process.env.DB_USER,
    password: process.env.DB_PASS,
  },
  redis: {
    host: process.env.REDIS_HOST || 'redis',
    port: parseInt(process.env.REDIS_PORT || '6379'),
  },
};
