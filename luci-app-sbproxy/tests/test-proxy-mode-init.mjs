import fs from 'node:fs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const root = new URL('../', import.meta.url);
const source = fs.readFileSync(new URL('root/etc/init.d/sbproxy', root), 'utf8');
const selection = source.slice(source.indexOf('\tlocal outbound_node\n'), source.indexOf('\n\tlocal server_enabled proxy_client_requested=0'));
assert(selection.includes('"disabled"'));
for (const [mode, main, custom, expected] of [
  ['disabled', 'node1', 'node2', 'nil'], ['disabled', 'urltest', 'reject', 'nil'],
  ['bypass_mainland_china', 'node1', 'node2', 'node1'], ['global', 'node1', 'node2', 'node1'],
  ['custom', 'node1', 'node2', 'node2'], ['bypass_mainland_china', 'nil', 'node2', 'nil']
]) {
  const result = spawnSync('sh', ['-c', `
config_get() {
  case "$2.$3" in
    config.main_node) eval "$1=\\\"\\$MAIN\\\"" ;;
    routing.default_outbound) eval "$1=\\\"\\$CUSTOM\\\"" ;;
    *) exit 98 ;;
  esac
}
run_test() {
 local routing_mode="$MODE"
 ${selection}
 printf '%s' "$outbound_node"
}
run_test
`], { env: { ...process.env, MODE: mode, MAIN: main, CUSTOM: custom }, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, expected, mode);
}
assert(source.includes('if [ "$outbound_node" != "nil" ] || [ "$tailscale_enabled" = "1" ]; then'));
assert.match(source, /procd_open_instance "tailscale-sync"/);
assert.match(source, /\[ "\$tailscale_enabled" = "0" \]; then\s+sync_subscription_cron[^\n]*\n\s+return 0/);
const rpc = fs.readFileSync(new URL('root/usr/share/rpcd/ucode/luci.sbproxy', root), 'utf8');
assert.match(rpc, /mode: 'disabled', proxy_enabled: false/);
console.log('Proxy mode startup tests passed: saved nodes ignored only when off, Tailscale startup remains independent');

// The helper speaks gRPC (`sing-box api`). The dashboard port serves the HTTP
// Clash API for Yacd/MetaCubeXD, so Tailscale control must always use the
// internal API port, whatever the proxy mode and dashboard settings are.
const helper = fs.readFileSync(new URL('root/usr/sbin/sbproxy_tailscale_helper', root), 'utf8');
const loadSettings = helper.slice(helper.indexOf('load_settings() {'), helper.indexOf('\nvalidate_settings() {'));
assert(!/dashboard_(port|enabled|secret)/.test(loadSettings), 'helper must not read dashboard settings');
assert(!helper.includes('BOX_API_SECRET'), 'internal API has no secret');
for (const mode of ['disabled', 'global', 'custom', 'bypass_mainland_china']) {
  for (const enabled of ['0', '1']) {
    const result = spawnSync('sh', ['-c', `
config_load() { :; }
config_get() {
  case "$2.$3" in
    config.routing_mode) value="$MODE" ;;
    config.dashboard_enabled) value="$DASHBOARD_ENABLED" ;;
    config.dashboard_port) value=19095 ;;
    infra.tailscale_api_port) value=19096 ;;
    *) value="\${4:-}" ;;
  esac
  export "$1=$value"
}
config_get_bool() { config_get "$@"; }
${loadSettings}
load_settings
printf '%s' "$API_URL"
`], { env: { ...process.env, MODE: mode, DASHBOARD_ENABLED: enabled }, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'http://127.0.0.1:19096', `${mode} dashboard=${enabled}`);
  }
}
assert.match(source, /\[ "\$routing_mode" != "disabled" \] \|\| dashboard_enabled=0/);
console.log('Tailscale helper always uses its internal gRPC API port, even with the dashboard enabled');
