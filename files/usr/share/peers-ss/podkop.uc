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

// private uci delta dir: we never commit changes an admin staged in LuCI (/tmp/.uci)
function ucur() { mkdirp(RUN + '/uci'); return cursor(null, RUN + '/uci'); }

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
function create_section(name, c) {
	if (c.get('podkop', name) != null) return false;
	let used = used_ports(), port = DEFAULT_MIXED_PORT;
	while (used['' + port]) port++;
	c.set('podkop', name, 'section');
	c.set('podkop', name, 'connection_type', 'proxy');
	c.set('podkop', name, 'proxy_config_type', 'url');
	c.set('podkop', name, 'enable_udp_over_tcp', '0');
	c.set('podkop', name, 'mixed_proxy_enabled', '1');
	c.set('podkop', name, 'mixed_proxy_port', '' + port);
	return true;
}

// spec §7: enable mixed proxy of the managed section for tunnel checks
function ensure_mixed(name, c) {
	if (c.get('podkop', name, 'mixed_proxy_enabled') == '1' && c.get('podkop', name, 'mixed_proxy_port')) return false;
	let used = used_ports(), port = DEFAULT_MIXED_PORT;
	while (used['' + port]) port++;
	c.set('podkop', name, 'mixed_proxy_enabled', '1');
	if (!c.get('podkop', name, 'mixed_proxy_port')) c.set('podkop', name, 'mixed_proxy_port', '' + port);
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

// after a podkop restart dnsmasq is reconfigured: wait until the router resolves names again (GitHub/API writes follow)
function wait_dns(max_s) {
	let t0 = time();
	while (time() - t0 < (max_s ?? 30)) {
		if (sh('nslookup api.github.com 127.0.0.1 >/dev/null 2>&1').code == 0) return true;
		sleep_s(2);
	}
	return false;
}

// layer 4: request through the managed section's mixed proxy
function tunnel_check(timeout) {
	let px = mixed_proxy_url();
	if (!px) return { ok: false, err: 'no mixed proxy' };
	let r = request(TEST_URL, { proxy: px, timeout: timeout ?? 8, connect_timeout: 5 });
	return { ok: r.status == 204, status: r.status };
}

// spec §7 step 4: up to 60 s, every 5 s: sing-box up and layer 4 passes
function wait_up(max_s) {
	let t0 = time();
	max_s ??= 60;
	sleep_s(3);
	while (time() - t0 < max_s) {
		if (sing_box_running() && tunnel_check(min(6, max(2, max_s - (time() - t0)))).ok) return true;
		sleep_s(5);
	}
	return false;
}

// spec §7 step 6: latency via Clash API (sing-box URL test); fallback: median of 3 requests via mixed proxy
function latency() {
	// first URL test warms the connection; then median of 3
	let d = [];
	for (let i = 0; i < 4; i++) {
		let r = sh(sprintf('%s clash_api get_proxy_latency %s 5000', PODKOP, q(section() + '-out')));
		let j = null;
		try { j = json(r.out); } catch (e) {}
		if (i > 0 && j?.delay > 0) push(d, j.delay);
	}
	if (length(d)) return { ms: int(median(d)), method: 'clash' };
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
	req1(d.nft, ['table_exist', 'rules_mangle_exist', 'rules_mangle_output_exist', 'rules_proxy_exist'], 'nft');
	// LuCI: rules_other_mark_exist=1 is only a warning ("additional marking rules found"), 0 is fine
	d.warnings = (d.nft?.rules_other_mark_exist === 1) ? ['nft:other_mark_rules'] : [];
	req1(d.fakeip, ['fakeip'], 'fakeip');
	let lat = pj(sprintf('clash_api get_proxy_latency %s 5000', q(section() + '-out')));
	if (!(lat?.delay > 0)) push(fails, 'outbound:latency');
	d.outbound = lat;
	d.ok = length(fails) == 0;
	d.fails = fails;
	return d;
}

// single-writer lock around podkop changes (CLI, service and rpcd may race); stale after 300 s
function lock() {
	let d = RUN + '/podkop.lock';
	mkdirp(RUN);
	let mypid = split(trim(fs.readfile('/proc/self/stat') ?? '0'), ' ')[0];
	for (let i = 0; i < 120; i++) {
		if (fs.mkdir(d, 0700)) { fs.writefile(d + '/pid', mypid); return true; }
		let owner = trim(fs.readfile(d + '/pid') ?? ''), st = fs.stat(d);
		if ((owner && !fs.stat('/proc/' + owner)) || (!owner && st && time() - st.mtime > 10) || (st && time() - st.mtime > 300)) {
			fs.unlink(d + '/pid'); fs.rmdir(d); continue;
		}
		sleep_s(1);
	}
	return false;
}
function unlock() { fs.unlink(RUN + '/podkop.lock/pid'); fs.rmdir(RUN + '/podkop.lock'); }

// spec §7 apply cycle. returns { changed, ok, diag, latency, err, rolled_back }
// opts: { force, diag (default true), setup (create section if missing), restore (do not overwrite prev), wait }
function apply_link(link, opts) {
	opts ??= {};
	if (type(link) != 'string' || substr(link, 0, 8) != 'vless://' || length(link) < 20)
		return { changed: false, ok: false, err: 'not a vless link' };
	let name = section();
	let c = ucur();
	if (c.get('podkop', name) == null && !opts.setup)
		return { changed: false, ok: false, err: 'podkop section missing: ' + name, podkop_changed: true };
	if (c.get('podkop', name) != null && !section_ok(name))
		return { changed: false, ok: false, err: 'podkop section is not a url proxy section: ' + name, podkop_changed: true };
	let cur = c.get('podkop', name, 'proxy_string');
	if (cur == link && !opts.force) return { changed: false, ok: true };
	if (!lock()) return { changed: false, ok: false, err: 'podkop is locked by another apply' };
	backup_orig();
	mkdirp(RUN);
	if (cur && !opts.restore) writefile(RUN + '/podkop.prev', cur, 0600);
	c = ucur();
	c.revert('podkop');
	create_section(name, c);
	ensure_mixed(name, c);
	c.set('podkop', name, 'proxy_config_type', 'url');
	c.set('podkop', name, 'proxy_string', link);
	c.commit('podkop');
	log('info', 'podkop: new link written to section ' + name + ', restarting podkop');
	restart();
	let up = wait_up(opts.wait ?? 60);
	wait_dns(30);
	let res = { changed: true, ok: up };
	if (!up) {
		res.err = sprintf('tunnel did not come up in %d s', opts.wait ?? 60);
		// LAN safety: if sing-box itself is down, dnsmasq points to a dead resolver — go back
		if (!sing_box_running()) {
			let prev = opts.restore ? null : fs.readfile(RUN + '/podkop.prev');
			unlock();
			if (prev && prev != link) {
				log('error', 'podkop: sing-box down after apply, restoring previous link');
				apply_link(prev, { force: true, diag: false, restore: true });
			}
			if (!sing_box_running()) {
				log('error', 'podkop: sing-box still down, stopping podkop to restore dnsmasq');
				sh('/etc/init.d/podkop stop');
			}
			res.rolled_back = true;
			return res;
		}
		unlock();
		return res;
	}
	if (opts.diag !== false) {
		res.diag = diagnostics();
		res.ok = res.diag.ok;
		if (!res.ok) res.err = 'diagnostics: ' + join(',', res.diag.fails);
	}
	res.latency = latency();
	unlock();
	return res;
}

// back to the link that was active before the last apply
function restore_prev() {
	let prev = fs.readfile(RUN + '/podkop.prev');
	return prev ? apply_link(prev, { force: true, diag: false, restore: true }) : null;
}

// spec §7: at service start check that podkop still has our section and option
function check_podkop() {
	if (!installed()) return { ok: false, reason: 'podkop not installed' };
	let v = version();
	let name = section();
	if (cursor().get('podkop', name) == null) return { ok: false, reason: 'section ' + name + ' missing', version: v };
	if (!section_ok(name)) return { ok: false, reason: 'section ' + name + ' is not proxy/url', version: v };
	let code = fs.readfile('/usr/bin/podkop') ?? '';
	if (index(code, 'proxy_string') < 0) return { ok: false, reason: 'podkop does not know proxy_string', version: v };
	return { ok: true, version: v, version_tested: match(v, /0\.7\.24/) != null };
}

export { PODKOP, installed, version, section, proxy_sections, section_ok, create_section, ensure_mixed, listen_address,
	mixed_proxy_url, current_link, wait_dns, restart, sing_box_running, tunnel_check, wait_up, latency, diagnostics, apply_link, restore_prev, check_podkop };
