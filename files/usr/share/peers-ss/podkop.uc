// Peers-SS: podkop 0.7.24 integration. Peers-SS changes exactly one field of podkop:
// proxy_string of the managed section (plus creating that section / enabling its mixed proxy once).
// "Apply" = what LuCI podkop does: uci commit -> procd config.change trigger -> /etc/init.d/podkop restart.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { ETC, RUN, q, sh, mkdirp, log, sleep_s, median, writefile } from './util.uc';
import { request } from './http.uc';

const PODKOP = '/usr/bin/podkop';
const TEST_URL = 'https://www.gstatic.com/generate_204';
const DEFAULT_MIXED_PORT = 2080;

function section() { return cursor().get('peers-ss', 'main', 'podkop_section') ?? 'peers_ss'; }

function installed() { return fs.access(PODKOP, 'x') && fs.access('/etc/init.d/podkop'); }

function version() {
	let r = sh('opkg status podkop | sed -n "s/^Version: //p"');
	return trim(r.out);
}

function proxy_sections() {
	let c = cursor(), out = [];
	c.foreach('podkop', 'section', (s) => {
		if (s.connection_type == 'proxy') push(out, s['.name']);
	});
	return out;
}

function section_ok(name) {
	let c = cursor();
	name ??= section();
	return c.get('podkop', name) == 'section' && c.get('podkop', name, 'connection_type') == 'proxy'
		&& c.get('podkop', name, 'proxy_config_type') == 'url';
}

function used_ports() {
	let r = sh("netstat -lnt | awk 'NR>2{n=split($4,a,\":\"); print a[n]}'");
	let s = {};
	for (let p in split(r.out, '\n')) if (p != '') s[p] = true;
	cursor().foreach('podkop', 'section', (x) => { if (x.mixed_proxy_port) s[x.mixed_proxy_port] = true; });
	return s;
}

// create the managed proxy section (spec §4 A.6) — only if it does not exist
function create_section(name) {
	let c = cursor();
	if (c.get('podkop', name) != null) return false;
	let used = used_ports(), port = DEFAULT_MIXED_PORT;
	while (used['' + port]) port++;
	c.set('podkop', name, 'section');
	c.set('podkop', name, 'connection_type', 'proxy');
	c.set('podkop', name, 'proxy_config_type', 'url');
	c.set('podkop', name, 'enable_udp_over_tcp', '0');
	c.set('podkop', name, 'mixed_proxy_enabled', '1');
	c.set('podkop', name, 'mixed_proxy_port', '' + port);
	c.save('podkop');
	return true;
}

// spec §7: enable mixed proxy of the managed section for tunnel checks
function ensure_mixed(name) {
	let c = cursor();
	if (c.get('podkop', name, 'mixed_proxy_enabled') == '1' && c.get('podkop', name, 'mixed_proxy_port')) return false;
	let used = used_ports(), port = DEFAULT_MIXED_PORT;
	while (used['' + port]) port++;
	c.set('podkop', name, 'mixed_proxy_enabled', '1');
	if (!c.get('podkop', name, 'mixed_proxy_port')) c.set('podkop', name, 'mixed_proxy_port', '' + port);
	c.save('podkop');
	return true;
}

// same rule as podkop get_service_listen_address: settings.service_listen_address, else IP of "lan"
function listen_address() {
	let a = cursor().get('podkop', 'settings', 'service_listen_address');
	if (a) return a;
	let u = connect();
	let st = u?.call('network.interface.lan', 'status');
	return st?.['ipv4-address']?.[0]?.address;
}

function mixed_proxy_url() {
	let port = cursor().get('podkop', section(), 'mixed_proxy_port');
	let addr = listen_address();
	return (port && addr) ? sprintf('socks5h://%s:%s', addr, port) : null;
}

function current_link() { return cursor().get('podkop', section(), 'proxy_string'); }

function backup_orig() {
	mkdirp(ETC);
	if (!fs.stat(ETC + '/podkop.orig')) {
		writefile(ETC + '/podkop.orig', fs.readfile('/etc/config/podkop'), 0600);
		log('info', 'saved original /etc/config/podkop to ' + ETC + '/podkop.orig');
	}
}

function restart() {
	// LuCI "Save & Apply": uci commit triggers procd -> restart. We commit and call restart directly
	// so we know when it finished (procd trigger would run the same restart after reload delay).
	return sh('/etc/init.d/podkop restart >/dev/null 2>&1').code;
}

function sing_box_running() { return sh('pidof sing-box').code == 0; }

// layer 4: request through the managed section's mixed proxy
function tunnel_check(timeout) {
	let px = mixed_proxy_url();
	if (!px) return { ok: false, err: 'no mixed proxy' };
	let r = request(TEST_URL, { proxy: px, timeout: timeout ?? 8, connect_timeout: 5 });
	return { ok: r.status == 204, status: r.status };
}

// spec §7 step 4: up to 60 s, every 5 s: sing-box up and layer 4 passes
function wait_up(max_s) {
	let t = 0;
	max_s ??= 60;
	sleep_s(3);
	while (t < max_s) {
		if (sing_box_running() && tunnel_check(6).ok) return true;
		sleep_s(5);
		t += 5;
	}
	return false;
}

// spec §7 step 6: latency via Clash API (sing-box URL test); fallback: median of 3 requests via mixed proxy
function latency() {
	let r = sh(sprintf('%s clash_api get_proxy_latency %s 5000', PODKOP, q(section() + '-out')));
	let j = null;
	try { j = json(r.out); } catch (e) {}
	if (j?.delay > 0) return { ms: j.delay, method: 'clash' };
	let px = mixed_proxy_url(), t = [];
	if (px) for (let i = 0; i < 3; i++) {
		let c = sh(sprintf('curl -s -o /dev/null -m 8 -x %s -w "%%{http_code} %%{time_total}" %s', q(px), q(TEST_URL)));
		let p = split(c.out, ' ');
		if (p[0] == '204') push(t, +p[1] * 1000);
	}
	let m = median(t);
	return m != null ? { ms: int(m), method: 'mixed' } : { ms: null, method: 'none' };
}

function pj(cmd) {
	let r = sh(PODKOP + ' ' + cmd);
	try { return json(r.out); } catch (e) { return null; }
}

// spec §7 step 5: the same router-side checks as the LuCI podkop "Diagnostics" tab
function diagnostics() {
	let d = {
		dns: pj('check_dns_available'),
		sing_box: pj('check_sing_box'),
		nft: pj('check_nft_rules'),
		fakeip: pj('check_fakeip'),
	};
	let fails = [];
	let req1 = (obj, keys, tag) => {
		if (obj == null) { push(fails, tag + ':no-data'); return; }
		for (let k in keys) if (obj[k] !== 1 && obj[k] !== true) push(fails, tag + ':' + k);
	};
	req1(d.dns, ['dns_status', 'dns_on_router', 'bootstrap_dns_status', 'dhcp_config_status'], 'dns');
	req1(d.sing_box, ['sing_box_installed', 'sing_box_version_ok', 'sing_box_service_exist', 'sing_box_autostart_disabled', 'sing_box_process_running', 'sing_box_ports_listening'], 'sing_box');
	// counters may legitimately be 0 when no traffic went through yet (RECON)
	req1(d.nft, ['table_exist', 'rules_mangle_exist', 'rules_mangle_output_exist', 'rules_proxy_exist', 'rules_other_mark_exist'], 'nft');
	req1(d.fakeip, ['fakeip'], 'fakeip');
	let lat = pj(sprintf('clash_api get_proxy_latency %s 5000', q(section() + '-out')));
	if (!(lat?.delay > 0)) push(fails, 'outbound:latency');
	d.outbound = lat;
	d.ok = length(fails) == 0;
	d.fails = fails;
	return d;
}

// spec §7 apply cycle. returns { changed, ok, diag, latency, err }
function apply_link(link, opts) {
	opts ??= {};
	if (type(link) != 'string' || substr(link, 0, 8) != 'vless://' || length(link) < 20)
		return { changed: false, ok: false, err: 'not a vless link' };
	let name = section();
	if (!section_ok(name)) return { changed: false, ok: false, err: 'podkop section missing: ' + name, podkop_changed: true };
	let cur = current_link();
	if (cur == link && !opts.force) return { changed: false, ok: true };
	backup_orig();
	mkdirp(RUN);
	if (cur) writefile(RUN + '/podkop.prev', cur, 0600);
	let c = cursor();
	c.set('podkop', name, 'proxy_config_type', 'url');
	c.set('podkop', name, 'proxy_string', link);
	c.save('podkop');
	c.commit('podkop');
	log('info', 'podkop: new link written to section ' + name + ', restarting podkop');
	restart();
	let up = wait_up(opts.wait ?? 60);
	let res = { changed: true, ok: up };
	if (!up) { res.err = 'tunnel did not come up in 60 s'; return res; }
	if (opts.diag !== false) {
		res.diag = diagnostics();
		res.ok = res.diag.ok;
		if (!res.ok) res.err = 'diagnostics: ' + join(',', res.diag.fails);
	}
	res.latency = latency();
	return res;
}

// roll back to the previous link (used when diagnostics of a new link fail and no candidate is left)
function restore_prev() {
	let prev = fs.readfile(RUN + '/podkop.prev');
	return prev ? apply_link(prev, { force: true, diag: false }) : null;
}

export { PODKOP, installed, version, section, proxy_sections, section_ok, create_section, ensure_mixed, listen_address,
	mixed_proxy_url, current_link, restart, sing_box_running, tunnel_check, wait_up, latency, diagnostics, apply_link, restore_prev };
