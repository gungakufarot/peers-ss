'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

var E = c.E;

return view.extend({
	load: function() { c.css(); return Promise.all([ c.api.ui(), c.api.events() ]); },

	tokenCard: function(u) {
		var self = this, shown = false;
		var val = E('code', u.token_masked || '—');
		var info = E('div', { 'class': 'muted', 'style': 'margin-top:8px' });
		var check = function(tok, box) {
			box.textContent = 'проверка…';
			return c.api.tokenCheck(tok || '').then(function(r) {
				box.innerHTML = '';
				if (!r.ok) { box.appendChild(E('span', { 'style': 'color:var(--pss-bad)' }, '✗ токен не прошёл проверку (HTTP ' + r.status + ')')); return r; }
				box.appendChild(E('span', '✓ аккаунт ' + r.account + ' · vless-конфигов: ' + r.vless + ' · ближайшее окончание: ' + c.fmtDate(r.soonest) + (r.vless == 0 ? ' · аккаунт пуст' : '')));
				if (r.follower_bindings && r.follower_bindings.length)
					box.appendChild(E('div', { 'style': 'color:var(--pss-warn)' }, '⚠ с этим токеном роутер станет ведомым для: ' + r.follower_bindings.map(function(b) { return c.cfgTitle(u, b); }).join(', ')));
				return r;
			});
		};
		var replace = function() {
			var inp = E('input', { 'type': 'text', 'class': 'cbi-input-text w', 'placeholder': 'stlth_…' });
			var lbl = E('input', { 'type': 'text', 'class': 'cbi-input-text w', 'value': u.token_label || '', 'placeholder': 'например, «Аккаунт Иванова»' });
			var box = E('div', { 'class': 'muted' });
			c.modal(u.has_token ? 'Заменить токен' : 'Добавить токен', [ c.kv([ [ 'Токен (виден при вводе)', inp ], [ 'Метка', lbl ] ]), E('div', { 'style': 'margin-top:8px' }, box) ], [
				c.btn('Проверить', function() { check(inp.value.trim(), box); }),
				c.btn('Сохранить', function() {
					check(inp.value.trim(), box).then(function(r) {
						if (!r.ok) return;
						if (r.follower_bindings.length && !confirm('Роутер станет ведомым для части конфигов. Сохранить?')) return;
						c.api.tokenSet(inp.value.trim(), lbl.value).then(function(x) { if (!c.err(x)) { ui.hideModal(); c.notify('Токен сохранён'); window.location.reload(); } });
					});
				}, 'cbi-button-save') ]);
		};
		return E('div', { 'class': 'card' }, [
			E('h3', [ '🔑 Токен StealthSurf', E('span', { 'class': 'sp' }), u.has_token ? E('span', { 'class': 'pill ok' }, 'роутер ведущий') : E('span', { 'class': 'pill mute' }, 'ведомый роутер') ]),
			u.has_token ? c.kv([ [ 'Метка', u.token_label || '—' ], [ 'Аккаунт', String(u.account) ], [ 'Токен', E('span', { 'class': 'row', 'style': 'gap:6px' }, [ val,
				E('button', { 'class': 'ib', 'click': function(ev) { shown = !shown; c.api.tokenGet(shown).then(function(t) { if (t && t.token) { val.textContent = t.token; ev.target.textContent = shown ? '🙈' : '👁'; } else c.notify('Не удалось получить токен', 'danger'); }); } }, '👁') ]) ] ])
				: E('p', { 'class': 'muted' }, 'Без токена роутер только применяет новые ссылки; ротацию делает роутер контура с токеном того же аккаунта.'),
			info,
			E('div', { 'class': 'right' }, [
				u.has_token ? c.btn('Проверить', function() { check('', info); }) : '', ' ',
				c.btn(u.has_token ? 'Заменить' : 'Добавить токен', replace, 'cbi-button-action'), ' ',
				u.has_token ? c.btn('Удалить', function() { if (confirm('Удалить токен? Роутер станет ведомым по всем привязкам.')) c.api.tokenDelete().then(function() { window.location.reload(); }); }, 'cbi-button-negative') : ''
			]) ]);
	},

	diagCard: function(u) {
		var st = u.state || {}, l = st.layers || {};
		var mark = function(ok, name, hint) { return E('div', { 'class': 'layer', 'title': hint }, [ ok === true ? '✓ ' : ok === false ? '✗ ' : '· ', name ]); };
		return E('div', { 'class': 'card' }, [
			E('h3', [ '🩺 Диагностика', E('span', { 'class': 'sp' }), c.pill(st.status) ]),
			E('div', { 'class': 'layers' }, [
				mark(l.l1, 'Интернет', 'HTTPS к известным хостам мимо туннеля'), mark(l.l2, 'podkop / sing-box', 'служба и процесс'),
				mark(l.l3, 'Сервер доступен', 'TCP к серверу из ссылки'), mark(l.l4, 'Туннель', 'generate_204 через mixed-прокси') ]),
			E('p', { 'class': 'muted' }, 'Последняя проверка ' + c.ago(st.last_check) + (st.counter ? ' · сбоев подряд: ' + st.counter : '') + (st.ping_ms ? ' · пинг через vless ' + st.ping_ms + ' мс' : '')),
			E('div', { 'class': 'row' }, [
				c.btn('Диагностика podkop', function() { c.job('diag', 'Диагностика podkop'); }),
				u.has_token && u.binding ? c.btn('Пробная ротация', function() { c.job('dry', 'Пробная ротация (всё, кроме PATCH)'); }) : '',
				c.btn('Скачать отчёт', function() {
					c.api.report().then(function(r) {
						var a = E('a', { 'href': URL.createObjectURL(new Blob([ r.report ], { type: 'text/plain' })), 'download': 'peers-ss-report.txt' });
						document.body.appendChild(a); a.click(); a.remove();
					});
				}) ]) ]);
	},

	historyCard: function(u) {
		var h = (((u.rotations || {})[u.binding] || {}).history || []).slice().reverse();
		var name = function(rid) { return ((u.contour.routers || {})[rid] || {}).name || rid; };
		return E('div', { 'class': 'card' }, [ E('h3', '↻ История ротаций'),
			h.length ? E('ul', { 'class': 'feed' }, h.map(function(x) {
				return E('li', [ E('b', c.fmtTime(x.at)), ' · ' + (x.location || '') + ', сервер ' + x.from_server + ' → ' + x.to_server,
					E('span', { 'class': 'muted' }, ' · ' + name(x.by) + ' · ' + c.reason(x.reason) + (x.note ? ' (записано после сбоя GitHub)' : '')) ]);
			})) : E('p', { 'class': 'muted' }, 'Ротаций ещё не было.') ]);
	},

	logCard: function(ev) {
		var lines = (ev.log || '').trim().split('\n').filter(String).reverse().map(function(l) {
			var p = l.split(' '); return { t: +p[0], lvl: p[1], msg: p.slice(2).join(' ') };
		});
		var pre = E('pre', { 'class': 'log' });
		var filt = E('input', { 'type': 'search', 'class': 'cbi-input-text', 'placeholder': 'фильтр…', 'style': 'width:14em' });
		var onlyWarn = E('input', { 'type': 'checkbox' });
		var paint = function() {
			var f = filt.value.toLowerCase();
			pre.textContent = lines.filter(function(l) { return (!onlyWarn.checked || l.lvl != 'info') && (!f || c.logLine(l.msg).toLowerCase().indexOf(f) >= 0); })
				.slice(0, 300).map(function(l) { return c.fmtTime(l.t) + '  ' + (l.lvl == 'info' ? '' : (l.lvl == 'warn' ? '⚠ ' : '✗ ')) + c.logLine(l.msg); }).join('\n') || '—';
		};
		filt.addEventListener('input', paint); onlyWarn.addEventListener('change', paint); paint();
		return E('div', { 'class': 'card' }, [ E('h3', [ '📜 Журнал событий', E('span', { 'class': 'sp' }), filt, E('label', { 'class': 'muted' }, [ onlyWarn, ' только ошибки' ]) ]), pre ]);
	},

	render: function(data) {
		var u = data[0], ev = data[1] || {};
		var root = E('div', { 'class': 'pss' });
		if (!u.configured) { root.appendChild(E('div', { 'class': 'banner warn' }, 'Роутер не зарегистрирован в контуре.')); return root; }
		[ E('h2', 'Токен и диагностика'), c.staleBanner(u) || '', this.tokenCard(u), this.diagCard(u), this.historyCard(u), this.logCard(ev),
			c.footer(u, function() { c.refresh(function() { window.location.reload(); }); }) ].forEach(function(n) { if (n) root.appendChild(n); });
		return root;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
