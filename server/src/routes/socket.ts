// /v1/socket — hibernating WebSocket for seq pokes (§4.6).

import { SOCKET_DEVICE_HEADER, SOCKET_VERIFIER_HEADER } from "../do/account";
import { ApiError } from "../lib/errors";
import { authenticate } from "./context";

export async function openSocket(request: Request, env: Env): Promise<Response> {
	if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
		throw new ApiError(426, "bad_request", "Expected a WebSocket upgrade");
	}
	const { account, auth } = await authenticate(request, env, true);

	// Forward a fresh request so no client-supplied header can impersonate the
	// internal ones; the DO re-checks the verifier and device.
	const headers = new Headers({ upgrade: "websocket", [SOCKET_VERIFIER_HEADER]: auth.verifier });
	for (const h of ["sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions"]) {
		const v = request.headers.get(h);
		if (v !== null) headers.set(h, v);
	}
	if (auth.deviceId !== null) headers.set(SOCKET_DEVICE_HEADER, auth.deviceId);
	const response = await account.fetch("https://account.internal/socket", { headers });
	if (response.status === 101) return response;

	// Translate the DO's JSON error into the API envelope.
	let code = "internal";
	try {
		const parsed: unknown = await response.json();
		if (parsed !== null && typeof parsed === "object" && "error" in parsed && typeof parsed.error === "string") {
			code = parsed.error;
		}
	} catch {
		// keep "internal"
	}
	return Response.json({ error: code }, { status: response.status });
}
