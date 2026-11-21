#!/usr/bin/env python3
"""ucode has no function hoisting: report top-level functions used before their definition."""
import re, sys, glob
bad = 0
for f in sys.argv[1:] or glob.glob('files/usr/share/peers-ss/*.uc') + ['files/usr/bin/peers-ss']:
    s = open(f).read()
    code = re.sub(r'//[^\n]*', lambda m: ' ' * len(m.group(0)), s)
    defs = {m.group(1): m.start() for m in re.finditer(r'^function (\w+)\(', code, re.M)}
    for name, pos in defs.items():
        for m in re.finditer(r'(?<![\w.])' + name + r'\(', code):
            if m.start() < pos and not code[max(0, m.start() - 9):m.start()].endswith('function '):
                print(f"{f}:{code.count(chr(10), 0, m.start()) + 1}: {name}() used before definition"); bad = 1
    for m in re.finditer(r'^(?:let|const) (\w+)', code, re.M):
        for u in re.finditer(r'(?<![\w.\'"])' + m.group(1) + r'\b', code[:m.start()]):
            print(f"{f}:{code.count(chr(10), 0, u.start()) + 1}: variable {m.group(1)} used before declaration"); bad = 1
sys.exit(bad)
