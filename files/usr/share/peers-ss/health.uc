// Peers-SS: 4-layer check (spec §5). Router's own traffic bypasses the tunnel (enable_output_network_interface=0).
'use strict';

import { request } from './http.uc';
import { parse_vless, q, sh } from './util.uc';
import * as PK from './podkop.uc';

const DIRECT_HOSTS = ['https://www.cloudflare.com/cdn-cgi/trace', 'https://ya.ru/', 'https://www.google.com/generate_204'];

// layer 1: direct HTTPS to well-known hosts (any answer = internet works)
function l1_internet() {
	for (let u in DIRECT_HOSTS) {
		let r = request(u, { method: 'HEAD', timeout: 6, connect_timeout: 4 });
		if (r.status > 0) return true;
	}
	return false;
}

// layer 2: podkop service + sing-box process
function l2_podkop() { return PK.sing_box_running(); }

// layer 3: TCP to host:port of the vless link, directly
function l3_server(link) {
	let v = parse_vless(link ?? '');
	if (!v) return false;
	let h = index(v.host, ':') >= 0 ? '[' + v.host + ']' : v.host;
	let r = sh(sprintf('curl -sk -o /dev/null -m 5 --connect-timeout 4 -w "%%{time_connect}" %s', q('https://' + h + ':' + v.port + '/')));
	let t = +r.out;
	return t > 0;
}

// layer 4: generate_204 through the managed section's mixed proxy
function l4_tunnel() { return PK.tunnel_check(8).ok; }

// returns { l1, l2, l3, l4, verdict: ok | no_internet | podkop_down | fail }
function check(link) {
	let r = { l1: l1_internet() };
	if (!r.l1) { r.verdict = 'no_internet'; return r; }
	r.l2 = l2_podkop();
	if (!r.l2) { r.verdict = 'podkop_down'; return r; }
	r.l3 = l3_server(link);
	r.l4 = l4_tunnel();
	r.verdict = (r.l3 && r.l4) ? 'ok' : 'fail';
	return r;
}

// layers 3-4 only (re-check before rotating, spec §5 step 3)
function recheck(link) { return l3_server(link) && l4_tunnel(); }

export { DIRECT_HOSTS, l1_internet, l2_podkop, l3_server, l4_tunnel, check, recheck };
