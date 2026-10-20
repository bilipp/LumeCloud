// /v1/accounts — create, read and delete accounts (PROTOCOL.md §4.1).

import { randomB64url, sha256B64url, timingSafeEqualStr } from "../lib/b64url";
import { ApiError, rateLimited, unwrap } from "../lib/errors";
import { json, noContent, readJsonObject } from "../lib/http";
import { clientIpKey } from "../lib/ip";
import { MAX_SMALL_BODY_BYTES } from "../lib/limits";
import { enforce } from "../lib/ratelimit";
import { accountStub, signupGuardStub } from "../lib/stubs";
import { requireB64urlBytes, requireString } from "../lib/validate";
import { authenticate } from "./context";

const ACCOUNT_ID_ATTEMPTS = 3;

async function inviteMatches(env: Env, invite: unknown): Promise<boolean> {
	const expected = env.INVITE_CODE;
	if (typeof expected !== "string" || expected === "" || typeof invite !== "string") return false;
	// Hash both sides so the comparison is constant time regardless of length.
	return timingSafeEqualStr(await sha256B64url(expected), await sha256B64url(invite));
}

export async function createAccount(request: Request, env: Env): Promise<Response> {
	const body = await readJsonObject(request, MAX_SMALL_BODY_BYTES);
	requireB64urlBytes(body, "authVerifier", 32);
	const verifier = requireString(body, "authVerifier");

	const mode: string = env.SIGNUP;
	if (mode !== "open" && !(await inviteMatches(env, body["invite"]))) {
		throw new ApiError(403, "signup_closed");
	}

	const ipKey = clientIpKey(request);
	await enforce(env.RL_SIGNUP, `signup:${ipKey}`, 60);
	const guard = await signupGuardStub(env, ipKey);
	const decision = await guard.consume(Date.now());
	if (!decision.allowed) throw rateLimited(decision.retryAfter);

	for (let attempt = 0; attempt < ACCOUNT_ID_ATTEMPTS; attempt++) {
		const accountId = randomB64url(16);
		const createdAt = Date.now();
		const { created } = await accountStub(env, accountId).create(accountId, verifier, createdAt);
		if (created) return json({ accountId, createdAt }, 201);
	}
	throw new ApiError(503, "unavailable", "Could not allocate an account id");
}

export async function getAccount(request: Request, env: Env): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	return json(unwrap(await account.info(auth)));
}

export async function deleteAccount(request: Request, env: Env): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	unwrap(await account.deleteAccount(auth));
	return noContent();
}
