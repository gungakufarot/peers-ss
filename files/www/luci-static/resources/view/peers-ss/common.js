'use strict';
'require baseclass';
'require rpc';
'require ui';

var call = function(method, params) {
	return rpc.declare({ object: 'luci.peers-ss', method: method, params: params || [], expect: {} });
};

var api = {
	ui: call('ui'),
	contourOp: call('contour_op', [ 'op', 'args', 'rev' ]),
	tokenGet: call('token_get', [ 'reveal' ]),
	tokenCheck: call('token_check', [ 'token' ]),
	tokenSet: call('token_set', [ 'token', 'label' ]),
	tokenDelete: call('token_delete'),
	configs: call('configs', [ 'rid' ]),
	jobStart: call('job_start', [ 'name' ]),
	jobStatus: call('job_status', [ 'name' ]),
	testAlert: call('test_alert'),
	apiCheck: call('api_check'),
	passwordChange: call('password_change', [ 'old', 'new' ]),
	inviteCreate: call('invite_create', [ 'group', 'env', 'hours' ]),
	inviteRevoke: call('invite_revoke', [ 'id' ]),
	events: call('events'),
	report: call('report')
};

var STATUS = {
	ok: [ 'Работает', 'ok' ], failing: [ 'Сбои проверки', 'warn' ], blocked: [ 'Блокировка', 'bad' ],
	waiting: [ 'Ожидание: техработы', 'bad' ], no_internet: [ 'Нет интернета', 'mute' ],
	podkop_down: [ 'podkop не работает', 'bad' ], podkop_changed: [ 'podkop изменился', 'bad' ],
	bad_channel: [ 'Плохой канал', 'warn' ], apply_failed: [ 'Ссылка не прошла проверку', 'bad' ],
	no_binding: [ 'Конфиг не назначен', 'mute' ], update_required: [ 'Обновите Peers-SS', 'bad' ]
};

var CSS = '\
.pss{--pss-line:rgba(127,127,127,.25);--pss-soft:rgba(127,127,127,.07);--pss-ok:#1a7f37;--pss-warn:#b08800;--pss-bad:#cf222e;--pss-mute:#6e7781;--pss-acc:#0969da}\
.pss h2{margin:.2em 0 .6em}\
.pss .card{border:1px solid var(--pss-line);border-radius:12px;padding:16px 18px;margin:0 0 16px;background:var(--pss-soft)}\
.pss .card h3{margin:0 0 12px;font-size:1.05em;display:flex;align-items:center;gap:8px}\
.pss .card h3 .sp{flex:1}\
.pss .card h3 .pill{align-self:center;line-height:1.5;font-weight:500}\
.pss .row{display:flex;flex-wrap:wrap;gap:12px;align-items:center}\
.pss .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px}\
.pss .kv{display:grid;grid-template-columns:minmax(140px,max-content) 1fr;gap:6px 18px}\
.pss .kv .k{opacity:.65}\
.pss .pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:999px;font-size:.85em;color:#fff;white-space:nowrap}\
.pss .pill.ok{background:var(--pss-ok)}.pss .pill.warn{background:var(--pss-warn)}.pss .pill.bad{background:var(--pss-bad)}.pss .pill.mute{background:var(--pss-mute)}\
.pss .dot{width:9px;height:9px;border-radius:50%;display:inline-block;flex:none}\
.pss .dot.ok{background:var(--pss-ok)}.pss .dot.warn{background:var(--pss-warn)}.pss .dot.bad{background:var(--pss-bad)}.pss .dot.mute{background:var(--pss-mute)}\
.pss .hero{display:grid;grid-template-columns:1fr auto;gap:14px;align-items:start}\
.pss .hero .big{font-size:1.5em;font-weight:600;margin:4px 0}\
.pss .muted{opacity:.65;font-size:.9em}\
.pss .chip{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--pss-line);border-radius:8px;padding:5px 10px;margin:3px;cursor:grab;user-select:none;background:rgba(127,127,127,.06)}\
.pss .chip:hover{border-color:var(--pss-acc)}\
.pss .chip.me{font-weight:600}\
.pss .env{border:1px dashed var(--pss-line);border-radius:10px;padding:10px 12px;min-height:90px;transition:background .15s,border-color .15s}\
.pss .env.over{border-color:var(--pss-acc);background:rgba(9,105,218,.08)}\
.pss .env .head{display:flex;align-items:center;gap:6px;margin-bottom:6px;font-weight:600}\
.pss .env .head .sp{flex:1}\
.pss .cfg{font-size:.88em;margin:0 0 6px;opacity:.85}\
.pss .zone{border:2px dashed var(--pss-line);border-radius:10px;padding:14px;text-align:center;opacity:.7}\
.pss .zone.over{border-color:var(--pss-acc);opacity:1;background:rgba(9,105,218,.08)}\
.pss .ib{border:none;background:none;cursor:pointer;padding:2px 6px;border-radius:6px;font-size:1em;color:inherit;opacity:.7}\
.pss .ib:hover{opacity:1;background:var(--pss-soft)}\
.pss .banner{border-radius:10px;padding:10px 14px;margin:0 0 14px;border:1px solid}\
.pss .banner.bad{border-color:var(--pss-bad);background:rgba(207,34,46,.08)}\
.pss .banner.warn{border-color:var(--pss-warn);background:rgba(176,136,0,.08)}\
.pss details.card>summary{cursor:pointer;font-weight:600;list-style:none}\
.pss details.card>summary::before{content:"▸ ";opacity:.6}\
.pss details.card[open]>summary::before{content:"▾ "}\
.pss details.card[open]>summary{margin-bottom:12px}\
.pss .feed{list-style:none;margin:0;padding:0}\
.pss .feed li{padding:7px 0;border-bottom:1px solid var(--pss-line)}\
.pss .feed li:last-child{border:none}\
.pss pre.log{max-height:360px;overflow:auto;white-space:pre-wrap;font-size:.85em;margin:0}\
.pss .foot{display:flex;justify-content:space-between;align-items:center;opacity:.65;font-size:.85em;margin-top:6px}\
.pss input.w{width:100%;box-sizing:border-box}\
.pss .layers{display:flex;gap:10px;flex-wrap:wrap}\
.pss .layer{border:1px solid var(--pss-line);border-radius:8px;padding:6px 10px}\
.pss.busy{opacity:.55;pointer-events:none;transition:opacity .2s}\
.pss .saving{position:fixed;right:24px;bottom:24px;padding:8px 14px;border-radius:8px;background:var(--pss-acc);color:#fff;box-shadow:0 2px 10px rgba(0,0,0,.25);z-index:1000}\
@media (max-width:700px){.pss .hero{grid-template-columns:1fr}.pss .kv{grid-template-columns:1fr}}';

// Safe element builder: LuCI dom.append() puts a *string* child into innerHTML; names, statuses, alerts and titles
// come from other routers / StealthSurf, so strings always become text nodes here.
var RAW_E = window.E;
function SE(tag, attrs, children) {
	if (typeof attrs === 'string' || typeof attrs === 'number' || Array.isArray(attrs) || attrs instanceof Node) { children = attrs; attrs = null; }
	if (typeof children === 'string' || typeof children === 'number') children = [ String(children) ];
	return RAW_E(tag, attrs || {}, children);
}
function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"']/g, function(ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; });
}

return baseclass.extend({
	api: api,
	E: SE,
	esc: esc,

	css: function() {
		if (!document.getElementById('pss-css')) {
			var s = document.createElement('style');
			s.id = 'pss-css'; s.textContent = CSS;
			document.head.appendChild(s);
		}
	},

	fmtTime: function(ts) { return ts ? new Date(ts * 1000).toLocaleString('ru-RU', { timeZone: 'Europe/Moscow', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—'; },
	fmtDate: function(ts) { return ts ? new Date(ts * 1000).toLocaleDateString('ru-RU', { timeZone: 'Europe/Moscow' }) : '—'; },
	ago: function(ts) {
		if (!ts) return '—';
		var s = Math.floor(Date.now() / 1000) - ts;
		if (s < 60) return 'только что';
		if (s < 5400) return Math.round(s / 60) + ' мин назад';
		if (s < 172800) return Math.round(s / 3600) + ' ч назад';
		return Math.round(s / 86400) + ' дн назад';
	},
	daysLeft: function(ts) { return ts ? Math.ceil((ts * 1000 - Date.now()) / 86400000) : null; },
	cls: function(status) { return (STATUS[status] || [ '', 'mute' ])[1]; },
	pill: function(status) {
		var s = STATUS[status] || [ String(status || '—'), 'mute' ];
		return SE('span', { 'class': 'pill ' + s[1] }, s[0]);
	},
	dot: function(status) { return SE('span', { 'class': 'dot ' + this.cls(status), 'title': (STATUS[status] || [ status ])[0] }); },

	// config title for a binding: rotation file facts, then bot card, then the raw binding
	cfgTitle: function(u, b) {
		if (!b) return 'конфиг не назначен';
		var r = (u.rotations || {})[b] || {}, c = (u.cards || {})[b] || {};
		return r.title || c.title || b;
	},

	// human-readable reasons and journal lines (the service logs in English)
	reason: function(r) {
		r = String(r || '');
		var m;
		if (r == 'blocked') return 'блокировка';
		if (r == 'manual') return 'вручную';
		if (r == 'dry run') return 'пробная';
		if (r == 'retry (waiting)') return 'повтор после ожидания';
		if (r == 'blocked (GitHub down)') return 'блокировка, GitHub недоступен';
		if ((m = r.match(/^blocked on (.+)$/))) return 'блокировка у ' + m[1];
		return r;
	},
	logLine: function(msg) {
		var m, rules = [
			[ /^check failed \(l3=(\w+) l4=(\w+)\), counter (\d+)\/(\d+)/, function(m) { return 'Проверка не прошла: сервер ' + (m[1] == 'true' ? '✓' : '✗') + ', туннель ' + (m[2] == 'true' ? '✓' : '✗') + ' — сбой ' + m[3] + ' из ' + m[4]; } ],
			[ /^applying new link \((.*)\)/, function(m) { return 'Применяю новую ссылку (' + m[1].replace('rotations rev', 'ревизия').replace('own rotation', 'своя ротация') + ')'; } ],
			[ /^podkop: new link written to section (\S+), restarting podkop/, function(m) { return 'Ссылка записана в секцию podkop «' + m[1] + '», podkop перезапущен'; } ],
			[ /^rotation result: (\w+)(.*)/, function(m) { return 'Результат ротации: ' + ({ rotated: 'сервер сменён', locked: 'ротацию делает другой роутер', recovered: 'связь восстановилась сама', applied: 'взята новая ссылка', waiting: 'режим ожидания', error: 'ошибка' }[m[1]] || m[1]) + m[2]; } ],
			[ /^PATCH config (\d+) -> location (\d+), (\w+) \[([^\]]*)\]/, function(m) { return 'Перенос конфига ' + m[1] + ' в локацию ' + m[2] + ' (серверы ' + m[4] + ')'; } ],
			[ /^alert written: ([^ ]+) — (.*)/, function(m) { return 'Алерт боту: ' + m[2]; } ],
			[ /^recheck passed — no rotation/, function() { return 'Повторная проверка прошла — ротация не нужна'; } ],
			[ /^follower: blocked report written/, function() { return 'Ведомый роутер: отправлен отчёт о блокировке, жду роутер с токеном'; } ],
			[ /^blocked report from (.+) — rotating for it/, function(m) { return 'Отчёт о блокировке от ' + m[1] + ' — делаю ротацию'; } ],
			[ /^podkop\/sing-box down — restarting podkop/, function() { return 'podkop / sing-box не работает — перезапуск'; } ],
			[ /^waiting mode over: link works/, function() { return 'Режим ожидания снят — связь работает'; } ],
			[ /^contour password was changed — switching to the new key/, function() { return 'Пароль контура сменён — роутер перешёл на новый ключ'; } ],
			[ /^StealthSurf (\S+) (\S+) -> (\d+)/, function(m) { return 'StealthSurf ' + m[1] + ' ' + m[2].split('?')[0] + ' — ' + (m[3] == '0' ? 'нет связи' : 'ответ ' + m[3]); } ],
			[ /^store: write conflict on (\S+)/, function(m) { return 'Одновременная запись ' + m[1] + ' — повтор'; } ],
			[ /^LuCI: (.*)/, function(m) { return 'LuCI: ' + m[1]; } ]
		];
		for (var i = 0; i < rules.length; i++) if ((m = String(msg).match(rules[i][0]))) return rules[i][1](m);
		return msg;
	},

	notify: function(text, kind) { ui.addNotification(null, SE('p', text), kind || 'info'); },
	err: function(res) {
		if (res && res.conflict) { this.notify(res.message, 'warning'); return true; }
		if (!res || res.error) { this.notify('Ошибка: ' + ((res && res.error) || 'нет ответа'), 'danger'); return true; }
		return false;
	},
	// contour edit; rev = revision the page shows (concurrent edits are rejected, spec §8)
	op: function(op, args, rev) {
		var self = this;
		return api.contourOp(op, args || {}, rev).then(function(res) {
			if (self.err(res)) return null;
			return res;
		});
	},

	modal: function(title, body, buttons) {
		ui.showModal(esc(title), [ SE('div', { 'class': 'pss' }, body),
			SE('div', { 'class': 'right', 'style': 'margin-top:14px' }, [ SE('button', { 'class': 'btn', 'click': ui.hideModal }, 'Закрыть') ].concat(buttons || [])) ]);
	},
	btn: function(label, fn, kind) { return SE('button', { 'class': 'btn ' + (kind || ''), 'click': fn }, label); },

	// background job with progress (long operations run in the service process, spec §8)
	job: function(name, title, onDone) {
		var out = SE('pre', { 'class': 'log' }, '…');
		var state = SE('p', { 'class': 'spinning' }, 'Выполняется…');
		var t = null, t0 = Date.now();
		ui.showModal(esc(title), [ SE('div', { 'class': 'pss' }, [ state, out ]),
			SE('div', { 'class': 'right' }, SE('button', { 'class': 'btn', 'click': function() { if (t) window.clearInterval(t); ui.hideModal(); } }, 'Закрыть')) ]);
		return api.jobStart(name).then(function(r) {
			if (r && r.running) state.textContent = 'Уже выполняется — показываю ход…';
			t = window.setInterval(function() {
				if (Date.now() - t0 > 15 * 60 * 1000) { window.clearInterval(t); return; }
				api.jobStatus(name).then(function(st) {
					out.textContent = st.output || '…';
					if (!st.running) {
						window.clearInterval(t);
						state.classList.remove('spinning');
						state.textContent = st.rc === 0 ? '✓ Готово' : '✗ Завершено с ошибкой (код ' + st.rc + ')';
						if (onDone) onDone(st);
					}
				});
			}, 2000);
		});
	},

	kv: function(rows) {
		var out = [];
		rows.forEach(function(r) { if (r) { out.push(SE('div', { 'class': 'k' }, r[0])); out.push(SE('div', {}, r[1])); } });
		return SE('div', { 'class': 'kv' }, out);
	},

	footer: function(u, onRefresh) {
		return SE('div', { 'class': 'foot' }, [
			SE('span', 'Данные службы: ' + (u.age != null ? (u.age < 60 ? u.age + ' с' : Math.round(u.age / 60) + ' мин') + ' назад' : '—') + ' · Peers-SS ' + (u.version || '')),
			SE('button', { 'class': 'ib', 'click': onRefresh, 'title': 'Перечитать хранилище' }, '⟳ Обновить из хранилища')
		]);
	},

	// pull a fresh snapshot from GitHub (slow path) and redraw
	refresh: function(redraw) {
		var self = this;
		return self.job('snapshot', 'Обновление данных из хранилища', function() { ui.hideModal(); redraw(); });
	}
});
