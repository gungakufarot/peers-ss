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

// registration failed after the claim: give the invite back (only our own claim)
function release(cid, iid, rid) {
	return ST.update(C.p_invite(cid, iid), (i) => i?.used_by == rid ? { ...i, used_by: null, used_at: null } : null, { message: 'invite ' + iid + ': released' });
}

function list(x) {
	let files = ST.list_dir(x.cid + '/invites') ?? [], out = [], now = ST.now();
	for (let f in files) {
		let r = ST.get(x.cid + '/invites/' + f.name);
		if (!r.ok) continue;
		let i = r.obj;
		// housekeeping: used/revoked/expired invites older than 30 days are deleted
		if ((i.used_by || i.revoked || i.expires_at < now) && now - i.expires_at > 30 * 86400) {
			ST.delete_raw(x.cid + '/invites/' + f.name, r.sha, 'invite ' + i.id + ': cleanup');
			continue;
		}
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
		// secret first: without it nothing about the invite state is revealed
		if (i.secret_hash != secret_hash(secret)) { reason = 'invite secret does not match'; return null; }
		if (i.revoked) { reason = 'invite was revoked'; return null; }
		if (i.used_by) { reason = 'invite was already used'; return null; }
		if (ST.now() > i.expires_at) { reason = 'invite expired'; return null; }
		inv = { ...i, used_by: new_rid, used_at: ST.now() };
		return inv;
	}, { message: 'invite ' + iid + ': used' });
	if (reason) return { ok: false, err: reason };
	if (!w.ok) return { ok: false, err: w.status == 404 || w.err == 'HTTP 404' ? 'invite does not exist' : ('cannot read invite: ' + (w.err ?? '')) };
	return { ok: true, invite: inv };
}

// ---- password change ----
// 1) rekeys/<id(old key)>.json = new key encrypted with the old key (other routers follow it, also through chains);
// 2) this router switches at once and keeps the old key as a read-only fallback;
// 3) every contour-key file is re-encrypted (CAS with retries), contour.json last. A partial failure is harmless:
//    such files stay readable with the old key (fallback ring) and get the new key on their next write.
// Note: whoever knows an old password can follow the chain — a password change does not lock out a leaked password
// (replace the GitHub token for that).
function rekey_path(cid, key) { return cid + '/rekeys/' + substr(sha256_hex('peers-ss/rekey\x00' + key), 0, 16) + '.json'; }

function switch_key(new_key, old_key) {
	let prev = filter([old_key, ...(S.get('prev_keys') ?? [])], (k) => k && k != new_key);
	S.save({ ...S.load(), contour_key: new_key, prev_keys: slice(prev, 0, 3) });
	ST.set_key(new_key);
	ST.set_keyring(prev);
}

function change_password(x, new_password) {
	let old_key = x.key, new_key = contour_key(new_password, x.cid);
	if (new_key == old_key) return { error: 'the new password is the same' };
	let at = ST.now();
	let rk = ST.update(rekey_path(x.cid, old_key), () => ({ new_key, at, by: x.rid }), { key: old_key, message: 'contour: rekey' });
	if (!rk.ok) return { error: 'cannot write rekey file: ' + (rk.err ?? '') };
	// a reused password (A→B→A): the old rekey file of the new key points back to a stale key — remove it
	let stale = ST.get_raw(rekey_path(x.cid, new_key), false);
	if (stale.ok) ST.delete_raw(rekey_path(x.cid, new_key), stale.sha, 'contour: drop stale rekey');
	switch_key(new_key, old_key);
	let paths = [];
	for (let d in ['routers', 'rotations', 'invites'])
		for (let f in ST.list_dir(x.cid + '/' + d) ?? []) push(paths, x.cid + '/' + d + '/' + f.name);
	push(paths, C.p_contour(x.cid));   // last
	let failed = [];
	for (let p in paths) {
		let w = ST.update(p, (o) => o, { message: 'contour: re-encrypt with the new key' });   // read: any key of the ring, write: new key
		if (!w.ok) push(failed, p);
	}
	U.log('info', sprintf('contour password changed: %d files re-encrypted, %d left for later', length(paths) - length(failed), length(failed)));
	return { ok: true, files: length(paths), failed };
}

// other routers: follow rekeys from the current key (chain of changes); returns the newest key or null
function try_rekey(cid, key) {
	let cur = key, found = null, seen = { [key]: true };
	for (let i = 0; i < 5; i++) {
		let r = ST.get(rekey_path(cid, cur), cur);
		if (!r.ok || !r.obj.new_key || seen[r.obj.new_key]) break;   // loop guard
		seen[r.obj.new_key] = true;
		found = cur = r.obj.new_key;
	}
	// only switch to a key that really opens the contour (contour.json is re-encrypted last)
	if (found && !ST.get(C.p_contour(cid), found).ok) return null;
	return found;
}

export { encode, decode, create, list, revoke, claim, release, change_password, try_rekey, switch_key, secret_hash };
