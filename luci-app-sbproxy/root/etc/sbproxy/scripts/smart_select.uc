#!/usr/bin/ucode
'use strict';

import { readfile, writefile, popen, open, stat } from 'fs';
import { urlencode } from 'luci.http';
import { observe, observeSession, eligibleNodes, speedCandidates, recordSpeeds, decide } from 'smart_score';

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
function run(command, allowed) {
	const fd = popen(command + ' 2>/dev/null');
	if (!fd) return null;
	const output = fd.read('all');
	const status = fd.close();
	return status === 0 || index(allowed || [], status) >= 0 ? output : null;
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
const log_path = plan.log_path || '/var/run/sbproxy/sing-box-c.log';
let log_offset = 0;
let pending_node = null;
const session_error = /context deadline exceeded|i\/o timeout|connection timed out|handshake timeout/;
function sessionFailures(nodes, probes) {
	const failed = {};
	const file = open(log_path, 'r');
	if (!file) return failed;
	const size = stat(log_path)?.size || 0;
	if (log_offset > size) log_offset = 0;
	file.seek(log_offset);
	let line;
	while ((line = file.read('line')) != null) {
		const outbound = match(line, /outbound\/[A-Za-z0-9_-]+\[([^\]]+)\]/);
		if (outbound) pending_node = outbound[1];
		/* Delay and bandwidth probes use the same outbounds. Count only user
		 * sessions, which sing-box logs with an inbound. */
		if (!pending_node || !match(line, session_error) || !match(line, /inbound\//))
			continue;
		if (index(nodes, pending_node) >= 0 && index(probes, pending_node) < 0)
			failed[pending_node] = true;
		pending_node = null;
	}
	log_offset = file.tell();
	file.close();
	return failed;
}
function probe(state, node) {
	const delays = [];
	for (let url in targets) {
		const result = api('/proxies/' + urlencode(node) + '/delay?timeout=2000&url=' + urlencode(url));
		push(delays, result?.delay == null ? null : (result.delay > 0 ? result.delay : 1));
	}
	state.samples[node] = observe(state.samples[node], delays, time());
}
const speed_bytes = 4194304;
const speed_interval = 1800;
/* Time only the transfer after the first byte, so connection setup on a
 * distant node is not mistaken for low throughput. A node that cannot finish
 * within the time limit is measured from its partial download (curl 28). */
function speed(node) {
	if (!select(plan.probe_tag, node)) return null;
	const result = run('curl --noproxy ' + quote('') + ' --proxy ' +
		quote(sprintf('http://127.0.0.1:%d', plan.probe_port)) +
		' -fsS --connect-timeout 3 --max-time 8 --max-filesize ' + speed_bytes + ' -o /dev/null -w ' +
		quote('%{size_download} %{time_starttransfer} %{time_total}') + ' ' +
		quote('https://speed.cloudflare.com/__down?bytes=' + speed_bytes), [ 28 ]);
	if (!result) return null;
	const parts = split(trim(result), ' ');
	const size = +parts[0];
	return size >= 65536 ? size / max(0.05, +parts[2] - +parts[1]) : null;
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
		for (let node in batch)
			probe(state, node);
		const sessions = sessionFailures(group.nodes, [plan.probe_tag, group.fallback]);
		for (let node in group.nodes) {
			if (!state.samples[node] && !sessions[node]) continue;
			state.samples[node] = observeSession(state.samples[node], !!sessions[node], time());
		}
		const now = time();
		if (group.bandwidth && now - state.bandwidth_at >= speed_interval) {
			/* Candidates may come from earlier rotations. Refresh their latency
			 * so a measured node can be compared in this cycle. */
			const results = {};
			for (let node in speedCandidates(state.samples, group.nodes, current, now, 3)) {
				if (time() - state.samples[node].checked > 120) probe(state, node);
				if (state.samples[node].healthy) results[node] = speed(node) || 0;
			}
			/* Without any healthy candidate, retry on the next cycle. */
			if (length(results)) {
				recordSpeeds(state.samples, results, time());
				state.bandwidth_at = time();
			}
		}
		const decision_at = time();
		const eligible = group.bandwidth ? eligibleNodes(state.samples, group.nodes, decision_at) : group.nodes;
		const next = decide(state, state.samples, eligible, current, decision_at);
		if (next && select(group.tag, next)) {
			state.switched = time(); state.wins = 0; state.challenger = null;
			warn(sprintf('Smart selection: %s -> %s (%s)\n', current, next, group.tag));
		}
		if (state.samples[current]?.failures > 0 || state.samples[current]?.session_failures > 0)
			urgent = true;
		writefile(plan_path + '.status', sprintf('%.J\n', states));
	}
	const elapsed = time() - started;
	const delay = (urgent ? 10 : 60) - elapsed;
	sleep((delay > 0 ? delay : 1) * 1000);
}
