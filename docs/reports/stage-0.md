# Этап 0 — подготовка (выполнено агентом по поручению владельца)

- Бэкапы `sysupgrade -b` роутеров 1 и 2 → `/root/peers-ss-backups/` на хосте (0600, вне репозитория).
- Роутер 1: поставлены `sing-box curl jq kmod-nft-tproxy coreutils-base64 bind-dig uencrypt-mbedtls` из фида 24.10 и
  `podkop`/`luci-app-podkop`/`luci-i18n-podkop-ru` 0.7.24 из GitHub Release `itdoginfo/podkop` (ipk `all`).
  Существующий `/etc/config/podkop` сохранён (opkg положил новый как `podkop-opkg`), копия — `/root/podkop.before-install`.
- `podkop.settings.routing_excluded_ips = 192.168.200.127` (хост администратора).
- Запуск podkop со страховкой `/root/podkop-deadman.sh`: если DNS через dnsmasq не отвечает 60 с — `podkop stop`. Отработала: «dns ok».
- **Не сделано по решению владельца:** ссылка Tailscale в `KCA.remote_domain_lists` оставлена (KCA не трогаем). podkop пишет в лог
  «… is not a valid domain» — известный шум.
- Конфиг `Test-conf` есть (id 344883, локация NL, протокол `vless-2410`).
