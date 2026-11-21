# RECON — разведка (этап 1)

Дата: 2026-11-21. Пометки: **[факт]** — наблюдалось на роутере/в ответе API; **[код]** — прочитано в коде podkop 0.7.24, проверяется на этапе 4. Токенов и ссылок `vless://` в документе нет.

## Роутер 1 (192.168.200.1)
| Что | Факт |
| --- | --- |
| Прошивка | OpenWrt 24.10.8, `mediatek/filogic`, `aarch64_cortex-a53`, ОЗУ 234 МБ |
| Флеш | `/overlay` 60.9 МБ, свободно 24.3 МБ (после podkop); `/tmp` 117 МБ |
| podkop | 0.7.24-r1 (поставлен на этапе 0 из GitHub Release `itdoginfo/podkop` 0.7.24, ipk `all`), sing-box 1.12.22-r1 |
| Пакеты | `ucode`, `rpcd-mod-ucode` — были; `curl` 8.23, `jq`, `uencrypt-mbedtls` — поставлены на этапе 0 |
| ucode-модули | установлены: fs, uci, ubus, uloop, math, rtnl, nl80211, html. В фиде есть `ucode-mod-digest`, `ucode-mod-socket`, `ucode-mod-log` |
| uencrypt | `uencrypt [-d|-e] [-n] -k <hex key> [-i <hex iv>] [-c cipher]`; `aes-256-cbc` работает, GCM нет. **Ключ и IV видны в `/proc/*/cmdline` всем пользователям** (файл `-r--r--r--`); на роутере кроме root работают `dnsmasq`, `ntp`, `logd`, `network`, `ubus`. Другого способа передать ключ у uencrypt нет — риск принят и записан (ключ живёт в cmdline доли секунды) |
| ucode-mod-digest | **[факт]** установлен на этапе 1→2: функции `sha256, sha1, md5, sha384, sha512, *_file`; HMAC нет — HMAC-SHA256 собирается вручную. Размер `digest.so` 65 КБ (зависимость, не наш пакет) |
| ping | busybox `ping -c 2 -W 1` работает по имени хоста |
| TCP-замер | `curl -sk -o /dev/null -m 3 -w %{time_connect} https://host:port/` даёт время TCP-соединения на любом порту (схема `telnet://` в curl не собрана) |
| LAN | `br-lan` 192.168.200.1; хост 192.168.200.127 внесён в `podkop.settings.routing_excluded_ips` |
| `enable_output_network_interface` | `0` — запросы самого роутера идут мимо туннеля |

## podkop 0.7.24 — как устроен
- UCI: `config settings 'settings'` + секции `config section '<имя>'`. Для прокси-секции:
  `connection_type 'proxy'`, `proxy_config_type 'url'`, `proxy_string 'vless://…'`; `mixed_proxy_enabled '1'`, `mixed_proxy_port '<порт>'`.
- «Сохранить и применить» в LuCI = `uci commit` через rpcd → procd-триггер `config.change` → **`/etc/init.d/podkop restart`**
  (`procd_add_config_trigger "config.change" podkop … restart`). Эквивалент из shell: `uci commit podkop && /etc/init.d/podkop restart`
  (или `reload_config`). `restart` = `podkop stop` (+ восстановление dnsmasq) + `podkop start` (+ перенастройка dnsmasq).
  `reload` = только пересборка sing-box без dnsmasq. Peers-SS повторяет LuCI: `uci commit` + `restart`.
- Тег outbound секции: `<секция>-out` (`get_outbound_tag_by_section`).
- **[факт]** Задержка «Применить»: `PROCD_RELOAD_DELAY = badwan_reload_delay` (по умолчанию 2000 мс); LuCI JS (podkop.js, section.js, settings.js)
  дополнительных вызовов при сохранении не делает. Триггер: `procd_add_config_trigger "config.change" podkop /etc/init.d/podkop restart 'on_config_change'`.
- **[факт]** Прокси-секции на роутере 1 нет (только `settings` и `KCA`) — Peers-SS **создаёт** секцию `peers_ss` (режим А установщика).
  Раскладка опций подтверждена на роутере 2 (`connection_type 'proxy'`, `proxy_config_type 'url'`, `proxy_string`).
- `#имя` в хвосте ссылки: ссылки StealthSurf уже содержат `#…`; podkop парсит ссылку в sing-box outbound, фрагмент — только метка.
  Peers-SS хвост **не меняет** (ТЗ разрешает, но не требует) — вставляем ссылку как есть.
- **[факт]** Clash API: всегда включён, `192.168.200.1:9090`. **[код]** Адрес = `get_service_listen_address`: сначала `settings.service_listen_address`,
  иначе IP интерфейса `lan`; при `enable_yacd`+`enable_yacd_wan_access` — `0.0.0.0` с Bearer-ключом; без IP — `127.0.0.1` (только Clash).
  Задержка: `podkop clash_api get_proxy_latency <секция>-out [timeout_ms]` → JSON `{delay}` (URL теста `https://www.gstatic.com/generate_204`).
- **[код] mixed_proxy слушает LAN-адрес**, а не `127.0.0.1` (тот же `get_service_listen_address`); если адрес не определён — mixed-прокси
  **не создаётся** (podkop:1273-1276). Peers-SS берёт адрес так же, как podkop (`service_listen_address` → IP `lan`), не зашивает.
  Проверка туннеля: `curl -x socks5h://<адрес>:<порт> https://www.gstatic.com/generate_204`.
- **Риск (записан):** Clash API и mixed-прокси на LAN **без аутентификации** (Bearer только при WAN-доступе YACD, podkop:2280): любой
  хост LAN может пользоваться туннелем и переключать селекторы. Это поведение podkop; Peers-SS включает mixed-прокси только у своей секции.
- **[факт+код]** Вкладка «Диагностика» LuCI (main.js:2564-2784) запускает `podkop check_dns_available`, `check_sing_box`, `check_nft_rules`,
  `check_fakeip` (все JSON); проверка outbound — `clash_api get_proxy_latency <tag> 5000` / `get_group_latency <tag> 10000` (main.js:3880-3913);
  плюс `get_system_info`, действия `global_check`, `check_logs`, `show_sing_box_config`. `get_status`, `get_sing_box_status`,
  `clash_api get_proxies` — это дашборд. Браузерная часть FakeIP-проверки (fetch к `fakeip.podkop.fyi`) с роутера не воспроизводится —
  Peers-SS повторяет только роутерную часть.
- **[факт]** Роутер 1 после старта: `check_dns_available`, `check_sing_box` — всё 1; `check_nft_rules` — всё 1, кроме `rules_mangle_counters: 0`
  (трафика через прокси ещё нет); `check_fakeip` = true. Peers-SS не считает нулевые счётчики ошибкой.
- Секция `KCA` (vpn, интерфейс `kca` отсутствует) содержит в `remote_domain_lists` ссылку входа Tailscale — podkop пишет в лог мусор
  «… is not a valid domain». По решению владельца KCA не трогаем; на проверки управляемой секции это не влияет.

## API StealthSurf — реальные ответы
- `GET /profile` → `data.id` (ID аккаунта для привязок), `email` и др.
- `GET /configs` → массив; у Test-conf поля: `id, server_id, connection_url, location_id, protocol, is_extended_settings_enabled, title,
  is_online, expires_at, created_at, auto_renewal, auto_renewal_days, ipv6`. **`xray_config` и `flags` в ответе нет.**
  Отдельного GET одного конфига нет (`/configs/:id` → 404).
- **Протокол всех конфигов — `vless-2410`**, а не `vless`; ссылка `vless://…` (tcp, reality, flow `xtls-rprx-vision`, fp `chrome`, порт 43000).
  Решение: «vless-конфиг» = ссылка `vless://`; в `PATCH` и `available-servers` передаём `protocol` самого конфига (`vless-2410`).
  `available-servers` на `vless` и `vless-2410` отдаёт одинаковые списки.
- Лимиты: заголовки `X-RateLimit-Limit/Remaining/Reset`, `Retry-After` при 429.
- `GET /locations` — 28 локаций, у всех `tags` либо `[]`, либо `['virtual']`:
  - «Умная» — **`code: "RB"`**, `title` начинается с «Умная локация» (id 18 активна, id 22 «(Восток)» неактивна);
  - «Россия» — **`code: "RU"`** (id 12 «Россия», id 29 «Россия (игровая)», неактивна).
  - Правило исключения: `code ∈ {RB, RU}` или `title` начинается с «Умная». Настройка `exclude_locations: ["smart","RU"]`, где `smart` → `RB`/«Умная».
- **`ping_ip` — это `host:port`** (например `ping-nl.stealthsurf.network:2053`), не IP; бывает `null`. Многие «virtual»-локации
  делят один `ping-nl` → одинаковый пинг. Замер: ICMP по хосту, при неудаче — время TCP к `host:port`.
- `GET /configs/available-servers?location_id=&protocol=` → `[{id, ip, available_slots}]` до 5; бывает `[]` (например, для текущей
  локации NL и для KZ). Серверы пингуем по `ip`.
- Флаги для `PATCH`: в API их читать неоткуда. Решение: брать из `xray_config`, если он когда-нибудь придёт; иначе выводить из ссылки:
  `security != reality` → `disable_reality: true`; `type = xhttp` → `use_xhttp`; `type = grpc` → `use_grpc`; `fp` не `chrome` → `randomize_fingerprint`;
  `is_extended_settings_enabled` → `use_extended_settings`. Прочие флаги (warp, DNS, фильтры, torrent) не видны — **известное ограничение**.
- `cantChangeSettings` в ответах не встречается; обрабатываем по факту ошибки `PATCH` (`BAD_REQUEST` с этим текстом) → алерт.

## Отклонения от ТЗ (решения владельца)
- §11 этап 0 / §7: ссылку Tailscale из `KCA.remote_domain_lists` **не убираем** — владелец запретил трогать KCA.
- §6: флаги для `PATCH` в API не читаются — передаём только выводимые из ссылки; прочие могут сброситься (ограничение API).
- Вывод ключа — многократный SHA-256 по ТЗ (20000 итераций), а не PBKDF2/scrypt: стойкость упирается в силу пароля контура.

## Роутер 2 (100.100.205.51, tailscale)
OpenWrt 24.10.8, тот же target; podkop 0.7.24, sing-box 1.12.22, curl, jq уже стоят; `uencrypt` нет; свободно 24 МБ.
Секция `main` (proxy, ссылка с `#…`) — владелец разрешил удалить (без бэкапа). podkop на роутере 2 сейчас остановлен (`shutdown_correctly=1`, sing-box не слушает).

## Вывод для реализации
- Зависимости: `ucode`, `rpcd-mod-ucode`, `ucode-mod-fs/uci/ubus` (есть), **`ucode-mod-digest`** (SHA-256/HMAC для вывода ключа и
  целостности — `uencrypt` даёт только CBC без аутентификации), `curl`, `uencrypt-*`.
- Шифрование: AES-256-CBC (`uencrypt`) + HMAC-SHA256 (encrypt-then-MAC), ключи выводятся из пароля и соли контура многократным SHA-256.
