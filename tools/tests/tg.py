#!/usr/bin/env python3
"""Minimal client for the local telegram-mcp HTTP server — ONLY for talking to the test bot.
usage: tg.py send <text> | history [n] | press <message_id> <button_text>"""
import json, sys, urllib.request
BOT = '@podminiapp_bot'
KEY = [l.split('=', 1)[1].strip() for l in open('/home/musaev/.config/opencode/secrets/telegram-mcp.env') if l.startswith('MCP_API_KEY=')][0]
URL = 'http://127.0.0.1:8765/mcp'
H = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Authorization': 'Bearer ' + KEY}

def post(body, sid=None):
    h = dict(H)
    if sid: h['Mcp-Session-Id'] = sid
    r = urllib.request.urlopen(urllib.request.Request(URL, data=json.dumps(body).encode(), headers=h), timeout=60)
    raw = r.read().decode()
    for line in raw.splitlines():
        if line.startswith('data:'): raw = line[5:]
    return r.headers.get('Mcp-Session-Id'), (json.loads(raw) if raw.strip().startswith('{') else None)

sid, _ = post({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'peers-ss-test', 'version': '1'}}})
post({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, sid)

def tool(name, **args):
    _, r = post({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}}, sid)
    c = (r or {}).get('result', {}).get('content', [{}])
    txt = c[0].get('text', '') if c else ''
    try: return json.loads(txt)
    except Exception: return txt

cmd = sys.argv[1]
if cmd == 'send': print(json.dumps(tool('send_message', chat_id=BOT, text=sys.argv[2]), ensure_ascii=False)[:200])
elif cmd == 'history':
    h = tool('get_history', chat_id=BOT, limit=int(sys.argv[2]) if len(sys.argv) > 2 else 8)
    msgs = h.get('messages', h) if isinstance(h, dict) else h
    for m in reversed(msgs if isinstance(msgs, list) else []):
        print('[%s] %s: %s' % (m.get('messageId'), 'me' if m.get('isOutgoing') else 'bot', (m.get('text') or '').replace('\n', ' | ')[:400]))
    if not isinstance(msgs, list): print(json.dumps(h, ensure_ascii=False)[:800])
elif cmd == 'buttons': print(json.dumps(tool('list_inline_buttons', chat_id=BOT, message_id=int(sys.argv[2])), ensure_ascii=False)[:600])
elif cmd == 'press': print(json.dumps(tool('press_inline_button', chat_id=BOT, message_id=int(sys.argv[2]), button_text=sys.argv[3]), ensure_ascii=False)[:300])
