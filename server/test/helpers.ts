import { env, exports } from "cloudflare:workers";
import { encodeB64url, sha256B64url } from "../src/lib/b64url";
import { accountStub, pairingStub } from "../src/lib/stubs";

export const BASE = "https://cloud.test";

export function randomIp(): string {
	const b = crypto.getRandomValues(new Uint8Array(3));
	return `10.${b[0]}.${b[1]}.${b[2]}`;
}

export function randomUuid(): string {
	return crypto.randomUUID().toUpperCase();
}

export async function call(path: string, init: RequestInit = {}): Promise<Response> {
	const headers = new Headers(init.headers);
	if (!headers.has("cf-connecting-ip")) headers.set("cf-connecting-ip", randomIp());
	if (init.body !== undefined && !headers.has("content-type")) headers.set("content-type", "application/json");
	return exports.default.fetch(new Request(`${BASE}${path}`, { ...init, headers }));
}

export interface TestAccount {
	accountId: string;
	authKey: Uint8Array;
	deviceId: string;
	headers: (deviceId?: string | null) => Record<string, string>;
}

export function bearer(accountId: string, authKey: Uint8Array): string {
	return `Bearer ${accountId}.${encodeB64url(authKey)}`;
}

/** A random well-formed account id (stands in for the HKDF-derived one). */
export function randomAccountId(): string {
	return encodeB64url(crypto.getRandomValues(new Uint8Array(16)));
}

export async function newAccount(): Promise<TestAccount> {
	const authKey = crypto.getRandomValues(new Uint8Array(32));
	const res = await call("/v1/accounts", {
		method: "POST",
		body: JSON.stringify({ authVerifier: await sha256B64url(authKey), accountId: randomAccountId() }),
	});
	if (res.status !== 201) throw new Error(`account create failed: ${res.status} ${await res.text()}`);
	const { accountId } = await res.json<{ accountId: string }>();
	const deviceId = randomUuid();
	return {
		accountId,
		authKey,
		deviceId,
		headers: (device: string | null = deviceId) => {
			const h: Record<string, string> = { authorization: bearer(accountId, authKey) };
			if (device !== null) h["x-lume-device"] = device;
			return h;
		},
	};
}

/** A deterministic 43-char rid for a label (stands in for the HMAC). */
export async function rid(label: string): Promise<string> {
	return sha256B64url(label);
}

export function ciphertext(bytes = 64): string {
	const out = new Uint8Array(bytes);
	for (let i = 0; i < bytes; i += 65_536) crypto.getRandomValues(out.subarray(i, Math.min(bytes, i + 65_536)));
	return encodeB64url(out);
}

export interface PushRecord {
	rid: string;
	baseVersion: number;
	deleted: boolean;
	ciphertext: string | null;
}

export async function push(acct: TestAccount, records: PushRecord[]): Promise<Response> {
	return call("/v1/push", { method: "POST", headers: acct.headers(), body: JSON.stringify({ records }) });
}

export async function changes(acct: TestAccount, since: number, limit?: number): Promise<Response> {
	const q = limit === undefined ? `since=${since}` : `since=${since}&limit=${limit}`;
	return call(`/v1/changes?${q}`, { headers: acct.headers() });
}

export const accountDO = (accountId: string) => accountStub(env, accountId);
export const pairingDO = (code: string) => pairingStub(env, code);

export interface WireRecord {
	rid: string;
	version: number;
	seq: number;
	deleted: boolean;
	ciphertext: string | null;
	updatedAt: number;
}

export interface ChangesBody {
	records: WireRecord[];
	nextSeq: number;
	hasMore: boolean;
}

export interface PushBody {
	results: (
		| { rid: string; status: "ok"; version: number; seq: number }
		| { rid: string; status: "conflict"; current: WireRecord }
	)[];
	nextSeq: number;
}
