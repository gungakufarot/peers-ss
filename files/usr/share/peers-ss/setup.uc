// Peers-SS: contour creation / router registration (used by install.sh, CLI and invites)
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import * as U from './util.uc';
import * as S from './secrets.uc';
import * as ST from './store.uc';
import * as C from './contour.uc';
import { contour_key } from './crypto.uc';

function uci_set_main(vals) {
	let c = cursor();
	if (c.get('peers-ss', 'main') == null) c.set('peers-ss', 'main', 'peers-ss');
	for (let k, v in vals) {
		if (v == null) c.delete('peers-ss', 'main', k); else c.set('peers-ss', 'main', k, v);
	}
	c.commit('peers-ss');
}

// router id change re-keys the local secrets file (device key includes router_id)
function set_identity(rid, cid, repo) {
	let old = cursor().get('peers-ss', 'main', 'router_id') ?? '';
	let sec = S.load();
	uci_set_main({ router_id: rid, contour_id: cid, repo });
	S.save(sec);
	return old;
}

function new_rid() { return 'r' + U.rand_hex(4); }
function new_cid() { return 'c' + U.rand_hex(6); }

// returns { ok, cid, rid, err }
function create_contour(name, password, repo, binding, cfg) {
	let gh = S.get('gh_token');
	if (!gh) return { ok: false, err: 'GitHub token not set' };
	let cid = new_cid(), rid = new_rid();
	let key = contour_key(password, cid);
	ST.init(repo, gh, key);
	let contour = C.new_contour(name, rid, binding);
	// rotation file first: a failure leaves no half-created contour
	if (binding && cfg) {
		let r = ST.put(C.p_rotation(cid, binding), { rev: 1, binding, url: cfg.connection_url, server_id: cfg.server_id,
			location_id: cfg.location_id, history: [], blacklist: {}, reports: {}, triggers: {}, lock: null, updated_at: ST.now() },
			null, 'rotation ' + binding + ': initial link');
		if (!r.ok) return { ok: false, err: r.status == 403 ? 'GitHub token has no write access (Contents: Read and write)' : 'cannot write rotation file (HTTP ' + r.status + ')' };
	}
	let w = ST.put(C.p_contour(cid), contour, null, 'contour ' + cid + ': create');
	if (!w.ok) return { ok: false, err: w.status == 403 ? 'GitHub token has no write access (Contents: Read and write)' : 'cannot create contour.json (HTTP ' + w.status + ')' };
	set_identity(rid, cid, repo);
	S.set('contour_key', key);
	U.log('info', 'contour ' + cid + ' created, router ' + rid + ' = openwrt-1');
	return { ok: true, cid, rid };
}

// open an existing contour with the password: { ok, contour, key, sha, err }
function open_contour(cid, password, repo, gh) {
	let key = contour_key(password, cid);
	ST.init(repo, gh, key);
	let r = ST.get(C.p_contour(cid));
	if (!r.ok) return { ok: false, err: r.bad_key ? 'wrong contour password' : (r.err ?? ('HTTP ' + r.status)), bad_key: r.bad_key };
	return { ok: true, contour: r.obj, key, sha: r.sha };
}

// register this router into env (group_id may be null for standalone; env_id null -> new env)
// returns { ok, rid, name, binding, err }
function register_router(cid, key, repo, gh, target, rid) {
	ST.init(repo, gh, key);
	rid ??= new_rid();
	let name = null, binding = null;
	let w = ST.update(C.p_contour(cid), (c) => {
		if (!c) return null;
		let n = { ...c, rev: (c.rev ?? 0) + 1 };
		let num = n.next_router_num ?? (length(keys(n.routers ?? {})) + 1);
		name = 'openwrt-' + num;
		n.next_router_num = num + 1;
		n.routers = { ...(n.routers ?? {}), [rid]: { name } };
		let env = null;
		if (target.group_id) {
			let g = n.groups?.[target.group_id];
			if (!g) return null;
			if (target.env_id && g.envs?.[target.env_id]) env = g.envs[target.env_id];
			else if (target.env_id) return null;   // environment was deleted/merged after the invite
			else {
				let eid = 'e' + (n.next_env_num ?? 2);
				n.next_env_num = (n.next_env_num ?? 2) + 1;
				env = g.envs[eid] = { name: 'среда-' + (length(keys(g.envs)) + 1), config: target.config ?? null, routers: [] };
			}
		} else {
			let eid = 'e' + (n.next_env_num ?? 2);
			n.next_env_num = (n.next_env_num ?? 2) + 1;
			n.standalone = { ...(n.standalone ?? {}) };
			env = n.standalone[eid] = { name: name, config: target.config ?? null, routers: [] };
		}
		env.routers = [...(env.routers ?? []), rid];
		binding = env.config;
		return n;
	}, { message: 'contour ' + cid + ': register router' });
	if (!w.ok || w.aborted) return { ok: false, err: 'cannot register (' + (w.err ?? 'target not found') + ')' };
	set_identity(rid, cid, repo);
	S.set('contour_key', key);
	S.set('gh_token', gh);
	U.log('info', 'router registered as ' + name + ' (' + rid + ')');
	return { ok: true, rid, name, binding };
}

export { uci_set_main, set_identity, create_contour, open_contour, register_router, new_rid, new_cid };
