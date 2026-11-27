import { readfile } from 'fs';
function assert(ok, message) { if (!ok) die(message); }
for (let file in ARGV) {
 const c = json(readfile(file)), plan = json(readfile(file + '.smart.json'));
 const fixed = match(file, /\/(yacd-fixed|metacubexd-fixed|native-fixed|unconfigured-secret|dashboard-off)\.json$/);
 if (fixed) {
  assert(length(plan.groups) === 0, fixed[1] + ': no smart selection group');
  const clash = c.experimental?.clash_api;
  const native = filter(c.services || [], (s) => s.type === 'api' && s.dashboard?.enabled);
  if (fixed[1] in ['yacd-fixed', 'metacubexd-fixed']) {
   assert(clash?.external_controller === '0.0.0.0:19095', fixed[1] + ': dashboard port');
   assert(clash.secret === 'dashboard-secret', fixed[1] + ': dashboard authentication');
   assert(clash.external_ui === '/etc/sbproxy/dashboard', fixed[1] + ': dashboard web files');
   assert(length(native) === 0, fixed[1] + ': no native dashboard');
  } else {
   assert(!clash, fixed[1] + ': no Clash API');
   assert(length(native) === (fixed[1] === 'native-fixed' ? 1 : 0), fixed[1] + ': native dashboard state');
  }
  continue;
 }
 const ordinary = index(file, 'ordinary') >= 0;
 assert(length(plan.groups) === (ordinary ? 0 : 1), 'Plan group count');
 if (ordinary) {
  assert(!length(filter(c.inbounds, (i) => i.tag === 'sbproxy-smart-probe-in')), 'Probe disabled');
  const test = filter(c.outbounds, (o) => o.type === 'urltest')[0];
  assert(test.interval === '60s' && test.tolerance === 75, 'URLTest defaults');
  continue;
 }
 const group = plan.groups[0];
 const selector = filter(c.outbounds, (o) => o.tag === group.tag)[0];
 assert(selector.type === 'selector' && selector.default === group.fallback, 'Selector fallback');
 assert(length(selector.outbounds) === 3 && length(group.nodes) === 2, 'Candidate membership');
 if (index(file, 'dashboard') >= 0) {
  /* Yacd serves the Clash API on the dashboard port behind its secret. */
  assert(c.experimental.clash_api.external_controller === '0.0.0.0:19095', 'Dashboard API');
  assert(c.experimental.clash_api.secret === 'dashboard-secret', 'Dashboard secret');
  assert(plan.api_port === 19095 && plan.api_secret === 'dashboard-secret', 'Selector follows dashboard API');
 } else {
  assert(c.experimental.clash_api.external_controller === '127.0.0.1:19090', 'Private API');
  assert(plan.api_port === 19090 && plan.api_secret == null, 'Selector uses private API');
 }
 const probe = filter(c.inbounds, (i) => i.listen_port === plan.probe_port)[0];
 assert(probe.listen === '127.0.0.1', 'Probe loopback only');
 assert(c.route.rules[0].outbound === plan.probe_tag, 'Probe bypasses user routing');
 assert(c.route.final === group.tag, 'User route preserved');
}
print('Smart main/custom/disabled/dashboard configurations passed\n');
