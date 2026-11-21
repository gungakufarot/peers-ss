# PROGRESS — Peers-SS

Обновляется после каждого этапа. По этому файлу работу можно продолжить без участия владельца.

## Где сейчас
Этапы 0–5 завершены (отчёт stage-5). Текущий: **этап 6** — установщик (`install.sh` + `peers-ss wizard`), токен (set/replace/delete), `config assign`. Сборка архива: `tools/build.sh <tag>`.

Тестовый контур: `c8a9d4463c410` «Тест» в `gungakufarot/peers-ss-state`, группа g1 / среда e1 / Test-conf `91408:344883`.
Роутеры: r1 `r916f3a17` (openwrt-1, токен), r2 `r2b4ed69e` (openwrt-2, токен, DNS sing-box нестабилен), r3 VM `r98cd07a6` (openwrt-3, ведомый).
Пароль контура и ключ бота — `/root/peers-ss-secrets-test.env` (вне репо). VM: `/root/peers-ss-vm/start.sh`, ssh-алиас `router3` (127.0.0.1:2222).
Тестовые утилиты: `tools/deploy.sh <host> [--test-mode]`, `tools/check-order.py` (ucode без hoisting), `tools/tests/`.
В режиме теста на роутерах `peers-ss.main.test_patch_allow=344883`. Правила nft тестов — таблица `inet pss_test` (удалять после теста).

## Сделано
- `.gitignore`, `AGENTS.md`, `CLAUDE.md`; публичный репозиторий `gungakufarot/peers-ss`.
- Бэкапы `sysupgrade -b` обоих роутеров: `/root/peers-ss-backups/` на хосте (вне репозитория).

## Стенд
| Роль | Адрес | Примечание |
| --- | --- | --- |
| Роутер 1 (основной тестовый) | `ssh root@192.168.200.1` | mediatek/filogic aarch64; хост 192.168.200.127 в Routing Excluded IPs; секцию `KCA` не трогать |
| Роутер 2 | `ssh root@100.100.205.51` (tailscale) | секцию `main` можно удалять |
| Роутер 3 | VM OpenWrt 24.10.8 x86 на хосте (qemu) | создаётся на этапе 8 |
| Сервер бота | `ssh root@169.58.31.113` | только своя служба и папка; без Caddy/портов |

## Решения владельца
- KCA не трогать (даже ссылку Tailscale в `remote_domain_lists`); ложные ошибки диагностики от KCA — известные.
- Админ бота: chat_id 5800245964; тест-клиент — тот же аккаунт через telegram-mcp (HTTP 127.0.0.1:8765), после теста отвязать.
- PATCH-гард на Test-conf (344883) — настройка тестового режима, не константа; в релизе выключен.
- Токен GitHub: проверено действиями — только Contents (admin-запросы → 403).
- Секреты: сейчас `/root/peers-ss-secrets.env` (свободный текст); позже владелец создаст `/root/peers-ss-secrets-end.env` в формате KEY=VALUE
  (`STEALTHSURF_API_KEY`, `GITHUB_STATE_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ADMIN_CHAT_ID`, `CONTOUR_PASSWORD`, `STATE_REPO`). Скрипты читают его, если он есть.

- Этап 0: podkop 0.7.24 на роутере 1 (отчёт `docs/reports/stage-0.md`).
- Этап 1: разведка → `docs/RECON.md`, отчёт `docs/reports/stage-1.md`.

- Этап 2: клиент API, CLI, пинг (отчёт stage-2).
- Этап 3: хранилище GitHub + шифрование (отчёт stage-3). Тестовые файлы `test-stage3/` в state-репо можно удалить в конце.
- Этап 4: podkop apply/diag/latency (отчёт stage-4). На роутере 1 секция `peers_ss` с Test-conf.

- Этап 5: служба, ротация, доставка; все проверки (а)–(д) и «GitHub недоступен» пройдены (отчёт stage-5).

## Дальше
Этапы 0 → 10 по разделу 11 ТЗ.
