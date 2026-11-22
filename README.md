# Peers-SS

Сервис для OpenWrt 24.10 + podkop 0.7.24: держит назначенный конфиг StealthSurf (`vless://`) на роутерах клиента и при блокировке
за ~3–4 минуты переводит все роутеры с этим конфигом на сервер в локации с минимальным пингом. Общая точка — приватный репозиторий
GitHub (данные зашифрованы паролем контура). Telegram-бот (`bot/`) напоминает клиентам об окончании конфига и шлёт алерты администратору.

ТЗ: [docs/SPEC.md](docs/SPEC.md) · итоговый отчёт: [docs/reports/FINAL.md](docs/reports/FINAL.md)

## Установка
Нужно: OpenWrt 24.10.x, установленный и запущенный podkop 0.7.24. Остальное (`ucode-mod-digest`, `uencrypt`) установщик предложит сам.

Первый роутер нового контура:
```sh
wget -qO- https://raw.githubusercontent.com/gungakufarot/peers-ss/main/install.sh | sh
```
Следующие роутеры — командой из LuCI → Services → Peers-SS → «Добавить роутер»:
```sh
wget -qO- https://raw.githubusercontent.com/gungakufarot/peers-ss/main/install.sh | sh -s -- --join PSS1.…
```
(`--join -` — ввести код с клавиатуры, чтобы он не попал в историю shell.)

Файлы ставятся из последнего GitHub Release (проверка SHA256). Есть и `.ipk` (arch all).

## Командная строка
`peers-ss status | check | rotate [--dry-run] | token set|show|check|delete | github-token set | config assign | invite create|revoke|list | contour show | podkop status|diag | uninstall`

## Перед прошивкой роутера (sysupgrade)
Настройки Peers-SS сохраняются (`/etc/config/peers-ss`, `/etc/peers-ss/`). Пакеты (podkop, Peers-SS) после прошивки ставятся заново;
установщик узнаёт роутер и продолжает работу без ввода данных. Остановите podkop перед прошивкой (`/etc/init.d/podkop stop`),
иначе в сохранённом `/etc/config/dhcp` останется перенаправление DNS на sing-box и после прошивки у роутера не будет DNS до установки podkop.
