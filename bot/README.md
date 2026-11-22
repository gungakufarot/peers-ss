# Peers-SS Telegram-бот

Python 3 (Ubuntu 24.04), long polling (входящие порты не нужны), SQLite, systemd, расписание `Europe/Moscow`.
Зависимость — системный `python3-cryptography` (в Ubuntu 24.04 есть по умолчанию).

## Установка
```sh
install -d -m 700 /opt/peers-ss-bot /etc/peers-ss-bot
install -m 600 peers_ss_bot.py pss_crypto.py /opt/peers-ss-bot/
install -m 600 /dev/null /etc/peers-ss-bot/env   # заполнить (см. ниже)
install -m 644 peers-ss-bot.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now peers-ss-bot
```

`/etc/peers-ss-bot/env` (права 600):
```
TELEGRAM_BOT_TOKEN=123456:AA...
TELEGRAM_ADMIN_CHAT_ID=...
BOT_KEY=<64 hex — тот же ключ бота, что в LuCI → Уведомления>
GITHUB_TOKEN=github_pat_...   # fine-grained, Contents на peers-ss-state (запись нужна только для ежедневной копии базы)
STATE_REPO=owner/peers-ss-state
BACKUP_KEY=<64 hex — отдельный ключ копии базы (openssl rand -hex 32); без него копия не делается>
DB_PATH=/opt/peers-ss-bot/bot.db
# REMIND_AT=21:00   STORE_POLL_S=300
```

## Что делает
- Клиент: `/start` → ник → администратору «Новый клиент: … — привязать?» → выбор контура → конфига → клиенту «Подключено: …, действует до …».
- Напоминания в 21:00 МСК: за 3 дня и каждый день, «сегодня», один раз «истёк». Карточка старше 24 ч — клиенту ничего, администратору алерт.
  Если сервер был выключен в 21:00 — сегодняшние напоминания уходят сразу после запуска, один раз.
- Алерты роутеров (`alerts/*.json`) пересылаются администратору сразу; «тихий режим» на N часов.
- Админка (`/admin`): клиенты (привязать/отвязать), заявки, конфиги всех контуров, роутеры, тихий режим.
- Раз в сутки зашифрованная (ключом бота) копия базы → `bot/backup.json` в хранилище.
- Проверка напоминаний на дату: `python3 peers_ss_bot.py --remind-now --today 2026-11-26` (с окружением службы).
