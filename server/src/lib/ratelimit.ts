// Thin wrapper over the Workers Rate Limiting binding (10 s / 60 s windows).

import { rateLimited } from "./errors";

/** Throws 429 rate_limited (Retry-After = the binding's period) when exhausted. */
export async function enforce(limiter: RateLimit, key: string, periodSeconds: 10 | 60): Promise<void> {
	const { success } = await limiter.limit({ key });
	if (!success) throw rateLimited(periodSeconds);
}
