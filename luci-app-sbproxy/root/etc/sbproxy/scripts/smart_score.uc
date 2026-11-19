'use strict';

/* Kept independent of I/O so switching decisions can be replayed in tests. */
export function observe(previous, delays, now) {
	let ok = 0, total = 0, low = 100000, high = 0;
	for (let delay in delays) {
		if (delay == null || delay <= 0) continue;
		ok++; total += delay;
		if (delay < low) low = delay;
		if (delay > high) high = delay;
	}
	const latency = ok ? total * 1.0 / ok : 6000;
	const loss = length(delays) ? 1.0 - ok * 1.0 / length(delays) : 1.0;
	const old = previous || {};
	const delta = old.latency == null ? 0 : (latency > old.latency ? latency - old.latency : old.latency - latency);
	const spread = ok > 1 ? high - low : 0;
	return {
		...old, checked: now, healthy: ok >= 2,
		failures: ok >= 2 ? 0 : (old.failures || 0) + 1,
		/* A successful probe does not prove the node can finish a real TLS
		 * session. Keep session failures until a later cycle clears them. */
		session_failures: old.session_failures || 0,
		latency: old.latency == null ? latency : old.latency * 0.6 + latency * 0.4,
		jitter: old.jitter == null ? spread : old.jitter * 0.6 + (spread + delta) * 0.4,
		loss: old.loss == null ? loss : old.loss * 0.6 + loss * 0.4
	};
};

/* Real outbound failures are independent of the HTTPS probe. One cycle of
 * repeated dial or handshake timeouts counts as one session failure. */
export function observeSession(previous, failed, now) {
	const old = previous || {};
	const count = old.session_failures || 0;
	return {
		...old, checked: old.checked == null ? now : old.checked,
		session_at: now,
		session_failures: failed ? count + 1 : 0
	};
};

const UNAVAILABLE = 1000000000;
const SPEED_FRESH = 3600;

function base(sample) {
	return sample.latency + sample.jitter * 0.25 + sample.loss * 3000;
}

/* Expected milliseconds to download 1 MiB, capped so one bad download costs
 * the same as a severe loss. A failed download is stored as speed 1. */
function penalty(speed) {
	return min(8000, 1048576000.0 / speed);
}

function downloaded(sample, now) {
	return sample?.speed > 1 && sample.speed_checked != null &&
		now - sample.speed_checked < SPEED_FRESH;
}

export function score(sample, now) {
	if (!sample || !sample.healthy || now - sample.checked > 180) return UNAVAILABLE;
	const bandwidth = sample.speed > 0 && sample.speed_checked != null &&
		now - sample.speed_checked < SPEED_FRESH ? penalty(sample.speed) : 0;
	return base(sample) + bandwidth;
};

/* Average with the previous fresh success so one noisy download does not
 * decide alone. The harmonic mean averages download times, not rates. */
export function observeSpeed(previous, value, now) {
	const old = previous || {};
	let speed = 1;
	if (value > 0)
		speed = downloaded(old, now) ? 2.0 / (1.0 / old.speed + 1.0 / value) : value;
	return { ...old, speed, speed_checked: now };
};

/* A failure counts only when another node succeeded in the same round.
 * When every download fails, the test endpoint is the likely problem. */
export function recordSpeeds(samples, results, now) {
	let succeeded = false;
	for (let node, value in results)
		if (value > 0) succeeded = true;
	if (!succeeded) return false;
	for (let node, value in results)
		samples[node] = observeSpeed(samples[node], value, now);
	return true;
};

/* Pick nodes for one download round: the active node, the best previously
 * measured alternative, then the least recently measured healthy nodes.
 * A node whose latency alone loses to the best known score is skipped,
 * because no download result could make it win. */
export function speedCandidates(samples, nodes, current, now, limit) {
	const recent = filter(nodes, (node) => samples[node]?.healthy &&
		now - samples[node].checked <= 1800);
	const expected = (node) => base(samples[node]) + penalty(samples[node].speed);
	const known = filter(recent, (node) => samples[node].speed > 1);
	sort(known, (a, b) => expected(a) - expected(b));
	const picked = [];
	if (index(recent, current) >= 0) push(picked, current);
	for (let node in known) {
		if (node === current) continue;
		push(picked, node);
		break;
	}
	const ceiling = length(known) ? expected(known[0]) : UNAVAILABLE;
	const rest = filter(recent, (node) => index(picked, node) < 0 &&
		base(samples[node]) < ceiling);
	sort(rest, (a, b) => ((samples[a].speed_checked || 0) - (samples[b].speed_checked || 0)) ||
		base(samples[a]) - base(samples[b]));
	for (let node in rest) {
		if (length(picked) >= limit) break;
		push(picked, node);
	}
	return slice(picked, 0, limit);
};

/* Once any healthy node has a fresh successful download, compare only such
 * nodes. Unmeasured nodes carry no download penalty and would otherwise win
 * by default; failed downloads are excluded instead of pinning a node. */
export function eligibleNodes(samples, nodes, now) {
	const measured = filter(nodes, (node) => downloaded(samples[node], now) &&
		score(samples[node], now) < UNAVAILABLE);
	return length(measured) ? measured : nodes;
};

export function decide(state, samples, nodes, current, now) {
	let best = null, best_score = UNAVAILABLE;
	for (let node in nodes) {
		const value = score(samples[node], now);
		if (value < best_score) { best = node; best_score = value; }
	}
	if (!best || best === current) {
		state.challenger = null; state.wins = 0;
		return null;
	}
	const active = samples[current];
	/* Never treat stale/unprobed state as proof of failure. A fresh real
	 * session timeout is proof even when the lightweight probe still passes. */
	const failed = active && (
		(now - active.checked <= 180 && active.failures >= 2) ||
		(active.session_at != null && now - active.session_at <= 180 &&
			active.session_failures >= 2)
	);
	const bootstrap = current === state.fallback;
	const current_score = score(active, now);
	if (bootstrap || failed) {
		state.challenger = null; state.wins = 0;
		return best;
	}
	if (!active?.healthy || now - active.checked > 180 ||
	    best_score > current_score * 0.75 || current_score - best_score < 75) {
		state.challenger = null; state.wins = 0;
		return null;
	}
	state.wins = state.challenger === best ? (state.wins || 0) + 1 : 1;
	state.challenger = best;
	return state.wins >= 3 && now - (state.switched || 0) >= 180 ? best : null;
};
