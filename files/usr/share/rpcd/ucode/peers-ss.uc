// Peers-SS: rpcd backend for LuCI (ubus object "luci.peers-ss"). Access: root only (ACL luci-app-peers-ss).
// Long operations (check, rotation, diagnostics) run as background CLI jobs; the page polls job status.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import * as U from '/usr/share/peers-ss/util.uc';
import * as S from '/usr/share/peers-ss/secrets.uc';
import * as ST from '/usr/share/peers-ss/store.uc';
import * as C from '/usr/share/peers-ss/contour.uc';
import * as API from '/usr/share/peers-ss/api.uc';
import * as PK from '/usr/share/peers-ss/podkop.uc';
import * as E from '/usr/share/peers-ss/engine.uc';
import * as OPS from '/usr/share/peers-ss/ops.uc';
import * as INV from '/usr/share/peers-ss/invite.uc';
import { request } from '/usr/share/peers-ss/http.uc';
import { contour_key, fp } from '/usr/share/peers-ss/crypto.uc';

const JOBS = ['check', 'rotate', 'dry', 'diag'];

function ctx() {
	if (!E.init()) return null;
	E.refresh_contour();
	return E.ctx();
}

function mask(t) { return t ? substr(t, 0, 6) + '…' + substr(t, -4) : null; }

function job_file(name) { return U.RUN + '/job-' + name + '.json'; }

function job_start(name) {
	if (index(JOBS, name) < 0) return { error: 'unknown job' };
	let st = U.readjson(job_file(name));
	if (st?.running && fs.stat('/proc/' + st.pid)) return { started: false, running: true };
	let cmd = { check: 'check', rotate: 'rotate', dry: 'rotate --dry-run', diag: 'podkop diag' }[name];
	U.mkdirp(U.RUN);
	U.writejson(job_file(name), { running: true, started: time() });
	system(sprintf('(sh -c \'echo "{\\"pid\\":$$,\\"running\\":true,\\"started\\":%d}" > %s; /usr/bin/peers-ss %s > %s.out 2>&1; rc=$?; echo "{\\"running\\":false,\\"rc\\":$rc,\\"finished\\":$(date +%%s)}" > %s\') >/dev/null 2>&1 &',
		time(), job_file(name), cmd, job_file(name), job_file(name)));
	return { started: true };
}

function job_status(name) {
	let st = U.readjson(job_file(name)) ?? { running: false };
	st.output = U.redact(fs.readfile(job_file(name) + '.out') ?? '');
	return st;
}

// router records + names for UI tables
function routers_view(x) {
	let recs = E.read_routers(), out = [];
	for (let rid in sort(keys(x.contour?.routers ?? {}))) {
		let r = rid == x.rid ? E.router_record() : recs[rid];
		let eo = C.env_of(x.contour, rid);
		push(out, { rid, name: C.router_name(x.contour, rid), me: rid == x.rid, group: eo?.group_id, env: eo?.env_id,
			group_name: eo?.group_id ? x.contour.groups[eo.group_id].name : null, env_name: eo?.env?.name, binding: eo?.env?.config,
			status: r?.status, last_contact: r?.last_contact, ping_ms: r?.ping_ms, has_token: r?.has_token, account: r?.account,
			token_label: r?.token_label, diag_ok: r?.diag_ok, version: r?.version });
	}
	return out;
}

function rotation_view(x, binding) {
	let r = ST.get(C.p_rotation(x.cid, binding));
	if (!r.ok) return null;
	let o = r.obj;
	return { rev: o.rev, server_id: o.server_id, location_id: o.location_id, lock: o.lock, waiting: o.waiting,
		history: o.history ?? [], updated_at: o.updated_at, link_fp: o.url ? fp(o.url) : null };
}

function card_view(x, binding) {
	if (!x.bot_key || !binding) return null;
	let r = ST.get(C.p_card(x.cid, binding), x.bot_key);
	return r.ok ? r.obj : null;
}

function alerts_view(x) {
	if (!x.bot_key) return [];
	let list = ST.list_dir(x.cid + '/alerts') ?? [], out = [];
	for (let f in slice(sort(list, (a, b) => a.name < b.name ? -1 : 1), -30)) {
		let r = ST.get(x.cid + '/alerts/' + f.name, x.bot_key);
		if (r.ok) push(out, { event: r.obj.event, text: r.obj.text, at: r.obj.at, router: r.obj.router });
	}
	return sort(out, (a, b) => b.at - a.at);
}

// save a contour edit with CAS; rev = contour rev the page was opened with (spec §8 concurrent edits)
function contour_op(op, args, rev) {
	let x = ctx();
	if (!x) return { error: 'not configured' };
	let conflict = null, err = null;
	let w = ST.update(C.p_contour(x.cid), (c) => {
		if (rev != null && c.rev != rev) { conflict = c.edited_by ? C.router_name(c, c.edited_by) : '?'; return null; }
		let n = json(sprintf('%J', c));
		err = OPS.apply(n, op, args ?? {});
		if (err) return null;
		OPS.bump(n, x.rid);
		rev = n.rev;
		return n;
	}, { message: 'contour: ' + op + ' (' + C.router_name(x.contour, x.rid) + ')' });
	if (conflict) return { conflict: true, by: conflict, message: 'Настройки изменены на ' + conflict + ', обновите страницу' };
	if (err) return { error: err };
	if (!w.ok) return { error: w.err ?? 'GitHub write failed' };
	U.log('info', 'LuCI: contour ' + op);
	return { ok: true, rev: w.obj.rev };
}

const methods = {
	status: {
		call: function() {
			let x = ctx();
			let base = { version: E.VERSION, configured: !!x, podkop: PK.check_podkop() };
			if (!x) return base;
			E.load_state();
			let st = E.state() ?? {};
			let eo = C.env_of(x.contour, x.rid);
			return { ...base, rid: x.rid, cid: x.cid, repo: x.repo, contour_name: x.contour?.name, contour_rev: x.contour?.rev,
				name: C.router_name(x.contour, x.rid), group: eo?.group_id ? x.contour.groups[eo.group_id].name : null,
				env: eo?.env?.name, binding: x.binding, has_token: !!x.token, account: x.acct,
				state: { status: st.status, counter: st.counter, ping_ms: st.ping_ms, ping_at: st.ping_at, last_check: st.last_check,
					layers: st.layers, diag_ok: st.diag_ok, diag_fails: st.diag_fails, last_rotation: st.last_rotation, ignore_until: st.ignore_until },
				rotation: x.binding ? rotation_view(x, x.binding) : null, card: card_view(x, x.binding),
				alerts: slice(alerts_view(x), 0, 10), github_error: ST.last_error() };
		}
	},
	contour_get: {
		call: function() {
			let x = ctx();
			if (!x) return { error: 'not configured' };
			let cards = {};
			for (let b in C.all_bindings(x.contour)) cards[b] = card_view(x, b);
			let rots = {};
			for (let b in C.all_bindings(x.contour)) { let r = rotation_view(x, b); if (r) rots[b] = { server_id: r.server_id, location_id: r.location_id, rev: r.rev }; }
			return { contour: x.contour, me: x.rid, routers: routers_view(x), cards, rotations: rots,
				archive: x.contour.archive ?? [], settings: C.settings(x.contour) };
		}
	},
	contour_op: {
		args: { op: '', args: {}, rev: 0 },
		call: function(req) { return contour_op(req.args.op, req.args.args, req.args.rev); }
	},
	token_get: {
		args: { reveal: false },
		call: function(req) {
			let t = S.get('ss_token');
			return { has: !!t, token: t ? (req.args.reveal ? t : mask(t)) : null, label: S.get('ss_label'), account: S.get('ss_account') };
		}
	},
	token_check: {
		args: { token: '' },
		call: function(req) {
			let t = req.args.token || S.get('ss_token');
			if (!t) return { error: 'no token' };
			let p = API.profile(t);
			if (!p.ok) return { ok: false, status: p.status, message: p.message };
			let c = API.configs(t);
			if (!c.ok) return { ok: false, status: c.status, message: 'GET /configs failed' };
			let v = API.vless_configs(c.data), soon = null;
			for (let q in v) if (soon == null || q.expires_at < soon) soon = q.expires_at;
			// spec §4: which bindings become follower with this token
			let x = ctx(), follower = [];
			if (x) for (let b in C.all_bindings(x.contour)) {
				let pb = C.parse_binding(b);
				if (index(C.binding_routers(x.contour, b), x.rid) >= 0 && pb.account != p.data.id) push(follower, b);
			}
			return { ok: true, account: p.data.id, email: p.data.email, vless: length(v), soonest: soon, follower_bindings: follower };
		}
	},
	token_set: {
		args: { token: '', label: '' },
		call: function(req) {
			let t = trim(req.args.token ?? '');
			if (!match(t, /^stlth_[a-f0-9]{8}_[a-f0-9]{24}$/)) return { error: 'token format: stlth_<8 hex>_<24 hex>' };
			let p = API.profile(t);
			if (!p.ok) return { error: 'token rejected by API (HTTP ' + p.status + ')' };
			S.save({ ...S.load(), ss_token: t, ss_account: p.data.id, ss_label: req.args.label || ('#' + p.data.id) });
			U.log('info', 'LuCI: token set for account ' + p.data.id);
			return { ok: true, account: p.data.id };
		}
	},
	token_delete: {
		call: function() {
			let s = { ...S.load() };
			delete s.ss_token; delete s.ss_account; delete s.ss_label;
			S.save(s);
			U.log('info', 'LuCI: token deleted');
			return { ok: true };
		}
	},
	// vless configs of a token: own token, or via another router of the contour (rid) through the store
	configs: {
		args: { rid: '' },
		call: function(req) {
			let x = ctx();
			if (!x) return { error: 'not configured' };
			let rid = req.args.rid || x.rid;
			if (rid == x.rid) {
				if (!x.token) return { error: 'this router has no StealthSurf token' };
				let c = API.configs(x.token);
				if (!c.ok) return { error: 'GET /configs failed (HTTP ' + c.status + ')' };
				return { ok: true, account: +x.acct, configs: map(API.vless_configs(c.data), (q) => ({ id: q.id, title: q.title, expires_at: q.expires_at,
					location_id: q.location_id, server_id: q.server_id, binding: x.acct + ':' + q.id })) };
			}
			let path = x.cid + '/requests/' + rid + '.json';
			let r = ST.get(path);
			if (r.ok && r.obj.answered_at && r.obj.from == x.rid && time() - r.obj.answered_at < 300) return { ok: true, via: rid, account: r.obj.account, configs: r.obj.configs };
			if (!(r.ok && r.obj.from == x.rid && !r.obj.answered_at && ST.now() - r.obj.at < 120))
				ST.update(path, () => ({ from: x.rid, at: ST.now() }), { message: 'configs request' });
			return { pending: true, via: rid };
		}
	},
	job_start: { args: { name: '' }, call: function(req) { return job_start(req.args.name); } },
	job_status: { args: { name: '' }, call: function(req) { return job_status(req.args.name); } },
	test_alert: {
		call: function() {
			let x = ctx();
			if (!x?.bot_key) return { error: 'no bot key in contour settings' };
			let ok = E.alert('test-' + time(), 'Тестовый алерт с ' + C.router_name(x.contour, x.rid));
			return { ok };
		}
	},
	api_check: {
		call: function() {
			let x = ctx();
			let gh = request('https://api.github.com/repos/' + (x?.repo ?? cursor().get('peers-ss', 'main', 'repo')), { headers: { Authorization: 'Bearer ' + (S.get('gh_token') ?? ''), 'User-Agent': 'peers-ss' }, timeout: 10 });
			let res = { github: gh.status == 200, github_status: gh.status };
			let t = S.get('ss_token');
			if (t) { let p = API.profile(t); res.stealthsurf = p.ok; res.stealthsurf_status = p.status; }
			else { let r = request('https://api.stealthsurf.net/', { timeout: 10 }); res.stealthsurf_reachable = r.status > 0; }
			return res;
		}
	},
	password_change: {
		args: { old: '', new: '' },
		call: function(req) {
			let x = ctx();
			if (!x) return { error: 'not configured' };
			if (contour_key(req.args.old ?? '', x.cid) != x.key) return { error: 'current password is wrong' };
			if (length(req.args.new ?? '') < 8) return { error: 'new password: at least 8 characters' };
			return INV.change_password(x, req.args.new);
		}
	},
	invites: { call: function() { let x = ctx(); return x ? INV.list(x) : { error: 'not configured' }; } },
	invite_create: {
		args: { group: '', env: '', hours: 24 },
		call: function(req) { let x = ctx(); return x ? INV.create(x, req.args.group || null, req.args.env || null, +(req.args.hours || 24)) : { error: 'not configured' }; }
	},
	invite_revoke: {
		args: { id: '' },
		call: function(req) { let x = ctx(); return x ? INV.revoke(x, req.args.id) : { error: 'not configured' }; }
	},
	events: {
		call: function() { return { log: U.redact(fs.readfile(U.RUN + '/events.log') ?? '') }; }
	},
	report: {
		call: function() {
			let x = ctx();
			let st = U.readjson(U.RUN + '/state.json') ?? {};
			let rot = x?.binding ? rotation_view(x, x.binding) : null;
			let txt = sprintf('Peers-SS %s report %s\nrouter %s (%s) contour %s binding %s token %s\nstate %J\nrotation %J\npodkop %J\n--- events ---\n%s',
				E.VERSION, U.redact('' + time()), x ? C.router_name(x.contour, x.rid) : '-', x?.rid ?? '-', x?.cid ?? '-', x?.binding ?? '-',
				x?.token ? 'yes' : 'no', st, rot, PK.check_podkop(), fs.readfile(U.RUN + '/events.log') ?? '');
			return { report: U.redact(txt) };
		}
	}
};

return { 'luci.peers-ss': methods };
