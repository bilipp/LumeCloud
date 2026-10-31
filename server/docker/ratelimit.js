// Stand-in for the Workers Rate Limiting binding when the server runs on plain
// workerd (Docker). Fixed windows of `period` seconds, counted in memory: the
// counters reset when the container restarts, like Cloudflare's counters are
// per location. Same interface as the binding: limit({ key }) → { success }.

const windows = new Map(); // `${namespace}:${key}` → { start, count }
let lastSweep = 0;

function sweep(now, periodMs) {
	if (now - lastSweep < periodMs) return;
	lastSweep = now;
	for (const [k, w] of windows) if (now - w.start >= w.periodMs) windows.delete(k);
}

export default function makeBinding({ namespace, limit, period }) {
	const periodMs = period * 1000;
	return {
		async limit({ key }) {
			const now = Date.now();
			sweep(now, periodMs);
			const id = `${namespace}:${key}`;
			let w = windows.get(id);
			if (w === undefined || now - w.start >= periodMs) {
				w = { start: now, count: 0, periodMs };
				windows.set(id, w);
			}
			w.count += 1;
			return { success: w.count <= limit };
		},
	};
}
