// Runs the login helpers written by sbproxy-dashboard-select against a fake page.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const [singboxPath, yacdPath] = process.argv.slice(2);
const singbox = fs.readFileSync(singboxPath, 'utf8');
const yacd = fs.readFileSync(yacdPath, 'utf8');
const prefix = 'sing-box-dashboard.';

function page(href, stored = {}) {
	const url = new URL(href);
	const items = new Map(Object.entries(stored));
	const location = { origin: url.origin, pathname: url.pathname, search: url.search, hash: url.hash };
	const replaced = [];
	const attributes = {};
	const window = {
		location,
		localStorage: {
			getItem: key => items.has(key) ? items.get(key) : null,
			setItem: (key, value) => items.set(key, String(value)),
			removeItem: key => items.delete(key)
		}
	};
	const context = {
		window,
		localStorage: window.localStorage,
		history: { state: null, replaceState: (state, title, next) => replaced.push(next) },
		document: { getElementById: id => id === 'app' ? { setAttribute: (key, value) => attributes[key] = value } : null }
	};
	return {
		run: source => vm.runInNewContext(source, context),
		servers: () => JSON.parse(items.get(prefix + 'servers') ?? 'null'),
		items, replaced, attributes
	};
}

// No login fragment: nothing changes.
let p = page('http://192.168.9.1:31187/dashboard/#/connections');
p.run(singbox);
assert.equal(p.items.size, 0);
assert.deepEqual(p.replaced, []);

// First visit: add this router, select it and drop the secret from the address bar.
p = page('http://192.168.9.1:31187/dashboard/?x=1#sbproxy-secret=a%26b%3Dc');
p.run(singbox);
assert.deepEqual(p.replaced, ['/dashboard/?x=1']);
let state = p.servers();
assert.equal(state.servers.length, 1);
assert.deepEqual({ ...state.servers[0], id: '' }, { id: '', name: '', url: '192.168.9.1:31187', secret: 'a&b=c' });
assert.match(state.activeId, /^sbproxy-router-/);
assert.equal(state.activeId, state.servers[0].id);

// A saved entry for this router is updated in place; other servers stay.
p = page('http://192.168.9.1:31187/dashboard/#sbproxy-secret=new', {
	[prefix + 'servers']: JSON.stringify({
		servers: [
			{ id: 'other', name: 'Other', url: '10.0.0.2:9090', secret: 'x' },
			{ id: 'mine', name: 'Router', url: 'http://192.168.9.1:31187/', secret: 'old' }
		],
		activeId: 'other'
	})
});
p.run(singbox);
state = p.servers();
assert.equal(state.activeId, 'mine');
assert.deepEqual(state.servers, [
	{ id: 'other', name: 'Other', url: '10.0.0.2:9090', secret: 'x' },
	{ id: 'mine', name: 'Router', url: 'http://192.168.9.1:31187/', secret: 'new' }
]);

// The old single-server record is migrated instead of lost.
p = page('https://router.example.ts.net:31187/dashboard/#sbproxy-secret=s', {
	[prefix + 'server']: JSON.stringify({ url: 'http://10.0.0.3:9090', secret: 'legacy' })
});
p.run(singbox);
state = p.servers();
assert.equal(p.items.has(prefix + 'server'), false);
assert.deepEqual(state.servers.map(server => [server.url, server.secret]), [
	['10.0.0.3:9090', 'legacy'],
	['https://router.example.ts.net:31187', 's']
]);
assert.equal(state.activeId, state.servers[1].id);

// Broken saved data must not stop the dashboard from loading.
p = page('http://192.168.9.1:31187/dashboard/#sbproxy-secret=s', { [prefix + 'servers']: '{' });
p.run(singbox);
assert.equal(p.items.get(prefix + 'servers'), '{');

// Yacd edits a copy of its base URL for query login; it must be this origin.
p = page('http://192.168.9.1:31187/ui/?hostname=192.168.9.1&port=31187&secret=s');
p.run(yacd);
assert.deepEqual(p.attributes, { 'data-base-url': 'http://192.168.9.1:31187' });

console.log('dashboard login helpers passed');
