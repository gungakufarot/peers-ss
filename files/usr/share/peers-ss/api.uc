// Peers-SS: StealthSurf API client (https://docs.stealthsurf.net/api)
'use strict';

import { cursor } from 'uci';
import { request, json_body } from './http.uc';
import { log, sleep_s, parse_vless } from './util.uc';

const BASE = 'https://api.stealthsurf.net';

// returns { ok, status, data, code (errorCode), message, retry_after }
function call(token, method, path, body) {
	let opts = { method, headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' }, timeout: 25 };
	if (body != null) {
		opts.headers['Content-Type'] = 'application/json';
		opts.body = sprintf('%J', body);
	}
	for (let attempt = 0; attempt < 3; attempt++) {
		let r = request(BASE + path, opts);
		let j = json_body(r) ?? {};
		let res = { ok: r.status == 200 && j.status === true, status: r.status, data: j.data,
			code: j.errorCode, message: j.message, retry_after: +(r.headers['retry-after'] ?? 0), err: r.err };
		if (r.status == 429 && attempt < 2) {
			let w = res.retry_after > 0 ? res.retry_after : 2;
			if (w > 60) return res;
			log('warn', sprintf('StealthSurf 429 on %s, waiting %ds', path, w));
			sleep_s(w);
			continue;
		}
		if (r.status == 503 && attempt < 2) { sleep_s(2); continue; }
		if (!res.ok)
			log('warn', sprintf('StealthSurf %s %s -> %d err=%s %s', method, path, r.status, res.code ?? '-', res.message ?? r.err ?? ''));
		return res;
	}
}

function profile(token) { return call(token, 'GET', '/profile'); }
function configs(token) { return call(token, 'GET', '/configs?limit=1000'); }
function locations(token) { return call(token, 'GET', '/locations'); }
function available_servers(token, location_id, protocol) {
	return call(token, 'GET', sprintf('/configs/available-servers?location_id=%d&protocol=%s', location_id, protocol));
}

// only vless:// configs (protocol field may be "vless", "vless-2410", ...)
function vless_configs(list) {
	let out = [];
	for (let c in list ?? [])
		if (c && type(c.connection_url) == 'string' && substr(c.connection_url, 0, 8) == 'vless://')
			push(out, c);
	return out;
}

// exclusion: "smart" = code RB or title "Умная…"; other entries compare with code (case-insensitive)
function location_excluded(loc, exclude) {
	for (let e in exclude ?? []) {
		e = lc(e);
		if (e == 'smart' && (lc(loc.code) == 'rb' || match(loc.title ?? '', /^Умная/))) return true;
		if (lc(loc.code ?? '') == e) return true;
	}
	return false;
}

function candidate_locations(list, exclude) {
	let out = [];
	for (let l in list ?? [])
		if (l && l.is_active && l.ping_ip && !location_excluded(l, exclude)) push(out, l);
	return out;
}

// flags to re-send on PATCH (spec §6). API does not return xray_config in GET /configs (RECON),
// so: use xray_config when present; otherwise derive what the link itself shows.
const FLAG_MAP = {
	is_warp_enabled: 'use_warp', is_reality_disabled: 'disable_reality', is_sni_changed: 'change_sni',
	is_sni_disabled: 'disable_sni', is_family_filter_enabled: 'enable_family_filter',
	is_block_bittorrent: 'block_bittorrent', is_pass_all_traffic_through_vpn: 'pass_all_traffic_through_vpn',
	is_xhttp_enabled: 'use_xhttp', is_grpc_enabled: 'use_grpc', is_grpc_multi_enabled: 'grpc_multi_mode',
	is_fingerprint_randomized: 'randomize_fingerprint', is_loopbacks_enabled: 'use_loopbacks'
};

function patch_flags(cfg) {
	let f = {};
	if (cfg.is_extended_settings_enabled) f.use_extended_settings = true;
	let x = null;
	if (type(cfg.xray_config) == 'string') { try { x = json(cfg.xray_config); } catch (e) {} }
	if (type(x) == 'object') {
		for (let k, b in FLAG_MAP) if (type(x[k]) == 'bool') f[b] = x[k];
		if (x.dns_preset) f.dns_preset = x.dns_preset;
		if (x.custom_dns_url) f.custom_dns_url = x.custom_dns_url;
		f._source = 'xray_config';
		return f;
	}
	let v = parse_vless(cfg.connection_url ?? '');
	if (v) {
		let p = v.params;
		if (p.security && p.security != 'reality') f.disable_reality = true;
		if (p.type == 'xhttp') f.use_xhttp = true;
		if (p.type == 'grpc') { f.use_grpc = true; if (p.mode == 'multi') f.grpc_multi_mode = true; }
		if (p.fp && p.fp != 'chrome') f.randomize_fingerprint = true;
	}
	f._source = 'link';
	return f;
}

// Test-mode guard: if peers-ss.main.test_patch_allow is set, PATCH only listed config ids.
// The option is absent in release builds (files/etc/config/peers-ss) — see docs/reports/FINAL.md.
function patch_allowed(config_id) {
	let allow = cursor().get('peers-ss', 'main', 'test_patch_allow');
	if (allow == null) return true;
	if (type(allow) != 'array') allow = [allow];
	for (let a in allow) if (+a == +config_id) return true;
	return false;
}

function patch_settings(token, cfg, location_id, server_ids) {
	if (!patch_allowed(cfg.id)) {
		log('error', sprintf('PATCH blocked by test_patch_allow for config %d', cfg.id));
		return { ok: false, status: 0, code: -1, message: 'blocked by test_patch_allow' };
	}
	let body = { location_id: +location_id, protocol: cfg.protocol };
	let f = patch_flags(cfg);
	for (let k, v in f) if (k != '_source') body[k] = v;
	if (length(server_ids)) body.server_ids = slice(server_ids, 0, 50);
	log('info', sprintf('PATCH config %d -> location %d, servers [%s], flags from %s', cfg.id, location_id, join(',', server_ids ?? []), f._source));
	return call(token, 'PATCH', sprintf('/configs/%d/settings', cfg.id), body);
}

export { call, profile, configs, locations, available_servers, vless_configs, location_excluded, candidate_locations, patch_flags, patch_allowed, patch_settings };
