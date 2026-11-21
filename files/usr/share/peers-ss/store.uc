// Peers-SS: shared state in a private GitHub repo via Contents API.
// Reads use If-None-Match (304 is free), writes carry the current `sha` (atomic compare-and-swap).
// On-repo file format: {"schema":1,"enc":"PSE1.…"} — only file names and schema number are plaintext.
'use strict';

import * as fs from 'fs';
import { request, json_body, parse_http_date } from './http.uc';
import { RUN, mkdirp, readjson, writejson, log, sleep_s } from './util.uc';
import { encrypt_json, decrypt_json, sha256_hex } from './crypto.uc';

const SCHEMA = 1;
const API = 'https://api.github.com';
const CACHE = RUN + '/store';

let ctx = { repo: null, token: null, key: null };
let clock_ref = null;   // { gh: unix from GitHub Date, mono: monotonic seconds }
let last_ok = 0;        // monotonic time of last successful GitHub response
let last_err = null;

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
	// 409: sha mismatch; 422: "sha wasn't supplied" (file exists) / invalid sha
	return { ok: false, status: r.status, conflict: r.status == 409 || r.status == 422, err: r.err };
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
	let r = track(request(url(path), { headers: headers(), timeout: 20 }));
	if (r.status == 404) return [];
	if (r.status != 200) return null;
	let j = json_body(r);
	return type(j) == 'array' ? map(filter(j, (e) => e.type == 'file'), (e) => ({ name: e.name, sha: e.sha })) : null;
}

// ---- encrypted objects ----
function wrap(obj, key) { return sprintf('%J', { schema: SCHEMA, enc: encrypt_json(key ?? ctx.key, obj) }) + '\n'; }

// { ok, sha, obj, missing, schema_newer, bad_key }
function unwrap(text, key) {
	let w;
	try { w = json(text); } catch (e) { return { ok: false, err: 'bad json' }; }
	if (type(w) != 'object') return { ok: false, err: 'bad json' };
	if (+w.schema > SCHEMA) return { ok: false, schema_newer: true, err: 'schema newer — update Peers-SS' };
	let obj = decrypt_json(key ?? ctx.key, w.enc);
	if (obj == null) return { ok: false, bad_key: true, err: 'cannot decrypt (wrong password/key)' };
	return { ok: true, obj };
}

function get(path, key) {
	let r = get_raw(path);
	if (!r.ok) return r;
	let u = unwrap(r.text, key);
	u.sha = r.sha; u.status = r.status; u.cached = r.cached;
	return u;
}

function put(path, obj, sha, message, key) { return put_raw(path, wrap(obj, key), sha, message); }

// read-modify-write with CAS retries. fn(obj_or_null, sha) returns new obj, or null to abort.
// returns { ok, obj, sha, attempts, aborted, conflicts }
function update(path, fn, opts) {
	opts ??= {};
	let conflicts = 0;
	for (let attempt = 1; attempt <= (opts.retries ?? 6); attempt++) {
		let cur = get(path, opts.key);
		if (!cur.ok && !cur.missing) return { ok: false, err: cur.err ?? ('HTTP ' + cur.status), schema_newer: cur.schema_newer };
		let nobj = fn(cur.ok ? cur.obj : null, cur.sha);
		if (nobj == null) return { ok: true, aborted: true, obj: cur.obj, sha: cur.sha, attempts: attempt, conflicts };
		let w = put(path, nobj, cur.ok ? cur.sha : null, opts.message, opts.key);
		if (w.ok) return { ok: true, obj: nobj, sha: w.sha, attempts: attempt, conflicts };
		if (!w.conflict) return { ok: false, err: 'HTTP ' + w.status, attempts: attempt };
		conflicts++;
		log('info', sprintf('store: write conflict on %s, retry %d', path, attempt));
		fs.unlink(cache_file(path));
		sleep_s(0.3 + (attempt * 0.4));
	}
	return { ok: false, err: 'too many conflicts', conflicts };
}

export { SCHEMA, init, set_key, now, reachable_since, last_error, get_raw, put_raw, delete_raw, list_dir, wrap, unwrap, get, put, update, mono };
