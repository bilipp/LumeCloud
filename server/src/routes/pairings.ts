// /v1/pairings — HPKE handoff of the account key to a new device (§4.5).

import { isB64url, randomB64url } from "../lib/b64url";
import { ApiError, notFound, unwrap } from "../lib/errors";
import { json, noContent, readJsonObject } from "../lib/http";
import { clientIpKey } from "../lib/ip";
import { MAX_SEALED_BYTES, MAX_SMALL_BODY_BYTES, PAIRING_CODE_ATTEMPTS, PAIRING_TTL_MS } from "../lib/limits";
import { enforce } from "../lib/ratelimit";
import { pairingStub } from "../lib/stubs";
import { isPairingCode, requireB64urlBytes, requireDeviceName, requirePlatform, requireString } from "../lib/validate";
import { authenticate } from "./context";

/** Uniform 6-digit code (leading zeros allowed), by rejection sampling. */
function drawCode(): string {
	const buf = new Uint32Array(1);
	const bound = 4_294_000_000; // largest multiple of 1e6 below 2^32
	for (;;) {
		crypto.getRandomValues(buf);
		const v = buf[0] ?? bound;
		if (v < bound) return String(v % 1_000_000).padStart(6, "0");
	}
}

export async function createPairing(request: Request, env: Env): Promise<Response> {
	const body = await readJsonObject(request, MAX_SMALL_BODY_BYTES);
	requireB64urlBytes(body, "publicKey", 32);
	const req = {
		publicKey: requireString(body, "publicKey"),
		deviceName: requireDeviceName(body, "deviceName"),
		platform: requirePlatform(body, "platform"),
	};
	await enforce(env.RL_PAIRING_CREATE, `pairing-create:${clientIpKey(request)}`, 60);

	const pollToken = randomB64url(32);
	for (let attempt = 0; attempt < PAIRING_CODE_ATTEMPTS; attempt++) {
		const code = drawCode();
		const expiresAt = Date.now() + PAIRING_TTL_MS;
		const { created } = await pairingStub(env, code).open(req, pollToken, expiresAt);
		if (created) return json({ code, pollToken, expiresAt }, 201);
	}
	throw new ApiError(503, "unavailable", "No free pairing code, try again");
}

/** Joined device: confirm who is asking before sealing anything. */
export async function lookupPairing(request: Request, env: Env, code: string): Promise<Response> {
	const { accountId, account, auth } = await authenticate(request, env, true);
	await enforce(env.RL_PAIRING_LOOKUP, `pairing-lookup:${accountId}`, 60);
	// Verify the caller's credentials before revealing anything about the code.
	unwrap(await account.info(auth));
	if (!isPairingCode(code)) throw notFound("Pairing code expired or unknown");
	return json(unwrap(await pairingStub(env, code).lookup()));
}

export async function sealPairing(request: Request, env: Env, code: string): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	unwrap(await account.info(auth));
	if (!isPairingCode(code)) throw notFound("Pairing code expired or unknown");
	const body = await readJsonObject(request, MAX_SMALL_BODY_BYTES);
	requireB64urlBytes(body, "enc", 32);
	const ct = requireB64urlBytes(body, "ciphertext");
	if (ct.byteLength === 0 || ct.byteLength > MAX_SEALED_BYTES) {
		throw new ApiError(400, "bad_request", `"ciphertext" must be 1–${MAX_SEALED_BYTES} bytes`);
	}
	unwrap(await pairingStub(env, code).seal(requireString(body, "enc"), requireString(body, "ciphertext")));
	return noContent();
}

/** New device polls, unauthenticated, with its poll token. */
export async function pairingResult(request: Request, env: Env, code: string, url: URL): Promise<Response> {
	await enforce(env.RL_PAIRING_POLL, `pairing-poll:${clientIpKey(request)}`, 60);
	const pollToken = url.searchParams.get("pollToken") ?? "";
	if (!isPairingCode(code) || pollToken.length !== 43 || !isB64url(pollToken)) {
		throw notFound("Pairing code expired or unknown");
	}
	return json(unwrap(await pairingStub(env, code).result(pollToken)));
}
