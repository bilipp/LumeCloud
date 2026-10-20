// Parses `Authorization: Bearer <accountId>.<authKeyB64url>` + X-Lume-Device.

import { decodeB64url, sha256B64url } from "./b64url";
import { ApiError, badRequest } from "./errors";
import type { AuthContext } from "./types";
import { isAccountId, isUuid } from "./validate";

export interface Credentials {
	accountId: string;
	auth: AuthContext;
}

const badAuth = (): ApiError => new ApiError(401, "bad_auth");

/** Extracts the account id without hashing anything (used for rate limiting first). */
export function bearerAccountId(request: Request): string {
	const header = request.headers.get("authorization");
	if (header === null) throw badAuth();
	const m = /^Bearer ([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(header.trim());
	if (m === null || m[1] === undefined || !isAccountId(m[1])) throw badAuth();
	return m[1];
}

/**
 * Validates the auth header shape and computes the verifier the account stores.
 * The DO does the constant-time compare. `requireDevice` enforces X-Lume-Device.
 */
export async function readCredentials(request: Request, requireDevice: boolean): Promise<Credentials> {
	const accountId = bearerAccountId(request);
	const header = request.headers.get("authorization") ?? "";
	const keyPart = header.trim().slice(`Bearer ${accountId}.`.length);
	const authKey = decodeB64url(keyPart);
	if (authKey === null || authKey.byteLength !== 32) throw badAuth();

	const rawDevice = request.headers.get("x-lume-device");
	let deviceId: string | null = null;
	if (rawDevice !== null && rawDevice !== "") {
		if (!isUuid(rawDevice)) throw badRequest("X-Lume-Device must be a UUID");
		deviceId = rawDevice.toUpperCase();
	} else if (requireDevice) {
		throw badRequest("Missing X-Lume-Device header");
	}

	return { accountId, auth: { verifier: await sha256B64url(authKey), deviceId } };
}
