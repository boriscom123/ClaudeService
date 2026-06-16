// Главное меню — INLINE-кнопки (callback_query), а не ReplyKeyboard.
// Причина: нажатие кнопки нижней ReplyKeyboard клиент Telegram отправляет
// как reply на сообщение-владельца клавиатуры → каждое сообщение бота
// выглядело «отвеченным». Inline-кнопки шлют callback и reply не создают.
const MAIN_MENU_INLINE = {
  inline_keyboard: [
    [{ text: '📋 Задачи', callback_data: 'm:tasks' }, { text: '🧪 На тестировании', callback_data: 'm:testing' }],
    [{ text: '💻 Статус VPS', callback_data: 'm:vps' }, { text: '🔀 Фиксировать git', callback_data: 'm:git' }],
    [{ text: '🗑️ Очистить чат', callback_data: 'm:clear' }, { text: '❓ Помощь', callback_data: 'm:help' }],
  ],
};

// Нижняя ReplyKeyboard приветствия. Пока одна кнопка — ❓ Помощь.
// Отправляется ОДИН раз с приветствием (send() её не переотправляет),
// поэтому нажатие помечается reply на приветствие — известное поведение
// ReplyKeyboard, не лечится; для «без reply» нужен inline.
const WELCOME_KEYBOARD = {
  keyboard: [
    ['📋 Задачи', '💻 Информация о VPS'],
    ['🔀 Фиксация на git', '🗑️ Очистить чат'],
    ['❓ Справка'],
  ],
  resize_keyboard: true,
  is_persistent: true,
};

function taskInlineKeyboard(tag) {
  return {
    inline_keyboard: [[
      { text: '✅ Закрыть', callback_data: `ok:${tag}` },
      { text: '🔄 Вернуть', callback_data: `reject:${tag}` },
    ]],
  };
}

module.exports = { MAIN_MENU_INLINE, WELCOME_KEYBOARD, taskInlineKeyboard };
