// Peers-SS: engine — polling, rotation, delivery, alerts, cards (spec §5, §9)
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import * as U from './util.uc';
import * as S from './keystore.uc';
import * as ST from './store.uc';
import * as C from './contour.uc';
import * as API from './api.uc';
import * as PK from './podkop.uc';
import * as H from './health.uc';
import * as P from './ping.uc';
import { fp } from './crypto.uc';
import { try_rekey, switch_key } from './invite.uc';

const VERSION = '1.0.2';
const STATE = U.RUN + '/state.json';
const LOCK_TTL = 180;
const ROT_HISTORY = 10;
const BLACKLIST_S = 86400;
const ALERT_EVERY = 6 * 3600;
const HEARTBEAT_S = 1800;
const OFFLINE_S = 3600;
const BAD_WINDOW = 1800, BAD_IGNORE = 3600;

let X = null;      // context
let START_MONO = null;   // monotonic start of this process (GitHub-down timer)
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
	ST.set_keyring(sec.prev_keys ?? []);
	load_state();
	START_MONO ??= ST.mono();
	return true;
}

function refresh_contour() {
	let r = ST.get(C.p_contour(X.cid));
	// contour password changed on another router: follow the rekey chain (spec §8 «Сменить пароль контура»),
	// on a key error and every 10 min (files may already be re-encrypted while contour.json is still old)
	if ((!r.ok && r.bad_key) || ST.mono() - (st.rekey_mono ?? 0) > 600 || ST.mono() < (st.rekey_mono ?? 0)) {
		st.rekey_mono = ST.mono();
		let nk = try_rekey(X.cid, X.key);
		if (nk) {
			U.log('info', 'contour password was changed — switching to the new key');
			switch_key(nk, X.key);
			X.key = nk;
			r = ST.get(C.p_contour(X.cid));
		}
	}
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
// routers/*.json in one listing (+ only changed files)
function read_routers() {
	let d = ST.read_dir(X.cid + '/routers') ?? {}, out = {};
	for (let rid in keys(X.contour?.routers ?? {})) if (d[rid + '.json']) out[rid] = d[rid + '.json'];
	return out;
}

// first online router with a token of this binding's account (deterministic by router id)
function first_token_router(binding, recs) {
	let b = C.parse_binding(binding), now = ST.now();
	for (let rid in C.binding_routers(X.contour, binding)) {
		let rec = rid == X.rid ? router_record() : recs[rid];
		if (!rec) continue;
		let fresh = rid == X.rid || now - (rec.last_contact ?? 0) < HEARTBEAT_S + 300;
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

// ---------- local (per-router) engine lock: daemon tick, CLI check/rotate, rpcd must not overlap ----------
let LOCK_DEPTH = 0;
function engine_lock(wait_s) {
	if (LOCK_DEPTH > 0) { LOCK_DEPTH++; return true; }
	let d = U.RUN + '/engine.lock';
	U.mkdirp(U.RUN);
	let t0 = time();
	let mypid = trim(fs.readfile('/proc/self/stat') ?? '0');
	mypid = split(mypid, ' ')[0];
	while (true) {
		if (fs.mkdir(d, 0700)) { fs.writefile(d + '/pid', mypid); LOCK_DEPTH = 1; return true; }
		// stale: owner process is gone (killed daemon) or lock older than 15 min
		let owner = trim(fs.readfile(d + '/pid') ?? '');
		let stt = fs.stat(d);
		if ((owner && !fs.stat('/proc/' + owner)) || (!owner && stt && time() - stt.mtime > 10) || (stt && time() - stt.mtime > 900)) {
			fs.unlink(d + '/pid'); fs.rmdir(d); continue;
		}
		if (time() - t0 >= (wait_s ?? 0)) return false;
		U.sleep_s(2);
	}
}
function engine_unlock() {
	if (LOCK_DEPTH > 1) { LOCK_DEPTH--; return; }
	LOCK_DEPTH = 0;
	fs.unlink(U.RUN + '/engine.lock/pid');
	fs.rmdir(U.RUN + '/engine.lock');
}

function blacklisted(o, now) {
	let b = {};
	for (let sid, until in o?.blacklist ?? {}) if (until > now) b[sid] = until;
	return b;
}
function blacklisted_any(o, now) { return blacklisted(o, now); }

// API answers for GET /configs may be cached up to 300 s (spec §6): right after a rotation the API can still
// return the old (blocked) link. Such a link must never be adopted.
const API_CACHE_S = 330;
function api_link_trusted(cfg, rot) {
	let now = ST.now();
	let last = max(rot?.updated_at ?? 0, rot?.history?.[-1]?.at ?? 0, st.last_rotation?.at ?? 0);
	if (now - last < API_CACHE_S) return false;
	if (blacklisted_any(rot, now)['' + cfg.server_id]) return false;
	if ((st.own_bl?.['' + cfg.server_id] ?? 0) > now) return false;
	return true;
}

// poll rotations/… and apply a revision newer than the applied one (spec §5 "Остальные роутеры")
function deliver() {
	if (!X.binding || st.pending_writeback) return;
	let r = rot_get();
	if (!r.ok) return;
	st.rot = { rev: r.obj.rev, waiting: r.obj.waiting, updated_at: r.obj.updated_at };
	let cur = PK.current_link();
	if (r.obj.url && r.obj.url == cur) { st.applied_rev = r.obj.rev; return; }
	if (r.obj.url && (r.obj.rev ?? 0) > (st.applied_rev ?? -1)) {
		if (st.status == 'update_required') return;
		let a = apply_link(r.obj.url, 'rotations rev ' + r.obj.rev);
		if (a.changed || a.ok) st.applied_rev = r.obj.rev;
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

// takes the lock and re-checks (inside the CAS) everything that another router may have changed
function lock_take(binding, opts, cur_link) {
	let now = ST.now(), res = null;
	let w = ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		if (o.lock && o.lock.by != X.rid && o.lock.until > now) { res = 'busy'; return null; }
		if (o.url && o.url != cur_link && (o.rev ?? 0) > (st.applied_rev ?? -1)) { res = 'newer'; return null; }
		let last = o.history?.[-1]?.at ?? 0;
		if (!opts.manual && !opts.retry && now - last < X.settings.retry_min * 60) { res = 'too_soon'; return null; }
		if (!opts.manual && o.waiting && now < o.waiting.next_try) { res = 'waiting'; return null; }
		if (opts.retry && !o.waiting) { res = 'too_soon'; return null; }   // waiting already over (someone recovered)
		return { ...o, lock: { by: X.rid, until: now + LOCK_TTL } };
	}, { message: 'lock ' + binding });
	if (!w.ok) return { ok: false, why: 'github' };
	if (res) return { ok: false, why: res, obj: w.obj };
	return { ok: true, obj: w.obj, taken_mono: ST.mono() };
}

// extend our lock before each PATCH; false if we lost it
function lock_renew(binding) {
	let lost = false, now = ST.now();
	let w = ST.update(rot_path(binding), (o) => {
		if (!o?.lock || o.lock.by != X.rid) { lost = true; return null; }
		return { ...o, lock: { by: X.rid, until: now + LOCK_TTL } };
	}, { message: 'lock renew' });
	return w.ok && !lost;
}

// wait up to 3 min for someone else's new link
function wait_new_link(binding, max_s) {
	let t0 = ST.mono(), cur = PK.current_link();
	while (ST.mono() - t0 < (max_s ?? 180)) {
		U.sleep_s(10);
		let r = rot_get(binding);
		if (r.ok && r.obj.url && r.obj.url != cur) {
			apply_link(r.obj.url, 'rotation by ' + (r.obj.lock?.by ?? r.obj.history?.[-1]?.by ?? '?'));
			st.applied_rev = r.obj.rev;
			return true;
		}
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

function apply_candidate(url) {
	let ar = apply_link(url, 'own rotation');
	if (!ar.ok && match(ar.err ?? '', /locked/)) { U.sleep_s(15); ar = apply_link(url, 'own rotation (retry)'); }
	return ar;
}

// opts: { reason, manual, dry_run, ext_pings, nolock, retry, for_report }
// returns { ok, action: applied|recovered|rotated|locked|too_soon|waiting|error|dry_run|busy, ... }
function rotate_inner(opts) {
	let binding = X.binding;
	if (!binding) return { ok: false, action: 'error', err: 'no binding' };
	let b = C.parse_binding(binding);
	if (!my_token_fits(binding)) return { ok: false, action: 'error', err: 'no token of account ' + b.account };
	let now = ST.now();
	let cur_link = PK.current_link();

	// 1. newer revision already in the file
	let rf = opts.nolock ? null : rot_get(binding);
	if (rf?.ok && rf.obj.url && rf.obj.url != cur_link && (rf.obj.rev ?? 0) > (st.applied_rev ?? -1) && !opts.dry_run) {
		apply_link(rf.obj.url, 'rotation file newer');
		st.applied_rev = rf.obj.rev;
		return { ok: true, action: 'applied' };
	}
	if (!opts.manual && !opts.dry_run && rf?.ok && rf.obj.waiting && now < rf.obj.waiting.next_try)
		return { ok: false, action: 'waiting', err: 'next try in ' + (rf.obj.waiting.next_try - now) + ' s' };
	// 10-minute rule (normal mode)
	let last = rf?.ok ? (rf.obj.history?.[-1]?.at ?? 0) : max(st.last_rotation?.at ?? 0, 0);
	if (!opts.manual && !opts.dry_run && !opts.retry && now - last < X.settings.retry_min * 60)
		return { ok: false, action: 'too_soon', err: 'last rotation ' + (now - last) + ' s ago' };

	// 2. lock
	let lock_mono = ST.mono();
	if (!opts.nolock && !opts.dry_run) {
		let l = lock_take(binding, opts, cur_link);
		if (!l.ok) {
			if (l.why == 'busy') {
				U.log('info', 'rotation lock held by ' + l.obj.lock.by + ', waiting for new link');
				return { ok: wait_new_link(binding), action: 'locked' };
			}
			if (l.why == 'newer') { apply_link(l.obj.url, 'rotation file newer'); st.applied_rev = l.obj.rev; return { ok: true, action: 'applied' }; }
			if (l.why == 'github') return { ok: false, action: 'error', err: 'cannot take lock (GitHub)' };
			return { ok: false, action: l.why };
		}
		rf = { ok: true, obj: l.obj };
	}
	let release = () => { if (!opts.nolock && !opts.dry_run) rot_release(binding); };

	// 3. re-check layers 3-4 (skipped for a follower's report: the block is there, the bad-channel rule guards it)
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
		if (api_link_trusted(cfg, rf?.obj)) {
			U.log('info', 'API link differs from mine (changed in console / other contour) — taking it');
			let w = write_rotation(binding, (n) => {
				n.rev = (n.rev ?? 0) + 1; n.url = cfg.connection_url; n.server_id = cfg.server_id; n.location_id = cfg.location_id;
				n.lock = null; n.updated_at = ST.now();
			}, 'rotation: link from API');
			apply_link(cfg.connection_url, 'API link');
			if (w.ok) st.applied_rev = w.obj.rev;
			return { ok: true, action: 'applied_api' };
		}
		U.log('info', 'API link differs but may be a cached (stale) answer — ignored');
		cfg = { ...cfg, connection_url: cur_link ?? cfg.connection_url, server_id: rf?.obj?.server_id ?? cfg.server_id };
	}

	// 5. locations ranked by ping (from the router that saw the block)
	let lr = API.locations(X.token);
	if (!lr.ok) { release(); return { ok: false, action: 'error', err: 'GET /locations failed' }; }
	let locs = API.candidate_locations(lr.data, X.settings.exclude_locations);
	let ranked = filter(ranked_locations(locs, opts.ext_pings), (x) => x.ms != null);
	let vport = U.parse_vless(cfg.connection_url)?.port;
	let bl = blacklisted(rf?.obj, now);
	for (let sid, until in st.own_bl ?? {}) if (until > now) bl[sid] = until;
	bl['' + cfg.server_id] = now + BLACKLIST_S;

	let max_cand = opts.retry ? 1 : 3;
	let attempts = 0, patches = 0, tried = [], old_server = cfg.server_id, plan = [];
	let old_host = U.parse_vless(cfg.connection_url)?.host;
	let li = 0;
	while (attempts < max_cand && patches < 6 && li < length(ranked)) {
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
		// 7. PATCH (lock renewed first; abort if lost). Preference list; if the service kept the same server — explicit server_id once
		let pr = null, moved = false;
		for (let mode in ['list', 'single']) {
			if (!opts.nolock && (!lock_renew(binding) || ST.mono() - lock_mono > 600)) {
				U.log('warn', 'rotation lock lost — stopping this rotation');
				return { ok: false, action: 'error', err: 'lock lost' };
			}
			pr = API.patch_settings(X.token, cfg, loc.id, ids, mode == 'single' ? ids[0] : null);
			patches++;
			if (!pr.ok) break;
			let nh = U.parse_vless(pr.data?.connection_url ?? '')?.host;
			moved = pr.data?.server_id != old_server && nh != old_host;
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
			// still on the blocked server: publish its recreated link so others stay in sync; next location
			U.log('warn', sprintf('location %s: config stayed on server %s — next location', loc.code, new_sid));
			let w = write_rotation(binding, (n) => { n.rev = (n.rev ?? 0) + 1; n.url = new_url; n.server_id = new_sid; n.updated_at = ST.now(); }, 'rotation: same server, relinked');
			if (w.ok) st.applied_rev = w.obj.rev;
			li++;
			continue;
		}
		attempts++;
		push(tried, new_sid);
		cfg = { ...cfg, connection_url: new_url, server_id: new_sid, location_id: loc.id };
		st.own_bl = { ...(st.own_bl ?? {}), ['' + old_server]: ST.now() + BLACKLIST_S };
		// 8. write file
		let hist = { at: ST.now(), by: X.rid, reason: opts.reason ?? 'blocked', from_server: old_server, to_server: new_sid,
			location: loc.code, location_id: loc.id };
		let w = opts.nolock ? { ok: false } : write_rotation(binding, (n) => {
			n.rev = (n.rev ?? 0) + 1; n.url = new_url; n.server_id = new_sid; n.location_id = loc.id;
			n.history = slice([...(n.history ?? []), hist], -ROT_HISTORY);
			n.location_title = loc.title;
			n.blacklist = { ...blacklisted(n, ST.now()), ['' + old_server]: ST.now() + BLACKLIST_S };
			n.lock = { by: X.rid, until: ST.now() + LOCK_TTL };
			n.reports = {};
			n.waiting = null;
			n.updated_at = ST.now();
		}, sprintf('rotation: %s -> server %d (%s)', binding, new_sid, loc.code));
		if (w.ok) st.applied_rev = w.obj.rev;
		else st.pending_writeback = { binding, url: new_url, server_id: new_sid, location_id: loc.id, hist, old_server };
		st.last_rotation = { at: ST.now(), to_server: new_sid, location: loc.code };
		save_state();
		// 9. apply + diagnostics
		let ar = apply_candidate(new_url);
		if (ar.ok) {
			release();
			delete st.waiting_until;
			alert('rotated-' + replace(binding, ':', '-'), sprintf('Блокировка и ротация: %s → %s, сервер %d → %d (%s)',
				cfg.title ?? binding, loc.title ?? loc.code, hist.from_server, new_sid, C.router_name(X.contour, X.rid)));
			return { ok: true, action: 'rotated', server_id: new_sid, location: loc.code, attempts, patches };
		}
		U.log('warn', sprintf('candidate server %d failed diagnostics (%s)', new_sid, ar.err ?? ''));
		bl['' + new_sid] = ST.now() + BLACKLIST_S;
		st.own_bl['' + new_sid] = ST.now() + BLACKLIST_S;
		old_server = new_sid;
		old_host = U.parse_vless(new_url)?.host;
	}
	if (opts.dry_run) return { ok: true, action: 'dry_run', plan, flags: API.patch_flags(cfg) };
	// waiting mode (spec: candidates failed / none available): one router retries every retry_min through the lock
	let retry = X.settings.retry_min * 60;
	st.waiting_until = ST.now() + retry;
	if (!opts.nolock) {
		let ww = write_rotation(binding, (n) => {
			n.waiting = { since: n.waiting?.since ?? ST.now(), next_try: ST.now() + retry, attempts: (n.waiting?.attempts ?? 0) + attempts };
			n.blacklist = { ...blacklisted(n, ST.now()) };
			for (let s in tried) n.blacklist['' + s] = ST.now() + BLACKLIST_S;
			if (n.lock?.by == X.rid) n.lock = null;
		}, 'rotation: waiting mode');
		if (ww.ok) st.rot = { rev: ww.obj.rev, waiting: ww.obj.waiting, updated_at: ww.obj.updated_at };
	}
	st.status = 'waiting';
	save_state();
	alert('waiting-' + replace(binding, ':', '-'), sprintf('Ротация не помогает (кандидатов: %d) — режим ожидания: техработы или массовая блокировка. Повтор каждые %d мин.', attempts, X.settings.retry_min));
	return { ok: false, action: 'waiting', attempts };
}

function rotate(opts) {
	opts ??= {};
	if (!engine_lock(opts.dry_run ? 30 : 150)) return { ok: false, action: 'busy', err: 'another Peers-SS process is working' };
	let r;
	try { r = rotate_inner(opts); }
	catch (e) { U.log('error', 'rotate failed: ' + e); r = { ok: false, action: 'error', err: '' + e }; }
	save_state();
	engine_unlock();
	return r;
}

// ---------- GitHub unavailable mode (spec §5) ----------
function github_down_s() {
	let since = ST.reachable_since();
	return ST.mono() - (since > 0 ? since : START_MONO);
}

function rotate_without_github() {
	if (st.waiting_until && ST.now() < st.waiting_until) return { ok: false, action: 'waiting' };
	if (st.last_rotation && ST.now() - st.last_rotation.at < X.settings.retry_min * 60) return { ok: false, action: 'too_soon' };
	let b = bind_parts();
	U.sleep_s(int(U.rand01() * 90));
	let fc = find_config(X.token, b.config_id);
	if (fc.err) return { ok: false, err: fc.err };
	if (fc.cfg.connection_url != PK.current_link() && api_link_trusted(fc.cfg, null)) {
		apply_link(fc.cfg.connection_url, 'API link (GitHub down)');
		st.pending_writeback ??= { binding: X.binding, url: fc.cfg.connection_url, server_id: fc.cfg.server_id, location_id: fc.cfg.location_id };
		save_state();
		return { ok: true, action: 'applied_api' };
	}
	U.log('warn', 'GitHub unreachable for 3+ min — rotating without lock');
	return rotate({ reason: 'blocked (GitHub down)', nolock: true });
}

// when GitHub is back: rotator appends a revision with the new link
function writeback() {
	let p = st.pending_writeback;
	if (!p) return;
	let w = write_rotation(p.binding, (n) => {
		if (n.url != p.url) {
			n.rev = (n.rev ?? 0) + 1; n.url = p.url; n.server_id = p.server_id; n.location_id = p.location_id ?? n.location_id;
			n.updated_at = ST.now();
		}
		// history + blacklist even if another router already published the link (reconcile)
		if (p.hist && !length(filter(n.history ?? [], (h) => h.at == p.hist.at && h.by == p.hist.by)))
			n.history = slice([...(n.history ?? []), { ...p.hist, note: 'written after GitHub outage' }], -ROT_HISTORY);
		if (p.old_server) n.blacklist = { ...blacklisted(n, ST.now()), ['' + p.old_server]: ST.now() + BLACKLIST_S };
		if (n.lock?.by == X.rid) n.lock = null;
	}, 'rotation: writeback after GitHub outage');
	if (w.ok) { U.log('info', 'writeback after GitHub outage done'); st.applied_rev = w.obj.rev; delete st.pending_writeback; save_state(); }
}

// ---------- follower report / bad channel ----------
let RECS = {}, RECS_MONO = 0;
function recs_refresh(force) {
	if (force || ST.mono() - RECS_MONO > 240) { RECS = read_routers(); RECS_MONO = ST.mono(); }
	return RECS;
}

// one trigger per blocked episode; ignored (bad channel) if this router triggered twice in 30 min while others pass
function record_trigger(binding) {
	let now = ST.now(), ignore = false;
	let recs = recs_refresh(true);
	let others_ok = false;
	for (let rid in C.binding_routers(X.contour, binding))
		if (rid != X.rid && recs[rid]?.status == 'ok' && now - (recs[rid].last_contact ?? 0) < HEARTBEAT_S + 300) others_ok = true;
	ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		let t = filter(o.triggers?.[X.rid] ?? [], (x) => now - x < BAD_WINDOW);
		if (length(t) >= 2 && others_ok) { ignore = true; return null; }
		push(t, now);
		return { ...o, triggers: { ...(o.triggers ?? {}), [X.rid]: t } };
	}, { message: 'trigger ' + X.rid });
	return { ignore };
}

// follower: report once per episode, refreshed every 150 s while still blocked
function follower_report(binding) {
	let now = ST.now();
	if (st.episode?.report_at && now - st.episode.report_at < 150) return;
	let r = rot_get(binding);
	let snap = r.ok ? r.obj.loc_snapshot : null;
	let pings = [];
	if (snap) {
		let ranked = P.rank_locations(snap);
		pings = map(filter(ranked, (x) => x.ms != null), (x) => ({ id: x.loc.id, ms: x.ms }));
	}
	let first_at = st.episode?.first_report_at ?? now;
	let w = ST.update(rot_path(binding), (o) => {
		o ??= { rev: 0, binding, history: [], blacklist: {}, reports: {}, triggers: {} };
		return { ...o, reports: { ...(o.reports ?? {}), [X.rid]: { at: ST.now(), first_at, pings } } };
	}, { message: 'blocked report ' + X.rid });
	if (w.ok) { st.episode.report_at = now; st.episode.first_report_at = first_at; }
	U.log('info', 'follower: blocked report written, waiting for a token router');
}

// token router: take over a follower's fresh report (first token router at once, any other after 100 s)
function handle_reports(recs) {
	let r = rot_get();
	if (!r.ok || !r.obj.reports) return;
	let now = ST.now(), last = r.obj.history?.[-1]?.at ?? 0;
	if (r.obj.waiting && now < r.obj.waiting.next_try) return;
	for (let rid, rep in r.obj.reports) {
		if (rid == X.rid || now - rep.at > 180 || rep.at < last) continue;
		let first = first_token_router(X.binding, recs) == X.rid;
		if (!first && now - (rep.first_at ?? rep.at) < 100) continue;
		U.log('info', 'blocked report from ' + C.router_name(X.contour, rid) + ' — rotating for it' + (first ? '' : ' (first token router did not react)'));
		let rr = rotate({ reason: 'blocked on ' + C.router_name(X.contour, rid), ext_pings: rep.pings, for_report: true });
		U.log('info', 'rotation for report: ' + rr.action + (rr.err ? ' — ' + rr.err : ''));
		return;
	}
}

// ---------- requests from LuCI on other routers: list vless configs through my token ----------
function serve_requests() {
	if (!X.token) return;
	let list = null;
	for (let f in ST.list_dir(X.cid + '/requests/' + X.rid) ?? []) {
		let path = X.cid + '/requests/' + X.rid + '/' + f.name;
		let r = ST.get(path);
		if (!r.ok || r.obj.answered_at || ST.now() - (r.obj.at ?? 0) > 300) continue;
		if (list == null) {
			let c = API.configs(X.token);
			if (!c.ok) return;
			list = map(API.vless_configs(c.data), (q) => ({ id: q.id, title: q.title, expires_at: q.expires_at, location_id: q.location_id,
				server_id: q.server_id, binding: X.acct + ':' + q.id }));
		}
		ST.update(path, (o) => o && !o.answered_at ? { ...o, answered_at: ST.now(), account: +X.acct, configs: list } : null, { message: 'configs answer' });
		U.log('info', 'answered configs request from ' + C.router_name(X.contour, r.obj.from));
	}
}

// a config assigned in LuCI on any router: the token router of that account creates rotations/<binding>.json
function ensure_rotation_files() {
	if (!X.token || st.ensured_sha == st.contour_sha) return;
	let ok = true;
	for (let bnd in C.all_bindings(X.contour)) {
		if (!my_token_fits(bnd)) continue;
		let r = ST.get(C.p_rotation(X.cid, bnd));
		if (r.ok || !r.missing) continue;
		let fc = find_config(X.token, C.parse_binding(bnd).config_id);
		if (fc.err) { ok = false; continue; }
		let w = ST.put(C.p_rotation(X.cid, bnd), { rev: 1, binding: bnd, url: fc.cfg.connection_url, server_id: fc.cfg.server_id,
			location_id: fc.cfg.location_id, history: [], blacklist: {}, reports: {}, triggers: {}, lock: null, updated_at: ST.now() },
			null, 'rotation ' + bnd + ': initial link');
		if (w.ok) U.log('info', 'created rotation file for ' + bnd); else ok = false;
	}
	if (ok) st.ensured_sha = st.contour_sha;
}

// ---------- reconcile + cards (token router) ----------
function write_card(cfg, exists) {
	if (!X.bot_key) return;
	let lc = X.contour?.name;
	let card = { binding: X.binding, cid: X.cid, contour: lc, exists, title: cfg?.title ?? null, expires_at: cfg?.expires_at,
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
			if (now - (st.cards_at ?? 0) >= 6 * 3600) { write_card(null, false); st.cards_at = now; }
			alert('config-missing-' + replace(X.binding, ':', '-'), 'Конфиг ' + X.binding + ' исчез из аккаунта');
			if (!length(API.vless_configs(fc.list))) alert('account-empty-' + b.account, 'Аккаунт ' + b.account + ' пуст: нет vless-конфигов');
		}
		return;
	}
	let r = rot_get();
	let file_url = r.ok ? r.obj.url : null;
	if (fc.cfg.connection_url != file_url && r.ok && !r.obj.lock && api_link_trusted(fc.cfg, r.obj)) {
		U.log('info', 'reconcile: API link differs from storage (changed in console) — writing it');
		let w = write_rotation(X.binding, (n) => {
			n.rev = (n.rev ?? 0) + 1; n.url = fc.cfg.connection_url; n.server_id = fc.cfg.server_id;
			n.location_id = fc.cfg.location_id; n.updated_at = ST.now();
		}, 'rotation: reconcile with API');
		if (w.ok) { apply_link(fc.cfg.connection_url, 'reconcile'); st.applied_rev = w.obj.rev; }
	}
	// config facts for LuCI (no secrets): title, expiry, auto-renewal, location
	if (r.ok) {
		let o = r.obj, lt = null;
		for (let l in o.loc_snapshot ?? []) if (l.id == fc.cfg.location_id) lt = l.title ?? l.code;
		if (!lt || lt == fc.cfg.location_id || !o.loc_snapshot?.[0]?.title) {
			// titles are not in an old snapshot yet: one GET /locations
			let lr = API.locations(X.token);
			if (lr.ok) for (let l in lr.data) if (l.id == fc.cfg.location_id) lt = l.title;
		}
		if (o.title != fc.cfg.title || o.expires_at != fc.cfg.expires_at || o.auto_renewal != fc.cfg.auto_renewal || (lt && o.location_title != lt))
			write_rotation(X.binding, (n) => { n.title = fc.cfg.title; n.expires_at = fc.cfg.expires_at; n.auto_renewal = fc.cfg.auto_renewal; if (lt) n.location_title = lt; }, 'rotation: config facts');
	}
	// cards + location snapshot every 6 h
	if (now - (st.cards_at ?? 0) >= 6 * 3600) {
		write_card(fc.cfg, true);
		let lr = API.locations(X.token);
		if (lr.ok) {
			let snap = map(API.candidate_locations(lr.data, X.settings.exclude_locations), (l) => ({ id: l.id, code: l.code, title: l.title, ping_ip: l.ping_ip }));
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

// ---------- UI snapshot (/tmp/peers-ss/ui.json): LuCI reads it instantly instead of GitHub round trips ----------
const UI_FILE = U.RUN + '/ui.json';
let UI_SLOW = null, UI_SLOW_MONO = 0;

function rotation_view(o) {
	return { rev: o.rev, server_id: o.server_id, location_id: o.location_id, location: o.location_title, title: o.title,
		expires_at: o.expires_at, auto_renewal: o.auto_renewal, lock: o.lock, waiting: o.waiting,
		history: o.history ?? [], updated_at: o.updated_at, link_fp: o.url ? fp(o.url) : null };
}

function ui_slow(force) {
	if (!force && UI_SLOW && ST.mono() - UI_SLOW_MONO < 300) return UI_SLOW;
	let cards = {}, alerts = [], invites = [];
	if (X.bot_key) {
		for (let n, o in ST.read_dir(X.cid + '/cards', X.bot_key) ?? {}) if (o?.binding) cards[o.binding] = o;
		for (let n, a in ST.read_dir(X.cid + '/alerts', X.bot_key) ?? {})
			push(alerts, { event: a.event, text: a.text, at: a.at, router: a.router });
		alerts = slice(sort(alerts, (a, b) => b.at - a.at), 0, 20);
	}
	let now = ST.now();
	for (let n, i in ST.read_dir(X.cid + '/invites') ?? {})
		push(invites, { id: i.id, group: i.group, env: i.env, created_at: i.created_at, expires_at: i.expires_at,
			used_by: i.used_by, used_name: i.used_by ? C.router_name(X.contour, i.used_by) : null, used_at: i.used_at,
			revoked: i.revoked, active: !i.revoked && !i.used_by && i.expires_at > now });
	UI_SLOW = { cards, alerts, invites: sort(invites, (a, b) => b.created_at - a.created_at) };
	UI_SLOW_MONO = ST.mono();
	return UI_SLOW;
}

function write_ui(force) {
	if (!X?.contour) return null;
	let rots = {};
	for (let b in C.all_bindings(X.contour)) {
		let r = rot_get(b);
		if (r.ok) rots[b] = rotation_view(r.obj);
	}
	let slow = ui_slow(force);
	let recs = RECS ?? {}, routers = [];
	for (let rid in sort(keys(X.contour.routers ?? {}))) {
		let r = rid == X.rid ? router_record() : recs[rid];
		let eo = C.env_of(X.contour, rid);
		push(routers, { rid, name: C.router_name(X.contour, rid), me: rid == X.rid, group: eo?.group_id, env: eo?.env_id,
			binding: eo?.env?.config, status: r?.status, last_contact: r?.last_contact, ping_ms: r?.ping_ms,
			has_token: r?.has_token, account: r?.account, token_label: r?.token_label, diag_ok: r?.diag_ok, version: r?.version });
	}
	let ui = { at: ST.now(), version: VERSION, rid: X.rid, cid: X.cid, repo: X.repo, binding: X.binding,
		contour: X.contour, settings: C.settings(X.contour), routers, rotations: rots, cards: slow.cards, alerts: slow.alerts,
		invites: slow.invites, podkop_section: PK.section(), has_token: !!X.token, account: X.token ? +X.acct : null,
		token_label: X.token ? S.get('ss_label') : null,
		state: { status: st.status, counter: st.counter, ping_ms: st.ping_ms, ping_at: st.ping_at, last_check: st.last_check,
			layers: st.layers, diag_ok: st.diag_ok, diag_fails: st.diag_fails, last_rotation: st.last_rotation,
			ignore_until: st.ignore_until }, podkop: st.podkop, github_error: ST.last_error() };
	U.mkdirp(U.RUN);
	U.writejson(UI_FILE, ui);
	return ui;
}

function ctx() { return X; }
function state() { return st; }

// ---------- one service iteration ----------
function tick_inner() {
	let now_m = ST.mono();
	U.cleanup_tmp();
	let gh_ok = refresh_contour();
	if (!X.binding) { st.status = 'no_binding'; if (gh_ok) { heartbeat(); serve_requests(); ensure_rotation_files(); } return; }
	if (st.status == 'update_required') return;

	// podkop changed after update? (spec §7)
	let pc = PK.check_podkop();
	st.podkop = pc;
	if (!pc.ok && PK.current_link() != null) {
		st.status = 'podkop_changed';
		alert('podkop-changed-' + X.rid, 'podkop изменился на ' + C.router_name(X.contour, X.rid) + ': ' + pc.reason + ' — нужна перенастройка');
		heartbeat(); return;
	}

	if (gh_ok) { writeback(); deliver(); }

	// health (4 layers)
	let link = PK.current_link();
	let h = link ? H.check(link) : { verdict: 'no_link' };
	st.layers = h;
	st.last_check = ST.now();
	let waiting = (st.rot?.waiting && ST.now() < st.rot.waiting.next_try + 600) || (st.waiting_until && ST.now() < st.waiting_until + 600);
	if (h.verdict == 'no_internet') st.status = 'no_internet';
	else if (h.verdict == 'podkop_down') {
		st.status = 'podkop_down';
		U.log('warn', 'podkop/sing-box down — restarting podkop');
		PK.restart();
	}
	else if (h.verdict == 'ok') {
		let was_blocked = !!st.episode;
		st.counter = 0;
		delete st.episode;
		delete st.waiting_until;
		st.status = 'ok';
		// link works again: leave waiting mode (any token router)
		if (gh_ok && was_blocked && st.rot?.waiting && my_token_fits(X.binding)) {
			let w = write_rotation(X.binding, (n) => { n.waiting = null; }, 'rotation: waiting mode over');
			if (w.ok) { st.rot.waiting = null; U.log('info', 'waiting mode over: link works'); }
		}
		if (st.lat_mono == null || now_m - st.lat_mono > 1800 || now_m < st.lat_mono) { let l = PK.latency(); if (l.ms) { st.ping_ms = l.ms; st.ping_at = ST.now(); } st.lat_mono = now_m; }
	}
	else if (h.verdict == 'fail') {
		st.counter = (st.counter ?? 0) + 1;
		st.status = waiting ? 'waiting' : 'failing';
		U.log('warn', sprintf('check failed (l3=%s l4=%s), counter %d/%d', h.l3, h.l4, st.counter, X.settings.fail_threshold));
	}
	save_state();

	let blocked = st.counter >= X.settings.fail_threshold;
	let ignore = st.ignore_until && ST.now() < st.ignore_until;
	if (blocked && !ignore) {
		if (!st.episode) {
			// new blocked episode: one trigger (bad-channel bookkeeping)
			st.episode = { at: ST.now() };
			if (gh_ok && record_trigger(X.binding).ignore) {
				st.ignore_until = ST.now() + BAD_IGNORE;
				st.status = 'bad_channel';
				alert('badchannel-' + X.rid, 'Плохой канал на ' + C.router_name(X.contour, X.rid) + ': сигналы блокировки игнорируются 1 час');
				save_state(); heartbeat(); return;
			}
		}
		st.status = waiting ? 'waiting' : 'blocked';
		save_state();
		if (!gh_ok && github_down_s() >= 180) {
			if (my_token_fits(X.binding)) {
				let r = rotate_without_github();
				U.log('info', 'rotation without GitHub: ' + (r.action ?? '-') + (r.err ? ' — ' + r.err : ''));
			}
		} else if (gh_ok) {
			if (my_token_fits(X.binding)) {
				let retry = st.rot?.waiting && ST.now() >= st.rot.waiting.next_try;
				let r = rotate({ reason: retry ? 'retry (waiting)' : 'blocked', retry });
				if (r.action != 'too_soon' && r.action != 'waiting') U.log('info', 'rotation result: ' + r.action + (r.err ? ' — ' + r.err : ''));
			} else follower_report(X.binding);
		}
		save_state();
	}

	// GitHub down: token routers compare with API every 2 min (never adopting a possibly cached/blocked link)
	if (!gh_ok && github_down_s() >= 60 && my_token_fits(X.binding) && ST.now() - (st.gh_down_check ?? 0) >= 120) {
		st.gh_down_check = ST.now();
		let fc = find_config(X.token, bind_parts().config_id);
		if (!fc.err && fc.cfg.connection_url != PK.current_link() && api_link_trusted(fc.cfg, null)) {
			apply_link(fc.cfg.connection_url, 'API link while GitHub is down');
			st.pending_writeback ??= { binding: X.binding, url: fc.cfg.connection_url, server_id: fc.cfg.server_id, location_id: fc.cfg.location_id };
		}
	}

	if (gh_ok) {
		let recs = recs_refresh(st.status != 'ok');
		if (my_token_fits(X.binding)) { handle_reports(recs); reconcile(recs, 600); }
		serve_requests();
		ensure_rotation_files();
		heartbeat();
		if (now_m - (st.watch_mono ?? 0) > 600 && length(keys(recs))) { watchdog(recs); write_summary(recs); st.watch_mono = now_m; }
		write_ui();
	}
}

function tick() {
	if (!engine_lock(60)) { U.log('info', 'tick skipped: another Peers-SS process is working'); return; }
	try { tick_inner(); } catch (e) { U.log('error', 'tick failed: ' + e + '\n' + (e.stacktrace?.[0]?.context ?? '')); }
	save_state();
	engine_unlock();
}

export { VERSION, init, tick, rotate, refresh_contour, deliver, heartbeat, read_routers, alert, write_rotation, router_record,
	load_state, save_state, apply_link, first_token_router, ctx, state, write_ui, recs_refresh, UI_FILE };
