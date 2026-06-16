-- Claude Service — таблицы (идемпотентно). Применить к БД проекта.
CREATE TABLE IF NOT EXISTS dev_tasks (
  id          SERIAL PRIMARY KEY,
  tag         VARCHAR(50) UNIQUE NOT NULL,
  title       VARCHAR(255) NOT NULL,
  description TEXT,
  checklist   TEXT,
  status      VARCHAR(20) DEFAULT 'pending',
  created_at  TIMESTAMP DEFAULT NOW(),
  updated_at  TIMESTAMP DEFAULT NOW()
);
ALTER TABLE dev_tasks ADD COLUMN IF NOT EXISTS attachment_url TEXT;
ALTER TABLE dev_tasks ADD COLUMN IF NOT EXISTS telegram_message_id BIGINT;
ALTER TABLE dev_tasks ADD COLUMN IF NOT EXISTS result TEXT;
ALTER TABLE dev_tasks ADD COLUMN IF NOT EXISTS test_steps TEXT;

CREATE TABLE IF NOT EXISTS dev_feedback (
  id           SERIAL PRIMARY KEY,
  task_tag     VARCHAR(50) NOT NULL,
  feedback     TEXT NOT NULL,
  from_chat_id BIGINT,
  created_at   TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS telegram_bot_messages (
  id         SERIAL PRIMARY KEY,
  chat_id    BIGINT NOT NULL,
  message_id BIGINT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
