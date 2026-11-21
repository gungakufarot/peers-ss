'use strict';
'require view';
'require ui';
'require poll';
'require view.peers-ss.common as c';

return view.extend({
	load: function() { return c.api.status(); },

	renderStatus: function(s) {
		if (!s.configured) return E('div', { 'class': 'alert-message warning' }, 'Роутер не зарегистрирован в контуре. Запустите install.sh.');
		var st = s.state || {}, card = s.card || {}, rot = s.rotation || {};
		var last = (rot.history || []).slice(-1)[0];
		var rows = [
			[ 'Роутер', s.name + ' (' + s.rid + ')' ],
			[ 'Контур', (s.contour_name || '—') + ' (' + s.cid + ')' ],
			[ 'Группа / среда', (s.group || 'одиночный') + ' / ' + (s.env || '—') ],
			[ 'Назначенный конфиг', s.binding ? (card.title || s.binding) : 'не назначен' ],
			[ 'Локация / сервер', rot.location_id ? ('локация ' + rot.location_id + ', сервер ' + rot.server_id) : '—' ],
			[ 'Срок действия', card.expires_at ? c.fmtDate(card.expires_at) + (card.auto_renewal ? ' (автопродление)' : '') : '—' ],
			[ 'Статус', c.badge(st.status) ],
			[ 'Пинг через vless', st.ping_ms ? st.ping_ms + ' мс (' + c.ago(st.ping_at) + ')' : '—' ],
			[ 'Диагностика podkop', st.diag_ok === false ? E('span', { 'style': 'color:#cf222e' }, 'ошибки: ' + (st.diag_fails || []).join(', ')) : (st.diag_ok ? 'зелёная' : '—') ],
			[ 'Последняя проверка', c.ago(st.last_check) + (st.counter ? ', сбоев подряд: ' + st.counter : '') ],
			[ 'Последняя ротация', last ? c.fmtTime(last.at) + ': сервер ' + last.from_server + ' → ' + last.to_server + ' (' + last.location + '), ' + last.reason : 'не было' ],
			[ 'Токен StealthSurf', s.has_token ? 'есть (аккаунт ' + s.account + ')' : 'нет — ведомый роутер' ],
			[ 'Версия', s.version + (s.podkop && !s.podkop.ok ? ' — podkop: ' + s.podkop.reason : '') ]
		];
		if (rot.waiting) rows.push([ 'Режим ожидания', 'с ' + c.fmtTime(rot.waiting.since) + ', следующая попытка ' + c.fmtTime(rot.waiting.next_try) ]);
		if (s.github_error) rows.push([ 'GitHub', E('span', { 'style': 'color:#cf222e' }, 'недоступен: ' + s.github_error) ]);
		var tbl = E('table', { 'class': 'table' }, rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'style': 'width:30%' }, E('strong', r[0])), E('td', { 'class': 'td left' }, r[1]) ]);
		}));
		var alerts = (s.alerts || []).map(function(a) { return E('li', c.fmtTime(a.at) + ' — ' + a.text); });
		return E('div', [ tbl, E('h3', 'Алерты контура'), alerts.length ? E('ul', alerts) : E('p', { 'class': 'cbi-value-description' }, 'нет') ]);
	},

	render: function(s) {
		var self = this;
		var box = E('div', {}, this.renderStatus(s));
		poll.add(function() { return c.api.status().then(function(n) { box.innerHTML = ''; box.appendChild(self.renderStatus(n)); }); }, 15);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', 'Peers-SS — обзор'),
			E('div', { 'class': 'cbi-section' }, [
				box,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-action', 'click': function() { c.job('check', 'Проверить сейчас'); } }, 'Проверить сейчас'), ' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
						if (confirm('Сменить сервер сейчас? Конфиг будет перенесён для ВСЕХ роутеров с этой привязкой.')) c.job('rotate', 'Смена сервера');
					} }, 'Сменить сервер сейчас')
				])
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
