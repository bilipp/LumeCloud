// Field validators for request bodies. Each throws `bad_request` on failure.

import { decodeB64url } from "./b64url";
import { badRequest } from "./errors";
import { MAX_DEVICE_NAME_CHARS } from "./limits";

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
/** Platform tokens: the documented ones plus room for additive v1 values. */
const PLATFORM_RE = /^[a-z][a-z0-9]{0,31}$/;
const ACCOUNT_ID_RE = /^[A-Za-z0-9_-]{22}$/;
const RID_RE = /^[A-Za-z0-9_-]{43}$/;
const CODE_RE = /^[0-9]{6}$/;

export function requireString(body: Record<string, unknown>, key: string): string {
	const v = body[key];
	if (typeof v !== "string") throw badRequest(`"${key}" must be a string`);
	return v;
}

export function requireB64urlBytes(body: Record<string, unknown>, key: string, exactLength?: number): Uint8Array {
	const bytes = decodeB64url(requireString(body, key));
	if (bytes === null) throw badRequest(`"${key}" is not valid base64url`);
	if (exactLength !== undefined && bytes.byteLength !== exactLength) {
		throw badRequest(`"${key}" must decode to ${exactLength} bytes`);
	}
	return bytes;
}

export function requireUuid(value: string, what: string): string {
	if (!UUID_RE.test(value)) throw badRequest(`${what} must be a UUID`);
	return value.toUpperCase();
}

export function requireDeviceName(body: Record<string, unknown>, key: string): string {
	const name = requireString(body, key).trim();
	if (name.length === 0 || [...name].length > MAX_DEVICE_NAME_CHARS) {
		throw badRequest(`"${key}" must be 1–${MAX_DEVICE_NAME_CHARS} characters`);
	}
	return name;
}

export function requirePlatform(body: Record<string, unknown>, key: string): string {
	const p = requireString(body, key);
	if (!PLATFORM_RE.test(p)) throw badRequest(`"${key}" is not a valid platform`);
	return p;
}

export const isAccountId = (s: string): boolean => ACCOUNT_ID_RE.test(s);
export const isRid = (s: string): boolean => RID_RE.test(s);
export const isPairingCode = (s: string): boolean => CODE_RE.test(s);
export const isUuid = (s: string): boolean => UUID_RE.test(s);
