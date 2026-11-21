// Peers-SS: one-time invite links (spec §4 mode B) and contour password change
'use strict';

import * as U from './util.uc';
import * as S from './secrets.uc';
import * as ST from './store.uc';
import * as C from './contour.uc';
import { contour_key, sha256_hex, encrypt_json, decrypt_json, fp } from './crypto.uc';

function b64url(s) { return replace(replace(replace(b64enc(s), '+', '-'), '/', '_'), /=+$/, ''); }
function b64url_dec(s) {
	s = replace(replace(s, '-', '+'), '_', '/');
	while (length(s) % 4) s += '=';
	return b64dec(s);
}

function secret_hash(secret) { return sha256_hex('peers-ss/invite\x00' + secret); }

// PSS1.<base64url(JSON)>: repo, GitHub token, contour_id, invite_id, link secret. No StealthSurf token, no password.
function encode(repo, gh, cid, iid, secret) {
	return 'PSS1.' + b64url(sprintf('%J', { r: repo, t: gh, c: cid, i: iid, s: secret }));
}

function decode(code) {
	if (type(code) != 'string' || substr(code, 0, 5) != 'PSS1.') return null;
	let j = null;
	try { j = json(b64url_dec(substr(code, 5))); } catch (e) { return null; }
	if (type(j) != 'object' || !j.r || !j.t || !j.c || !j.i || !j.s) return null;
	return { repo: j.r, gh: j.t, cid: j.c, iid: j.i, secret: j.s };
}

// target: group_id + env_id (existing env), group_id + env_id=null (new env in group), group_id=null (standalone)
function create(x, group_id, env_id, hours) {
	if (group_id && !x.contour.groups?.[group_id]) return { error: 'no such group' };
	if (group_id && env_id && !x.contour.groups[group_id].envs?.[env_id]) return { error: 'no such environment' };
	if (!(hours >= 1 && hours <= 24 * 30)) hours = 24;
	let iid = 'i' + U.rand_hex(5), secret = U.rand_hex(16);
	let now = ST.now();
	let inv = { id: iid, group: group_id, env: env_id, created_at: now, expires_at: now + int(hours * 3600),
		secret_hash: secret_hash(secret), created_by: x.rid, used_by: null, used_at: null, revoked: false };
	let w = ST.put(C.p_invite(x.cid, iid), inv, null, 'invite ' + iid + ': create');
	if (!w.ok) return { error: 'cannot write invite (HTTP ' + w.status + ')' };
	let code = encode(x.repo, S.get('gh_token'), x.cid, iid, secret);
	U.log('info', 'invite ' + iid + ' created for ' + (group_id ?? 'standalone') + '/' + (env_id ?? 'new') + ', ' + hours + ' h');
	return { ok: true, id: iid, expires_at: inv.expires_at,
		command: 'wget -qO- https://raw.githubusercontent.com/gungakufarot/peers-ss/main/install.sh | sh -s -- --join ' + code };
}

function list(x) {
	let files = ST.list_dir(x.cid + '/invites') ?? [], out = [], now = ST.now();
	for (let f in files) {
		let r = ST.get(x.cid + '/invites/' + f.name);
		if (!r.ok) continue;
		let i = r.obj;
		push(out, { id: i.id, group: i.group, env: i.env, created_at: i.created_at, expires_at: i.expires_at,
			used_by: i.used_by, used_name: i.used_by ? C.router_name(x.contour, i.used_by) : null, used_at: i.used_at,
			revoked: i.revoked, active: !i.revoked && !i.used_by && i.expires_at > now,
			group_name: i.group ? x.contour.groups?.[i.group]?.name : null, env_name: i.group && i.env ? x.contour.groups?.[i.group]?.envs?.[i.env]?.name : null });
	}
	return { ok: true, invites: sort(out, (a, b) => b.created_at - a.created_at) };
}

function revoke(x, iid) {
	if (!match(iid ?? '', /^i[0-9a-f]+$/)) return { error: 'bad id' };
	let w = ST.update(C.p_invite(x.cid, iid), (i) => i ? { ...i, revoked: true, revoked_at: ST.now(), revoked_by: x.rid } : null, { message: 'invite ' + iid + ': revoke' });
	if (!w.ok || w.aborted) return { error: 'cannot revoke' };
	U.log('info', 'invite ' + iid + ' revoked');
	return { ok: true };
}

// joining side: validate and claim the invite atomically (CAS). returns { ok, invite, err }
function claim(cid, iid, secret, new_rid) {
	let reason = null, inv = null;
	let w = ST.update(C.p_invite(cid, iid), (i) => {
		if (!i) { reason = 'invite does not exist'; return null; }
		if (i.revoked) { reason = 'invite was revoked'; return null; }
		if (i.used_by) { reason = 'invite was already used'; return null; }
		if (ST.now() > i.expires_at) { reason = 'invite expired'; return null; }
		if (i.secret_hash != secret_hash(secret)) { reason = 'invite secret does not match'; return null; }
		inv = { ...i, used_by: new_rid, used_at: ST.now() };
		return inv;
	}, { message: 'invite ' + iid + ': used' });
	if (reason) return { ok: false, err: reason };
	if (!w.ok) return { ok: false, err: w.status == 404 || w.err == 'HTTP 404' ? 'invite does not exist' : ('cannot read invite: ' + (w.err ?? '')) };
	return { ok: true, invite: inv };
}

// ---- password change: re-encrypt contour files, leave rekeys/<fp(old)>.json (new key under old key) for other routers ----
function rekey_path(cid, key) { return cid + '/rekeys/' + substr(sha256_hex('peers-ss/rekey\x00' + key), 0, 16) + '.json'; }

function change_password(x, new_password) {
	let old_key = x.key, new_key = contour_key(new_password, x.cid);
	// 1. publish the new key for routers that still have the old one
	let rk = ST.put(rekey_path(x.cid, old_key), { new_key, at: ST.now(), by: x.rid }, null, 'contour: rekey', old_key);
	if (!rk.ok && !rk.conflict) return { error: 'cannot write rekey file (HTTP ' + rk.status + ')' };
	// 2. re-encrypt every contour-key file
	let paths = [C.p_contour(x.cid)];
	for (let d in ['routers', 'rotations', 'invites', 'requests'])
		for (let f in ST.list_dir(x.cid + '/' + d) ?? []) push(paths, x.cid + '/' + d + '/' + f.name);
	let failed = [];
	for (let p in paths) {
		let r = ST.get(p, old_key);
		if (!r.ok) { if (!r.missing) push(failed, p); continue; }
		let w = ST.put(p, r.obj, r.sha, 'contour: re-encrypt', new_key);
		if (!w.ok) push(failed, p);
	}
	S.set('contour_key', new_key);
	ST.set_key(new_key);
	U.log('info', sprintf('contour password changed (%d files re-encrypted, %d failed)', length(paths) - length(failed), length(failed)));
	return { ok: !length(failed), files: length(paths), failed };
}

// other routers: current key cannot decrypt -> look for a rekey file made with our (old) key
function try_rekey(cid, key) {
	let r = ST.get(rekey_path(cid, key), key);
	if (!r.ok || !r.obj.new_key) return null;
	return r.obj.new_key;
}

export { encode, decode, create, list, revoke, claim, change_password, try_rekey, secret_hash };
