'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

return view.extend({
	load: function() { return c.api.contourGet().then(function(d) { return [ d, { repo: d.repo } ]; }); },
	render: function(data) {
		var d = data[0], st = data[1];
		if (d.error) return E('div', { 'class': 'alert-message warning' }, d.error);
		var s = d.settings;
		var f = function(label, el, help) { return E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, label), E('div', { 'class': 'cbi-value-field' }, [ el, help ? E('div', { 'class': 'cbi-value-description' }, help) : '' ]) ]); };
		var iv = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.check_interval_s }),
			th = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.fail_threshold }),
			rt = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.retry_min }),
			ex = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': (s.exclude_locations || []).join(', ') }),
			ps = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': s.podkop_section });
		var res = E('div');
		return E('div', { 'class': 'cbi-map' }, [ E('h2', 'Настройки контура'), E('div', { 'class': 'cbi-section' }, [
			f('Интервал проверки, с', iv, 'по умолчанию 45'), f('Порог сбоев подряд', th, 'по умолчанию 3'), f('Повтор в режиме ожидания, мин', rt, 'по умолчанию 10'),
			f('Исключённые локации', ex, 'smart = «Умная», RU = Россия; коды локаций через запятую'), f('Секция podkop', ps),
			f('Репозиторий хранилища', E('code', st.repo || '—')),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn cbi-button-save', 'click': function() {
				c.op('settings', { check_interval_s: +iv.value, fail_threshold: +th.value, retry_min: +rt.value, exclude_locations: ex.value, podkop_section: ps.value }, d.contour.rev).then(function(r) { if (r) window.location.reload(); });
			} }, 'Сохранить')) ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', 'Действия'),
				E('button', { 'class': 'btn', 'click': function() {
					res.textContent = 'проверка…';
					c.api.apiCheck().then(function(r) { res.textContent = 'GitHub: ' + (r.github ? 'ok' : 'нет (HTTP ' + r.github_status + ')') + '; StealthSurf: ' + (r.stealthsurf != null ? (r.stealthsurf ? 'ok' : 'ошибка ' + r.stealthsurf_status) : (r.stealthsurf_reachable ? 'доступен (токена нет)' : 'недоступен')); });
				} }, 'Проверить связь с API и GitHub'), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					var o = E('input', { 'type': 'text', 'class': 'cbi-input-text' }), n1 = E('input', { 'type': 'text', 'class': 'cbi-input-text' }), n2 = E('input', { 'type': 'text', 'class': 'cbi-input-text' });
					ui.showModal('Сменить пароль контура', [ E('p', 'Текущий пароль:'), o, E('p', 'Новый пароль (дважды):'), n1, n2,
						E('p', { 'class': 'cbi-value-description' }, 'Все файлы контура перешифруются; остальные роутеры получат новый ключ автоматически.'),
						E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ', E('button', { 'class': 'btn cbi-button-action', 'click': function() {
							if (n1.value != n2.value) return alert('Пароли не совпадают');
							c.api.passwordChange(o.value, n1.value).then(function(r) { if (!c.err(r)) { ui.hideModal(); ui.addNotification(null, E('p', 'Пароль изменён, файлов перешифровано: ' + r.files), 'info'); } });
						} }, 'Сменить') ]) ]);
				} }, 'Сменить пароль контура'), res ]) ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
