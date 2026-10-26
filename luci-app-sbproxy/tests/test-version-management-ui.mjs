import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../htdocs/luci-static/resources/view/sbproxy/core.js', import.meta.url), 'utf8');
String.prototype.format = function(...args) { let i = 0; return this.replace(/%s/g, () => args[i++]); };
const nodes = [], calls = [];
const E = (tag, attrs = {}, children = []) => {
  const node = { tag, attrs, children, value: attrs.value || '', disabled: !!attrs.disabled };
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
  return { code: 0 };
} };
const view = Function('rpc', 'view', 'ui', 'dom', 'E', '_', source)(rpc,
  { extend: value => value }, { createHandlerFn: (owner, fn) => fn.bind(owner) },
  { content: (node, children) => { node.children = children; } }, E, s => s);
const submissions = [];
view.confirmOperation = (_title, _message, operation) => operation();
view.runOperation = async (_title, operation, target) => { submissions.push(target); await operation(target, 'a'.repeat(32)); };
view.render([{ plugin_version: '1.0.1-r39', version: '1.15.0-alpha.12', manager_supported: true }, {}]);
const checks = nodes.filter(n => n.tag === 'button' && n.children[0] === 'Check for updates');
const selectors = nodes.filter(n => n.tag === 'select');
const installers = nodes.filter(n => n.tag === 'button' && n.attrs.class.includes('cbi-button-action'));
assert.equal(checks.length, 2);
assert.equal(nodes.filter(n => n.tag === 'table').length, 0, 'No feature/architecture/storage tables');
await checks[0].attrs.click();
assert.equal(selectors[0].children.length, 1, 'Plugin downgrade is not offered');
assert.equal(installers[0].children, 'Reinstall');
await installers[0].attrs.click();
assert.equal(calls.at(-1)[0], 'plugin_upgrade');
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
console.log('Version management UI: independent plugin/core actions, rollback, shared busy state and query errors passed');
