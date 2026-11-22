'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

var E = c.E;

return view.extend({
	load: function() { return Promise.all([ c.api.contourGet(), c.api.invites() ]); },

	render: function(data) {
		var d = data[0], inv = data[1] || {};
		if (d.error) return E('div', { 'class': 'alert-message warning' }, d.error);
		var opts = [];
		Object.keys(d.contour.groups || {}).forEach(function(gid) {
			var g = d.contour.groups[gid];
			Object.keys(g.envs).forEach(function(eid) { opts.push(E('option', { 'value': gid + '/' + eid }, g.name + ' / ' + g.envs[eid].name)); });
			opts.push(E('option', { 'value': gid + '/' }, g.name + ' / новая среда'));
		});
		opts.push(E('option', { 'value': '/' }, 'одиночный роутер'));
		var target = E('select', { 'class': 'cbi-input-select' }, opts);
		var hours = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': '24', 'min': '1', 'max': '720', 'style': 'width:6em' });
		var result = E('div');
		var create = function() {
			var p = target.value.split('/');
			c.api.inviteCreate(p[0], p[1], +hours.value).then(function(r) {
				if (c.err(r)) return;
				var ta = E('textarea', { 'readonly': '', 'rows': 3, 'style': 'width:100%;font-family:monospace' }, r.command);
				result.innerHTML = '';
				result.appendChild(E('div', { 'class': 'alert-message' }, [
					E('p', 'Ссылка одноразовая, действует до ' + c.fmtTime(r.expires_at) + '. В ней токен GitHub с правом записи — передавайте её как пароль.'),
					ta, E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						ta.select();
						(navigator.clipboard ? navigator.clipboard.writeText(r.command) : Promise.reject()).catch(function() { document.execCommand('copy'); });
						ui.addNotification(null, E('p', 'Команда скопирована'), 'info');
					} }, 'Копировать команду') ]));
			});
		};
		var rows = (inv.invites || []).map(function(i) {
			return [ i.group_name ? i.group_name + ' / ' + (i.env_name || 'новая среда') : 'одиночный', c.fmtTime(i.expires_at),
				i.revoked ? 'отозвана' : (i.used_by ? 'использована: ' + i.used_name + ' ' + c.fmtTime(i.used_at) : (i.active ? 'активна' : 'истекла')),
				i.active ? E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					c.api.inviteRevoke(i.id).then(function(r) { if (!c.err(r)) window.location.reload(); });
				} }, 'Отозвать') : '' ];
		});
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Добавить роутер'),
			E('div', { 'class': 'cbi-section' }, [ E('p', 'Куда добавить: '), target, E('p', 'Срок действия, часов: '), hours, ' ',
				E('button', { 'class': 'btn cbi-button-add', 'click': create }, 'Создать ссылку'), result ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', 'Ссылки'), c.table([ 'Куда', 'Действует до', 'Состояние', '' ], rows) ]) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
