// Peers-SS: local secrets in /etc/peers-ss/secrets (0600), encrypted with a device-bound key.
// Honest note (spec §3): protects against casual viewing and leaked backups, not against root.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { ETC, mkdirp, writefile } from './util.uc';
import { encrypt_json, decrypt_json, device_key } from './crypto.uc';

const FILE = ETC + '/secrets';
let cache = null;

function rid() {
	let c = cursor();
	return c.get('peers-ss', 'main', 'router_id') ?? '';
}

function load() {
	if (cache) return cache;
	let env = fs.readfile(FILE);
	if (env == null) return (cache = {});
	let obj = decrypt_json(device_key(rid()), env);
	if (obj == null) {
		// other device / damaged file: start empty; next save() overwrites it
		warn('peers-ss: cannot decrypt ' + FILE + ' (other device or damaged file) — secrets must be entered again\n');
		obj = { _broken: true };
	}
	return (cache = obj);
}

function save(obj) {
	obj = { ...obj };
	delete obj._broken;
	mkdirp(ETC);
	writefile(FILE, encrypt_json(device_key(rid()), obj), 0600);
	cache = obj;
}

function get(k) { return load()[k]; }

function set(k, v) {
	let o = { ...load() };
	if (v == null) delete o[k]; else o[k] = v;
	save(o);
}

// re-encrypt after router_id changes (device key includes router_id)
function rekey(old_rid) {
	let env = fs.readfile(FILE);
	if (env == null) return;
	let obj = decrypt_json(device_key(old_rid), env);
	if (obj != null) save(obj);
}

export { load, save, get, set, rekey };
