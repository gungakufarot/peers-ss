'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

var E = c.E;

return view.extend({
	load: function() { return c.api.tokenGet(false); },

	render: function(t) {
		var shown = false;
		var val = E('code', t.has ? t.token : 'нет токена (ведомый роутер)');
		var info = E('div');
		var showInfo = function(r) {
			info.innerHTML = '';
			if (!r.ok) { info.appendChild(E('p', { 'style': 'color:#cf222e' }, 'Токен не прошёл проверку (HTTP ' + r.status + ')')); return; }
			info.appendChild(E('p', 'Аккаунт ' + r.account + ', vless-конфигов: ' + r.vless + ', ближайшее окончание: ' + c.fmtDate(r.soonest)));
			if (r.vless == 0) info.appendChild(E('p', { 'style': 'color:#b08800' }, 'Аккаунт пуст'));
		};
		var replace = function() {
			var inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'placeholder': 'stlth_…' });
			var lbl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': t.label || '', 'placeholder': 'Аккаунт Иванова' });
			var warn = E('div');
			ui.showModal('Заменить токен', [ E('p', 'Токен (виден при вводе):'), inp, E('p', 'Метка:'), lbl, warn,
				E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
					E('button', { 'class': 'btn', 'click': function() {
						c.api.tokenCheck(inp.value.trim()).then(function(r) {
							warn.innerHTML = '';
							if (!r.ok) { warn.appendChild(E('p', { 'style': 'color:#cf222e' }, 'Токен не прошёл проверку')); return; }
							warn.appendChild(E('p', 'Аккаунт ' + r.account + ', vless-конфигов: ' + r.vless));
							if (r.follower_bindings.length) warn.appendChild(E('p', { 'style': 'color:#b08800' }, 'С этим токеном роутер станет ВЕДОМЫМ по привязкам: ' + r.follower_bindings.join(', ')));
						});
					} }, 'Проверить'), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						c.api.tokenSet(inp.value.trim(), lbl.value).then(function(r) { if (!c.err(r)) { ui.hideModal(); window.location.reload(); } });
					} }, 'Сохранить') ]) ]);
		};
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Токен StealthSurf'), E('div', { 'class': 'cbi-section' }, [
			E('p', [ E('strong', 'Метка: '), t.label || '—' ]), E('p', [ E('strong', 'Аккаунт: '), t.account || '—' ]),
			E('p', [ E('strong', 'Токен: '), val ]), info,
			E('div', { 'class': 'right' }, [
				t.has ? E('button', { 'class': 'btn', 'click': function(ev) {
					shown = !shown;
					c.api.tokenGet(shown).then(function(n) { val.textContent = n.token; ev.target.textContent = shown ? 'Скрыть' : 'Показать'; });
				} }, 'Показать') : '', ' ',
				t.has ? E('button', { 'class': 'btn', 'click': function() { c.api.tokenCheck('').then(showInfo); } }, 'Проверить') : '', ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': replace }, t.has ? 'Заменить' : 'Добавить'), ' ',
				t.has ? E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					if (confirm('Удалить токен? Роутер станет ведомым по всем привязкам.')) c.api.tokenDelete().then(function() { window.location.reload(); });
				} }, 'Удалить') : ''
			]) ]) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
