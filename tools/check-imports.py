#!/usr/bin/env python3
"""Every ucode import and every LuCI 'require view.peers-ss.*' must resolve to a file tracked by git."""
import re, subprocess, sys, os
tracked = set(subprocess.check_output(['git', 'ls-files'], text=True).split())
bad = 0
for f in [t for t in tracked if t.startswith('files/') and (t.endswith('.uc') or t.endswith('.js') or t == 'files/usr/bin/peers-ss')]:
    s = open(f).read()
    for m in re.finditer(r"from '([^']+\.uc)'", s):
        p = m.group(1)
        path = 'files' + p if p.startswith('/') else os.path.normpath(os.path.join(os.path.dirname(f), p))
        if path not in tracked: print(f'{f}: import {p} -> {path} NOT TRACKED'); bad = 1
    for m in re.finditer(r"'require view\.peers-ss\.(\w+)", s):
        path = 'files/www/luci-static/resources/view/peers-ss/%s.js' % m.group(1)
        if path not in tracked: print(f'{f}: require {m.group(1)} NOT TRACKED'); bad = 1
sys.exit(bad)
