#!/bin/sh
# Dev deploy of files/ to a test router: tools/deploy.sh root@192.168.200.1 [--test-mode]
# Never overwrites /etc/config/peers-ss if it exists. --test-mode sets test_patch_allow=Test-conf (344883).
set -e
H=$1; [ -n "$H" ] || { echo "usage: $0 user@host [--test-mode]"; exit 1; }
cd "$(dirname "$0")/../files"
tar -czf - --exclude=etc/config/peers-ss . | ssh "$H" 'tar -xzf - -C / && chmod 755 /usr/bin/peers-ss /etc/init.d/peers-ss 2>/dev/null; true'
ssh "$H" '[ -f /etc/config/peers-ss ] || cat > /etc/config/peers-ss' < etc/config/peers-ss
if [ "$2" = "--test-mode" ]; then
  ssh "$H" 'uci -q get peers-ss.main.test_patch_allow >/dev/null || { uci add_list peers-ss.main.test_patch_allow=344883; uci commit peers-ss; }'
fi
echo "deployed to $H"
