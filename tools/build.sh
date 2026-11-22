#!/bin/sh
# Build release artifacts into dist/: peers-ss-<tag>.tar.gz (files/ tree) and peers-ss_<ver>_all.ipk
# usage: tools/build.sh <tag e.g. v0.6.0>
set -e
TAG=${1:?usage: build.sh <tag>}
VER=${TAG#v}
cd "$(dirname "$0")/.."
OUT=dist; rm -rf "$OUT"; mkdir -p "$OUT/tree"
cp -a files/. "$OUT/tree/"
sed -i "s/^const VERSION = '[^']*';/const VERSION = '$VER';/" "$OUT/tree/usr/share/peers-ss/engine.uc"
chmod 755 "$OUT/tree/usr/bin/peers-ss" "$OUT/tree/etc/init.d/peers-ss"
( cd "$OUT/tree" && tar --owner=0 --group=0 --numeric-owner -czf "../peers-ss-$TAG.tar.gz" . )
# ipk (arch all): debian-binary + control.tar.gz + data.tar.gz, outer tar.gz (opkg format)
mkdir -p "$OUT/ipk/control"
SIZE=$(du -sk "$OUT/tree" | cut -f1)
cat > "$OUT/ipk/control/control" <<C
Package: peers-ss
Version: $VER
Depends: libc, ucode, rpcd-mod-ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-ubus, ucode-mod-digest, curl, podkop
Section: net
Architecture: all
Installed-Size: $((SIZE * 1024))
Maintainer: Peers-SS
Description: Keeps a StealthSurf vless config alive on OpenWrt+podkop: block detection, rotation, delivery to all routers
C
echo "/etc/config/peers-ss" > "$OUT/ipk/control/conffiles"
cat > "$OUT/ipk/control/postinst" <<'C'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
for f in /etc/config/peers-ss /etc/peers-ss/; do grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf; done
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
C
cat > "$OUT/ipk/control/prerm" <<'C'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
[ "$1" = "upgrade" ] && { /etc/init.d/peers-ss stop; exit 0; }
/usr/bin/peers-ss uninstall --from-opkg </dev/null 2>/dev/null || { /etc/init.d/peers-ss stop; /etc/init.d/peers-ss disable; }
exit 0
C
chmod 755 "$OUT/ipk/control/postinst" "$OUT/ipk/control/prerm"
echo "2.0" > "$OUT/ipk/debian-binary"
( cd "$OUT/ipk/control" && tar --owner=0 --group=0 --numeric-owner -czf ../control.tar.gz . )
( cd "$OUT/tree" && tar --owner=0 --group=0 --numeric-owner -czf ../ipk/data.tar.gz . )
( cd "$OUT/ipk" && tar --owner=0 --group=0 --numeric-owner -czf "../peers-ss_${VER}_all.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz )
rm -rf "$OUT/ipk" "$OUT/tree"
( cd "$OUT" && sha256sum "peers-ss-$TAG.tar.gz" "peers-ss_${VER}_all.ipk" > SHA256SUMS )
ls -l "$OUT"
