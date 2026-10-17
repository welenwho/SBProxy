import { readfile } from 'fs';
function assert(ok, message) { if (!ok) die(message); }
for (let file in ARGV) {
 const c = json(readfile(file)), plan = json(readfile(file + '.smart.json'));
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
 assert(c.experimental.clash_api.external_controller === '127.0.0.1:19090', 'Private API');
 const probe = filter(c.inbounds, (i) => i.listen_port === plan.probe_port)[0];
 assert(probe.listen === '127.0.0.1', 'Probe loopback only');
 assert(c.route.rules[0].outbound === plan.probe_tag, 'Probe bypasses user routing');
 assert(c.route.final === group.tag, 'User route preserved');
}
print('Smart main/custom/disabled configurations passed\n');
