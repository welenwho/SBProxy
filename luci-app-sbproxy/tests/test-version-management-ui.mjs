import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../htdocs/luci-static/resources/view/sbproxy/core.js', import.meta.url), 'utf8');
String.prototype.format = function(...args) { let i = 0; return this.replace(/%s/g, () => args[i++]); };
const nodes = [], calls = [];
const E = (tag, attrs = {}, children = []) => {
  const node = { tag, attrs, children, value: attrs.value || '', disabled: !!attrs.disabled, style: {} };
  nodes.push(node); return node;
};
let failCheck = false;
const rpc = { declare: ({ method }) => async (...args) => {
  calls.push([method, ...args]);
  if (failCheck) throw Error('network');
  if (method === 'plugin_check_update') return { code: 0, latest_package_version: '1.0.1-r39', assets: [
    { filename: 'luci-app-sbproxy-1.0.1-r38.apk', package_version: '1.0.1-r38', relation: 'older' },
    { filename: 'luci-app-sbproxy-1.0.1-r39.apk', package_version: '1.0.1-r39', relation: 'current' }
  ] };
  if (method === 'core_check_update') return { code: 0, latest_package_version: '1.14.4', latest_alpha_package_version: '1.15.0-alpha.13', assets: [
    { filename: 'sing-box-1.14.4.apk', package_version: '1.14.4', relation: 'older' },
    { filename: 'sing-box-1.15.0-alpha.13.apk', package_version: '1.15.0-alpha.13', relation: 'newer' }
  ] };
  if (method === 'resources_get') return resourceState;
  if (method === 'resources_update') {
    resourceState = { ...resourceState, operation: { target: args[0], running: true } };
    return { accepted: true, operation: resourceState.operation };
  }
  return { code: 0 };
} };
let resourceState = { resources: [
  { type: 'geoip_cn', version: '20261112', source: 'https://example.invalid/geoip' },
  { type: 'geosite_cn', version: '', source: 'https://example.invalid/geosite' }
], operation: null };
const polls = [];
const view = Function('rpc', 'view', 'ui', 'dom', 'E', '_', 'poll', 'L', 'cbi_update_table', source)(rpc,
  { extend: value => value }, { createHandlerFn: (owner, fn) => fn.bind(owner) },
  { content: (node, children) => { node.children = children; } }, E, s => s,
  { add: fn => polls.push(fn) }, { resolveDefault: (promise, fallback) => promise.catch(() => fallback) },
  (table, rows) => { table.rows = rows; });
const submissions = [];
view.confirmOperation = (_title, _message, operation) => operation();
view.runOperation = async (_title, operation, target) => { submissions.push(target); await operation(target, 'a'.repeat(32)); };
view.render([{ plugin_version: '1.0.1-r39', version: '1.15.0-alpha.12', manager_supported: true }, {}, resourceState]);
const checks = nodes.filter(n => n.tag === 'button' && n.children[0] === 'Check for updates');
const selectors = nodes.filter(n => n.tag === 'select');
const installers = nodes.filter(n => n.tag === 'button' && n.attrs.class.includes('cbi-button-action') && n.attrs.type !== 'button');
const resourceButtons = nodes.filter(n => n.tag === 'button' && n.attrs.type === 'button');
assert.equal(checks.length, 2);
assert.equal(installers.length, 2);
assert.equal(nodes.filter(n => n.tag === 'table').length, 1, 'Only the resource table; no feature/architecture/storage tables');
await checks[0].attrs.click();
assert.deepEqual(selectors[0].children.map(option => option.attrs.value),
  ['luci-app-sbproxy-1.0.1-r39.apk', 'luci-app-sbproxy-1.0.1-r38.apk'], 'Plugin downgrade is offered, newest first');
assert.equal(installers[0].children, 'Reinstall');
await installers[0].attrs.click();
assert.equal(calls.at(-1)[0], 'plugin_upgrade');
selectors[0].value = 'luci-app-sbproxy-1.0.1-r38.apk';
selectors[0].onchange();
assert.equal(installers[0].children, 'Roll back');
await installers[0].attrs.click();
assert.deepEqual(calls.at(-1).slice(0, 2), ['plugin_upgrade', 'luci-app-sbproxy-1.0.1-r38.apk'],
  'A plugin downgrade uses the same verified install path');
await checks[1].attrs.click();
assert.equal(installers[1].children, 'Update', 'Keep an installed Alpha on the Alpha channel by default');
selectors[1].value = 'sing-box-1.14.4.apk';
selectors[1].onchange();
assert.equal(installers[1].children, 'Roll back');
await installers[1].attrs.click();
assert.equal(calls.at(-1)[0], 'core_rollback');
selectors[1].value = 'sing-box-1.15.0-alpha.13.apk';
selectors[1].onchange();
await installers[1].attrs.click();
assert.equal(calls.at(-1)[0], 'core_upgrade');
view.operationBusy = true; view.refreshButtons();
assert(checks.every(n => n.disabled));
assert(installers.every(n => n.disabled));
view.operationBusy = false; failCheck = true;
await checks[0].attrs.click();
assert(installers[0].disabled, 'A failed query cannot install a stale selection');
assert(!checks[0].disabled, 'Network errors allow retry');

// Resource versions live on the same page and keep their own busy state.
failCheck = false;
const table = nodes.find(n => n.tag === 'table');
assert.deepEqual(table.rows.map(row => row[0]), ['China IP rules (IPv4 and IPv6)', 'China domain rule set',
  'sing-box dashboard', 'Yacd-meta', 'MetaCubeXD']);
assert.equal(table.rows[0][1].children, '20261112');
assert.equal(table.rows[0][1].style.color, 'green');
assert.equal(table.rows[1][1].children, '-');
assert.equal(table.rows[1][1].style.color, 'red');
assert.equal(table.rows[0][2].attrs.href, 'https://example.invalid/geoip');
assert.equal(table.rows[2][2], '-');
assert.equal(resourceButtons.length, 6);
assert.equal(resourceButtons.at(-1).children[0], 'Update all');
assert.equal(polls.length, 1, 'Resource versions are refreshed by the LuCI poller');
assert(resourceButtons.every(n => !n.disabled), 'Core busy state does not lock resource updates');
const resourceStatus = nodes.find(n => n.tag === 'p' && n.attrs.role === 'status');
await table.rows[1][3].attrs.click();
assert.deepEqual(calls.filter(c => c[0] === 'resources_update').at(-1), ['resources_update', 'geosite_cn']);
assert(resourceButtons.every(n => n.disabled), 'Resource buttons stay locked while an update runs');
assert.equal(resourceStatus.children, 'China domain rule set — Updating…');
resourceState = { resources: [{ type: 'geosite_cn', version: '20261118141523' }],
  operation: { target: 'all', running: false, status: 4, failed: ['geoip_cn', 'yacd'] } };
await polls[0]();
assert(resourceButtons.every(n => !n.disabled));
assert.equal(table.rows[1][1].children, '20261118141523');
assert.equal(resourceStatus.children, 'All resources — Some resources failed to update. Check the log for details. Failed resources: China IP rules (IPv4 and IPv6), Yacd-meta');
console.log('Version management UI: independent plugin/core actions, plugin and core downgrade, shared busy state, query errors and resource updates passed');
