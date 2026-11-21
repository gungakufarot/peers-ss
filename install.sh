#!/bin/sh
# Peers-SS installer for OpenWrt 24.10 + podkop 0.7.24
#   new contour:  wget -qO- https://raw.githubusercontent.com/gungakufarot/peers-ss/main/install.sh | sh
#   join:         wget -qO- https://raw.githubusercontent.com/gungakufarot/peers-ss/main/install.sh | sh -s -- --join PSS1.…
# Files are taken from the latest GitHub Release (not from main). PEERS_SS_TARBALL=<url|path> overrides (testing).
set -e

# whole script inside main(): a truncated download never runs half of it
main() {
REPO_CODE="gungakufarot/peers-ss"
JOIN=""
while [ $# -gt 0 ]; do
	case "$1" in
		--join) JOIN="$2"; shift 2 ;;
		--tarball) PEERS_SS_TARBALL="$2"; shift 2 ;;
		*) echo "unknown option: $1"; exit 1 ;;
	esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask() { printf '%s' "$1" >/dev/tty; read -r REPLY </dev/tty || REPLY=""; }

( exec </dev/tty ) 2>/dev/null || die "no terminal: run the installer in an interactive SSH session (ssh -t)"

# ---- 1. checks ----
. /etc/openwrt_release 2>/dev/null || die "not OpenWrt"
case "$DISTRIB_RELEASE" in 24.10.*) ;; *) die "OpenWrt 24.10.x required (found $DISTRIB_RELEASE)";; esac
say "OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)"

PODKOP_VER=$(opkg status podkop 2>/dev/null | sed -n 's/^Version: //p')
[ -n "$PODKOP_VER" ] || die "podkop is not installed. Install podkop 0.7.24 first (https://github.com/itdoginfo/podkop), then run this installer again."
case "$PODKOP_VER" in *0.7.24*) ;; *) say "WARNING: podkop $PODKOP_VER found, Peers-SS is tested with 0.7.24";; esac
/etc/init.d/podkop enabled 2>/dev/null || die "podkop is installed but not enabled (/etc/init.d/podkop enable && /etc/init.d/podkop start)"
pidof sing-box >/dev/null 2>&1 || say "WARNING: sing-box is not running now — podkop will be (re)started when the link is applied"

need=""
for p in ucode rpcd-mod-ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-digest curl; do
	opkg status "$p" 2>/dev/null | grep -q '^Status:.*installed' || need="$need $p"
done
if ! opkg list-installed 2>/dev/null | grep -q '^uencrypt-'; then
	# pick the crypto backend the firmware already uses (spec §3: mbedtls or wolfssl)
	if opkg list-installed | grep -q '^libustream-wolfssl\|^libwolfssl'; then need="$need uencrypt-wolfssl"; else need="$need uencrypt-mbedtls"; fi
fi
FREE_KB=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$FREE_KB" ] || FREE_KB=$(df -k / | awk 'NR==2{print $4}')
[ "${FREE_KB:-0}" -ge 1024 ] || die "not enough free flash (${FREE_KB} KB, need 1 MB)"
if [ -n "$need" ]; then
	say "Missing packages:$need"
	ask "Install them with opkg now? [Y/n] "
	case "$REPLY" in n|N) die "required packages missing";; esac
	opkg update >/dev/null || die "opkg update failed"
	# shellcheck disable=SC2086
	opkg install $need || die "opkg install failed"
	FREE_KB=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')
	[ "${FREE_KB:-0}" -ge 512 ] || die "not enough free flash after installing packages (${FREE_KB} KB)"
fi

# ---- 2. files from the latest release ----
TMPD=$(mktemp -d /tmp/peers-ss-inst.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
if [ -z "$PEERS_SS_TARBALL" ]; then
	TAG=$(curl -fsSL "https://api.github.com/repos/$REPO_CODE/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$TAG" ] || die "cannot find the latest release of $REPO_CODE"
	PEERS_SS_TARBALL="https://github.com/$REPO_CODE/releases/download/$TAG/peers-ss-$TAG.tar.gz"
	PEERS_SS_SUMS="https://github.com/$REPO_CODE/releases/download/$TAG/SHA256SUMS"
	say "Release $TAG"
fi
case "$PEERS_SS_TARBALL" in
	http*) curl -fsSL -o "$TMPD/p.tgz" "$PEERS_SS_TARBALL" || die "download failed: $PEERS_SS_TARBALL"
		if [ -n "$PEERS_SS_SUMS" ]; then
			curl -fsSL -o "$TMPD/SUMS" "$PEERS_SS_SUMS" || die "cannot download SHA256SUMS"
			want=$(grep " peers-ss-$TAG.tar.gz\$" "$TMPD/SUMS" | cut -d' ' -f1)
			have=$(sha256sum "$TMPD/p.tgz" | cut -d' ' -f1)
			[ -n "$want" ] && [ "$want" = "$have" ] || die "checksum mismatch for peers-ss-$TAG.tar.gz"
		fi ;;
	*) cp "$PEERS_SS_TARBALL" "$TMPD/p.tgz" ;;
esac
mkdir "$TMPD/root"
tar -xzf "$TMPD/p.tgz" -C "$TMPD/root" || die "bad archive"
[ -x "$TMPD/root/usr/bin/peers-ss" ] || die "archive does not contain usr/bin/peers-ss"
/etc/init.d/peers-ss stop 2>/dev/null || true
KEEP_CFG=""
[ -f /etc/config/peers-ss ] && KEEP_CFG=1
# previous version's code is replaced as a whole
rm -rf /usr/share/peers-ss
( cd "$TMPD/root" && find . -type f ! -path ./etc/config/peers-ss ) > "$TMPD/list"
while read -r f; do
	mkdir -p "/$(dirname "$f")" && cp "$TMPD/root/$f" "/$f" || die "copying $f failed (flash full?) — run the installer again"
done < "$TMPD/list"
[ -n "$KEEP_CFG" ] || cp "$TMPD/root/etc/config/peers-ss" /etc/config/peers-ss
chmod 755 /usr/bin/peers-ss /etc/init.d/peers-ss
# keep settings across sysupgrade (spec §3)
for f in /etc/config/peers-ss /etc/peers-ss/; do
	grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd reload 2>/dev/null || true
say "Peers-SS $(/usr/bin/peers-ss version) files installed"

# ---- 3. interactive part (ucode) ----
if [ -n "$JOIN" ]; then
	PEERS_SS_JOIN="$JOIN" /usr/bin/peers-ss wizard </dev/tty
else
	/usr/bin/peers-ss wizard </dev/tty
fi
}

main "$@"
