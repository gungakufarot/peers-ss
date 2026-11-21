'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

return view.extend({
	load: function() { return c.api.contourGet(); },
	reload: function() { window.location.reload(); },

	move: function(d, r) {
		var self = this, opts = [];
		Object.keys(d.contour.groups || {}).forEach(function(gid) {
			var g = d.contour.groups[gid];
			Object.keys(g.envs).forEach(function(eid) { opts.push(E('option', { 'value': gid + '/' + eid }, g.name + ' / ' + g.envs[eid].name)); });
			opts.push(E('option', { 'value': gid + '/' }, g.name + ' / + новая среда'));
		});
		var sel = E('select', { 'class': 'cbi-input-select' }, opts);
		ui.showModal('Перенести «' + r.name + '»', [ sel, E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
			E('button', { 'class': 'btn cbi-button-action', 'click': function() {
				var p = sel.value.split('/');
				c.op('move_router', { rid: r.rid, gid: p[0], eid: p[1] || null }, d.contour.rev).then(function(x) { ui.hideModal(); if (x) self.reload(); });
			} }, 'Перенести') ]) ]);
	},

	render: function(d) {
		if (d.error) return E('div', { 'class': 'alert-message warning' }, d.error);
		var self = this, rev = d.contour.rev;
		var rows = d.routers.map(function(r) {
			return [
				r.name + (r.me ? ' (этот)' : ''), r.group_name || 'одиночный', r.env_name || '—',
				r.has_token ? 'есть (' + r.account + ')' : 'нет — ведомый',
				c.ago(r.last_contact), r.ping_ms ? r.ping_ms + ' мс' : '—', c.badge(r.status),
				E('div', [
					E('button', { 'class': 'btn', 'click': function() {
						var n = prompt('Новое имя (1–32 символа):', r.name);
						if (n && n != r.name) c.op('rename_router', { rid: r.rid, name: n }, rev).then(function(x) { if (x) self.reload(); });
					} }, 'Переименовать'), ' ',
					E('button', { 'class': 'btn', 'click': function() { self.move(d, r); } }, 'Перенести'), ' ',
					r.group ? E('button', { 'class': 'btn', 'click': function() {
						if (confirm('Сделать «' + r.name + '» одиночным? Конфиг сохранится.')) c.op('make_standalone', { rid: r.rid }, rev).then(function(x) { if (x) self.reload(); });
					} }, 'Сделать одиночным') : '', ' ',
					r.me ? '' : E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
						if (confirm('Убрать «' + r.name + '» из контура? На самом роутере выполните peers-ss uninstall.')) c.op('remove_router', { rid: r.rid }, rev).then(function(x) { if (x) self.reload(); });
					} }, 'Убрать из контура')
				])
			];
		});
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Устройства'), E('div', { 'class': 'cbi-section' },
			c.table([ 'Имя', 'Группа', 'Среда', 'Токен', 'Последний контакт', 'Пинг', 'Статус', '' ], rows)) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
