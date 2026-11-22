#!/bin/sh
# Dev deploy of files/ to a test router: tools/deploy.sh root@192.168.200.1 [--test-mode]
# Never overwrites /etc/config/peers-ss if it exists. --test-mode sets test_patch_allow=Test-conf (344883).
set -e
H=$1; [ -n "$H" ] || { echo "usage: $0 user@host [--test-mode]"; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$ROOT/tools/stage-tree.sh" "$T/tree" "dev$(date +%s)" >/dev/null
cd "$T/tree"
tar -czf - --exclude=etc/config/peers-ss . | ssh "$H" 'rm -rf /www/luci-static/resources/view/peers-ss /tmp/luci-indexcache* /tmp/luci-modulecache; tar -xzf - -C / && chmod 755 /usr/bin/peers-ss /etc/init.d/peers-ss 2>/dev/null; true'
ssh "$H" '[ -f /etc/config/peers-ss ] || cat > /etc/config/peers-ss' < etc/config/peers-ss
if [ "$2" = "--test-mode" ]; then
  ssh "$H" 'uci -q get peers-ss.main.test_patch_allow >/dev/null || { uci add_list peers-ss.main.test_patch_allow=344883; uci commit peers-ss; }'
fi
echo "deployed to $H"
