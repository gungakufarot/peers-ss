'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

return view.extend({
	load: function() { return Promise.all([ c.api.events(), c.api.status() ]); },
	render: function(data) {
		var ev = data[0] || {}, s = data[1] || {};
		var lines = (ev.log || '').trim().split('\n').reverse().slice(0, 150).map(function(l) {
			var p = l.split(' '); return c.fmtTime(+p[0]) + ' ' + p.slice(1).join(' ');
		});
		var hist = ((s.rotation || {}).history || []).slice().reverse().map(function(h) {
			return [ c.fmtTime(h.at), h.by, h.from_server + ' → ' + h.to_server, h.location, h.reason + (h.note ? ' (' + h.note + ')' : '') ];
		});
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Диагностика'),
			E('div', { 'class': 'cbi-section' }, [ E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': function() { c.job('diag', 'Диагностика podkop'); } }, 'Диагностика podkop'), ' ',
				E('button', { 'class': 'btn', 'click': function() { c.job('dry', 'Пробная ротация (без PATCH)'); } }, 'Пробная ротация'), ' ',
				E('button', { 'class': 'btn', 'click': function() {
					c.api.report().then(function(r) {
						var a = E('a', { 'href': URL.createObjectURL(new Blob([ r.report ], { type: 'text/plain' })), 'download': 'peers-ss-report.txt' });
						document.body.appendChild(a); a.click(); a.remove();
					});
				} }, 'Скачать отчёт') ]) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', 'История ротаций'), c.table([ 'Когда', 'Роутер', 'Сервер', 'Локация', 'Причина' ], hist) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', 'Журнал событий'), E('pre', { 'style': 'max-height:400px;overflow:auto;white-space:pre-wrap' }, lines.join('\n')) ]) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
