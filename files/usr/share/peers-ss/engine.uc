// Peers-SS: engine — polling, rotation, delivery, alerts, cards (spec §5, §9)
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import * as U from './util.uc';
import * as S from './secrets.uc';
import * as ST from './store.uc';
import * as C from './contour.uc';
import * as API from './api.uc';
import * as PK from './podkop.uc';
import * as H from './health.uc';
import * as P from './ping.uc';
import { fp } from './crypto.uc';

const VERSION = '0.5.0';
const STATE = U.RUN + '/state.json';
const LOCK_TTL = 180;
const ROT_HISTORY = 10;
const BLACKLIST_S = 86400;
const ALERT_EVERY = 6 * 3600;
const HEARTBEAT_S = 1800;
const OFFLINE_S = 3600;
const BAD_WINDOW = 1800, BAD_IGNORE = 3600;

let X = null;      // context
let st = null;     // local volatile state (RAM)

function load_state() { st = U.readjson(STATE) ?? { counter: 0 }; return st; }
function save_state() { U.mkdirp(U.RUN); U.writejson(STATE, st); }

function uci_main() { return cursor().get_all('peers-ss', 'main') ?? {}; }

// ---------- context ----------
function init() {
	let m = uci_main();
	let sec = S.load();
	X = {
		rid: m.router_id, cid: m.contour_id, repo: m.repo,
		key: sec.contour_key, gh: sec.gh_token, token: sec.ss_token, acct: sec.ss_account,
		contour: null, binding: null, settings: C.settings(null), bot_key: null
	};
	if (!X.rid || !X.cid || !X.repo || !X.key || !X.gh) return false;
	ST.init(X.repo, X.gh, X.key);
	load_state();
	return true;
}

function refresh_contour() {
	let r = ST.get(C.p_contour(X.cid));
	let online = r.ok;
	if (!r.ok && !r.bad_key && !r.rollback) {
		// GitHub unreachable: keep working with the last known contour (binding must not be lost)
		let c = ST.get_cached(C.p_contour(X.cid));
		if (c.ok) { X.contour = c.obj; X.settings = C.settings(c.obj); X.binding = C.binding_of(c.obj, X.rid); X.bot_key = c.obj?.settings?.bot_key; }
		return false;
	}
	if (r.ok) {
		if (r.schema_newer) { st.status = 'update_required'; }
		X.contour = r.obj;
		X.settings = C.settings(r.obj);
		X.binding = C.binding_of(r.obj, X.rid);
		X.bot_key = r.obj?.settings?.bot_key;
		st.contour_sha = r.sha;
		return true;
	}
	return false;
}

function my_token_fits(binding) {
	let b = C.parse_binding(binding);
	return !!(X.token && b && +X.acct == b.account);
}

function bind_parts() { return C.parse_binding(X.binding); }

// ---------- alerts & cards (encrypted with the bot key) ----------
function alert(ev, text, extra) {
	if (!X.bot_key) { U.log('warn', 'alert ' + ev + ' not sent: no bot key in contour'); return false; }
	let now = ST.now();
	let r = ST.update(C.p_alert(X.cid, ev), (old) => {
		if (old && now - (old.at ?? 0) < ALERT_EVERY) return null;
		return { event: ev, text, at: now, contour: X.contour?.name, cid: X.cid,
			router: C.router_name(X.contour, X.rid), rid: X.rid, ...(extra ?? {}) };
	}, { key: X.bot_key, message: 'alert ' + ev });
	if (r.ok && !r.aborted) U.log('info', 'alert written: ' + ev + ' — ' + text);
	return r.ok;
}

// ---------- routers/<rid>.json ----------
function router_record() {
	return {
		rid: X.rid, status: st.status ?? 'unknown', counter: st.counter ?? 0,
		ping_ms: st.ping_ms, ping_at: st.ping_at, diag_ok: st.diag_ok, diag_fails: st.diag_fails ?? [],
		layers: st.layers, last_contact: ST.now(), applied_fp: st.applied_fp,
		has_token: !!X.token, account: X.token ? +X.acct : null, token_label: X.token ? S.get('ss_label') : null,
		binding: X.binding, version: VERSION, podkop: st.podkop ?? null,
		bad_channel_until: st.ignore_until ?? null, last_rotation: st.last_rotation ?? null
	};
}

function heartbeat(force) {
	let sig = sprintf('%s|%s|%s|%s|%s|%s', st.status, st.diag_ok, st.applied_fp, !!X.token, X.binding, st.ignore_until);
	let now = ST.now();
	if (!force && sig == st.hb_sig && now - (st.hb_at ?? 0) < HEARTBEAT_S) return;
	let rec = router_record();
	let r = ST.update(C.p_router(X.cid, X.rid), (old) => ({ ...(old ?? {}), ...rec }), { message: 'router ' + X.rid });
	if (r.ok) { st.hb_sig = sig; st.hb_at = now; }
}

// all routers files (ETag-cached); returns { rid: record }
function read_routers() {
	let out = {};
	for (let rid in keys(X.contour?.routers ?? {})) {
		let r = ST.get(C.p_router(X.cid, rid));
		if (r.ok) out[rid] = r.obj;
	}
	return out;
}

// first online router with a token of this binding's account (deterministic by router id)
function first_token_router(binding, recs) {
	let b = C.parse_binding(binding), now = ST.now();
	for (let rid in C.binding_routers(X.contour, binding)) {
		let rec = rid == X.rid ? router_record() : recs[rid];
		if (!rec) continue;
		let fresh = rid == X.rid || now - (rec.last_contact ?? 0) < OFFLINE_S;
		if (fresh && rec.has_token && +rec.account == b.account) return rid;
	}
	return null;
}

// ---------- rotation file ----------
function rot_path(binding) { return C.p_rotation(X.cid, binding ?? X.binding); }
function rot_get(binding) { return ST.get(rot_path(binding)); }

function apply_link(url, why) {
	let cur = PK.current_link();
	if (url == cur) return { changed: false, ok: true };
	U.log('info', 'applying new link (' + why + ')');
	let r = PK.apply_link(url, { setup: true });
	st.applied_fp = fp(PK.current_link() ?? '');
	st.diag_ok = r.diag?.ok ?? r.ok;
	st.diag_fails = r.diag?.fails ?? (r.err ? [r.err] : []);
	if (r.latency?.ms) { st.ping_ms = r.latency.ms; st.ping_at = ST.now(); }
	st.status = r.ok ? 'ok' : 'apply_failed';
	st.counter = 0;
	save_state();
	heartbeat(true);
	return r;
}

// poll rotations/… and apply a newer link (spec §5 "Остальные роутеры")
function deliver() {
	if (!X.binding) return;
	let r = rot_get();
	if (!r.ok) return;
	st.rot = { rev: r.obj.rev, waiting: r.obj.waiting };
	if (r.obj.url && r.obj.url != PK.current_link()) {
		if (st.status == 'update_required') return;
		apply_link(r.obj.url, 'rotations rev ' + r.obj.rev);
	}
}

// ---------- rotation (spec §5 steps 1-9) ----------
function rot_release(binding) {
	for (let i = 0; i < 3; i++) {
		let w = ST.update(rot_path(binding), (o) => (o?.lock?.by == X.rid ? { ...o, lock: null } : null), { message: 'unlock' });
		if (w.ok) return true;
		U.sleep_s(5);
	}
	U.log('warn', 'could not release rotation lock — it expires by itself in 180 s');
	return false;
}

function lock_take(binding) {
	let now = ST.now(), res = null;
	let w = ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		if (o.lock && o.lock.by != X.rid && o.lock.until > now) { res = 'busy'; return null; }
		return { ...o, lock: { by: X.rid, until: now + LOCK_TTL } };
	}, { message: 'lock ' + binding });
	if (!w.ok) return { ok: false, why: 'github' };
	if (res == 'busy') return { ok: false, why: 'busy', obj: w.obj };
	return { ok: true, obj: w.obj };
}

// wait up to 3 min for someone else's new link
function wait_new_link(binding, max_s) {
	let t0 = ST.mono(), cur = PK.current_link();
	while (ST.mono() - t0 < (max_s ?? 180)) {
		U.sleep_s(10);
		let r = rot_get(binding);
		if (r.ok && r.obj.url && r.obj.url != cur) { apply_link(r.obj.url, 'rotation by ' + (r.obj.lock?.by ?? r.obj.history?.[-1]?.by ?? '?')); return true; }
		if (r.ok && !r.obj.lock) return false;
	}
	return false;
}

function find_config(token, id) {
	let c = API.configs(token);
	if (!c.ok) return { err: c.status == 401 ? 'token_invalid' : 'api', res: c };
	for (let x in c.data ?? []) if (x && x.id == id) return { cfg: x, list: c.data };
	return { err: 'config_missing', list: c.data };
}

function write_rotation(binding, mutate, msg) {
	return ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		let n = { ...o };
		mutate(n);
		return n;
	}, { message: msg ?? ('rotation ' + binding) });
}

function blacklisted(o, now) {
	let b = {};
	for (let sid, until in o?.blacklist ?? {}) if (until > now) b[sid] = until;
	return b;
}

// rank candidate locations: reporter pings (follower) or own measurement
function ranked_locations(locs, ext) {
	if (ext && length(ext)) {
		let by = {};
		for (let l in locs) by[l.id] = l;
		let out = [];
		for (let e in ext) if (by[e.id]) push(out, { loc: by[e.id], ms: e.ms });
		if (length(out)) return out;
	}
	return P.rank_locations(locs);
}

// opts: { reason, manual, dry_run, ext_pings, nolock }
// returns { ok, action: applied|recovered|rotated|locked|waiting|error|dry_run, ... }
function rotate(opts) {
	opts ??= {};
	let binding = X.binding;
	if (!binding) return { ok: false, action: 'error', err: 'no binding' };
	let b = C.parse_binding(binding);
	if (!my_token_fits(binding)) return { ok: false, action: 'error', err: 'no token of account ' + b.account };
	let now = ST.now();
	let cur_link = PK.current_link();

	// 1. newer link already in the file
	let rf = opts.nolock ? null : rot_get(binding);
	if (rf?.ok && rf.obj.url && rf.obj.url != cur_link && !opts.dry_run) {
		apply_link(rf.obj.url, 'rotation file newer');
		return { ok: true, action: 'applied' };
	}
	// 10-minute rule (normal mode)
	let last = rf?.ok ? (rf.obj.history?.[-1]?.at ?? 0) : 0;
	if (!opts.manual && !opts.dry_run && !opts.retry && now - last < X.settings.retry_min * 60)
		return { ok: false, action: 'too_soon', err: 'last rotation ' + (now - last) + ' s ago' };

	// 2. lock
	if (!opts.nolock && !opts.dry_run) {
		let l = lock_take(binding);
		if (!l.ok) {
			if (l.why == 'busy') {
				U.log('info', 'rotation lock held by ' + l.obj.lock.by + ', waiting for new link');
				return { ok: wait_new_link(binding), action: 'locked' };
			}
			return { ok: false, action: 'error', err: 'cannot take lock (GitHub)' };
		}
		rf = { ok: true, obj: l.obj };
	}
	let release = () => { if (!opts.nolock && !opts.dry_run) rot_release(binding); };

	// 3. re-check layers 3-4
	// skipped when rotating for a follower's report: the block is at the reporter, not here (bad-channel rule guards it)
	if (!opts.manual && !opts.dry_run && !opts.for_report && H.recheck(cur_link)) {
		U.log('info', 'recheck passed — no rotation');
		release();
		st.counter = 0;
		return { ok: true, action: 'recovered' };
	}

	// 4. current state from API
	let fc = find_config(X.token, b.config_id);
	if (fc.err) {
		if (fc.err == 'token_invalid') alert('token-invalid-' + X.rid, 'Токен StealthSurf недействителен на ' + C.router_name(X.contour, X.rid));
		if (fc.err == 'config_missing') alert('config-missing-' + replace(binding, ':', '-'), 'Конфиг ' + binding + ' исчез из аккаунта');
		release();
		return { ok: false, action: 'error', err: fc.err };
	}
	let cfg = fc.cfg;
	if (cfg.connection_url != cur_link && !opts.dry_run && !opts.manual) {
		U.log('info', 'API link differs from mine (changed in console / other contour) — taking it');
		write_rotation(binding, (n) => {
			n.rev = (n.rev ?? 0) + 1; n.url = cfg.connection_url; n.server_id = cfg.server_id; n.location_id = cfg.location_id;
			n.lock = null; n.updated_at = ST.now();
		}, 'rotation: link from API');
		apply_link(cfg.connection_url, 'API link');
		return { ok: true, action: 'applied_api' };
	}

	// 5. locations ranked by ping (from the router that saw the block)
	let lr = API.locations(X.token);
	if (!lr.ok) { release(); return { ok: false, action: 'error', err: 'GET /locations failed' }; }
	let locs = API.candidate_locations(lr.data, X.settings.exclude_locations);
	let ranked = filter(ranked_locations(locs, opts.ext_pings), (x) => x.ms != null);
	let vport = U.parse_vless(cfg.connection_url)?.port;
	let bl = blacklisted(rf?.obj, now);
	bl['' + cfg.server_id] = now + BLACKLIST_S;

	let attempts = 0, patches = 0, tried = [], old_server = cfg.server_id, plan = [];
	let old_host = U.parse_vless(cfg.connection_url)?.host;
	let li = 0;
	while (attempts < 3 && patches < 6 && li < length(ranked)) {
		let loc = ranked[li].loc;
		// 6. servers of the best location
		let av = API.available_servers(X.token, loc.id, cfg.protocol);
		if (!av.ok) { li++; continue; }
		let servers = filter(av.data ?? [], (s) => !bl['' + s.id] && s.ip != old_host);
		if (!length(servers)) { li++; continue; }
		let rs = P.rank_servers(servers, vport);
		let ids = map(filter(rs, (x) => x.ms != null), (x) => x.server.id);
		if (!length(ids)) ids = map(rs, (x) => x.server.id);
		push(plan, { location: loc.code, location_id: loc.id, loc_ms: ranked[li].ms, servers: map(rs, (x) => [x.server.id, x.ms]) });
		if (opts.dry_run) { li++; if (length(plan) >= 3) break; continue; }
		// 7. PATCH: preference list first; if the service kept the same server — explicit server_id once
		let pr = null, moved = false;
		for (let mode in ['list', 'single']) {
			pr = API.patch_settings(X.token, cfg, loc.id, ids, mode == 'single' ? ids[0] : null);
			patches++;
			if (!pr.ok) break;
			let nh = U.parse_vless(pr.data?.connection_url ?? '')?.host;
			moved = pr.data?.server_id != old_server && nh != old_host;
			// the config was recreated: from now on "current" is what PATCH returned
			cfg = { ...cfg, connection_url: pr.data?.connection_url ?? cfg.connection_url, server_id: pr.data?.server_id ?? cfg.server_id };
			if (moved) break;
			U.log('warn', sprintf('PATCH kept server %s (%s) — retrying with explicit server_id', pr.data?.server_id, mode));
		}
		if (!pr.ok) {
			if (index([9, 52, 53], pr.code) >= 0) { li++; continue; }
			if (pr.code == 3 && match(pr.message ?? '', /cantChangeSettings|change/i)) {
				alert('cant-change-' + replace(binding, ':', '-'), 'Конфиг ' + (cfg.title ?? binding) + ' нельзя перенастроить (cantChangeSettings)');
			}
			release();
			return { ok: false, action: 'error', err: sprintf('PATCH failed: HTTP %d code %s %s', pr.status, pr.code ?? '-', pr.message ?? '') };
		}
		let new_url = pr.data?.connection_url, new_sid = pr.data?.server_id;
		if (!new_url) { release(); return { ok: false, action: 'error', err: 'PATCH returned no connection_url' }; }
		if (!moved) {
			// still on the blocked server: keep its (new) link in storage so others stay in sync, try next location
			U.log('warn', sprintf('location %s: config stayed on server %s — next location', loc.code, new_sid));
			write_rotation(binding, (n) => { n.rev = (n.rev ?? 0) + 1; n.url = new_url; n.server_id = new_sid; n.updated_at = ST.now(); }, 'rotation: same server, relinked');
			li++;
			continue;
		}
		attempts++;
		push(tried, new_sid);
		cfg = { ...cfg, connection_url: new_url, server_id: new_sid, location_id: loc.id };
		// 8. write file
		let hist = { at: ST.now(), by: X.rid, reason: opts.reason ?? 'blocked', from_server: old_server, to_server: new_sid,
			location: loc.code, location_id: loc.id };
		let w = write_rotation(binding, (n) => {
			n.rev = (n.rev ?? 0) + 1; n.url = new_url; n.server_id = new_sid; n.location_id = loc.id;
			n.history = slice([...(n.history ?? []), hist], -ROT_HISTORY);
			n.blacklist = { ...blacklisted(n, ST.now()), ['' + old_server]: ST.now() + BLACKLIST_S };
			n.lock = { by: X.rid, until: ST.now() + LOCK_TTL };
			n.reports = {};
			n.waiting = null;
			n.updated_at = ST.now();
		}, sprintf('rotation: %s -> server %d (%s)', binding, new_sid, loc.code));
		if (!w.ok) { st.pending_writeback = { binding, url: new_url, server_id: new_sid, location_id: loc.id, hist }; save_state(); }
		st.last_rotation = { at: ST.now(), to_server: new_sid, location: loc.code };
		// 9. apply + diagnostics
		let ar = apply_link(new_url, 'own rotation');
		if (ar.ok) {
			release();
			alert('rotated-' + replace(binding, ':', '-'), sprintf('Блокировка и ротация: %s → %s, сервер %d → %d (%s)',
				cfg.title ?? binding, loc.title ?? loc.code, hist.from_server, new_sid, C.router_name(X.contour, X.rid)));
			return { ok: true, action: 'rotated', server_id: new_sid, location: loc.code, attempts, patches };
		}
		U.log('warn', sprintf('candidate server %d failed diagnostics (%s)', new_sid, ar.err ?? ''));
		bl['' + new_sid] = ST.now() + BLACKLIST_S;
		old_server = new_sid;
		old_host = U.parse_vless(new_url)?.host;
	}
	if (opts.dry_run) return { ok: true, action: 'dry_run', plan, flags: API.patch_flags(cfg) };
	// waiting mode (spec: 3 candidates failed)
	let retry = X.settings.retry_min * 60;
	write_rotation(binding, (n) => {
		n.waiting = { since: n.waiting?.since ?? ST.now(), next_try: ST.now() + retry, attempts: attempts };
		n.blacklist = { ...blacklisted(n, ST.now()) };
		for (let s in tried) n.blacklist['' + s] = ST.now() + BLACKLIST_S;
		if (n.lock?.by == X.rid) n.lock = null;
	}, 'rotation: waiting mode');
	st.status = 'waiting';
	save_state();
	alert('waiting-' + replace(binding, ':', '-'), sprintf('Ротация не помогает (%d кандидатов) — режим ожидания: техработы или массовая блокировка. Повтор каждые %d мин.', attempts, X.settings.retry_min));
	return { ok: false, action: 'waiting', attempts };
}

// ---------- GitHub unavailable mode (spec §5) ----------
function github_down_s() {
	let since = ST.reachable_since();
	let base = since > 0 ? since : st.started_mono;
	return ST.mono() - base;
}

function rotate_without_github() {
	let b = bind_parts();
	U.sleep_s(int(U.rand01() * 90));
	let fc = find_config(X.token, b.config_id);
	if (fc.err) return { ok: false, err: fc.err };
	if (fc.cfg.connection_url != PK.current_link()) {
		apply_link(fc.cfg.connection_url, 'API link (GitHub down)');
		st.pending_writeback = { binding: X.binding, url: fc.cfg.connection_url, server_id: fc.cfg.server_id, location_id: fc.cfg.location_id };
		save_state();
		return { ok: true, action: 'applied_api' };
	}
	let r = rotate({ reason: 'blocked (GitHub down)', nolock: true });
	if (r.action == 'rotated') {
		st.pending_writeback = { binding: X.binding, url: PK.current_link(), server_id: r.server_id };
		save_state();
	}
	return r;
}

// when GitHub is back: rotator appends a revision with the new link
function writeback() {
	let p = st.pending_writeback;
	if (!p) return;
	let w = write_rotation(p.binding, (n) => {
		if (n.url != p.url) {
			n.rev = (n.rev ?? 0) + 1; n.url = p.url; n.server_id = p.server_id; n.location_id = p.location_id;
			if (p.hist) n.history = slice([...(n.history ?? []), p.hist], -ROT_HISTORY);
			n.updated_at = ST.now();
		}
		if (n.lock?.by == X.rid) n.lock = null;
	}, 'rotation: writeback after GitHub outage');
	if (w.ok) { U.log('info', 'writeback after GitHub outage done'); delete st.pending_writeback; save_state(); }
}

// ---------- follower report / bad channel ----------
function record_trigger(binding) {
	let now = ST.now(), mine = 0, ignore = false;
	let recs = read_routers();
	let others_ok = false;
	for (let rid in C.binding_routers(X.contour, binding))
		if (rid != X.rid && recs[rid] && recs[rid].status == 'ok' && now - (recs[rid].last_contact ?? 0) < 600) others_ok = true;
	ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		let t = filter(o.triggers?.[X.rid] ?? [], (x) => now - x < BAD_WINDOW);
		mine = length(t);
		if (mine >= 2 && others_ok) { ignore = true; return null; }
		push(t, now);
		return { ...o, triggers: { ...(o.triggers ?? {}), [X.rid]: t } };
	}, { message: 'trigger ' + X.rid });
	return { ignore, recs };
}

function follower_report(binding) {
	let r = rot_get(binding);
	let snap = r.ok ? r.obj.loc_snapshot : null;
	let pings = [];
	if (snap) {
		let ranked = P.rank_locations(snap);
		pings = map(filter(ranked, (x) => x.ms != null), (x) => ({ id: x.loc.id, ms: x.ms }));
	}
	ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		return { ...o, reports: { ...(o.reports ?? {}), [X.rid]: { at: ST.now(), pings } } };
	}, { message: 'blocked report ' + X.rid });
	U.log('info', 'follower: blocked report written, waiting for a token router');
}

// token router: take over a follower's fresh report
function handle_reports(recs) {
	let r = rot_get();
	if (!r.ok || !r.obj.reports) return;
	let now = ST.now(), last = r.obj.history?.[-1]?.at ?? 0;
	for (let rid, rep in r.obj.reports) {
		if (rid == X.rid || now - rep.at > 180 || rep.at < last) continue;
		if (first_token_router(X.binding, recs) != X.rid) return;
		U.log('info', 'blocked report from ' + C.router_name(X.contour, rid) + ' — rotating for it');
		let r = rotate({ reason: 'blocked on ' + C.router_name(X.contour, rid), ext_pings: rep.pings, for_report: true });
		U.log('info', 'rotation for report: ' + r.action + (r.err ? ' — ' + r.err : ''));
		return;
	}
	// no token router at all for this binding -> alert (any router)
}

// ---------- reconcile + cards (token router) ----------
function write_card(cfg, exists) {
	if (!X.bot_key) return;
	let lc = X.contour?.name;
	let card = { binding: X.binding, cid: X.cid, contour: lc, exists, title: cfg?.title, expires_at: cfg?.expires_at,
		auto_renewal: cfg?.auto_renewal, location_id: cfg?.location_id, updated_at: ST.now() };
	ST.update(C.p_card(X.cid, X.binding), () => card, { key: X.bot_key, message: 'card ' + X.binding });
}


function reconcile(recs, every_s) {
	if (!X.binding || !my_token_fits(X.binding)) return;
	if (first_token_router(X.binding, recs) != X.rid) return;
	let now = ST.now();
	if (now - (st.reconcile_at ?? 0) < every_s) return;
	st.reconcile_at = now;
	let b = bind_parts();
	let fc = find_config(X.token, b.config_id);
	if (fc.err) {
		if (fc.err == 'token_invalid') alert('token-invalid-' + X.rid, 'Токен StealthSurf недействителен на ' + C.router_name(X.contour, X.rid));
		else if (fc.err == 'config_missing') {
			alert('config-missing-' + replace(X.binding, ':', '-'), 'Конфиг ' + X.binding + ' исчез из аккаунта');
			if (!length(API.vless_configs(fc.list))) alert('account-empty-' + b.account, 'Аккаунт ' + b.account + ' пуст: нет vless-конфигов');
		}
		return;
	}
	let r = rot_get();
	let file_url = r.ok ? r.obj.url : null;
	if (fc.cfg.connection_url != file_url) {
		U.log('info', 'reconcile: API link differs from storage — writing it');
		write_rotation(X.binding, (n) => {
			n.rev = (n.rev ?? 0) + 1; n.url = fc.cfg.connection_url; n.server_id = fc.cfg.server_id;
			n.location_id = fc.cfg.location_id; n.updated_at = ST.now();
		}, 'rotation: reconcile with API');
	}
	if (fc.cfg.connection_url != PK.current_link()) apply_link(fc.cfg.connection_url, 'reconcile');
	// cards + location snapshot every 6 h
	if (now - (st.cards_at ?? 0) >= 6 * 3600) {
		write_card(fc.cfg, true);
		let lr = API.locations(X.token);
		if (lr.ok) {
			let snap = map(API.candidate_locations(lr.data, X.settings.exclude_locations), (l) => ({ id: l.id, code: l.code, ping_ip: l.ping_ip }));
			write_rotation(X.binding, (n) => { n.loc_snapshot = snap; }, 'rotation: location snapshot');
		}
		st.cards_at = now;
	}
}

// contour summary for the bot (router statuses) — written by the first online router
function write_summary(recs) {
	if (!X.bot_key) return;
	let now = ST.now();
	let online = filter(sort(keys(X.contour?.routers ?? {})), (rid) => rid == X.rid || now - (recs[rid]?.last_contact ?? 0) < OFFLINE_S);
	if (online[0] != X.rid) return;
	let list = [];
	for (let rid in sort(keys(X.contour.routers))) {
		let rec = rid == X.rid ? router_record() : recs[rid];
		push(list, { rid, name: C.router_name(X.contour, rid), status: rec?.status, last_contact: rec?.last_contact,
			has_token: rec?.has_token, binding: C.binding_of(X.contour, rid), ping_ms: rec?.ping_ms });
	}
	let sig = sprintf('%J', map(list, (x) => [x.rid, x.status, x.has_token, x.binding, int((x.last_contact ?? 0) / 1800)]));
	if (sig == st.summary_sig) return;
	let w = ST.update(X.cid + '/cards/_contour.json', () => ({ cid: X.cid, contour: X.contour.name, routers: list, updated_at: now }),
		{ key: X.bot_key, message: 'summary' });
	if (w.ok) st.summary_sig = sig;
}

// offline routers & bindings without any token router (any router may write these alerts)
function watchdog(recs) {
	let now = ST.now();
	for (let rid in keys(X.contour?.routers ?? {})) {
		if (rid == X.rid) continue;
		let lc = recs[rid]?.last_contact;
		if (lc && now - lc > OFFLINE_S)
			alert('offline-' + rid, sprintf('Роутер %s не на связи %d мин', C.router_name(X.contour, rid), int((now - lc) / 60)));
	}
	for (let bnd in C.all_bindings(X.contour)) {
		let b = C.parse_binding(bnd), has = false;
		for (let rid in C.binding_routers(X.contour, bnd)) {
			let rec = rid == X.rid ? router_record() : recs[rid];
			if (rec?.has_token && +rec.account == b.account) has = true;
		}
		if (!has) alert('notoken-' + replace(bnd, ':', '-'), 'Нет ни одного роутера с токеном для привязки ' + bnd + ' — некому ротировать');
	}
}

function ctx() { return X; }
function state() { return st; }

// ---------- one service iteration ----------
function tick() {
	let now_m = ST.mono();
	st.started_mono ??= now_m;
	U.cleanup_tmp();
	let gh_ok = refresh_contour();
	if (!X.binding) { st.status = 'no_binding'; save_state(); if (gh_ok) heartbeat(); return; }
	if (st.status == 'update_required') { save_state(); return; }

	// podkop changed after update?
	let pc = PK.check_podkop();
	st.podkop = pc;
	if (!pc.ok && PK.current_link() != null) {
		st.status = 'podkop_changed';
		alert('podkop-changed-' + X.rid, 'podkop изменился на ' + C.router_name(X.contour, X.rid) + ': ' + pc.reason + ' — нужна перенастройка');
		save_state(); heartbeat(); return;
	}

	if (gh_ok) { writeback(); deliver(); }

	// health
	let link = PK.current_link();
	let h = link ? H.check(link) : { verdict: 'no_link' };
	st.layers = h;
	st.last_check = ST.now();
	if (h.verdict == 'no_internet') { st.status = 'no_internet'; }
	else if (h.verdict == 'podkop_down') {
		st.status = 'podkop_down';
		U.log('warn', 'podkop/sing-box down — restarting podkop');
		PK.restart();
	}
	else if (h.verdict == 'ok') {
		st.counter = 0;
		if (st.status != 'waiting' || !st.rot?.waiting) st.status = 'ok';
		if (now_m - (st.lat_mono ?? 0) > 1800) { let l = PK.latency(); if (l.ms) { st.ping_ms = l.ms; st.ping_at = ST.now(); } st.lat_mono = now_m; }
	}
	else if (h.verdict == 'fail') {
		st.counter = (st.counter ?? 0) + 1;
		st.status = 'failing';
		U.log('warn', sprintf('check failed (l3=%s l4=%s), counter %d/%d', h.l3, h.l4, st.counter, X.settings.fail_threshold));
	}
	save_state();

	let ignore = st.ignore_until && ST.now() < st.ignore_until;
	if (st.counter >= X.settings.fail_threshold && !ignore) {
		st.status = 'blocked';
		save_state();
		if (!gh_ok && github_down_s() >= 180) {
			if (my_token_fits(X.binding)) rotate_without_github();
		} else if (gh_ok) {
			let t = record_trigger(X.binding);
			if (t.ignore) {
				st.ignore_until = ST.now() + BAD_IGNORE;
				st.status = 'bad_channel';
				alert('badchannel-' + X.rid, 'Плохой канал на ' + C.router_name(X.contour, X.rid) + ': сигналы блокировки игнорируются 1 час');
			} else if (my_token_fits(X.binding)) {
				let r = rotate({ reason: 'blocked' });
				U.log('info', 'rotation result: ' + r.action + (r.err ? ' — ' + r.err : ''));
			} else follower_report(X.binding);
		}
		save_state();
	}

	// waiting mode: retry every retry_min through the lock
	if (gh_ok && st.rot?.waiting && my_token_fits(X.binding) && ST.now() >= st.rot.waiting.next_try && st.counter >= X.settings.fail_threshold) {
		let r = rotate({ reason: 'retry (waiting)', retry: true });
		U.log('info', 'waiting-mode retry: ' + r.action);
	}

	// GitHub down: token routers compare with API every 2 min
	if (!gh_ok && github_down_s() >= 60 && my_token_fits(X.binding) && ST.now() - (st.gh_down_check ?? 0) >= 120) {
		st.gh_down_check = ST.now();
		let fc = find_config(X.token, bind_parts().config_id);
		if (!fc.err && fc.cfg.connection_url != PK.current_link()) {
			apply_link(fc.cfg.connection_url, 'API link while GitHub is down');
			st.pending_writeback = { binding: X.binding, url: fc.cfg.connection_url, server_id: fc.cfg.server_id, location_id: fc.cfg.location_id };
		}
	}

	if (gh_ok) {
		let recs = null;
		if (now_m - (st.routers_mono ?? 0) > 240 || st.status != 'ok') { recs = read_routers(); st.routers_mono = now_m; st.recs = recs; }
		recs ??= st.recs ?? {};
		if (my_token_fits(X.binding)) { handle_reports(recs); reconcile(recs, 600); }
		heartbeat();
		if (now_m - (st.watch_mono ?? 0) > 600) { watchdog(recs); write_summary(recs); st.watch_mono = now_m; }
	}
	delete st.recs;
	save_state();
}

export { VERSION, init, tick, rotate, refresh_contour, deliver, heartbeat, read_routers, alert, write_rotation, router_record,
	load_state, save_state, apply_link, first_token_router, ctx, state };
