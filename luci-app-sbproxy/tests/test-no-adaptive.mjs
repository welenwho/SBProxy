import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = new URL('../', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
for (const path of [
  'root/etc/sbproxy/scripts/generate_client.uc',
  'root/etc/sbproxy/scripts/sbproxy.uc',
  'root/etc/init.d/sbproxy',
  'root/usr/libexec/sbproxy-runtime-init',
  'root/usr/share/rpcd/ucode/luci.sbproxy',
  'root/usr/share/rpcd/acl.d/luci-app-sbproxy.json',
  'htdocs/luci-static/resources/view/sbproxy/client.js',
  'htdocs/luci-static/resources/view/sbproxy/core.js',
  'po/zh_Hans/sbproxy.po', 'po/templates/sbproxy.pot'
]) assert.doesNotMatch(read(path), /adaptive|自适应/i, path);
for (const path of [
  'root/etc/init.d/sbproxy-adaptive',
  'root/etc/sbproxy/scripts/adaptive.uc',
  'root/usr/share/sbproxy/defaults/sbproxy-adaptive',
  'htdocs/luci-static/resources/sbproxy-adaptive.js'
]) assert.equal(fs.existsSync(new URL(path, root)), false, path);

const client = read('htdocs/luci-static/resources/view/sbproxy/client.js');
const loadBody = client.slice(client.indexOf('\tload() {') + '\tload() {'.length, client.indexOf('\n\trender(data) {')).replace(/},\s*$/, '');
const load = Function('uci', 'sb', 'network', 'L', 'callIngressStatus', loadBody);
const data = await load(
  { load: async name => name, get: () => '1' },
  { getBuiltinFeatures: async () => ({ with_tailscale: true }) },
  { getHostHints: async () => ({ hosts: {} }) },
  { resolveDefault: promise => promise }, async () => ({ ingress: 'sentinel' })
);
assert.equal(data.length, 5);
assert.equal(data[4].ingress, 'sentinel');
assert.match(client, /ingressStatusContent\(data\[4\]/);
const generator = read('root/etc/sbproxy/scripts/generate_client.uc');
assert.match(generator, /config\.route\.final = 'main-out';/);
assert.match(generator, /config\.route\.final = final_outbound;/);
assert.match(generator, /const enable_clash_api = main_node === 'urltest' \|\| length\(smart_groups\) > 0;/);
assert.match(generator, /add_tailscale_exit_node_rule/);
assert.match(generator, /renderRouteMatch/);
assert.match(read('root/etc/sbproxy/scripts/firewall_pre.uc'), /iifname != \{ \$\{allowed\} \}/);
assert.match(client, /\(value \|\| ''\)\.length >= 16/);
JSON.parse(read('root/usr/share/rpcd/acl.d/luci-app-sbproxy.json'));
console.log('Removal regression passed: no active adaptive hooks, correct UI load indices, routing and dashboard protection retained');
