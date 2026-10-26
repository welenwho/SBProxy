#!/usr/bin/ucode
'use strict';

import { readfile, writefile, popen } from 'fs';
import { urlencode } from 'luci.http';
import { observe, score, decide } from 'smart_score';

const plan_path = ARGV[0] || '/var/run/sbproxy/sing-box-c.json.smart.json';
const plan = json(readfile(plan_path));
if (!length(plan?.groups)) exit(0);
const base = sprintf('http://127.0.0.1:%d', plan.api_port);
const targets = [
	'https://www.gstatic.com/generate_204',
	'https://cp.cloudflare.com/generate_204',
	'https://www.apple.com/library/test/success.html'
];
const states = {};
function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
function run(command) {
	const fd = popen(command + ' 2>/dev/null');
	if (!fd) return null;
	const output = fd.read('all');
	const status = fd.close();
	return status === 0 ? output : null;
}
function api(path, data) {
	const command = 'curl --noproxy ' + quote('*') + ' -fsS --connect-timeout 1 --max-time 4 ' +
		(data ? '-X PUT -H ' + quote('Content-Type: application/json') + ' --data-binary ' + quote(sprintf('%J', data)) + ' ' : '') +
		quote(base + path);
	const result = run(command);
	if (result == null) return null;
	if (data) return true;
	try { return json(result); } catch (e) { return null; }
}
function select(tag, node) { return api('/proxies/' + urlencode(tag), { name: node }); }
function speed(node) {
	if (!select(plan.probe_tag, node)) return null;
	const result = run('curl --noproxy ' + quote('') + ' --proxy ' +
		quote(sprintf('http://127.0.0.1:%d', plan.probe_port)) +
		' -fsS --connect-timeout 2 --max-time 6 --max-filesize 262144 -o /dev/null -w ' +
		quote('%{size_download} %{speed_download}') + ' ' + quote('https://speed.cloudflare.com/__down?bytes=262144'));
	if (!result) return null;
	const parts = split(trim(result), ' ');
	return +parts[0] >= 262144 && +parts[1] > 0 ? +parts[1] : null;
}

while (true) {
	const started = time();
	let urgent = false;
	const snapshot = api('/proxies');
	if (!snapshot?.proxies) { sleep(5000); continue; }
	for (let group in plan.groups) {
		const live = snapshot.proxies[group.tag];
		if (!live) continue;
		const state = states[group.tag] ||= { samples: {}, cursor: 0, switched: 0, bandwidth_at: 0, fallback: group.fallback };
		const current = live.now;
		/* Four rotating candidates plus the active node and challenger bound work per cycle. */
		const batch = [];
		if (index(group.nodes, current) >= 0) push(batch, current);
		if (state.challenger && index(batch, state.challenger) < 0) push(batch, state.challenger);
		for (let i = 0; i < length(group.nodes) && i < 4; i++) {
			const node = group.nodes[state.cursor++ % length(group.nodes)];
			if (index(batch, node) < 0) push(batch, node);
		}
		for (let node in batch) {
			const delays = [];
			for (let url in targets) {
				const result = api('/proxies/' + urlencode(node) + '/delay?timeout=2000&url=' + urlencode(url));
				push(delays, result?.delay == null ? null : (result.delay > 0 ? result.delay : 1));
			}
			state.samples[node] = observe(state.samples[node], delays, time());
		}
		const now = time();
		if (group.bandwidth && now - state.bandwidth_at >= 600) {
			const ranked = filter(group.nodes, (n) => score(state.samples[n], now) < 1000000000);
			sort(ranked, (a, b) => score(state.samples[a], now) - score(state.samples[b], now));
			/* Always compare the active node too; avoid comparing measured vs unmeasured candidates. */
			const candidates = slice(ranked, 0, 3);
			if (state.samples[current]?.healthy && index(candidates, current) < 0) {
				if (length(candidates) >= 3) pop(candidates);
				push(candidates, current);
			}
			for (let node in candidates) {
				const value = speed(node);
				state.samples[node].speed = value || 1;
				state.samples[node].speed_checked = time();
			}
			state.bandwidth_at = time();
		}
		/* Exclude unmeasured candidates while the current node has a fresh bandwidth result. */
		const measured = filter(group.nodes, (n) => state.samples[n]?.speed_checked > now - 1200 &&
			score(state.samples[n], time()) < 1000000000);
		const eligible = group.bandwidth && length(measured) ? measured : group.nodes;
		const next = decide(state, state.samples, eligible, current, time());
		if (next && select(group.tag, next)) {
			state.switched = time(); state.wins = 0; state.challenger = null;
			warn(sprintf('Smart selection: %s -> %s (%s)\n', current, next, group.tag));
		}
		if (state.samples[current]?.failures > 0) urgent = true;
		writefile(plan_path + '.status', sprintf('%.J\n', states));
	}
	const elapsed = time() - started;
	const delay = (urgent ? 10 : 60) - elapsed;
	sleep((delay > 0 ? delay : 1) * 1000);
}
