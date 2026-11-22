'use strict';
'require baseclass';
'require ui';
'require view.peers-ss.__V__.common as c';

var E = c.E;

var EVENTS = [ [ 'rotated', 'Блокировка и ротация' ], [ 'waiting', 'Ротация не помогает' ], [ 'offline', 'Роутер не на связи > 1 ч' ],
	[ 'account', 'Проблемы токена / конфига' ], [ 'notoken', 'Нет роутера с токеном' ], [ 'badchannel', 'Плохой канал, podkop изменился' ] ];

return baseclass.extend({

	hero: function(u) {
		var st = u.state || {}, rot = (u.rotations || {})[u.binding] || {}, card = (u.cards || {})[u.binding] || {};
		var exp = rot.expires_at || card.expires_at, left = c.daysLeft(exp);
		var last = (rot.history || []).slice(-1)[0];
		var me = (u.routers || []).filter(function(r) { return r.me; })[0] || {};
		var eo = c.envOf(u.contour, u.rid);
		var g = eo && eo.g ? u.contour.groups[eo.g] : null;
		var envName = eo ? (eo.g ? eo.env.name : 'одиночный') : 'вне среды';
		return E('div', { 'class': 'card' }, [
			E('div', { 'class': 'hero' }, [
				E('div', [
					E('div', { 'class': 'row' }, [ c.pill(st.status), E('span', { 'class': 'muted' }, 'проверено ' + c.ago(st.last_check)) ]),
					E('div', { 'class': 'big' }, c.cfgTitle(u, u.binding)),
					E('div', { 'class': 'muted' }, (me.name || u.rid) + ' · ' + (g ? g.name + ' / ' : '') + envName + ' · контур «' + (u.contour.name || u.cid) + '»')
				]),
				E('div', { 'class': 'row' }, [
					c.btn('Проверить сейчас', function() { c.job('check', 'Проверка', function() { c.api.ui().then(function(n) { if (n.configured && !document.querySelector('details[open]')) c.app.reload(); }); }); }, 'cbi-button-action'),
					u.has_token && u.binding ? c.btn('Сменить сервер', function() {
						if (confirm('Перенести конфиг на другой сервер сейчас? Это касается ВСЕХ роутеров с этим конфигом.')) c.job('rotate', 'Смена сервера');
					}, 'cbi-button-negative') : ''
				])
			]),
			E('div', { 'style': 'margin-top:14px' }, c.kv([
				[ 'Локация и сервер', rot.server_id ? (rot.location || ('локация ' + rot.location_id)) + ', сервер ' + rot.server_id : '—' ],
				[ 'Действует до', exp ? E('span', [ c.fmtDate(exp) + ' ', left != null ? E('span', { 'class': 'pill ' + (left <= 3 ? 'bad' : left <= 7 ? 'warn' : 'ok') }, left > 0 ? 'ещё ' + left + ' дн' : 'истёк') : '', (rot.auto_renewal || card.auto_renewal) ? ' · автопродление' : '' ]) : '—' ],
				[ 'Пинг через vless', st.ping_ms ? st.ping_ms + ' мс' : '—' ],
				[ 'Последняя ротация', last ? c.fmtTime(last.at) + ' — ' + (last.location || '') + ', ' + c.reason(last.reason) : 'не было' ],
				[ 'Токен StealthSurf', u.has_token ? 'есть' + (u.token_label ? ' — ' + u.token_label : '') : 'нет (ведомый роутер)' ]
			]))
		]);
	},

	banners: function(u) {
		var st = u.state || {}, rot = (u.rotations || {})[u.binding] || {}, out = [];
		var sb = c.staleBanner(u); if (sb) out.push(sb);
		if (rot.waiting) out.push(E('div', { 'class': 'banner bad' }, 'Режим ожидания: ротация не помогает (техработы или массовая блокировка). Следующая попытка — ' + c.fmtTime(rot.waiting.next_try) + '.'));
		if (u.podkop && u.podkop.ok === false) out.push(E('div', { 'class': 'banner bad' }, 'podkop: ' + u.podkop.reason + ' — нужна перенастройка.'));
		if (u.github_error) out.push(E('div', { 'class': 'banner warn' }, 'Хранилище GitHub недоступно (' + u.github_error + '). Роутер работает по последним данным.'));
		if (st.diag_ok === false) out.push(E('div', { 'class': 'banner warn' }, 'Диагностика podkop: ' + (st.diag_fails || []).join(', ')));
		if (!u.binding) out.push(E('div', { 'class': 'banner warn' }, 'Конфиг для этого роутера не назначен — назначьте его во вкладке «Роутеры».'));
		return out;
	},

	contourCard: function(u) {
		var tiles = (u.routers || []).map(function(r) {
			return E('div', { 'class': 'chip', 'style': 'cursor:default' }, [ c.dot(r.status), E('b', r.name), E('span', { 'class': 'muted' },
				(r.ping_ms ? r.ping_ms + ' мс · ' : '') + c.ago(r.last_contact) + (r.has_token ? ' · 🔑' : '')) ]);
		});
		return E('div', { 'class': 'card' }, [ E('h3', [ 'Роутеры контура', E('span', { 'class': 'sp' }), E('span', { 'class': 'muted' }, (u.routers || []).length + ' шт.') ]), E('div', tiles) ]);
	},

	alertsCard: function(u) {
		var items = (u.alerts || []).slice(0, 8).map(function(a) {
			return E('li', [ E('span', { 'class': 'muted' }, c.fmtTime(a.at) + ' · '), a.text ]);
		});
		return E('div', { 'class': 'card' }, [ E('h3', 'События'), items.length ? E('ul', { 'class': 'feed' }, items) : E('p', { 'class': 'muted' }, 'Событий нет — всё спокойно.') ]);
	},

	settingsCard: function(u, redraw) {
		var s = u.settings || {};
		var iv = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.check_interval_s, 'min': 15, 'style': 'width:7em' }),
			th = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.fail_threshold, 'min': 1, 'style': 'width:7em' }),
			rt = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': s.retry_min, 'min': 1, 'style': 'width:7em' }),
			ex = E('input', { 'type': 'text', 'class': 'cbi-input-text w', 'value': (s.exclude_locations || []).join(', ') });
		return E('details', { 'class': 'card' }, [ E('summary', 'Настройки контура'),
			c.kv([ [ 'Проверка каждые, с', iv ], [ 'Сбоев подряд до ротации', th ], [ 'Повтор в ожидании, мин', rt ],
				[ 'Не переходить в локации', E('div', [ ex, E('div', { 'class': 'muted' }, 'smart — «Умная», RU — Россия; коды через запятую') ]) ],
				[ 'Секция podkop (этот роутер)', E('code', u.podkop_section || '—') ], [ 'Хранилище', E('code', u.repo || '—') ] ]),
			E('div', { 'class': 'right' }, c.btn('Сохранить', function() {
				c.op('settings', { check_interval_s: +iv.value, fail_threshold: +th.value, retry_min: +rt.value, exclude_locations: ex.value }, u.contour.rev)
					.then(function(r) { if (r) { c.notify('Настройки сохранены — роутеры контура применят их в течение минуты'); redraw(); } });
			}, 'cbi-button-save')) ]);
	},

	notifyCard: function(u, redraw) {
		var s = u.settings || {}, ev = s.bot_events || {};
		var key = E('input', { 'type': 'password', 'class': 'cbi-input-text w', 'value': s.bot_key || '', 'style': 'font-family:monospace' });
		var checks = EVENTS.map(function(e) { return E('label', { 'style': 'display:block' }, [ E('input', { 'type': 'checkbox', 'value': e[0], 'checked': ev[e[0]] === false ? null : '' }), ' ' + e[1] ]); });
		return E('details', { 'class': 'card' }, [ E('summary', 'Уведомления (Telegram-бот)'),
			c.kv([ [ 'Ключ бота', E('div', { 'class': 'row', 'style': 'flex-wrap:nowrap' }, [ key, E('button', { 'class': 'ib', 'click': function() { key.type = key.type == 'password' ? 'text' : 'password'; } }, '👁') ]) ],
				[ 'Алерты администратору', E('div', checks) ],
				[ 'Карточки конфигов', E('span', { 'class': 'muted' }, 'название, срок, автопродление — раз в 6 ч, без ссылок и токенов') ] ]),
			E('div', { 'class': 'right' }, [
				c.btn('Тестовый алерт', function() { c.api.testAlert().then(function(r) { if (!c.err(r)) c.notify('Алерт записан — бот перешлёт его в течение 5 минут'); }); }), ' ',
				c.btn('Сохранить', function() {
					var evs = {}; checks.forEach(function(l) { evs[l.firstChild.value] = l.firstChild.checked; });
					c.op('settings', { bot_key: key.value.trim(), bot_events: evs }, u.contour.rev).then(function(r) { if (r) { c.notify('Сохранено'); redraw(); } });
				}, 'cbi-button-save') ]) ]);
	},

	securityCard: function(u) {
		var res = E('span', { 'class': 'muted' });
		return E('details', { 'class': 'card' }, [ E('summary', 'Связь и безопасность'),
			E('div', { 'class': 'row' }, [
				c.btn('Проверить связь с API и GitHub', function() {
					res.textContent = 'проверка…';
					c.api.apiCheck().then(function(r) {
						res.textContent = 'GitHub: ' + (r.github ? '✓' : '✗ HTTP ' + r.github_status) + ' · StealthSurf: ' + (r.stealthsurf != null ? (r.stealthsurf ? '✓' : '✗ ' + r.stealthsurf_status) : (r.stealthsurf_reachable ? '✓ (без токена)' : '✗'));
					});
				}),
				c.btn('Сменить пароль контура', function() {
					var o = E('input', { 'type': 'text', 'class': 'cbi-input-text w' }), n1 = E('input', { 'type': 'text', 'class': 'cbi-input-text w' }), n2 = E('input', { 'type': 'text', 'class': 'cbi-input-text w' });
					c.modal('Пароль контура', [ c.kv([ [ 'Текущий', o ], [ 'Новый', n1 ], [ 'Ещё раз', n2 ] ]),
						E('p', { 'class': 'muted' }, 'Все файлы контура перешифруются, остальные роутеры перейдут на новый ключ сами (до 10 мин).') ],
						[ c.btn('Сменить', function() {
							if (n1.value != n2.value) return alert('Пароли не совпадают');
							if (n1.value.length < 8) return alert('Минимум 8 символов');
							c.api.passwordChange(o.value, n1.value).then(function(r) { if (!c.err(r)) c.job('passwd', 'Смена пароля контура'); });
						}, 'cbi-button-action') ]);
				}, 'cbi-button-negative'), res ]) ]);
	},

	render: function(u) {
		var self = this, root = E('div', { 'class': 'pss' });
		self.root = root;
		self.draw = function(d) {
			root.innerHTML = '';
			if (!d.configured) { root.appendChild(E('div', { 'class': 'banner warn' }, d.pending ? 'Данные загружаются из хранилища — обновите страницу через минуту.' : 'Роутер не зарегистрирован в контуре. Запустите install.sh.')); return; }
			var redraw = function() { c.app.reload(); };
			self.banners(d).concat([ self.hero(d), self.contourCard(d), self.alertsCard(d),
				self.settingsCard(d, redraw), self.notifyCard(d, redraw), self.securityCard(d), c.footer(d, function() { c.refresh(redraw); }) ])
				.forEach(function(n) { root.appendChild(n); });
		};
		self.draw(u);
		return root;
	},
	// periodic refresh from the app: keep open sections / dialogs as the user left them
	refresh: function(n) {
		if (n.configured && !this.root.querySelector('details[open]') && !c.modalOpen()) this.draw(n);
	},
});
