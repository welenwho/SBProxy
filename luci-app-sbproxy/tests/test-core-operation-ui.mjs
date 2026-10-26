import fs from 'node:fs';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

const source = fs.readFileSync(new URL('../htdocs/luci-static/resources/view/sbproxy/core.js', import.meta.url), 'utf8');
const sortSource = source.slice(source.indexOf('function sortCoreAssets('), source.indexOf('\n}', source.indexOf('function sortCoreAssets(')) + 2);
const sortAssets = Function(sortSource + '; return sortCoreAssets;')();
assert.deepEqual(sortAssets(['1.15.0-alpha.9', '1.14.3', '1.15.0-alpha.12', '1.14.10']
  .map(package_version => ({ package_version }))).map(a => a.package_version),
  ['1.14.10', '1.14.3', '1.15.0-alpha.12', '1.15.0-alpha.9']);
String.prototype.format = function(...args) { let i = 0; return this.replace(/%s/g, () => args[i++]); };
const id = 'a'.repeat(32);
const running = { operation_id: id, operation_state: 'running', operation_stage: 'restarting' };
const success = { operation_id: id, operation_state: 'succeeded', result_code: 0, upgraded: true, package_version: '1.14.0-r2' };

function harness(sequence) {
  const messages = [], calls = [], results = [];
  let now = 0;
  let controller;
  const view = Function('rpc', 'view', 'ui', 'dom', 'E', '_', 'window', 'setTimeout', 'Date', source)(
    { declare: ({ method }) => async (...args) => {
      calls.push([method, ...args]);
      assert.equal(method, 'core_operation_status');
      assert.ok(sequence.length, 'unexpected extra poll');
      const next = sequence.shift();
      if (next instanceof Error) throw next;
      if (typeof next === 'function') return next(controller);
      return next;
    } },
    { extend: (value) => value },
    { showModal: () => {}, hideModal: () => {} },
    { content: (_el, message) => messages.push(message) },
    (...args) => ({ args }), (s) => s, { crypto: webcrypto },
    (fn, delay) => { now += delay; fn(); }, { now: () => now });
  controller = view;
  view.showSuccess = (...args) => results.push(['success', ...args]);
  view.showFailure = (...args) => results.push(['failure', ...args]);
  view.showUnconfirmed = (...args) => results.push(['unknown', ...args]);
  return { view, messages, calls, results };
}

// A brief network interruption is not a failed upgrade.
{
  const h = harness([running, new Error('timeout'), new Error('network'), success]);
  await h.view.monitorOperation('Upgrade', id);
  assert.equal(h.results[0][0], 'success');
  assert.equal(h.calls.length, 4);
  assert.ok(h.messages.some((m) => typeof m === 'string' && m.includes('Connection interrupted')));
}
// A real backend failure (including automatic recovery) is still shown.
{
  const failure = { ...running, operation_state: 'failed', result_code: 1, automatic_rollback: true, error_code: 'upgrade_failed_rolled_back' };
  const h = harness([failure]);
  await h.view.monitorOperation('Upgrade', id);
  assert.deepEqual(h.results[0], ['failure', 'Upgrade', failure]);
}
// Wrong job, missing state, and matching version without health success are uncertain.
for (const result of [{}, { ...success, operation_id: 'b'.repeat(32) },
  { ...success, operation_state: 'unknown' }, { ...success, result_code: 1 }]) {
  const h = harness([result]);
  await h.view.monitorOperation('Upgrade', id);
  assert.equal(h.results[0][0], 'unknown');
}
// If the acceptance response is lost, only query the original ID; never re-submit.
{
  let submissions = 0, submittedId;
  const h = harness([() => ({ ...success, operation_id: submittedId })]);
  await h.view.runOperation('Upgrade', async (target, jobId) => {
    submissions++;
    assert.equal(target, 'sing-box-1.14.0-r2.apk');
    assert.match(jobId, /^[a-f0-9]{32}$/);
    submittedId = jobId;
    throw new Error('reply lost');
  }, 'sing-box-1.14.0-r2.apk');
  assert.equal(submissions, 1);
  assert.equal(h.calls[0][1], submittedId);
  assert.equal(h.results[0][0], 'success');
}
// Closing/replacing a monitor cannot let a late response overwrite a newer modal.
{
  const h = harness([(view) => { view.monitorToken++; return success; }]);
  await h.view.monitorOperation('Upgrade', id);
  assert.equal(h.results.length, 0);
}
// Prolonged disconnection has a bounded foreground wait, not a false failure.
{
  const h = harness(Array.from({ length: 900 }, () => new Error('offline')));
  await h.view.monitorOperation('Upgrade', id);
  assert.equal(h.results[0][0], 'unknown');
  assert.equal(h.calls.length, 900);
}
console.log('Core operation UI reconnect, job identity and terminal-result tests passed');
