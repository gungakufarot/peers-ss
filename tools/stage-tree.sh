#!/bin/sh
# Copy files/ into <out> and put the LuCI views into a versioned folder view/peers-ss/<vdir>/ (menu points to it),
# so browsers never mix cached JS of different Peers-SS versions (LuCI's ?v= only follows the LuCI version).
# usage: tools/stage-tree.sh <out> <version-or-tag>
set -e
OUT=$1; V=$2
[ -n "$OUT" ] && [ -n "$V" ] || { echo "usage: $0 <out> <version>"; exit 1; }
cd "$(dirname "$0")/.."
VDIR=v$(printf '%s' "$V" | sed 's/^v//; s/[^A-Za-z0-9]/_/g')
rm -rf "$OUT"; mkdir -p "$OUT"
cp -a files/. "$OUT/"
VIEW="$OUT/www/luci-static/resources/view/peers-ss"
mkdir -p "$VIEW/$VDIR"
for f in "$VIEW"/*.js; do sed "s/__V__/$VDIR/g" "$f" > "$VIEW/$VDIR/$(basename "$f")"; rm "$f"; done
sed -i "s/__V__/$VDIR/g" "$OUT/usr/share/luci/menu.d/luci-app-peers-ss.json"
echo "$VDIR"
