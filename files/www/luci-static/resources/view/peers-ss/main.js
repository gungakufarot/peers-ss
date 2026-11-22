'use strict';
'require view';
'require poll';
'require view.peers-ss.__V__.common as c';
'require view.peers-ss.__V__.overview as overview';
'require view.peers-ss.__V__.network as network';
'require view.peers-ss.__V__.tools as tools';

// One LuCI page with client-side tabs (like podkop): switching tabs never reloads the page.
var TABS = [ [ 'overview', 'Обзор', overview ], [ 'routers', 'Роутеры', network ], [ 'tools', 'Токен и диагностика', tools ] ];

return view.extend({
	load: function() { c.css(); return c.api.ui(); },

	render: function(u) {
		var self = this, E = c.E;
		self.u = u;
		var body = E('div');
		var menu = E('ul', { 'class': 'cbi-tabmenu' });
		var cur = null;

		var show = function(id, keepScroll) {
			var t = TABS.filter(function(x) { return x[0] == id; })[0] || TABS[0];
			cur = t;
			Array.prototype.forEach.call(menu.children, function(li) { li.className = li.getAttribute('data-tab') == t[0] ? 'cbi-tab' : 'cbi-tab-disabled'; });
			body.innerHTML = '';
			body.appendChild(t[2].render(self.u));
			if (location.hash != '#' + t[0]) history.replaceState(null, '', '#' + t[0]);
			if (!keepScroll) window.scrollTo(0, 0);
		};

		TABS.forEach(function(t) {
			menu.appendChild(E('li', { 'class': 'cbi-tab-disabled', 'data-tab': t[0] },
				E('a', { 'href': '#' + t[0], 'click': function(ev) { ev.preventDefault(); show(t[0]); } }, t[1])));
		});

		// full data reload without leaving the page (after edits, token changes, jobs)
		c.app = { reload: function() { return c.api.ui().then(function(n) { self.u = n; show(cur[0], true); }); } };

		poll.add(function() {
			return c.api.ui().then(function(n) { self.u = n; if (cur && cur[2].refresh) cur[2].refresh(n); });
		}, 20);

		show((location.hash || '').replace('#', '') || 'overview');
		return E('div', { 'class': 'cbi-map' }, [ E('h2', { 'name': 'content' }, 'Peers-SS'), menu, body ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
