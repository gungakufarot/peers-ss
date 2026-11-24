#!/bin/sh
# Peers-SS service loop. Like podkop, nothing heavy stays in memory: the resident part is this shell (~1 MB);
# every check is a short-lived `peers-ss tick` process whose memory goes back to the system when it exits.
# The interval comes from the contour settings (written by the tick), 45 s by default (spec §5).
# procd stops the service with SIGTERM to this shell: the running tick goes down with it (no orphan writing
# to GitHub or restarting podkop after "stop"). ucode catches SIGTERM and may defer it while blocked in
# popen/sleep, so the tick gets 3 s and then SIGKILL (procd itself waits 5 s). Tick errors go to stderr -> logread.
c=
stop() {
	[ -n "$c" ] || exit 0
	kill "$c" 2>/dev/null
	for n in 1 2 3; do kill -0 "$c" 2>/dev/null || exit 0; sleep 1; done
	kill -9 "$c" 2>/dev/null
	exit 0
}
trap stop TERM INT
while :; do
	t0=$(cut -d. -f1 /proc/uptime)
	/usr/bin/peers-ss tick >/dev/null &
	c=$!; wait $c; c=
	i=$(cat /tmp/peers-ss/interval 2>/dev/null)
	case "$i" in ''|*[!0-9]*) i=45 ;; esac
	i=${i#"${i%%[!0]*}"}
	[ -z "$i" ] || [ "$i" -lt 15 ] && i=15
	[ "$i" -gt 3600 ] && i=3600
	s=$((i - ($(cut -d. -f1 /proc/uptime) - t0)))
	[ "$s" -lt 5 ] && s=5
	sleep "$s" &
	c=$!; wait $c; c=
done
