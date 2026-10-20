// Lume Cloud — zero-knowledge sync server (Cloudflare Worker entry point).
//
// Logging policy: one structured line per request with the method, route
// template, status and duration. Never request bodies, headers, keys, tokens,
// ciphertext, raw paths or query strings.

import { ApiError, errorResponse } from "./lib/errors";
import { route } from "./router";

export { AccountDO } from "./do/account";
export { PairingDO } from "./do/pairing";
export { SignupGuardDO } from "./do/signup-guard";

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const started = Date.now();
		const url = new URL(request.url);
		const routed = route(request, env, url);
		let response: Response;
		try {
			response = await routed.run();
		} catch (err) {
			if (err instanceof ApiError) {
				response = errorResponse(err);
			} else {
				console.error(
					JSON.stringify({
						event: "unhandled_error",
						route: routed.route,
						name: err instanceof Error ? err.name : typeof err,
						message: err instanceof Error ? err.message.slice(0, 200) : undefined,
					}),
				);
				response = errorResponse(new ApiError(500, "internal"));
			}
		}
		console.log(
			JSON.stringify({ event: "request", route: routed.route, status: response.status, ms: Date.now() - started }),
		);
		return response;
	},
} satisfies ExportedHandler<Env>;
