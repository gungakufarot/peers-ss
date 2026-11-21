// Peers-SS: common helpers (logging, shell, files, time)
'use strict';

import * as fs from 'fs';

const RUN = '/tmp/peers-ss';
const ETC = '/etc/peers-ss';

function q(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function mkdirp(path) {
	let parts = split(path, '/'), cur = '';
	for (let p in parts) {
		if (p == '') continue;
		cur += '/' + p;
		if (!fs.stat(cur)) fs.mkdir(cur, 0700);
	}
}

// run shell command, return { code, out }
function sh(cmd) {
	let p = fs.popen(cmd + ' 2>/dev/null', 'r');
	if (!p) return { code: -1, out: '' };
	let out = p.read('all') ?? '';
	let code = p.close();
	return { code, out };
}

function readjson(path) {
	let s = fs.readfile(path);
	if (s == null) return null;
	try { return json(s); } catch (e) { return null; }
}

// atomic write (tmp + rename); mode 0600 for anything under /etc/peers-ss
function writefile(path, data, mode) {
	let tmp = path + '.tmp' + time();
	if (!fs.writefile(tmp, data)) return false;
	fs.chmod(tmp, mode ?? 0600);
	return fs.rename(tmp, path);
}

function writejson(path, obj) {
	return writefile(path, sprintf('%J', obj));
}

// writes only if content differs (protects flash)
function writejson_if_changed(path, obj) {
	let s = sprintf('%J', obj);
	if (fs.readfile(path) == s) return false;
	return writefile(path, s);
}

// secret-aware log redaction: tokens, vless links, github pats
function redact(s) {
	s = '' + s;
	s = replace(s, /vless:\/\/[^ "'\n]*/g, 'vless://<hidden>');
	s = replace(s, /stlth_[A-Za-z0-9_]+/g, 'stlth_<hidden>');
	s = replace(s, /github_pat_[A-Za-z0-9_]+/g, 'github_pat_<hidden>');
	s = replace(s, /gh[pousr]_[A-Za-z0-9]{20,}/g, 'gh*_<hidden>');
	s = replace(s, /PSS1\.[A-Za-z0-9_-]+/g, 'PSS1.<hidden>');
	return s;
}

let log_echo = false;
function set_log_echo(v) { log_echo = v; }

// event journal in RAM (ring of 200 lines) + syslog
function log(level, msg) {
	msg = redact(msg);
	system('logger -t peers-ss ' + q('[' + level + '] ' + msg));
	mkdirp(RUN);
	let f = RUN + '/events.log';
	let line = sprintf('%d %s %s\n', time(), level, msg);
	let cur = fs.readfile(f) ?? '';
	let lines = split(cur, '\n');
	if (length(lines) > 200) cur = join('\n', slice(lines, -150));
	fs.writefile(f, cur + line);
	if (log_echo) warn(line);
}

function sleep_s(s) { sleep(int(s * 1000)); }

function rand_hex(nbytes) {
	let b = fs.readfile('/dev/urandom', nbytes);
	if (b == null || length(b) != nbytes) die('urandom failed');
	return hexenc(b);
}

// parse vless link: host, port, params (never logged)
function parse_vless(url) {
	let m = match(url, /^vless:\/\/([^@]+)@(\[[^\]]+\]|[^:\/?#]+):([0-9]+)(\?[^#]*)?(#.*)?$/);
	if (!m) return null;
	let host = m[2];
	if (substr(host, 0, 1) == '[') host = substr(host, 1, length(host) - 2);
	let params = {};
	if (m[4]) for (let kv in split(substr(m[4], 1), '&')) {
		let i = index(kv, '=');
		if (i > 0) params[substr(kv, 0, i)] = substr(kv, i + 1);
	}
	return { host, port: +m[3], params, frag: m[5] ? substr(m[5], 1) : '' };
}

function median(arr) {
	let a = sort([...arr], (x, y) => x - y);
	let n = length(a);
	if (!n) return null;
	return n % 2 ? a[n >> 1] : (a[n / 2 - 1] + a[n / 2]) / 2;
}

export { RUN, ETC, q, mkdirp, sh, readjson, writefile, writejson, writejson_if_changed, redact, log, set_log_echo, sleep_s, rand_hex, parse_vless, median };
