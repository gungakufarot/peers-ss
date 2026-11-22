'use strict';
'require baseclass';
'require ui';
'require view.peers-ss.__V__.common as c';

var E = c.E;

function envOf(ct, rid) {
	var res = null;
	Object.keys(ct.groups || {}).forEach(function(g) {
		Object.keys(ct.groups[g].envs || {}).forEach(function(e) { if ((ct.groups[g].envs[e].routers || []).indexOf(rid) >= 0) res = { g: g, e: e }; });
	});
	Object.keys(ct.standalone || {}).forEach(function(e) { if ((ct.standalone[e].routers || []).indexOf(rid) >= 0) res = { g: null, e: e }; });
	return res;
}

return baseclass.extend({

	// ---------- helpers ----------
	rec: function(rid) { return (this.u.routers || []).filter(function(r) { return r.rid == rid; })[0] || { rid: rid }; },
	name: function(rid) { return ((this.u.contour.routers || {})[rid] || {}).name || rid; },
	targets: function(withNew) {
		var ct = this.u.contour, out = [];
		Object.keys(ct.groups || {}).forEach(function(g) {
			Object.keys(ct.groups[g].envs).forEach(function(e) { out.push([ g + '/' + e, ct.groups[g].name + ' / ' + ct.groups[g].envs[e].name ]); });
			if (withNew) out.push([ g + '/', ct.groups[g].name + ' / + новая среда' ]);
		});
		return out;
	},
	apply: function(op, args) {
		var self = this;
		var badge = E('div', { 'class': 'saving' }, 'Сохраняю…');
		self.root.classList.add('busy'); document.body.appendChild(badge);
		return c.op(op, args, self.u.contour.rev).then(function(r) {
			self.root.classList.remove('busy'); badge.remove();
			if (!r) { c.api.ui().then(function(n) { if (n.configured) { self.u = n; self.draw(); } }); return null; }   // conflict/error: show the current state
			self.u.contour = r.contour;
			(self.u.routers || []).forEach(function(x) { var eo = envOf(r.contour, x.rid); x.group = eo ? eo.g : null; x.env = eo ? eo.e : null; });
			self.draw();
			return r;
		});
	},
	move: function(rid, g, e) {
		var ct = this.u.contour;
		if (!(ct.routers || {})[rid]) return;   // dropped something that is not a router of this contour
		var cur = envOf(ct, rid);
		if (cur && cur.g == g && cur.e == e) return;
		var curCfg = cur ? (cur.g ? ct.groups[cur.g].envs[cur.e].config : (ct.standalone[cur.e] || {}).config) : null;
		if (g === null) return this.apply('make_standalone', { rid: rid });
		if (!e) return this.apply('move_router', { rid: rid, gid: g, eid: null, config: curCfg });   // new env keeps the router's config
		var dst = ct.groups[g].envs[e].config;
		if (dst != curCfg && !confirm('«' + this.name(rid) + '» перейдёт ' + (dst ? 'на конфиг «' + c.cfgTitle(this.u, dst) + '»' : 'в среду без конфига (связь останется на текущей ссылке до назначения)') + '. Продолжить?')) return;
		return this.apply('move_router', { rid: rid, gid: g, eid: e });
	},
	dropTarget: function(node, fn) {
		node.addEventListener('dragover', function(ev) { ev.preventDefault(); node.classList.add('over'); });
		node.addEventListener('dragleave', function() { node.classList.remove('over'); });
		node.addEventListener('drop', function(ev) { ev.preventDefault(); node.classList.remove('over'); var rid = ev.dataTransfer.getData('text/plain'); if (rid) fn(rid); });
		return node;
	},
	rename: function(op, args, cur) {
		var n = prompt('Новое имя (1–32 символа):', cur);
		if (n && n != cur) { args.name = n.trim(); this.apply(op, args); }
	},

	// ---------- router chip + menu ----------
	chip: function(rid) {
		var self = this, r = self.rec(rid);
		var ch = E('div', { 'class': 'chip' + (r.me ? ' me' : ''), 'draggable': 'true', 'title': 'Перетащите в другую среду или нажмите' },
			[ c.dot(r.status), self.name(rid) + (r.me ? ' (этот)' : ''), r.has_token ? E('span', { 'title': 'есть токен StealthSurf' }, '🔑') : '' ]);
		ch.addEventListener('dragstart', function(ev) { self.dragging = true; ev.dataTransfer.setData('text/plain', rid); });
		ch.addEventListener('dragend', function() { self.dragging = false; });
		ch.addEventListener('click', function() { self.routerMenu(rid); });
		return ch;
	},
	routerMenu: function(rid) {
		var self = this, r = self.rec(rid), cur = envOf(self.u.contour, rid);
		var sel = E('select', { 'class': 'cbi-input-select' }, self.targets(true).map(function(t) {
			return E('option', { 'value': t[0], 'selected': cur && (cur.g + '/' + cur.e) == t[0] ? '' : null }, t[1]);
		}));
		c.modal(self.name(rid), [
			c.kv([ [ 'Статус', c.pill(r.status) ], [ 'Последний контакт', c.ago(r.last_contact) ], [ 'Пинг через vless', r.ping_ms ? r.ping_ms + ' мс' : '—' ],
				[ 'Токен StealthSurf', r.has_token ? 'есть' + (r.token_label ? ' — ' + r.token_label : '') : 'нет — ведомый' ], [ 'Версия', r.version || '—' ], [ 'ID', rid ] ]),
			E('hr'), E('div', { 'class': 'row' }, [ 'Перенести в', sel, c.btn('Перенести', function() { var p = sel.value.split('/'); ui.hideModal(); self.move(rid, p[0], p[1] || null); }, 'cbi-button-action') ])
		], [
			c.btn('Переименовать', function() { ui.hideModal(); self.rename('rename_router', { rid: rid }, self.name(rid)); }),
			cur && cur.g ? c.btn('Сделать одиночным', function() { ui.hideModal(); self.move(rid, null, null); }) : '',
			r.me ? '' : c.btn('Убрать из контура', function() {
				if (confirm('Убрать «' + self.name(rid) + '» из контура? На самом роутере затем выполните peers-ss uninstall.')) { ui.hideModal(); self.apply('remove_router', { rid: rid }); }
			}, 'cbi-button-negative')
		]);
	},

	// ---------- environment tile ----------
	envTile: function(g, e, env) {
		var self = this, u = self.u, rot = (u.rotations || {})[env.config] || {};
		var empty = !(env.routers || []).length;
		var cfgLine = env.config
			? E('div', { 'class': 'cfg' }, [ '📄 ' + c.cfgTitle(u, env.config), rot.server_id ? E('span', { 'class': 'muted' }, ' · ' + (rot.location || 'лок. ' + rot.location_id) + ', сервер ' + rot.server_id) : '',
				rot.expires_at ? E('span', { 'class': 'muted' }, ' · до ' + c.fmtDate(rot.expires_at)) : '' ])
			: E('div', { 'class': 'cfg', 'style': 'color:var(--pss-warn)' }, '⚠ конфиг не назначен');
		var tile = E('div', { 'class': 'env' }, [
			E('div', { 'class': 'head' }, [ g ? env.name : 'одиночный', E('span', { 'class': 'sp' }),
				g ? E('button', { 'class': 'ib', 'title': 'Переименовать', 'click': function() { self.rename('rename_env', { gid: g, eid: e }, env.name); } }, '✎') : '',
				E('button', { 'class': 'ib', 'title': 'Состав', 'click': function() { self.members(g, e, env); } }, 'ⓘ'),
				E('button', { 'class': 'ib', 'title': 'Назначить конфиг', 'click': function() { self.assign(g, e); } }, '📄'),
				g && (env.routers || []).length > 1 ? E('button', { 'class': 'ib', 'title': 'Разделить среду', 'click': function() { self.split(g, e, env); } }, '✂') : '',
				g ? E('button', { 'class': 'ib', 'title': 'Пригласить роутер в эту среду', 'click': function() { self.invite(g + '/' + e); } }, '＋') : '',
				empty ? E('button', { 'class': 'ib', 'title': 'Удалить пустую среду', 'click': function() { if (confirm('Удалить пустую среду «' + env.name + '»?')) self.apply('delete_env', { gid: g, eid: e }); } }, '🗑') : '' ]),
			cfgLine,
			E('div', (env.routers || []).map(function(rid) { return self.chip(rid); }).concat(empty ? [ E('div', { 'class': 'muted' }, 'перетащите сюда роутер') ] : []))
		]);
		return g ? self.dropTarget(tile, function(rid) { self.move(rid, g, e); }) : tile;
	},

	groupCard: function(g) {
		var self = this, grp = self.u.contour.groups[g];
		var envs = Object.keys(grp.envs || {});
		var count = envs.reduce(function(n, e) { return n + (grp.envs[e].routers || []).length; }, 0);
		var newZone = self.dropTarget(E('div', { 'class': 'zone' }, [ E('div', '＋ новая среда'), E('div', { 'class': 'muted' }, 'перетащите сюда роутер или нажмите') ]),
			function(rid) { self.move(rid, g, null); });
		newZone.style.cursor = 'pointer';
		newZone.addEventListener('click', function() { self.apply('create_env', { gid: g }); });
		return E('div', { 'class': 'card' }, [
			E('h3', [ '📁 ' + grp.name, E('span', { 'class': 'muted' }, envs.length + ' сред · ' + count + ' роутеров'), E('span', { 'class': 'sp' }),
				E('button', { 'class': 'ib', 'title': 'Переименовать группу', 'click': function() { self.rename('rename_group', { gid: g }, grp.name); } }, '✎'),
				envs.length > 1 ? E('button', { 'class': 'ib', 'title': 'Объединить среды', 'click': function() { self.merge(g); } }, '⇄ объединить') : '',
				count ? '' : E('button', { 'class': 'ib', 'title': 'Удалить пустую группу', 'click': function() { if (confirm('Удалить группу «' + grp.name + '»?')) self.apply('delete_group', { gid: g }); } }, '🗑') ]),
			E('div', { 'class': 'grid' }, envs.map(function(e) { return self.envTile(g, e, grp.envs[e]); }).concat([ newZone ]))
		]);
	},

	standaloneCard: function() {
		var self = this, sa = self.u.contour.standalone || {};
		var zone = self.dropTarget(E('div', { 'class': 'zone' }, [ E('div', '＋ сделать одиночным'), E('div', { 'class': 'muted' }, 'свой конфиг сохраняется') ]),
			function(rid) { self.move(rid, null, null); });
		return E('div', { 'class': 'card' }, [ E('h3', [ '◻ Одиночные роутеры', E('span', { 'class': 'muted' }, 'вне групп, свой конфиг') ]),
			E('div', { 'class': 'grid' }, Object.keys(sa).map(function(e) { return self.envTile(null, e, sa[e]); }).concat([ zone ])) ]);
	},

	// ---------- config assignment (full list only here, spec §8) ----------
	assign: function(g, e) {
		var self = this, u = self.u;
		var arch = (u.contour.archive || []).filter(function(a) { return a.group == g; });
		var src = (u.routers || []).filter(function(r) { return r.has_token; });
		var list = E('div');
		var pick = function(binding) { ui.hideModal(); self.apply('assign_config', { gid: g, eid: e, binding: binding }); };
		var row = function(title, sub, binding) {
			return E('div', { 'class': 'row', 'style': 'justify-content:space-between;border-bottom:1px solid var(--pss-line);padding:6px 0' },
				[ E('div', [ E('b', title), E('div', { 'class': 'muted' }, sub) ]), c.btn('Назначить', function() { pick(binding); }, 'cbi-button-action') ]);
		};
		var sel = E('select', { 'class': 'cbi-input-select' }, src.map(function(r) { return E('option', { 'value': r.rid, 'selected': r.me ? '' : null }, r.name + (r.me ? ' (этот)' : '') + ' — аккаунт ' + r.account); }));
		var fetch = function(tries) {
			list.innerHTML = '';
			list.appendChild(E('p', { 'class': 'spinning' }, sel.value == u.rid ? 'Запрос к StealthSurf…' : 'Запрос через выбранный роутер (до минуты)…'));
			c.api.configs(sel.value == u.rid ? '' : sel.value).then(function(res) {
				res = res || { error: 'нет ответа' };
				if (res.pending && tries < 40) return window.setTimeout(function() { fetch(tries + 1); }, 3000);
				list.innerHTML = '';
				if (!res.ok) return list.appendChild(E('p', { 'style': 'color:var(--pss-bad)' }, res.error || 'роутер не ответил'));
				if (!res.configs.length) return list.appendChild(E('p', 'Аккаунт пуст: нет vless-конфигов'));
				res.configs.forEach(function(q) { list.appendChild(row(q.title || ('#' + q.id), 'до ' + c.fmtDate(q.expires_at) + ' · ' + q.binding, q.binding)); });
			});
		};
		c.modal('Назначить конфиг', [
			arch.length ? E('div', [ E('h4', 'Из архива этой группы'), E('div', arch.map(function(a) { return row(c.cfgTitle(u, a.config), 'убран ' + c.fmtTime(a.at) + ' · ' + a.config, a.config); })), E('hr') ]) : '',
			src.length ? E('div', { 'class': 'row' }, [ 'Список конфигов через токен роутера', sel, c.btn('Показать', function() { fetch(0); }) ])
				: E('p', { 'class': 'muted' }, 'В контуре нет роутеров с токеном StealthSurf — добавьте токен во вкладке «Токен и диагностика».'),
			list
		], e && (self.envBinding(g, e)) ? [ c.btn('Снять конфиг', function() { pick(null); }, 'cbi-button-negative') ] : []);
		if (src.length) fetch(0);
	},
	envBinding: function(g, e) { var ct = this.u.contour; return g ? ct.groups[g].envs[e].config : (ct.standalone[e] || {}).config; },

	// «Состав» (spec §8): routers with status and last contact, config with location/server/expiry
	members: function(g, e, env) {
		var self = this, u = self.u, rot = (u.rotations || {})[env.config] || {}, card = (u.cards || {})[env.config] || {};
		c.modal('Состав: ' + (g ? env.name : 'одиночный'), [
			c.kv([ [ 'Конфиг', env.config ? c.cfgTitle(u, env.config) + ' (' + env.config + ')' : 'не назначен' ],
				[ 'Локация / сервер', rot.server_id ? (rot.location || rot.location_id) + ' / ' + rot.server_id : '—' ],
				[ 'Действует до', c.fmtDate(rot.expires_at || card.expires_at) ], [ 'Роутеров', String((env.routers || []).length) ] ]),
			E('hr'),
			E('ul', { 'class': 'feed' }, (env.routers || []).map(function(rid) {
				var r = self.rec(rid);
				return E('li', { 'class': 'row' }, [ c.dot(r.status), E('b', self.name(rid)), c.pill(r.status), E('span', { 'class': 'muted' }, 'контакт ' + c.ago(r.last_contact) + (r.ping_ms ? ' · ' + r.ping_ms + ' мс' : '') + (r.has_token ? ' · 🔑' : '')) ]);
			}))
		]);
	},

	// split part of an environment into a new one with its own config (archive / known config / later)
	split: function(g, e, env) {
		var self = this, u = self.u;
		var checks = (env.routers || []).map(function(rid) { return E('label', { 'style': 'display:block;margin:4px 0' }, [ E('input', { 'type': 'checkbox', 'value': rid }), ' ' + self.name(rid) ]); });
		var arch = (u.contour.archive || []).filter(function(a) { return a.group == g; });
		var known = Object.keys(u.rotations || {}).filter(function(b) { return b != env.config && !arch.some(function(a) { return a.config == b; }); });
		var cfg = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, 'назначить позже') ]
			.concat(arch.map(function(a) { return E('option', { 'value': a.config }, 'из архива: ' + c.cfgTitle(u, a.config)); }))
			.concat(known.map(function(b) { return E('option', { 'value': b }, c.cfgTitle(u, b)); })));
		c.modal('Разделить среду «' + env.name + '»', [ E('p', 'Какие роутеры перенести в новую среду:'), E('div', checks), E('p', 'Конфиг новой среды:'), cfg ], [
			c.btn('Разделить', function() {
				var rids = checks.map(function(l) { return l.firstChild; }).filter(function(i) { return i.checked; }).map(function(i) { return i.value; });
				if (!rids.length || rids.length >= (env.routers || []).length) return alert('Выберите часть роутеров (не всех)');
				ui.hideModal(); self.apply('split_env', { gid: g, eid: e, rids: rids, config: cfg.value || null });
			}, 'cbi-button-action') ]);
	},

	merge: function(g) {
		var self = this, grp = self.u.contour.groups[g];
		var envs = Object.keys(grp.envs);
		var checks = envs.map(function(e) { return E('label', { 'style': 'display:block;margin:4px 0' }, [ E('input', { 'type': 'checkbox', 'value': e, 'checked': '' }), ' ' + grp.envs[e].name + ' — ' + c.cfgTitle(self.u, grp.envs[e].config) ]); });
		var cfgs = envs.map(function(e) { return grp.envs[e].config; }).filter(function(b, i, a) { return b && a.indexOf(b) == i; });
		var keep = E('select', { 'class': 'cbi-input-select' }, cfgs.map(function(b) { return E('option', { 'value': b }, c.cfgTitle(self.u, b)); }).concat([ E('option', { 'value': '' }, 'без конфига') ]));
		c.modal('Объединить среды группы «' + grp.name + '»', [ E('p', 'Какие среды объединить:'), E('div', checks), E('p', 'Какой конфиг останется (остальные уйдут в архив и их можно будет вернуть):'), keep ], [
			c.btn('Объединить', function() {
				var eids = checks.map(function(l) { return l.firstChild; }).filter(function(i) { return i.checked; }).map(function(i) { return i.value; });
				if (eids.length < 2) return alert('Выберите хотя бы две среды');
				ui.hideModal(); self.apply('merge_envs', { gid: g, eids: eids, config: keep.value || null });
			}, 'cbi-button-action') ]);
	},

	// ---------- invites ----------
	invite: function(preset) {
		var self = this;
		var opts = self.targets(true).concat([ [ '/', 'одиночный роутер' ] ]);
		var target = E('select', { 'class': 'cbi-input-select' }, opts.map(function(t) { return E('option', { 'value': t[0], 'selected': t[0] == preset ? '' : null }, t[1]); }));
		var hours = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': '24', 'min': 1, 'max': 720, 'style': 'width:6em' });
		var out = E('div');
		c.modal('Добавить роутер', [ c.kv([ [ 'Куда', target ], [ 'Ссылка действует, ч', hours ] ]), out ], [
			c.btn('Создать ссылку', function() {
				var p = target.value.split('/');
				c.api.inviteCreate(p[0], p[1], +hours.value).then(function(r) {
					if (c.err(r)) return;
					var ta = E('textarea', { 'readonly': '', 'rows': 4, 'class': 'w', 'style': 'font-family:monospace;margin-top:10px' }, r.command);
					out.innerHTML = '';
					out.appendChild(E('div', [ E('p', 'Выполните на новом роутере (SSH). Ссылка одноразовая, до ' + c.fmtTime(r.expires_at) + '. В ней токен GitHub — передавайте как пароль.'), ta,
						c.btn('Копировать', function() { ta.select(); (navigator.clipboard ? navigator.clipboard.writeText(r.command) : Promise.reject()).catch(function() { document.execCommand('copy'); }); c.notify('Команда скопирована'); }, 'cbi-button-action') ]));
					self.reloadSoon();
				});
			}, 'cbi-button-add') ]);
	},
	invitesCard: function() {
		var self = this, inv = self.u.invites || [], ct = self.u.contour;
		var where = function(i) { return i.group ? ((ct.groups[i.group] || {}).name || i.group) + ' / ' + (i.env ? ((ct.groups[i.group] || { envs: {} }).envs[i.env] || {}).name || i.env : 'новая среда') : 'одиночный'; };
		var active = inv.filter(function(i) { return i.active; }), old = inv.filter(function(i) { return !i.active; }).slice(0, 10);
		return E('div', { 'class': 'card' }, [ E('h3', [ '✉ Приглашения', E('span', { 'class': 'sp' }), c.btn('＋ Добавить роутер', function() { self.invite(); }, 'cbi-button-add') ]),
			active.length ? E('ul', { 'class': 'feed' }, active.map(function(i) {
				return E('li', { 'class': 'row', 'style': 'justify-content:space-between' }, [ E('span', [ E('b', where(i)), E('span', { 'class': 'muted' }, ' · до ' + c.fmtTime(i.expires_at)) ]),
					c.btn('Отозвать', function() { c.api.inviteRevoke(i.id).then(function(r) { if (!c.err(r)) { i.active = false; i.revoked = true; self.draw(); } }); }, 'cbi-button-negative') ]);
			})) : E('p', { 'class': 'muted' }, 'Активных ссылок нет.'),
			old.length ? E('details', [ E('summary', { 'class': 'muted' }, 'Использованные и истёкшие'), E('ul', { 'class': 'feed' }, old.map(function(i) {
				return E('li', { 'class': 'muted' }, where(i) + ' — ' + (i.revoked ? 'отозвана' : i.used_by ? 'использована: ' + (i.used_name || i.used_by) + ' ' + c.fmtTime(i.used_at) : 'истекла ' + c.fmtTime(i.expires_at)));
			})) ]) : '' ]);
	},
	reloadSoon: function() { var self = this; window.setTimeout(function() { c.api.ui().then(function(n) { if (n.configured) { self.u = n; self.draw(); } }); }, 1500); },

	archiveCard: function() {
		var self = this, ar = self.u.contour.archive || [];
		if (!ar.length) return '';
		return E('details', { 'class': 'card' }, [ E('summary', 'Архив привязок (' + ar.length + ')'),
			E('p', { 'class': 'muted' }, 'Конфиги, убранные при смене схемы. Вернуть — кнопкой 📄 «Назначить конфиг» у нужной среды.'),
			E('ul', { 'class': 'feed' }, ar.slice().reverse().map(function(a) {
				return E('li', [ E('b', c.cfgTitle(self.u, a.config)), E('span', { 'class': 'muted' }, ' · ' + (a.group ? (self.u.contour.groups[a.group] || {}).name || a.group : 'одиночный') + ' · ' + c.fmtTime(a.at)) ]);
			})) ]);
	},

	draw: function() {
		var self = this, root = self.root, u = self.u;
		root.innerHTML = '';
		if (!u.configured) { root.appendChild(E('div', { 'class': 'banner warn' }, 'Роутер не зарегистрирован в контуре.')); return; }
		var ct = u.contour;
		root.appendChild(E('div', { 'class': 'row', 'style': 'justify-content:space-between;margin-bottom:8px' }, [
			E('h2', 'Роутеры — «' + (ct.name || u.cid) + '»'),
			E('div', { 'class': 'row' }, [ c.btn('＋ Группа', function() { self.apply('create_group', {}); }), c.btn('＋ Добавить роутер', function() { self.invite(); }, 'cbi-button-add') ])
		]));
		var sb = c.staleBanner(u); if (sb) root.appendChild(sb);
		root.appendChild(E('p', { 'class': 'muted' }, '🖱 Перетащите роутер в другую среду, на «＋ новая среда» или в «Одиночные». На телефоне — нажмите на роутер. 🔑 — есть токен StealthSurf.'));
		Object.keys(ct.groups || {}).forEach(function(g) { root.appendChild(self.groupCard(g)); });
		root.appendChild(self.standaloneCard());
		root.appendChild(self.invitesCard());
		var a = self.archiveCard(); if (a) root.appendChild(a);
		root.appendChild(c.footer(u, function() { c.refresh(function() { c.api.ui().then(function(n) { self.u = n; self.draw(); }); }); }));
	},

	render: function(u) {
		var self = this;
		self.u = u; self.root = E('div', { 'class': 'pss' });
		self.draw();
		return self.root;
	},
	// statuses refresh; the layout follows only newer contour revisions; nothing while dragging or in a dialog
	refresh: function(n) {
		var self = this;
		if (!n.configured || self.dragging || c.modalOpen()) return;
		var changed = n.contour.rev > self.u.contour.rev;
		self.u.routers = n.routers; self.u.rotations = n.rotations; self.u.invites = n.invites; self.u.age = n.age;
		if (changed) self.u.contour = n.contour;
		self.draw();
	},
});
