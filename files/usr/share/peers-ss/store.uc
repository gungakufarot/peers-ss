// Peers-SS: shared state in a private GitHub repo via Contents API.
// Reads use If-None-Match (304 is free), writes carry the current `sha` (atomic compare-and-swap).
// On-repo file format: {"schema":1,"enc":"PSE1.…"} — only file names and schema number are plaintext.
'use strict';

import * as fs from 'fs';
import { request, json_body, parse_http_date } from './http.uc';
import { RUN, mkdirp, readjson, writejson, log, sleep_s } from './util.uc';
import { encrypt_json, decrypt_json, sha256_hex, git_blob_sha } from './crypto.uc';

const SCHEMA = 1;
const API = 'https://api.github.com';
const CACHE = RUN + '/store';

let ctx = { repo: null, token: null, key: null };
let clock_ref = null;   // { gh: unix from GitHub Date, mono: monotonic seconds }
let last_ok = 0;        // monotonic time of last successful GitHub response
let last_err = null;

function hexdec_rand() { let b = fs.readfile('/dev/urandom', 2); return (ord(b, 0) * 256 + ord(b, 1)) / 65535.0; }

function mono() { let c = clock(true); return c[0] + c[1] / 1e9; }

function init(repo, token, key) { ctx = { repo, token, key }; }
function set_key(key) { ctx.key = key; }

function note_date(res) {
	let d = parse_http_date(res.headers['date']);
	if (d) clock_ref = { gh: d, mono: mono() };
}

// GitHub time (for lock expiry); falls back to local clock if GitHub never answered
function now() {
	if (!clock_ref) return time();
	return int(clock_ref.gh + (mono() - clock_ref.mono));
}

function reachable_since() { return last_ok; }   // monotonic of last success (0 = never)
function last_error() { return last_err; }

function headers() {
	return { Authorization: 'Bearer ' + ctx.token, Accept: 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'peers-ss' };
}

function url(path) {
	return sprintf('%s/repos/%s/contents/%s', API, ctx.repo, replace(path, /[^A-Za-z0-9._\/-]/g, (c) => sprintf('%%%02X', ord(c))));
}

function cache_file(path) { return CACHE + '/' + substr(sha256_hex(ctx.repo + '/' + path), 0, 24) + '.json'; }

function track(res) {
	if (res.status >= 200 && res.status < 500 && res.status != 0) {
		last_ok = mono(); last_err = null; note_date(res);
	} else last_err = res.err ?? ('HTTP ' + res.status);
	return res;
}

// raw read: { ok, status, sha, text, cached(bool) } ; status 404 -> ok=false, missing=true
function get_raw(path, use_cache) {
	mkdirp(CACHE);
	let cf = cache_file(path), c = use_cache !== false ? readjson(cf) : null;
	let h = headers();
	if (c?.etag) h['If-None-Match'] = c.etag;
	let r = track(request(url(path), { headers: h, timeout: 20 }));
	if (r.status == 304 && c) return { ok: true, status: 304, sha: c.sha, text: c.text, cached: true };
	if (r.status == 404) { fs.unlink(cf); return { ok: false, status: 404, missing: true }; }
	if (r.status != 200) return { ok: false, status: r.status, err: r.err };
	let j = json_body(r);
	if (type(j) != 'object' || j.type != 'file') return { ok: false, status: r.status, err: 'not a file' };
	if (j.encoding != 'base64') return { ok: false, status: r.status, err: 'file too large for Contents API' };
	let text = b64dec(replace(j.content ?? '', /\s/g, ''));
	writejson(cf, { etag: r.headers['etag'], sha: j.sha, text });
	return { ok: true, status: 200, sha: j.sha, text, cached: false };
}

// raw write; sha=null creates. { ok, status, sha, conflict(bool) }
function put_raw(path, text, sha, message) {
	let body = { message: message ?? ('peers-ss: ' + path), content: b64enc(text) };
	if (sha) body.sha = sha;
	let h = headers();
	h['Content-Type'] = 'application/json';
	let r = track(request(url(path), { method: 'PUT', headers: h, body: sprintf('%J', body), timeout: 25 }));
	if (r.status == 200 || r.status == 201) {
		let j = json_body(r);
		let nsha = j?.content?.sha;
		writejson(cache_file(path), { etag: null, sha: nsha, text });
		return { ok: true, status: r.status, sha: nsha };
	}
	// 409: sha mismatch; 422 is a conflict only when it is about the sha ("sha wasn't supplied" / does not match)
	let msg = json_body(r)?.message ?? '';
	let conflict = r.status == 409 || (r.status == 422 && match(msg, /sha/i) != null);
	if (!conflict) log('warn', sprintf('store: PUT %s -> %d %s', path, r.status, msg));
	return { ok: false, status: r.status, conflict, unknown: r.status == 0 || r.status >= 500, err: r.err ?? msg };
}

function delete_raw(path, sha, message) {
	let h = headers();
	h['Content-Type'] = 'application/json';
	let r = track(request(url(path), { method: 'DELETE', headers: h, timeout: 25,
		body: sprintf('%J', { message: message ?? ('peers-ss: delete ' + path), sha }) }));
	fs.unlink(cache_file(path));
	return { ok: r.status == 200, status: r.status, conflict: r.status == 409 || r.status == 422 };
}

function list_dir(path) {
	mkdirp(CACHE);
	let cf = cache_file(path + '/'), c = readjson(cf), h = headers();
	if (c?.etag) h['If-None-Match'] = c.etag;
	let r = track(request(url(path), { headers: h, timeout: 20 }));
	if (r.status == 304 && c) return c.list;
	if (r.status == 404) return [];
	if (r.status != 200) return null;
	let j = json_body(r);
	if (type(j) != 'array') return null;
	let list = map(filter(j, (e) => e.type == 'file'), (e) => ({ name: e.name, sha: e.sha }));
	writejson(cf, { etag: r.headers['etag'], list });
	return list;
}

// ---- encrypted objects ----
function aad(path, schema) { return ctx.repo + '/' + path + '#' + schema; }
function wrap(path, obj, key) { return sprintf('%J', { schema: SCHEMA, enc: encrypt_json(key ?? ctx.key, obj, aad(path, SCHEMA)) }) + '\n'; }

// { ok, sha, obj, missing, schema_newer, bad_key }
// schema newer than ours -> readable (if decryptable) but never written (spec §3)
function unwrap(path, text, key) {
	let w;
	try { w = json(text); } catch (e) { return { ok: false, err: 'bad json' }; }
	if (type(w) != 'object' || type(w.schema) != 'int' || w.schema < 1) return { ok: false, err: 'bad envelope' };
	let obj = decrypt_json(key ?? ctx.key, w.enc, aad(path, w.schema));
	if (obj == null) return { ok: false, bad_key: true, schema_newer: w.schema > SCHEMA, err: 'cannot decrypt (wrong password/key or tampered)' };
	return { ok: true, obj, schema: w.schema, schema_newer: w.schema > SCHEMA };
}

// anti-rollback: remember highest `rev` seen per file (RAM); an older rev is treated as tampering
function rev_guard(path, obj) {
	if (type(obj?.rev) != 'int') return true;
	let f = CACHE + '/revs.json', m = readjson(f) ?? {};
	if (m[path] != null && obj.rev < m[path]) return false;
	if (m[path] != obj.rev) { m[path] = obj.rev; writejson(f, m); }
	return true;
}

function get(path, key) {
	let r = get_raw(path);
	if (!r.ok) return r;
	let u = unwrap(path, r.text, key);
	if (u.ok && !rev_guard(path, u.obj)) {
		log('error', 'store: ' + path + ' rolled back to an older rev — ignored');
		return { ok: false, rollback: true, err: 'rolled back rev' };
	}
	u.sha = r.sha; u.status = r.status; u.cached = r.cached;
	return u;
}

// last known copy from the RAM cache (used while GitHub is unreachable)
function get_cached(path, key) {
	let c = readjson(cache_file(path));
	if (!c?.text) return { ok: false };
	let u = unwrap(path, c.text, key);
	u.sha = c.sha; u.cached = true; u.offline = true;
	return u;
}

function put(path, obj, sha, message, key) {
	let text = wrap(path, obj, key);
	let w = put_raw(path, text, sha, message);
	if (!w.ok && w.unknown) {
		// outcome unknown (timeout/5xx): the commit may have happened — compare blob sha
		sleep_s(1);
		let r = get_raw(path, false);
		if (r.ok && r.sha == git_blob_sha(text)) return { ok: true, status: 200, sha: r.sha, recovered: true };
	}
	if (w.ok) rev_guard(path, obj);
	return w;
}

// read-modify-write with CAS retries. fn(obj_or_null, sha) returns new obj, or null to abort.
// returns { ok, obj, sha, attempts, aborted, conflicts }
function update(path, fn, opts) {
	opts ??= {};
	let conflicts = 0;
	for (let attempt = 1; attempt <= (opts.retries ?? 6); attempt++) {
		let cur = get(path, opts.key);
		if (!cur.ok && !cur.missing) return { ok: false, err: cur.err ?? ('HTTP ' + cur.status), schema_newer: cur.schema_newer };
		if (cur.schema_newer) return { ok: false, schema_newer: true, err: 'schema newer — update Peers-SS' };
		let nobj = fn(cur.ok ? cur.obj : null, cur.sha);
		if (nobj == null) return { ok: true, aborted: true, obj: cur.obj, sha: cur.sha, attempts: attempt, conflicts };
		let w = put(path, nobj, cur.ok ? cur.sha : null, opts.message, opts.key);
		if (w.ok) return { ok: true, obj: nobj, sha: w.sha, attempts: attempt, conflicts };
		if (!w.conflict) return { ok: false, err: 'HTTP ' + w.status, attempts: attempt };
		conflicts++;
		log('info', sprintf('store: write conflict on %s, retry %d', path, attempt));
		fs.unlink(cache_file(path));
		sleep_s(0.2 + attempt * 0.3 + hexdec_rand() * 1.2);
	}
	return { ok: false, err: 'too many conflicts', conflicts };
}

export { get_cached, SCHEMA, init, set_key, now, reachable_since, last_error, get_raw, put_raw, delete_raw, list_dir, wrap, unwrap, get, put, update, mono };
