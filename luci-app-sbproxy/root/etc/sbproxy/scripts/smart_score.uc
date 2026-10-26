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
	const latency = ok ? total / ok : 6000;
	const loss = 1 - ok / length(delays);
	const old = previous || {};
	const delta = old.latency == null ? 0 : (latency > old.latency ? latency - old.latency : old.latency - latency);
	const spread = ok > 1 ? high - low : 0;
	return {
		...old, checked: now, healthy: ok >= 2,
		failures: ok >= 2 ? 0 : (old.failures || 0) + 1,
		latency: old.latency == null ? latency : old.latency * 0.6 + latency * 0.4,
		jitter: old.jitter == null ? spread : old.jitter * 0.6 + (spread + delta) * 0.4,
		loss: old.loss == null ? loss : old.loss * 0.6 + loss * 0.4
	};
};

export function score(sample, now) {
	if (!sample || !sample.healthy || now - sample.checked > 180) return 1000000000;
	const bandwidth = sample.speed > 0 && now - sample.speed_checked < 1200 ?
		(sample.speed < 8192 ? 8000 : 262144000 / sample.speed * 0.25) : 0;
	return sample.latency + sample.jitter * 0.25 + sample.loss * 3000 + bandwidth;
};

export function decide(state, samples, nodes, current, now) {
	let best = null, best_score = 1000000000;
	for (let node in nodes) {
		const value = score(samples[node], now);
		if (value < best_score) { best = node; best_score = value; }
	}
	if (!best || best === current) {
		state.challenger = null; state.wins = 0;
		return null;
	}
	const active = samples[current];
	/* Never treat stale/unprobed state as proof of failure. */
	const failed = active && now - active.checked <= 180 && active.failures >= 2;
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
