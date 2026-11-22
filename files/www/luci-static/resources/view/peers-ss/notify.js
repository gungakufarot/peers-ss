'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

var E = c.E;

var EVENTS = [ [ 'rotated', 'Блокировка и успешная ротация' ], [ 'waiting', 'Ротация не помогает, режим ожидания' ], [ 'offline', 'Роутер не на связи больше часа' ],
	[ 'account', 'Аккаунт пуст / конфиг исчез / токен недействителен / cantChangeSettings' ], [ 'notoken', 'Нет роутера с токеном' ], [ 'badchannel', 'Плохой канал, podkop изменился' ] ];

return view.extend({
	load: function() { return c.api.contourGet(); },
	render: function(d) {
		if (d.error) return E('div', { 'class': 'alert-message warning' }, d.error);
		var s = d.settings || {}, key = s.bot_key || '';
		var inp = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'style': 'width:100%;font-family:monospace', 'value': key });
		var ev = s.bot_events || {};
		var checks = EVENTS.map(function(e) { return E('label', { 'style': 'display:block' }, [ E('input', { 'type': 'checkbox', 'value': e[0], 'checked': ev[e[0]] === false ? null : '' }), ' ' + e[1] ]); });
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Уведомления'), E('div', { 'class': 'cbi-section' }, [
			E('p', 'Ключ бота (один на все контуры; им шифруются карточки и алерты для бота):'), inp,
			E('button', { 'class': 'btn', 'click': function(e) { inp.type = inp.type == 'password' ? 'text' : 'password'; e.target.textContent = inp.type == 'password' ? 'Показать' : 'Скрыть'; } }, 'Показать'),
			E('p', 'Боту уходят: карточки конфигов (название, срок, автопродление — без ссылок и токенов) раз в 6 ч и алерты:'), E('div', checks),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': function() { c.api.testAlert().then(function(r) { if (!c.err(r)) ui.addNotification(null, E('p', 'Тестовый алерт записан, бот перешлёт его администратору в течение 5 минут'), 'info'); }); } }, 'Отправить тестовый алерт'), ' ',
				E('button', { 'class': 'btn cbi-button-save', 'click': function() {
					var evs = {};
					checks.forEach(function(l) { evs[l.firstChild.value] = l.firstChild.checked; });
					c.op('settings', { bot_key: inp.value.trim(), bot_events: evs }, d.contour.rev).then(function(r) { if (r) window.location.reload(); });
				} }, 'Сохранить') ]) ]) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
