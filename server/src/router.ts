// Route table. Every handler throws ApiError for client-visible failures.

import { notFound } from "./lib/errors";
import { json } from "./lib/http";
import { createAccount, deleteAccount, getAccount } from "./routes/accounts";
import { listDevices, registerDevice, revokeDevice } from "./routes/devices";
import { createPairing, lookupPairing, pairingResult, sealPairing } from "./routes/pairings";
import { openSocket } from "./routes/socket";
import { getChanges, push } from "./routes/sync";

export interface Routed {
	/** Route template for logs, e.g. "GET /v1/pairings/:code" (never the raw path). */
	route: string;
	run: () => Promise<Response>;
}

export function route(request: Request, env: Env, url: URL): Routed {
	const method = request.method.toUpperCase();
	const path = url.pathname.replace(/\/+$/, "") || "/";
	const r = (template: string, run: () => Promise<Response>): Routed => ({ route: `${method} ${template}`, run });

	if (path === "/healthz" && method === "GET") {
		return r("/healthz", async () => json({ ok: true, version: env.VERSION }));
	}

	const segments = path.split("/").filter((s) => s !== "");
	if (segments[0] === "v1") {
		const [, a, b, c] = segments;
		const n = segments.length;

		if (a === "accounts") {
			if (n === 2 && method === "POST") return r("/v1/accounts", () => createAccount(request, env));
			if (n === 3 && b === "me" && method === "GET") return r("/v1/accounts/me", () => getAccount(request, env));
			if (n === 3 && b === "me" && method === "DELETE") return r("/v1/accounts/me", () => deleteAccount(request, env));
		}
		if (a === "devices") {
			if (n === 2 && method === "POST") return r("/v1/devices", () => registerDevice(request, env));
			if (n === 2 && method === "GET") return r("/v1/devices", () => listDevices(request, env));
			if (n === 3 && b !== undefined && method === "DELETE") {
				return r("/v1/devices/:id", () => revokeDevice(request, env, b));
			}
		}
		if (a === "changes" && n === 2 && method === "GET") return r("/v1/changes", () => getChanges(request, env, url));
		if (a === "push" && n === 2 && method === "POST") return r("/v1/push", () => push(request, env));
		if (a === "socket" && n === 2 && method === "GET") return r("/v1/socket", () => openSocket(request, env));
		if (a === "pairings") {
			if (n === 2 && method === "POST") return r("/v1/pairings", () => createPairing(request, env));
			if (n === 3 && b !== undefined && method === "GET") {
				return r("/v1/pairings/:code", () => lookupPairing(request, env, b));
			}
			if (n === 4 && b !== undefined && c === "seal" && method === "POST") {
				return r("/v1/pairings/:code/seal", () => sealPairing(request, env, b));
			}
			if (n === 4 && b !== undefined && c === "result" && method === "GET") {
				return r("/v1/pairings/:code/result", () => pairingResult(request, env, b, url));
			}
		}
	}

	return r("unmatched", async () => {
		throw notFound("Unknown route");
	});
}
