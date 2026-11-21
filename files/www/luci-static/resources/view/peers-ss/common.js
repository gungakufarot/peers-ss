'use strict';
'require baseclass';
'require rpc';
'require ui';
'require poll';

var call = function(method, params, expect) {
	return rpc.declare({ object: 'luci.peers-ss', method: method, params: params || [], expect: expect || {} });
};

var api = {
	status: call('status'),
	contourGet: call('contour_get'),
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
	invites: call('invites'),
	inviteCreate: call('invite_create', [ 'group', 'env', 'hours' ]),
	inviteRevoke: call('invite_revoke', [ 'id' ]),
	events: call('events'),
	report: call('report')
};

var STATUS = {
	ok: [ 'Работает', '#1a7f37' ], failing: [ 'Сбои проверки', '#b08800' ], blocked: [ 'Блокировка', '#cf222e' ],
	waiting: [ 'Ожидание: техработы или массовая блокировка', '#cf222e' ], no_internet: [ 'Нет интернета', '#6e7781' ],
	podkop_down: [ 'podkop не работает', '#cf222e' ], podkop_changed: [ 'podkop изменился, нужна перенастройка', '#cf222e' ],
	bad_channel: [ 'Плохой канал', '#b08800' ], apply_failed: [ 'Ссылка не прошла диагностику', '#cf222e' ],
	no_binding: [ 'Конфиг не назначен', '#6e7781' ], update_required: [ 'Обновите Peers-SS', '#cf222e' ]
};

return baseclass.extend({
	api: api,

	fmtTime: function(ts) {
		if (!ts) return '—';
		var d = new Date(ts * 1000);
		return d.toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' }) + ' МСК';
	},
	fmtDate: function(ts) { return ts ? new Date(ts * 1000).toLocaleDateString('ru-RU', { timeZone: 'Europe/Moscow' }) : '—'; },
	ago: function(ts) {
		if (!ts) return '—';
		var s = Math.floor(Date.now() / 1000) - ts;
		if (s < 90) return s + ' с назад';
		if (s < 5400) return Math.round(s / 60) + ' мин назад';
		return Math.round(s / 3600) + ' ч назад';
	},
	badge: function(status) {
		var s = STATUS[status] || [ status || '—', '#6e7781' ];
		return E('span', { 'style': 'display:inline-block;padding:1px 8px;border-radius:10px;color:#fff;background:' + s[1] }, s[0]);
	},
	err: function(res) {
		if (res && res.conflict) { ui.addNotification(null, E('p', res.message), 'warning'); return true; }
		if (!res || res.error) { ui.addNotification(null, E('p', 'Ошибка: ' + ((res && res.error) || 'нет ответа')), 'danger'); return true; }
		return false;
	},
	// contour edit with conflict detection (rev = revision the page was opened with)
	op: function(op, args, rev) {
		var self = this;
		return api.contourOp(op, args || {}, rev).then(function(res) {
			if (self.err(res)) return null;
			ui.addNotification(null, E('p', 'Сохранено. Остальные роутеры увидят изменения в течение минуты.'), 'info');
			return res;
		});
	},
	// run a background job and show progress until it finishes (spec §8: long operations run in the service)
	job: function(name, title) {
		var self = this;
		var out = E('pre', { 'style': 'max-height:300px;overflow:auto;white-space:pre-wrap' }, '…');
		ui.showModal(title, [ E('p', { 'class': 'spinning' }, 'Выполняется, это может занять до нескольких минут…'), out,
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Закрыть')) ]);
		return api.jobStart(name).then(function() {
			return new Promise(function(resolve) {
				var t = window.setInterval(function() {
					api.jobStatus(name).then(function(st) {
						out.textContent = st.output || '…';
						if (!st.running) {
							window.clearInterval(t);
							var sp = document.querySelector('.modal .spinning');
							if (sp) { sp.classList.remove('spinning'); sp.textContent = st.rc === 0 ? 'Готово' : 'Завершено с ошибкой (код ' + st.rc + ')'; }
							resolve(st);
						}
					});
				}, 2000);
			});
		});
	},
	bindingTitle: function(binding, cards) {
		if (!binding) return 'не назначен';
		var c = cards && cards[binding];
		return (c && c.title ? c.title + ' ' : '') + '(' + binding + ')';
	},
	table: function(head, rows) {
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, head.map(function(h) { return E('th', { 'class': 'th' }, h); }))
		].concat(rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, r.map(function(c) { return E('td', { 'class': 'td' }, c); }));
		})));
	}
});
