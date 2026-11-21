// Peers-SS: HTTP via curl. Secrets (Authorization) go through a 0600 curl config file, never argv.
'use strict';

import * as fs from 'fs';
import { RUN, q, mkdirp, sh, uniq_name } from './util.uc';

// Fallback resolver: the router's own DNS goes through podkop's sing-box; if that is down or flaky
// (curl exit 6) we resolve API/GitHub hosts directly via public resolvers and retry with --resolve.
const FALLBACK_DNS = ['1.1.1.1', '8.8.8.8', '9.9.9.9', '77.88.8.8'];

function resolve_direct(host) {
	let cf = RUN + '/dns-' + replace(host, /[^a-z0-9.-]/g, '_');
	let st = fs.stat(cf);
	if (st && time() - st.mtime < 600) { let ip = trim(fs.readfile(cf) ?? ''); if (ip) return ip; }
	for (let srv in FALLBACK_DNS) {
		let r = sh(sprintf('nslookup %s %s 2>/dev/null | sed -n "/^Name:/,\\$s/^Address[^:]*: *\\([0-9.]*\\)$/\\1/p" | head -1', q(host), srv));
		let ip = trim(r.out);
		if (match(ip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) { fs.writefile(cf, ip); return ip; }
	}
	return null;
}

// opts: { method, headers: {k:v}, body (string), timeout (s), proxy (socks5h://...), connect_timeout }
// returns { status, headers: {lowercased: value}, body, err }
function request(url, opts) {
	opts ??= {};
	mkdirp(RUN + '/http');
	let base = RUN + '/http/' + uniq_name();
	let cfg = base + '.cfg', hdr = base + '.hdr', out = base + '.out', inp = base + '.in';
	let lines = [];
	for (let k, v in opts.headers ?? {})
		push(lines, sprintf('header = "%s: %s"', k, replace(replace('' + v, /[\r\n]/g, ''), /["\\]/g, (c) => '\\' + c)));
	fs.writefile(cfg, join('\n', lines) + '\n');
	fs.chmod(cfg, 0600);
	let cmd = sprintf('curl -sS -K %s -X %s -D %s -o %s -w %%{http_code} --max-time %d --connect-timeout %d',
		q(cfg), q(opts.method ?? 'GET'), q(hdr), q(out), opts.timeout ?? 20, opts.connect_timeout ?? 8);
	if (opts.body != null) {
		fs.writefile(inp, opts.body);
		fs.chmod(inp, 0600);
		cmd += ' --data-binary @' + q(inp);
	}
	if (opts.proxy) cmd += ' -x ' + q(opts.proxy);
	let r = sh(cmd + ' ' + q(url));
	if (r.code == 6 && !opts.proxy) {
		let m = match(url, /^https:\/\/([^\/:]+)(:([0-9]+))?/);
		let ip = m ? resolve_direct(m[1]) : null;
		if (ip) r = sh(sprintf('%s --resolve %s %s', cmd, q(m[1] + ':' + (m[3] ?? '443') + ':' + ip), q(url)));
	}
	let res = { status: +r.out || 0, headers: {}, body: fs.readfile(out) ?? '', err: r.code ? 'curl exit ' + r.code : null };
	let raw = fs.readfile(hdr) ?? '';
	// keep only the last header block (after redirects/100-continue)
	let blocks = split(raw, /\r?\n\r?\n/);
	for (let b in blocks) if (length(trim(b))) raw = b;
	for (let l in split(raw, /\r?\n/)) {
		let i = index(l, ':');
		if (i > 0) res.headers[lc(trim(substr(l, 0, i)))] = trim(substr(l, i + 1));
	}
	for (let f in [cfg, hdr, out, inp]) fs.unlink(f);
	return res;
}

function json_body(res) {
	try { return json(res.body); } catch (e) { return null; }
}

// RFC 1123 date -> unix seconds (GitHub "Date" header)
const MON = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };
function parse_http_date(s) {
	let m = match(s ?? '', /(\d+) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d)/);
	if (!m) return null;
	let y = +m[3], mo = MON[m[2]], d = +m[1];
	// days from civil (Howard Hinnant)
	let yy = mo <= 2 ? y - 1 : y;
	let era = int(yy / 400);
	let yoe = yy - era * 400;
	let mp = (mo + 9) % 12; // March = 0
	let doy = int((153 * mp + 2) / 5) + d - 1;
	let doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	let days = era * 146097 + doe - 719468;
	return days * 86400 + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]);
}

export { request, json_body, parse_http_date, resolve_direct };
