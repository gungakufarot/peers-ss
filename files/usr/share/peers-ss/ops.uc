// Peers-SS: contour editing operations (pure functions on a contour object; caller saves with CAS)
// Every function returns null on success or an error string. Spec §8 (groups, envs, devices, scheme change, archive).
'use strict';

import * as C from './contour.uc';

function valid_name(n) { return type(n) == 'string' && length(trim(n)) >= 1 && length(n) <= 32 && trim(n) == n; }

function all_names(c) {
	let n = [];
	for (let rid, r in c.routers ?? {}) push(n, ['router', rid, r.name]);
	for (let gid, g in c.groups ?? {}) {
		push(n, ['group', gid, g.name]);
		for (let eid, e in g.envs ?? {}) push(n, ['env', gid + '/' + eid, e.name]);
	}
	for (let eid, e in c.standalone ?? {}) push(n, ['env', 'standalone/' + eid, e.name]);
	return n;
}

// names are unique inside the contour (spec §8), 1-32 chars
function check_name(c, kind, id, name) {
	if (!valid_name(name)) return 'name must be 1-32 characters without leading/trailing spaces';
	for (let x in all_names(c)) if (x[2] == name && !(x[0] == kind && x[1] == id)) return 'name «' + name + '» is already used';
	return null;
}

function bump(c, by) { c.rev = (c.rev ?? 0) + 1; c.edited_by = by; c.edited_at = time(); }

function find_env(c, gid, eid) {
	if (gid) return c.groups?.[gid]?.envs?.[eid];
	return c.standalone?.[eid];
}

function next_id(c, prefix, key) {
	let n = c[key] ?? 2;
	c[key] = n + 1;
	return prefix + n;
}

function free_name(c, base, start) {
	let used = {};
	for (let x in all_names(c)) used[x[2]] = true;
	for (let i = start ?? 1; ; i++) {
		let n = (i == 1 && base == 'peers-ss') ? base : base + '-' + i;
		if (!used[n]) return n;
	}
}

function detach_router(c, rid) {
	C.each_env(c, (eid, e) => { e.routers = filter(e.routers ?? [], (r) => r != rid); });
}

function archive_binding(c, gid, eid, binding, at) {
	if (!binding) return;
	c.archive = [...(c.archive ?? []), { at, group: gid, env: eid, config: binding }];
	if (length(c.archive) > 50) c.archive = slice(c.archive, -50);
}

// ---- operations ----
function rename_router(c, rid, name) {
	if (!c.routers?.[rid]) return 'no such router';
	let e = check_name(c, 'router', rid, name); if (e) return e;
	c.routers[rid].name = name;
	return null;
}

function rename_group(c, gid, name) {
	if (!c.groups?.[gid]) return 'no such group';
	let e = check_name(c, 'group', gid, name); if (e) return e;
	c.groups[gid].name = name;
	return null;
}

function rename_env(c, gid, eid, name) {
	let env = find_env(c, gid, eid);
	if (!env) return 'no such environment';
	let e = check_name(c, 'env', (gid ?? 'standalone') + '/' + eid, name); if (e) return e;
	env.name = name;
	return null;
}

function create_group(c, name) {
	let gid = next_id(c, 'g', 'next_group_num');
	name ??= free_name(c, 'peers-ss', 2);
	let e = check_name(c, 'group', gid, name); if (e) return e;
	let eid = next_id(c, 'e', 'next_env_num');
	c.groups = { ...(c.groups ?? {}), [gid]: { name, envs: { [eid]: { name: free_name(c, 'среда', 1), config: null, routers: [] } } } };
	return null;
}

function create_env(c, gid, name) {
	if (!c.groups?.[gid]) return 'no such group';
	let eid = next_id(c, 'e', 'next_env_num');
	name ??= free_name(c, 'среда', 2);
	let e = check_name(c, 'env', gid + '/' + eid, name); if (e) return e;
	c.groups[gid].envs[eid] = { name, config: null, routers: [] };
	return null;
}

function delete_env(c, gid, eid) {
	let env = find_env(c, gid, eid);
	if (!env) return 'no such environment';
	if (length(env.routers ?? [])) return 'environment is not empty';
	archive_binding(c, gid, eid, env.config, time());
	if (gid) delete c.groups[gid].envs[eid]; else delete c.standalone[eid];
	return null;
}

function delete_group(c, gid) {
	let g = c.groups?.[gid];
	if (!g) return 'no such group';
	for (let eid, e in g.envs ?? {}) if (length(e.routers ?? [])) return 'group is not empty';
	for (let eid, e in g.envs ?? {}) archive_binding(c, gid, eid, e.config, time());
	delete c.groups[gid];
	return null;
}

function assign_config(c, gid, eid, binding) {
	let env = find_env(c, gid, eid);
	if (!env) return 'no such environment';
	if (binding != null && !C.parse_binding(binding)) return 'bad binding';
	if (env.config && env.config != binding) archive_binding(c, gid, eid, env.config, time());
	env.config = binding;
	return null;
}

// move router into gid/eid; eid == null -> new environment in that group (config optional)
function move_router(c, rid, gid, eid, config) {
	if (!c.routers?.[rid]) return 'no such router';
	if (gid && !c.groups?.[gid]) return 'no such group';
	if (eid && !find_env(c, gid, eid)) return 'no such environment';
	detach_router(c, rid);
	let env;
	if (eid) env = find_env(c, gid, eid);
	else {
		let neid = next_id(c, 'e', 'next_env_num');
		if (gid) env = c.groups[gid].envs[neid] = { name: free_name(c, 'среда', 2), config: config ?? null, routers: [] };
		else env = (c.standalone ??= {})[neid] = { name: c.routers[rid].name, config: config ?? null, routers: [] };
	}
	env.routers = [...(env.routers ?? []), rid];
	return null;
}

// standalone = environment of 1 router outside groups, keeps its current config
function make_standalone(c, rid) {
	let cur = C.env_of(c, rid);
	if (!cur) return 'router not in any environment';
	if (!cur.group_id && length(cur.env.routers) == 1) return 'already standalone';
	return move_router(c, rid, null, null, cur.env.config);
}

function remove_router(c, rid) {
	if (!c.routers?.[rid]) return 'no such router';
	detach_router(c, rid);
	delete c.routers[rid];
	return null;
}

// scheme change: merge environments of a group into one; the kept env keeps `keep_config`, others go to archive
function merge_envs(c, gid, eids, keep_config) {
	let g = c.groups?.[gid];
	if (!g || length(eids) < 2) return 'choose at least 2 environments of one group';
	let target = g.envs[eids[0]];
	if (!target) return 'no such environment';
	let at = time();
	for (let i = 1; i < length(eids); i++) {
		let e = g.envs[eids[i]];
		if (!e) return 'no such environment';
		target.routers = [...target.routers, ...(e.routers ?? [])];
		if (e.config && e.config != keep_config) archive_binding(c, gid, eids[i], e.config, at);
		delete g.envs[eids[i]];
	}
	if (target.config && target.config != keep_config) archive_binding(c, gid, eids[0], target.config, at);
	target.config = keep_config;
	return null;
}

// scheme change: split routers out of an environment into a new one (config: from archive / any binding / null)
function split_env(c, gid, eid, rids, config) {
	let env = find_env(c, gid, eid);
	if (!env) return 'no such environment';
	if (!length(rids) || length(rids) >= length(env.routers)) return 'choose some (not all) routers to split off';
	for (let r in rids) if (index(env.routers, r) < 0) return 'router not in this environment';
	let neid = next_id(c, 'e', 'next_env_num');
	let ne = { name: free_name(c, 'среда', 2), config: config ?? null, routers: rids };
	if (gid) c.groups[gid].envs[neid] = ne; else c.standalone[neid] = ne;
	env.routers = filter(env.routers, (r) => index(rids, r) < 0);
	if (config) c.archive = filter(c.archive ?? [], (a) => !(a.config == config && a.group == gid));
	return null;
}

// archived bindings that could be restored for a group (spec §8)
function archive_for(c, gid) { return filter(c.archive ?? [], (a) => a.group == gid); }

// apply named operation with args object (used by rpcd)
function apply(c, op, a) {
	switch (op) {
	case 'rename_router': return rename_router(c, a.rid, a.name);
	case 'rename_group': return rename_group(c, a.gid, a.name);
	case 'rename_env': return rename_env(c, a.gid, a.eid, a.name);
	case 'create_group': return create_group(c, a.name);
	case 'create_env': return create_env(c, a.gid, a.name);
	case 'delete_env': return delete_env(c, a.gid, a.eid);
	case 'delete_group': return delete_group(c, a.gid);
	case 'assign_config': return assign_config(c, a.gid, a.eid, a.binding);
	case 'move_router': return move_router(c, a.rid, a.gid, a.eid, a.config);
	case 'make_standalone': return make_standalone(c, a.rid);
	case 'remove_router': return remove_router(c, a.rid);
	case 'merge_envs': return merge_envs(c, a.gid, a.eids, a.config);
	case 'split_env': return split_env(c, a.gid, a.eid, a.rids, a.config);
	case 'settings': {
		let s = { ...(c.settings ?? {}) };
		for (let k in ['check_interval_s', 'fail_threshold', 'retry_min']) if (a[k] != null) {
			let v = +a[k];
			if (!(v >= 1 && v <= 3600)) return k + ': wrong value';
			s[k] = v;
		}
		if (s.check_interval_s < 15) return 'check interval must be >= 15 s';
		if (a.exclude_locations != null) s.exclude_locations = filter(map(split('' + a.exclude_locations, /[ ,]+/), trim), length);
		if (a.podkop_section != null) { if (!match(a.podkop_section, /^[A-Za-z0-9_]+$/)) return 'bad podkop section'; s.podkop_section = a.podkop_section; }
		if (a.bot_key != null) { if (a.bot_key != '' && !match(a.bot_key, /^[0-9a-f]{64}$/)) return 'bot key: 64 hex'; s.bot_key = a.bot_key || null; }
		if (a.bot_events != null) s.bot_events = a.bot_events;
		c.settings = s;
		return null;
	}
	}
	return 'unknown operation ' + op;
}

export { valid_name, check_name, bump, find_env, rename_router, rename_group, rename_env, create_group, create_env, delete_env,
	delete_group, assign_config, move_router, make_standalone, remove_router, merge_envs, split_env, archive_for, apply };
