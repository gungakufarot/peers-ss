// Peers-SS: encryption. AES-256-CBC via `uencrypt` + HMAC-SHA256 (encrypt-then-MAC).
// Key = iterated SHA-256 of contour password and contour salt.
// Envelope: "PSE1." + base64(iv[16] | ciphertext | mac[32]).
'use strict';

import * as fs from 'fs';
import { sha256 } from 'digest';
import { RUN, q, mkdirp, sh, rand_hex } from './util.uc';

const KDF_ITER = 20000;

function sha256_bin(s) { return hexdec(sha256(s)); }

function hmac_sha256(key_bin, msg) {
	if (length(key_bin) > 64) key_bin = sha256_bin(key_bin);
	while (length(key_bin) < 64) key_bin += '\x00';
	let ipad = '', opad = '';
	for (let i = 0; i < 64; i++) {
		let c = ord(key_bin, i);
		ipad += chr(c ^ 0x36);
		opad += chr(c ^ 0x5c);
	}
	return sha256_bin(opad + sha256_bin(ipad + msg));
}

// returns 64-hex master key
function kdf(password, salt_hex, iter) {
	iter ??= KDF_ITER;
	let salt = hexdec(salt_hex);
	let h = sha256_bin(salt + '\x00' + password);
	for (let i = 1; i < iter; i++)
		h = sha256_bin(h + password + salt);
	return hexenc(h);
}

function subkeys(master_hex) {
	let m = hexdec(master_hex);
	return { enc: sha256('peers-ss/enc\x00' + m), mac: sha256_bin('peers-ss/mac\x00' + m) };
}

function ct_equal(a, b) {
	if (length(a) != length(b)) return false;
	let d = 0;
	for (let i = 0; i < length(a); i++) d |= ord(a, i) ^ ord(b, i);
	return d == 0;
}

let n = 0;
function tmpbase() {
	mkdirp(RUN + '/c');
	return sprintf('%s/c/%d-%d', RUN, time(), ++n);
}

function uenc(mode, key_hex, iv_hex, data) {
	let b = tmpbase();
	fs.writefile(b + '.i', data);
	fs.chmod(b + '.i', 0600);
	let r = sh(sprintf('umask 077; uencrypt %s -c aes-256-cbc -k %s -i %s < %s > %s',
		mode, key_hex, iv_hex, q(b + '.i'), q(b + '.o')));
	let out = fs.readfile(b + '.o');
	fs.unlink(b + '.i'); fs.unlink(b + '.o');
	return r.code == 0 ? out : null;
}

function encrypt(master_hex, plaintext) {
	let k = subkeys(master_hex);
	let iv = rand_hex(16);
	let ct = uenc('-e', k.enc, iv, plaintext);
	if (ct == null) die('uencrypt failed');
	let body = hexdec(iv) + ct;
	return 'PSE1.' + b64enc(body + hmac_sha256(k.mac, body));
}

// returns plaintext or null (wrong key / tampered)
function decrypt(master_hex, env) {
	if (type(env) != 'string' || substr(env, 0, 5) != 'PSE1.') return null;
	let raw = b64dec(trim(substr(env, 5)));
	if (raw == null || length(raw) < 16 + 16 + 32) return null;
	let k = subkeys(master_hex);
	let body = substr(raw, 0, length(raw) - 32), mac = substr(raw, length(raw) - 32);
	if (!ct_equal(mac, hmac_sha256(k.mac, body))) return null;
	return uenc('-d', k.enc, hexenc(substr(body, 0, 16)), substr(body, 16));
}

function encrypt_json(master_hex, obj) { return encrypt(master_hex, sprintf('%J', obj)); }
function decrypt_json(master_hex, env) {
	let s = decrypt(master_hex, env);
	if (s == null) return null;
	try { return json(s); } catch (e) { return null; }
}

// short non-reversible fingerprint (e.g. applied link hash, invite secret hash)
function fp(s) { return substr(sha256('peers-ss/fp\x00' + s), 0, 16); }

// key that only this device can rebuild: MAC addresses are not part of sysupgrade backups
function device_key(router_id) {
	let macs = '';
	for (let ifn in ['eth0', 'br-lan', 'lan1', 'wan']) {
		let m = trim(fs.readfile('/sys/class/net/' + ifn + '/address') ?? '');
		if (m && m != '00:00:00:00:00:00') { macs = m; break; }
	}
	let board = trim(fs.readfile('/tmp/sysinfo/board_name') ?? '');
	return kdf(macs + '|' + board, hexenc('peers-ss-device|' + (router_id ?? '')), 2000);
}

export { kdf, encrypt, decrypt, encrypt_json, decrypt_json, hmac_sha256, fp, device_key, sha256 };
