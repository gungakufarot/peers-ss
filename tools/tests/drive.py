#!/usr/bin/env python3
"""Drive an interactive command over `ssh -tt` (the installer reads /dev/tty).
usage: drive.py <host> <command> <script.json>
script.json: [[expect_substring, answer], ...]; answer may be "$SS_TOKEN", "$GH_TOKEN", "$CONTOUR_PASSWORD",
"$BOT_KEY", "$JOIN_CODE" (taken from env / secret files, never printed).
Transcript is printed with secrets redacted."""
import json, os, pty, re, select, subprocess, sys, time

def secrets():
    s = {}
    try:
        txt = open('/root/peers-ss-secrets.env').read()
        m = re.search(r'stlth_[A-Za-z0-9_]+', txt); s['$SS_TOKEN'] = m.group(0) if m else ''
        m = re.search(r'github_pat_[A-Za-z0-9_]+', txt); s['$GH_TOKEN'] = m.group(0) if m else ''
    except OSError:
        pass
    try:
        for l in open('/root/peers-ss-secrets-test.env'):
            k, _, v = l.strip().partition('=')
            s['$' + k] = v
    except OSError:
        pass
    if os.environ.get('JOIN_CODE'): s['$JOIN_CODE'] = os.environ['JOIN_CODE']
    return s

def redact(t, sec):
    for v in sec.values():
        if v and len(v) > 5: t = t.replace(v, '<hidden>')
    t = re.sub(r'stlth_[A-Za-z0-9_]+', 'stlth_<hidden>', t)
    t = re.sub(r'github_pat_[A-Za-z0-9_]+', 'github_pat_<hidden>', t)
    t = re.sub(r'PSS1\.[A-Za-z0-9_-]+', 'PSS1.<hidden>', t)
    return re.sub(r'vless://\S+', 'vless://<hidden>', t)

def main():
    host, cmd, script = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
    sec = secrets()
    master, slave = pty.openpty()
    p = subprocess.Popen(['ssh', '-tt', host, cmd], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    buf, out, step, deadline = '', '', 0, time.time() + 900
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 1)
        if r:
            try: data = os.read(master, 4096).decode('utf-8', 'replace')
            except OSError: break
            if not data: break
            buf += data; out += data
        if step < len(script) and script[step][0] in buf:
            ans = script[step][1]
            for k, v in sec.items(): ans = ans.replace(k, v)
            time.sleep(0.3)
            os.write(master, (ans + '\n').encode())
            buf = ''
            step += 1
        if p.poll() is not None and not r:
            break
    try:
        while True:
            r, _, _ = select.select([master], [], [], 0.5)
            if not r: break
            data = os.read(master, 4096).decode('utf-8', 'replace')
            if not data: break
            out += data
    except OSError:
        pass
    print(redact(out, sec))
    print(f'--- steps answered: {step}/{len(script)}, exit: {p.poll()}')

main()
