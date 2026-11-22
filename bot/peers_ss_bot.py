#!/usr/bin/env python3
"""Peers-SS Telegram bot (spec §9). Long polling, SQLite, systemd. Reads cards/alerts from the state repo
(encrypted with the bot key), reminds clients about config expiry at 21:00 Moscow time, forwards alerts to the admin.
Config: environment (see /etc/peers-ss-bot/env)."""
import base64, datetime as dt, json, logging, os, sqlite3, sys, threading, time, urllib.error, urllib.parse, urllib.request
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pss_crypto as PC  # noqa: E402

MSK = ZoneInfo('Europe/Moscow')
ENV = os.environ
BOT_TOKEN = ENV.get('TELEGRAM_BOT_TOKEN', '')
ADMIN = int(ENV.get('TELEGRAM_ADMIN_CHAT_ID', '0') or 0)
BOT_KEY = ENV.get('BOT_KEY', '')
GH_TOKEN = ENV.get('GITHUB_TOKEN', '')
REPO = ENV.get('STATE_REPO', '')
DB_PATH = ENV.get('DB_PATH', '/opt/peers-ss-bot/bot.db')
REMIND_AT = ENV.get('REMIND_AT', '21:00')           # HH:MM Moscow time
STORE_POLL_S = int(ENV.get('STORE_POLL_S', '300'))  # spec: every 5 minutes
CARD_STALE_S = int(ENV.get('CARD_STALE_S', str(24 * 3600)))  # test override only

log = logging.getLogger('peers-ss-bot')

# IPv6 to Telegram hangs on some servers (seen on the admin server): resolve IPv4 only unless BOT_IPV6=1
if ENV.get('BOT_IPV6') != '1':
    import socket
    _gai = socket.getaddrinfo
    socket.getaddrinfo = lambda host, port, family=0, *a, **k: _gai(host, port, socket.AF_INET, *a, **k)

# ---------------- helpers ----------------
def now_msk(): return dt.datetime.now(MSK)

def fmt_date(ts): return dt.datetime.fromtimestamp(int(ts), MSK).strftime('%d.%m.%Y') if ts else '—'

def plural_days(n):
    n = abs(n)
    if n % 10 == 1 and n % 100 != 11: return '%d день' % n
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14): return '%d дня' % n
    return '%d дней' % n

def redact(s):
    s = str(s)
    for v in (BOT_TOKEN, GH_TOKEN, BOT_KEY):
        if v: s = s.replace(v, '<hidden>')
    return s

# ---------------- storage (SQLite) ----------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS clients (chat_id INTEGER PRIMARY KEY, username TEXT, first_name TEXT, nick TEXT,
  status TEXT NOT NULL DEFAULT 'new', created_at INTEGER);
CREATE TABLE IF NOT EXISTS bindings (chat_id INTEGER, contour TEXT, binding TEXT, created_at INTEGER,
  PRIMARY KEY (chat_id, contour, binding));
CREATE TABLE IF NOT EXISTS sent (chat_id INTEGER, contour TEXT, binding TEXT, kind TEXT, day TEXT,
  PRIMARY KEY (chat_id, contour, binding, kind, day));
CREATE TABLE IF NOT EXISTS expired_sent (chat_id INTEGER, contour TEXT, binding TEXT, expires_at INTEGER,
  PRIMARY KEY (chat_id, contour, binding, expires_at));
CREATE TABLE IF NOT EXISTS alerts_seen (path TEXT PRIMARY KEY, at INTEGER);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
"""

class DB:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.c = sqlite3.connect(path, check_same_thread=False)
        self.c.executescript(SCHEMA)
        os.chmod(path, 0o600)

    def q(self, sql, args=()):
        with self.lock:
            cur = self.c.execute(sql, args)
            self.c.commit()
            return cur.fetchall()

    def get(self, k, d=None):
        r = self.q('SELECT v FROM kv WHERE k=?', (k,))
        return r[0][0] if r else d

    def set(self, k, v): self.q('INSERT OR REPLACE INTO kv VALUES (?,?)', (k, str(v)))

# ---------------- GitHub store (read with ETag) ----------------
class Store:
    def __init__(self):
        self.cache = {}  # path -> (etag, payload)

    def _req(self, method, path, body=None, etag=None):
        url = 'https://api.github.com/repos/%s/contents/%s' % (REPO, urllib.parse.quote(path))
        h = {'Authorization': 'Bearer ' + GH_TOKEN, 'Accept': 'application/vnd.github+json', 'User-Agent': 'peers-ss-bot',
             'X-GitHub-Api-Version': '2022-11-28'}
        if etag: h['If-None-Match'] = etag
        data = json.dumps(body).encode() if body is not None else None
        if data: h['Content-Type'] = 'application/json'
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.headers.get('ETag'), json.loads(r.read() or b'null')
        except urllib.error.HTTPError as e:
            return e.code, None, None

    def get_json(self, path):
        """GET with If-None-Match (304 is free); returns parsed JSON (dir list or file object)"""
        etag, payload = self.cache.get(path, (None, None))
        st, et, js = self._req('GET', path, etag=etag)
        if st == 304: return payload
        if st == 404: self.cache.pop(path, None); return None
        if st != 200: raise IOError('GitHub %s -> HTTP %s' % (path, st))
        self.cache[path] = (et, js)
        return js

    def list_dir(self, path):
        js = self.get_json(path)
        return [e for e in (js or []) if isinstance(js, list)]

    def read_obj(self, path, key):
        js = self.get_json(path)
        if not js or js.get('type') != 'file': return None
        text = base64.b64decode(js['content']).decode()
        return PC.unwrap(key, REPO, path, text)

    def put_obj(self, path, obj, key, message):
        st, _, js = self._req('GET', path)
        sha = js.get('sha') if st == 200 and js else None
        body = {'message': message, 'content': base64.b64encode(PC.wrap(key, REPO, path, obj).encode()).decode()}
        if sha: body['sha'] = sha
        st, _, _ = self._req('PUT', path, body=body)
        return st in (200, 201)

# ---------------- Telegram ----------------
class TG:
    def __init__(self, token): self.base = 'https://api.telegram.org/bot%s/' % token

    def call(self, method, **params):
        data = json.dumps(params).encode()
        req = urllib.request.Request(self.base + method, data=data, headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=70) as r:
                return json.loads(r.read()).get('result')
        except urllib.error.HTTPError as e:
            log.warning('telegram %s -> %s %s', method, e.code, redact(e.read()[:200]))
        except Exception as e:  # network
            log.warning('telegram %s failed: %s', method, redact(e))
        return None

    def send(self, chat_id, text, buttons=None):
        p = {'chat_id': chat_id, 'text': text, 'disable_web_page_preview': True}
        if buttons: p['reply_markup'] = {'inline_keyboard': buttons}
        return self.call('sendMessage', **p)

# ---------------- bot ----------------
class Bot:
    def __init__(self):
        self.db = DB(DB_PATH)
        self.st = Store()
        self.tg = TG(BOT_TOKEN)
        self.cards = {}      # (cid, binding) -> card
        self.summaries = {}  # cid -> _contour.json
        self.data_lock = threading.Lock()

    # ----- data from the store -----
    def refresh(self):
        cards, summaries, alerts = {}, {}, []
        for e in self.st.list_dir(''):
            if e.get('type') != 'dir' or not e['name'].startswith('c'): continue
            cid = e['name']
            for f in self.st.list_dir(cid + '/cards'):
                o = self.st.read_obj('%s/cards/%s' % (cid, f['name']), BOT_KEY)
                if o is None: continue
                if f['name'] == '_contour.json': summaries[cid] = o
                elif o.get('binding'): cards[(cid, o['binding'])] = o
            for f in self.st.list_dir(cid + '/alerts'):
                p = '%s/alerts/%s' % (cid, f['name'])
                o = self.st.read_obj(p, BOT_KEY)
                if o: alerts.append((p, o))
        with self.data_lock:
            self.cards, self.summaries = cards, summaries
        self.forward_alerts(alerts)

    def contour_name(self, cid):
        s = self.summaries.get(cid)
        if s: return s.get('contour') or cid
        for (c, _), card in self.cards.items():
            if c == cid and card.get('contour'): return card['contour']
        return cid

    def contours(self):
        return sorted({c for (c, _) in self.cards} | set(self.summaries))

    # ----- alerts to the admin -----
    def quiet(self):
        return float(self.db.get('quiet_until', 0)) > time.time()

    def forward_alerts(self, alerts):
        for path, a in sorted(alerts, key=lambda x: x[1].get('at', 0)):
            seen = self.db.q('SELECT at FROM alerts_seen WHERE path=?', (path,))
            at = int(a.get('at') or 0)
            if seen and seen[0][0] >= at: continue
            first_run = self.db.get('alerts_initialized') is None
            self.db.q('INSERT OR REPLACE INTO alerts_seen VALUES (?,?)', (path, at))
            if first_run and time.time() - at > 6 * 3600: continue  # do not flood with old alerts on first start
            if self.quiet():
                log.info('alert suppressed (quiet mode): %s', path)
                continue
            self.tg.send(ADMIN, '⚠️ %s: %s\n%s · %s МСК' % (a.get('contour') or path.split('/')[0], a.get('text'),
                                                       a.get('router') or '', dt.datetime.fromtimestamp(at, MSK).strftime('%d.%m %H:%M')))
        self.db.set('alerts_initialized', '1')

    # ----- reminders (21:00 MSK) -----
    def remind_due(self, now=None):
        now = now or now_msk()
        h, m = map(int, REMIND_AT.split(':'))
        today = now.date().isoformat()
        return (now.hour, now.minute) >= (h, m) and self.db.get('last_remind_day') != today

    def run_reminders(self, today=None):
        today = today or now_msk().date()
        day = today.isoformat()
        stale_reported = set()
        n = 0
        for chat_id, cid, binding in self.db.q("SELECT b.chat_id, b.contour, b.binding FROM bindings b JOIN clients c ON c.chat_id=b.chat_id WHERE c.status='active'"):
            card = self.cards.get((cid, binding))
            if not card or time.time() - int(card.get('updated_at') or 0) > CARD_STALE_S:
                if (cid, binding) not in stale_reported:
                    stale_reported.add((cid, binding))
                    if not self.db.q("SELECT 1 FROM sent WHERE chat_id=0 AND contour=? AND binding=? AND kind='stale' AND day=?", (cid, binding, day)):
                        self.db.q("INSERT INTO sent VALUES (0,?,?,'stale',?)", (cid, binding, day))
                        self.tg.send(ADMIN, '⚠️ Нет свежих данных по конфигу %s (%s): карточка старше 24 ч — клиенту напоминание не отправлено' % (binding, self.contour_name(cid)))
                continue
            if card.get('exists') is False or not card.get('expires_at'): continue
            title = card.get('title') or binding
            exp = dt.datetime.fromtimestamp(int(card['expires_at']), MSK).date()
            days = (exp - today).days
            if 1 <= days <= 3: kind, text = 'soon', 'Конфиг «%s» заканчивается %s (через %s)' % (title, exp.strftime('%d.%m.%Y'), plural_days(days))
            elif days == 0: kind, text = 'today', 'Конфиг «%s» заканчивается сегодня, %s' % (title, exp.strftime('%d.%m.%Y'))
            elif days == -1: kind, text = 'expired', 'Конфиг «%s» истёк %s' % (title, exp.strftime('%d.%m.%Y'))
            else: continue
            if kind == 'expired':
                if self.db.q('SELECT 1 FROM expired_sent WHERE chat_id=? AND contour=? AND binding=? AND expires_at=?', (chat_id, cid, binding, int(card['expires_at']))): continue
                self.db.q('INSERT INTO expired_sent VALUES (?,?,?,?)', (chat_id, cid, binding, int(card['expires_at'])))
            if self.db.q('SELECT 1 FROM sent WHERE chat_id=? AND contour=? AND binding=? AND kind=? AND day=?', (chat_id, cid, binding, kind, day)): continue
            self.db.q('INSERT INTO sent VALUES (?,?,?,?,?)', (chat_id, cid, binding, kind, day))
            if self.tg.send(chat_id, text): n += 1
        self.db.set('last_remind_day', day)
        log.info('reminders for %s: %d sent', day, n)
        return n

    # ----- daily encrypted DB backup into the store -----
    def backup(self):
        day = now_msk().date().isoformat()
        if self.db.get('last_backup_day') == day: return
        with self.db.lock:
            tmp = DB_PATH + '.bak'
            b = sqlite3.connect(tmp); self.db.c.backup(b); b.close()
        raw = open(tmp, 'rb').read(); os.unlink(tmp)
        if self.st.put_obj('bot/backup.json', {'at': int(time.time()), 'db': base64.b64encode(raw).decode()}, BOT_KEY, 'bot: daily backup'):
            self.db.set('last_backup_day', day)
            log.info('backup written (%d bytes)', len(raw))

    # ----- Telegram handlers -----
    def is_admin(self, chat_id): return ADMIN and chat_id == ADMIN

    def admin_menu(self):
        return [[{'text': 'Клиенты', 'callback_data': 'm:clients'}, {'text': 'Заявки', 'callback_data': 'm:requests'}],
                [{'text': 'Конфиги', 'callback_data': 'm:configs'}, {'text': 'Роутеры', 'callback_data': 'm:routers'}],
                [{'text': 'Тихий режим', 'callback_data': 'm:quiet'}]]

    def client_configs_text(self, chat_id):
        rows = self.db.q('SELECT contour, binding FROM bindings WHERE chat_id=?', (chat_id,))
        if not rows: return 'Конфиги пока не привязаны.'
        lines = []
        for cid, b in rows:
            c = self.cards.get((cid, b)) or {}
            lines.append('• %s — действует до %s' % (c.get('title') or b, fmt_date(c.get('expires_at'))))
        return 'Ваши конфиги:\n' + '\n'.join(lines)

    def on_message(self, m):
        chat = m['chat']['id']
        text = (m.get('text') or '').strip()
        user = m.get('from', {})
        if self.is_admin(chat) and text in ('/start', '/admin'):
            return self.tg.send(chat, 'Админка Peers-SS', self.admin_menu())
        if text == '/join':   # register as a client (also lets the admin test the client flow with the same account)
            text = '/start'
            self.db.q('DELETE FROM clients WHERE chat_id=? AND status NOT IN (?)', (chat, 'active'))
        row = self.db.q('SELECT status FROM clients WHERE chat_id=?', (chat,))
        status = row[0][0] if row else None
        if text == '/start' or status is None or (self.is_admin(chat) and status == 'awaiting_nick' and text.startswith('/')):
            if status == 'active': return self.tg.send(chat, self.client_configs_text(chat))
            self.db.q('INSERT OR REPLACE INTO clients (chat_id, username, first_name, nick, status, created_at) VALUES (?,?,?,?,?,?)',
                      (chat, user.get('username'), user.get('first_name'), None, 'awaiting_nick', int(time.time())))
            return self.tg.send(chat, 'Здравствуйте! Отправьте ваш ник (любой текст), чтобы администратор подключил уведомления о вашем конфиге.')
        if status == 'awaiting_nick' and text and not text.startswith('/'):
            self.db.q("UPDATE clients SET nick=?, status='pending', username=?, first_name=? WHERE chat_id=?", (text[:64], user.get('username'), user.get('first_name'), chat))
            self.tg.send(chat, 'Спасибо! Заявка отправлена администратору.')
            return self.notify_request(chat)
        if status == 'active': return self.tg.send(chat, self.client_configs_text(chat))
        if status == 'pending': return self.tg.send(chat, 'Заявка ещё на рассмотрении у администратора.')

    def notify_request(self, chat):
        r = self.db.q('SELECT nick, username, first_name FROM clients WHERE chat_id=?', (chat,))[0]
        who = '%s (%s%s)' % (r[0], '@' + r[1] if r[1] else 'без username', ', ' + r[2] if r[2] else '')
        btn = [[{'text': self.contour_name(cid), 'callback_data': 'c:%d:%s' % (chat, cid)}] for cid in self.contours()]
        btn.append([{'text': 'Отклонить', 'callback_data': 'x:%d' % chat}])
        self.tg.send(ADMIN, 'Новый клиент: %s — привязать? Выберите контур:' % who, btn)

    def on_callback(self, cq):
        chat = cq['message']['chat']['id']
        data = cq.get('data', '')
        self.tg.call('answerCallbackQuery', callback_query_id=cq['id'])
        if not self.is_admin(chat): return
        p = data.split(':')
        if p[0] == 'm':
            return getattr(self, 'menu_' + p[1])()
        if p[0] == 'c':  # contour chosen -> configs of that contour
            client, cid = int(p[1]), p[2]
            btn = [[{'text': '%s — до %s' % (c.get('title') or b, fmt_date(c.get('expires_at'))), 'callback_data': 'b:%d:%s:%s' % (client, cid, b)}]
                   for (cc, b), c in sorted(self.cards.items()) if cc == cid]
            return self.tg.send(ADMIN, 'Контур %s: выберите конфиг' % self.contour_name(cid), btn or None)
        if p[0] == 'b':  # bind
            client, cid, binding = int(p[1]), p[2], p[3] + ':' + p[4]
            self.db.q('INSERT OR IGNORE INTO bindings VALUES (?,?,?,?)', (client, cid, binding, int(time.time())))
            self.db.q("UPDATE clients SET status='active' WHERE chat_id=?", (client,))
            c = self.cards.get((cid, binding)) or {}
            self.tg.send(client, 'Подключено: %s, действует до %s' % (c.get('title') or binding, fmt_date(c.get('expires_at'))))
            return self.tg.send(ADMIN, 'Привязано: клиент %d ↔ %s (%s)' % (client, c.get('title') or binding, self.contour_name(cid)))
        if p[0] == 'u':  # unbind
            client, cid, binding = int(p[1]), p[2], p[3] + ':' + p[4]
            self.db.q('DELETE FROM bindings WHERE chat_id=? AND contour=? AND binding=?', (client, cid, binding))
            return self.tg.send(ADMIN, 'Отвязано: клиент %d от %s' % (client, binding))
        if p[0] == 'ub':  # choose binding to unbind
            client = int(p[1])
            btn = [[{'text': 'Отвязать %s' % ((self.cards.get((c, b)) or {}).get('title') or b), 'callback_data': 'u:%d:%s:%s' % (client, c, b)}]
                   for c, b in self.db.q('SELECT contour, binding FROM bindings WHERE chat_id=?', (client,))]
            return self.tg.send(ADMIN, 'Что отвязать?', btn or None)
        if p[0] == 'bc':  # bind more: choose contour
            client = int(p[1])
            return self.tg.send(ADMIN, 'Выберите контур', [[{'text': self.contour_name(cid), 'callback_data': 'c:%d:%s' % (client, cid)}] for cid in self.contours()])
        if p[0] == 'x':
            self.db.q("UPDATE clients SET status='rejected' WHERE chat_id=?", (int(p[1]),))
            return self.tg.send(ADMIN, 'Заявка отклонена')
        if p[0] == 'q':
            h = int(p[1])
            self.db.set('quiet_until', time.time() + h * 3600)
            return self.tg.send(ADMIN, 'Тихий режим: %s' % ('выключен' if h == 0 else 'на %d ч' % h))

    def menu_clients(self):
        rows = self.db.q("SELECT chat_id, nick, username FROM clients WHERE status='active' ORDER BY created_at")
        if not rows: return self.tg.send(ADMIN, 'Клиентов нет')
        for chat, nick, un in rows:
            binds = self.db.q('SELECT contour, binding FROM bindings WHERE chat_id=?', (chat,))
            t = '%s (%s)\n' % (nick, '@' + un if un else chat) + '\n'.join('• %s — до %s' % ((self.cards.get((c, b)) or {}).get('title') or b,
                                                                                         fmt_date((self.cards.get((c, b)) or {}).get('expires_at'))) for c, b in binds)
            self.tg.send(ADMIN, t, [[{'text': 'Привязать', 'callback_data': 'bc:%d' % chat}, {'text': 'Отвязать', 'callback_data': 'ub:%d' % chat}]])

    def menu_requests(self):
        rows = self.db.q("SELECT chat_id FROM clients WHERE status='pending'")
        if not rows: return self.tg.send(ADMIN, 'Новых заявок нет')
        for (chat,) in rows: self.notify_request(chat)

    def menu_configs(self):
        lines = []
        for cid in self.contours():
            lines.append('Контур %s:' % self.contour_name(cid))
            for (cc, b), c in sorted(self.cards.items()):
                if cc != cid: continue
                stale = time.time() - int(c.get('updated_at') or 0) > CARD_STALE_S
                lines.append('• %s — до %s%s%s' % (c.get('title') or b, fmt_date(c.get('expires_at')), ' (автопродление)' if c.get('auto_renewal') else '',
                                                  ' — нет свежих данных' if stale else ('' if c.get('exists', True) else ' — конфиг исчез')))
        self.tg.send(ADMIN, '\n'.join(lines) or 'Карточек нет')

    def menu_routers(self):
        lines = []
        for cid, s in sorted(self.summaries.items()):
            lines.append('Контур %s:' % s.get('contour', cid))
            for r in s.get('routers', []):
                lc = r.get('last_contact')
                lines.append('• %s: %s, токен %s, контакт %s' % (r.get('name'), r.get('status') or '—', 'есть' if r.get('has_token') else 'нет',
                                                              dt.datetime.fromtimestamp(lc, MSK).strftime('%d.%m %H:%M') if lc else '—'))
        self.tg.send(ADMIN, '\n'.join(lines) or 'Нет данных о роутерах')

    def menu_quiet(self):
        q = float(self.db.get('quiet_until', 0))
        self.tg.send(ADMIN, 'Тихий режим для алертов' + (' (сейчас до %s МСК)' % dt.datetime.fromtimestamp(q, MSK).strftime('%d.%m %H:%M') if q > time.time() else ''),
                     [[{'text': '%d ч' % h, 'callback_data': 'q:%d' % h} for h in (1, 3, 8, 24)], [{'text': 'Выключить', 'callback_data': 'q:0'}]])

    # ----- loops -----
    def poll_updates(self):
        off = int(self.db.get('update_offset', 0))
        while True:
            ups = self.tg.call('getUpdates', offset=off, timeout=50, allowed_updates=['message', 'callback_query'])
            if ups is None: time.sleep(5); continue
            for u in ups:
                off = u['update_id'] + 1
                log.info('update %s: %s', u['update_id'], 'callback' if 'callback_query' in u else 'message')
                self.db.set('update_offset', off)
                try:
                    if 'message' in u: self.on_message(u['message'])
                    elif 'callback_query' in u: self.on_callback(u['callback_query'])
                except Exception:
                    log.exception('update handling failed')

    def scheduler(self):
        last_poll = 0
        while True:
            try:
                if time.time() - last_poll >= STORE_POLL_S:
                    self.refresh(); last_poll = time.time()
                if self.remind_due():   # also covers "server was off at 21:00": sent once after start
                    if not self.cards: self.refresh()
                    self.run_reminders()
                self.backup()
            except Exception as e:
                log.warning('scheduler: %s', redact(e))
            time.sleep(30)

def main():
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    for k, v in (('TELEGRAM_BOT_TOKEN', BOT_TOKEN), ('TELEGRAM_ADMIN_CHAT_ID', ADMIN), ('BOT_KEY', BOT_KEY), ('GITHUB_TOKEN', GH_TOKEN), ('STATE_REPO', REPO)):
        if not v: sys.exit('missing %s in environment' % k)
    b = Bot()
    if '--remind-now' in sys.argv:   # test helper: run reminders for a given day (--today YYYY-MM-DD), ignores the 21:00 rule
        day = dt.date.fromisoformat(sys.argv[sys.argv.index('--today') + 1]) if '--today' in sys.argv else None
        b.refresh(); print('sent', b.run_reminders(day)); return
    log.info('Peers-SS bot started; reminders at %s MSK, store poll %ds', REMIND_AT, STORE_POLL_S)
    threading.Thread(target=b.scheduler, daemon=True).start()
    b.poll_updates()

if __name__ == '__main__':
    main()
