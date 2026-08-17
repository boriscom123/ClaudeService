// Главное меню — INLINE-кнопки (callback_query), а не ReplyKeyboard.
// Причина: нажатие кнопки нижней ReplyKeyboard клиент Telegram отправляет
// как reply на сообщение-владельца клавиатуры → каждое сообщение бота
// выглядело «отвеченным». Inline-кнопки шлют callback и reply не создают.
const MAIN_MENU_INLINE = {
  inline_keyboard: [
    [{ text: '💻 Статус VPS', callback_data: 'm:vps' }, { text: '🔀 Фиксировать git', callback_data: 'm:git' }],
    [{ text: '🗑️ Очистить чат', callback_data: 'm:clear' }],
    [{ text: '📁 Проект', callback_data: 'm:project' }, { text: '🔄 Перезагрузить VPS', callback_data: 'm:reboot' }],
    [{ text: '❓ Помощь', callback_data: 'm:help' }],
  ],
};

// Иконки проектов по id (дефолт — 📁). Имена берём из cs:projects.
const PROJECT_ICONS = { game: '🎮', cm: '💬', uq: '🎫', cs: '🤖' };

// Меню выбора проекта строится ДИНАМИЧЕСКИ из Redis-хэша cs:projects (id→имя),
// который пишет мост из scripts/projects.sh. Добавление проекта не требует
// пересборки devbot. Возвращает null, если реестр пуст (мост не запущен).
// В тексте кнопки — иконка, имя и КОД проекта; текущий помечается галочкой.
async function projectMenuInline(redis, current) {
  const map = await redis.hGetAll('cs:projects').catch(() => ({}));
  const ids = Object.keys(map || {}).sort();
  if (ids.length === 0) return null;
  return {
    inline_keyboard: ids.map(id => [{
      text: `${id === current ? '✅ ' : ''}${PROJECT_ICONS[id] || '📁'} ${map[id]} · ${id}`,
      callback_data: `proj:${id}`,
    }]),
  };
}

// Нижняя ReplyKeyboard приветствия.
// Отправляется ОДИН раз с приветствием (send() её не переотправляет),
// поэтому нажатие помечается reply на приветствие — известное поведение
// ReplyKeyboard, не лечится; для «без reply» нужен inline.
const WELCOME_KEYBOARD = {
  keyboard: [
    ['💻 Информация о VPS', '🔄 Перезагрузить VPS'],
    ['📁 Проект', '❓ Справка'],
  ],
  resize_keyboard: true,
  is_persistent: true,
};

module.exports = { MAIN_MENU_INLINE, WELCOME_KEYBOARD, projectMenuInline };
