#!/usr/bin/env python3
"""Conservative minifier for ucode/JS sources in the release tree: drops full-line // comments, leading
indentation and blank lines. Code lines are kept byte-for-byte (no risk for strings/regex literals)."""
import os, sys, re
root = sys.argv[1]
for dp, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(dp, f)
        if not (f.endswith('.uc') or f.endswith('.js') or p.endswith('/usr/bin/peers-ss')): continue
        out = []
        for i, line in enumerate(open(p, encoding='utf-8').read().split('\n')):
            if i == 0 and line.startswith('#!'): out.append(line); continue
            s = line.strip()
            if not s or s.startswith('//'): continue
            out.append(s)
        open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
