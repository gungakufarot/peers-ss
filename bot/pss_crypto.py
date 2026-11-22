"""Peers-SS envelope "PSE1." (compatible with files/usr/share/peers-ss/crypto.uc):
base64(iv[16] | AES-256-CBC(PKCS7) | HMAC-SHA256), MAC over "PSE1\\0" + aad + "\\0" + iv|ct.
Keys from a 64-hex master: enc = sha256("peers-ss/enc\\0"+master) used as hex key, mac = sha256("peers-ss/mac\\0"+master)."""
import base64, hashlib, hmac, json, os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding

def _subkeys(master_hex):
    m = bytes.fromhex(master_hex)
    enc = bytes.fromhex(hashlib.sha256(b'peers-ss/enc\x00' + m).hexdigest())
    mac = hashlib.sha256(b'peers-ss/mac\x00' + m).digest()
    return enc, mac

def _mac(mac_key, aad, body):
    return hmac.new(mac_key, b'PSE1\x00' + aad.encode() + b'\x00' + body, hashlib.sha256).digest()

def decrypt(master_hex, env, aad):
    if not isinstance(env, str) or not env.startswith('PSE1.'):
        return None
    raw = base64.b64decode(env[5:].strip())
    if len(raw) < 64:
        return None
    enc, mk = _subkeys(master_hex)
    body, tag = raw[:-32], raw[-32:]
    if not hmac.compare_digest(tag, _mac(mk, aad, body)):
        return None
    d = Cipher(algorithms.AES(enc), modes.CBC(body[:16])).decryptor()
    padded = d.update(body[16:]) + d.finalize()
    u = padding.PKCS7(128).unpadder()
    return u.update(padded) + u.finalize()

def encrypt(master_hex, plaintext, aad):
    enc, mk = _subkeys(master_hex)
    iv = os.urandom(16)
    p = padding.PKCS7(128).padder()
    data = p.update(plaintext) + p.finalize()
    e = Cipher(algorithms.AES(enc), modes.CBC(iv)).encryptor()
    body = iv + e.update(data) + e.finalize()
    return 'PSE1.' + base64.b64encode(body + _mac(mk, aad, body)).decode()

def unwrap(master_hex, repo, path, text):
    """Repo file {"schema":N,"enc":...} -> dict or None"""
    w = json.loads(text)
    pt = decrypt(master_hex, w.get('enc'), '%s/%s#%s' % (repo, path, w.get('schema')))
    return json.loads(pt) if pt is not None else None

def wrap(master_hex, repo, path, obj, schema=1):
    return json.dumps({'schema': schema, 'enc': encrypt(master_hex, json.dumps(obj, ensure_ascii=False).encode(), '%s/%s#%s' % (repo, path, schema))}) + '\n'
