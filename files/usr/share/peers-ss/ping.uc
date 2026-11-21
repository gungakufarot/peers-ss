// Peers-SS: parallel latency probes directly (bypassing the tunnel; router traffic is not proxied by podkop).
// ICMP `ping -c 2 -W 1`; if ICMP is closed -> TCP connect time via curl.
'use strict';

import * as fs from 'fs';
import { RUN, q, mkdirp, sh } from './util.uc';

// targets: [{ host, port }] ; returns { "host:port": { ms, method } } (ms = null -> unreachable)
function probe(targets) {
	let dir = sprintf('%s/ping-%d', RUN, time());
	mkdirp(dir);
	let uniq = {}, script = 'cd ' + q(dir) + '\n', i = 0, keys = [];
	for (let t in targets) {
		let key = t.host + ':' + (t.port ?? '');
		if (uniq[key] != null) continue;
		uniq[key] = i;
		push(keys, key);
		let tcp = t.port
			? sprintf('t=$(curl -sk -o /dev/null -m 2 --connect-timeout 2 -w "%%{time_connect}" %s); ' +
			          'case "$t" in ""|0|0.0*0) ;; *) echo "tcp $t" > %d; exit;; esac; ',
			          q('https://' + (index(t.host, ':') >= 0 ? '[' + t.host + ']' : t.host) + ':' + t.port + '/'), i)
			: '';
		script += sprintf('( r=$(ping -c 2 -W 1 %s 2>/dev/null | sed -n "s#.*min/avg/max = [0-9.]*/\\([0-9.]*\\)/.*#\\1#p"); ' +
			'if [ -n "$r" ]; then echo "icmp $r" > %d; exit; fi; %secho "none" > %d ) &\n', q(t.host), i, tcp, i);
		i++;
	}
	script += 'wait\n';
	fs.writefile(dir + '/run.sh', script);
	sh('sh ' + q(dir + '/run.sh'));
	let res = {};
	for (let n = 0; n < length(keys); n++) {
		let l = split(trim(fs.readfile(dir + '/' + n) ?? 'none'), ' ');
		let ms = null;
		if (l[0] == 'icmp') ms = +l[1];
		else if (l[0] == 'tcp') ms = +l[1] * 1000;
		res[keys[n]] = { ms: ms != null ? int(ms * 10) / 10 : null, method: l[0] };
		fs.unlink(dir + '/' + n);
	}
	fs.unlink(dir + '/run.sh');
	fs.rmdir(dir);
	return res;
}

// "host:port" or "host" -> { host, port }
function split_hostport(s) {
	s = trim(s ?? '');
	if (s == '') return null;
	let m = match(s, /^\[([0-9a-fA-F:.]+)\](:([0-9]+))?$/);          // [v6]:port
	if (m) return { host: m[1], port: m[3] ? +m[3] : null };
	if (length(split(s, ':')) > 2) return { host: s, port: null };   // bare IPv6
	m = match(s, /^([^:]+)(:([0-9]+))?$/);                            // host[:port]
	if (m) return { host: m[1], port: m[3] ? +m[3] : null };
	return null;
}

// locations -> sorted [{ loc, ms, method }]
function rank_locations(locs) {
	let targets = [], map = [];
	for (let l in locs) {
		let hp = split_hostport(l.ping_ip);
		if (!hp) continue;
		push(targets, hp);
		push(map, [l, hp.host + ':' + (hp.port ?? '')]);
	}
	let r = probe(targets);
	let out = [];
	for (let m in map) push(out, { loc: m[0], ms: r[m[1]].ms, method: r[m[1]].method });
	return sort(out, (a, b) => (a.ms ?? 1e9) - (b.ms ?? 1e9));
}

// servers [{id, ip}] -> sorted [{ server, ms }]; TCP fallback to the vless port
function rank_servers(servers, port) {
	let targets = map(servers, (s) => ({ host: s.ip, port }));
	let r = probe(targets);
	let out = map(servers, (s) => ({ server: s, ms: r[s.ip + ':' + (port ?? '')].ms }));
	return sort(out, (a, b) => (a.ms ?? 1e9) - (b.ms ?? 1e9));
}

export { probe, split_hostport, rank_locations, rank_servers };
