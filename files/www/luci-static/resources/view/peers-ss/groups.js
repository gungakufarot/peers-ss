'use strict';
'require view';
'require ui';
'require view.peers-ss.common as c';

return view.extend({
	load: function() { return c.api.contourGet(); },

	reload: function() { window.location.reload(); },

	envRows: function(d, gid, envs) {
		var self = this, rows = [];
		Object.keys(envs || {}).forEach(function(eid) {
			var e = envs[eid];
			var rts = d.routers.filter(function(r) { return r.group == gid && r.env == eid; });
			var bad = rts.filter(function(r) { return r.status && r.status != 'ok'; }).length;
			var rot = d.rotations[e.config];
			rows.push([
				(gid ? '' : 'одиночный: ') + e.name,
				c.bindingTitle(e.config, d.cards) + (rot ? ' — сервер ' + rot.server_id : ''),
				String(rts.length),
				rts.length ? (bad ? E('span', { 'style': 'color:#cf222e' }, 'проблемы: ' + bad) : c.badge('ok')) : '—',
				E('div', [
					E('button', { 'class': 'btn', 'click': function() { self.showMembers(d, e, rts); } }, 'Состав'), ' ',
					E('button', { 'class': 'btn', 'click': function() { self.rename('rename_env', { gid: gid, eid: eid }, e.name, d.contour.rev); } }, 'Переименовать'), ' ',
					E('button', { 'class': 'btn', 'click': function() { self.assign(d, gid, eid); } }, 'Назначить конфиг'), ' ',
					rts.length ? '' : E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
						if (confirm('Удалить пустую среду «' + e.name + '»?')) c.op('delete_env', { gid: gid, eid: eid }, d.contour.rev).then(function(r) { if (r) self.reload(); });
					} }, 'Удалить')
				])
			]);
		});
		return rows;
	},

	showMembers: function(d, e, rts) {
		var card = d.cards[e.config] || {}, rot = d.rotations[e.config] || {};
		ui.showModal('Состав: ' + e.name, [
			E('p', 'Роутеров: ' + rts.length),
			c.table([ 'Роутер', 'Статус', 'Последний контакт' ], rts.map(function(r) { return [ r.name, c.badge(r.status), c.ago(r.last_contact) ]; })),
			E('p', [ E('strong', 'Конфиг: '), c.bindingTitle(e.config, d.cards) ]),
			E('p', 'Локация: ' + (card.location_id || rot.location_id || '—') + ', сервер: ' + (rot.server_id || '—') + ', срок: ' + c.fmtDate(card.expires_at)),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Закрыть'))
		]);
	},

	rename: function(op, args, cur, rev) {
		var self = this, n = prompt('Новое имя (1–32 символа):', cur);
		if (!n || n == cur) return;
		args.name = n;
		c.op(op, args, rev).then(function(r) { if (r) self.reload(); });
	},

	// spec §8: full vless list appears only here; without a token of this router — choose a router with a token
	assign: function(d, gid, eid) {
		var self = this;
		var withTok = d.routers.filter(function(r) { return r.has_token; });
		var sel = E('select', { 'class': 'cbi-input-select' }, withTok.map(function(r) {
			return E('option', { 'value': r.rid, 'selected': r.me ? '' : null }, r.name + (r.me ? ' (этот)' : '') + ' — аккаунт ' + r.account);
		}));
		var list = E('div', {}, withTok.length ? E('em', 'выберите роутер и нажмите «Получить список»') : E('em', 'В контуре нет роутеров с токеном StealthSurf'));
		var fetchList = function(tries) {
			list.innerHTML = '';
			list.appendChild(E('p', { 'class': 'spinning' }, sel.value == d.me ? 'Запрос к StealthSurf…' : 'Запрос через выбранный роутер (до минуты)…'));
			c.api.configs(sel.value == d.me ? '' : sel.value).then(function(res) {
				if (res.pending && tries < 40) return window.setTimeout(function() { fetchList(tries + 1); }, 3000);
				list.innerHTML = '';
				if (!res.ok) { list.appendChild(E('p', { 'style': 'color:#cf222e' }, res.error || 'роутер не ответил')); return; }
				if (!res.configs.length) { list.appendChild(E('p', 'Аккаунт пуст: нет vless-конфигов')); return; }
				res.configs.forEach(function(q) {
					list.appendChild(E('div', [ E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						c.op('assign_config', { gid: gid, eid: eid, binding: q.binding }, d.contour.rev).then(function(r) { ui.hideModal(); if (r) self.reload(); });
					} }, 'Назначить'), ' ' + (q.title || q.id) + ' — до ' + c.fmtDate(q.expires_at) + ' (' + q.binding + ')' ]));
				});
			});
		};
		ui.showModal('Назначить конфиг', [ E('p', 'Чей токен использовать:'), sel, ' ',
			E('button', { 'class': 'btn', 'click': function() { fetchList(0); } }, 'Получить список'), E('hr'), list,
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена')) ]);
	},

	// scheme change wizard: merge environments of a group, or split routers off into a new environment (spec §8)
	scheme: function(d, gid) {
		var self = this, g = d.contour.groups[gid];
		var envs = Object.keys(g.envs);
		var arch = (d.archive || []).filter(function(a) { return a.group == gid; });
		var stepMerge = function() {
			var checks = envs.map(function(eid) { return E('label', { 'style': 'display:block' }, [ E('input', { 'type': 'checkbox', 'value': eid }), ' ' + g.envs[eid].name + ' — ' + c.bindingTitle(g.envs[eid].config, d.cards) ]); });
			var keep = E('select', { 'class': 'cbi-input-select' }, envs.filter(function(e) { return g.envs[e].config; }).map(function(e) { return E('option', { 'value': g.envs[e].config }, c.bindingTitle(g.envs[e].config, d.cards)); }).concat([ E('option', { 'value': '' }, 'без конфига') ]));
			ui.showModal('Объединить среды — шаг 2 из 3', [ E('p', 'Какие среды объединить:'), E('div', checks), E('p', 'Какой конфиг остаётся (остальные уйдут в архив):'), keep,
				E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						var eids = checks.map(function(l) { return l.firstChild; }).filter(function(i) { return i.checked; }).map(function(i) { return i.value; });
						if (!confirm('Шаг 3: объединить ' + eids.length + ' сред(ы)?')) return;
						c.op('merge_envs', { gid: gid, eids: eids, config: keep.value || null }, d.contour.rev).then(function(r) { ui.hideModal(); if (r) self.reload(); });
					} }, 'Объединить') ]) ]);
		};
		var stepSplit = function() {
			var src = E('select', { 'class': 'cbi-input-select' }, envs.map(function(e) { return E('option', { 'value': e }, g.envs[e].name); }));
			var box = E('div');
			var fill = function() {
				box.innerHTML = '';
				(g.envs[src.value].routers || []).forEach(function(rid) {
					var r = d.routers.filter(function(x) { return x.rid == rid; })[0];
					box.appendChild(E('label', { 'style': 'display:block' }, [ E('input', { 'type': 'checkbox', 'value': rid }), ' ' + (r ? r.name : rid) ]));
				});
			};
			src.addEventListener('change', fill); fill();
			var cfg = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, 'назначить позже') ].concat(arch.map(function(a) {
				return E('option', { 'value': a.config }, 'из архива: ' + c.bindingTitle(a.config, d.cards) + ' (' + c.fmtDate(a.at) + ')');
			})));
			ui.showModal('Разделить среду — шаг 2 из 3', [ E('p', 'Из какой среды:'), src, E('p', 'Какие роутеры перенести в новую среду:'), box,
				E('p', 'Конфиг новой среды' + (arch.length ? ' (можно восстановить из архива):' : ':')), cfg,
				E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						var rids = Array.prototype.slice.call(box.querySelectorAll('input')).filter(function(i) { return i.checked; }).map(function(i) { return i.value; });
						if (!confirm('Шаг 3: перенести ' + rids.length + ' роутер(ов) в новую среду?')) return;
						c.op('split_env', { gid: gid, eid: src.value, rids: rids, config: cfg.value || null }, d.contour.rev).then(function(r) { ui.hideModal(); if (r) self.reload(); });
					} }, 'Разделить') ]) ]);
		};
		ui.showModal('Сменить схему — шаг 1 из 3', [
			E('p', 'Сейчас: ' + (envs.length > 1 ? 'сложная схема, сред: ' + envs.length : 'групповая схема, одна среда') + '.'),
			E('p', 'Убранные привязки уходят в архив; при обратном разделении их можно восстановить.'),
			E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
				envs.length > 1 ? E('button', { 'class': 'btn cbi-button-action', 'click': stepMerge }, 'Объединить среды') : '', ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': stepSplit }, 'Разделить среду') ]) ]);
	},

	render: function(d) {
		if (d.error) return E('div', { 'class': 'alert-message warning' }, d.error);
		var self = this, out = [ E('h2', 'Группы и среды'), E('p', { 'class': 'cbi-value-description' }, 'Контур «' + d.contour.name + '», ревизия ' + d.contour.rev) ];
		Object.keys(d.contour.groups || {}).forEach(function(gid) {
			var g = d.contour.groups[gid];
			var empty = !Object.keys(g.envs).some(function(e) { return (g.envs[e].routers || []).length; });
			out.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', 'Группа «' + g.name + '»'),
				c.table([ 'Среда', 'Конфиг', 'Роутеров', 'Статус', '' ], self.envRows(d, gid, g.envs)),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { c.op('create_env', { gid: gid }, d.contour.rev).then(function(r) { if (r) self.reload(); }); } }, 'Создать среду'), ' ',
					E('button', { 'class': 'btn', 'click': function() { self.rename('rename_group', { gid: gid }, g.name, d.contour.rev); } }, 'Переименовать группу'), ' ',
					E('button', { 'class': 'btn', 'click': function() { self.scheme(d, gid); } }, 'Сменить схему'), ' ',
					empty ? E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
						if (confirm('Удалить пустую группу «' + g.name + '»?')) c.op('delete_group', { gid: gid }, d.contour.rev).then(function(r) { if (r) self.reload(); });
					} }, 'Удалить группу') : ''
				])
			]));
		});
		if (Object.keys(d.contour.standalone || {}).length)
			out.push(E('div', { 'class': 'cbi-section' }, [ E('h3', 'Одиночные роутеры'), c.table([ 'Среда', 'Конфиг', 'Роутеров', 'Статус', '' ], self.envRows(d, null, d.contour.standalone)) ]));
		if ((d.archive || []).length)
			out.push(E('div', { 'class': 'cbi-section' }, [ E('h3', 'Архив привязок'), c.table([ 'Когда', 'Группа', 'Конфиг' ], d.archive.map(function(a) {
				return [ c.fmtTime(a.at), a.group ? (d.contour.groups[a.group] || {}).name || a.group : 'одиночный', c.bindingTitle(a.config, d.cards) ];
			})) ]));
		out.push(E('div', { 'class': 'right' }, E('button', { 'class': 'btn cbi-button-add', 'click': function() {
			c.op('create_group', {}, d.contour.rev).then(function(r) { if (r) self.reload(); });
		} }, 'Создать группу')));
		return E('div', { 'class': 'cbi-map' }, out);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
