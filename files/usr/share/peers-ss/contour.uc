// Peers-SS: contour model (contour.json) and file paths (spec §3)
'use strict';

import * as ST from './store.uc';
import { log } from './util.uc';

const DEFAULT_SETTINGS = {
	check_interval_s: 45, fail_threshold: 3, retry_min: 10,
	exclude_locations: ['smart', 'RU'], podkop_section: 'peers_ss'
};

function p_contour(c) { return c + '/contour.json'; }
function p_router(c, rid) { return c + '/routers/' + rid + '.json'; }
function p_rotation(c, binding) { return c + '/rotations/' + replace(binding, ':', '-') + '.json'; }
function p_invite(c, id) { return c + '/invites/' + id + '.json'; }
function p_card(c, binding) { return c + '/cards/' + replace(binding, ':', '-') + '.json'; }
function p_alert(c, ev) { return c + '/alerts/' + ev + '.json'; }

function new_contour(name, rid, binding) {
	let c = {
		schema: ST.SCHEMA, rev: 1, name,
		settings: { ...DEFAULT_SETTINGS },
		groups: { g1: { name: 'peers-ss', envs: { e1: { name: 'среда-1', config: binding, routers: [rid] } } } },
		standalone: {},
		routers: {}, archive: [], next_router_num: 2, next_group_num: 2, next_env_num: 2
	};
	c.routers[rid] = { name: 'openwrt-1' };
	return c;
}

function settings(c) { return { ...DEFAULT_SETTINGS, ...(c?.settings ?? {}) }; }

// iterate all envs: cb(env_id, env, group_id|null)
function each_env(c, cb) {
	for (let gid, g in c?.groups ?? {})
		for (let eid, e in g.envs ?? {}) cb(eid, e, gid);
	for (let eid, e in c?.standalone ?? {}) cb(eid, e, null);
}

function env_of(c, rid) {
	let res = null;
	each_env(c, (eid, e, gid) => { if (!res && index(e.routers ?? [], rid) >= 0) res = { env_id: eid, env: e, group_id: gid }; });
	return res;
}

function binding_of(c, rid) { return env_of(c, rid)?.env?.config; }

// all routers of all envs with this binding (spec: rotated together)
function binding_routers(c, binding) {
	let out = [];
	each_env(c, (eid, e) => {
		if (e.config == binding) for (let r in e.routers ?? []) if (index(out, r) < 0) push(out, r);
	});
	return sort(out);
}

function all_bindings(c) {
	let out = [];
	each_env(c, (eid, e) => { if (e.config && index(out, e.config) < 0) push(out, e.config); });
	return out;
}

function router_name(c, rid) { return c?.routers?.[rid]?.name ?? rid; }

function parse_binding(b) {
	let p = split(b ?? '', ':');
	return length(p) == 2 ? { account: +p[0], config_id: +p[1] } : null;
}

export { DEFAULT_SETTINGS, p_contour, p_router, p_rotation, p_invite, p_card, p_alert, new_contour, settings, each_env,
	env_of, binding_of, binding_routers, all_bindings, router_name, parse_binding };
