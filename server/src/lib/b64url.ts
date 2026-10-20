// base64url without padding (RFC 4648 §5), strict on input.

const B64URL_RE = /^[A-Za-z0-9_-]*$/;

/** True when `s` is canonical unpadded base64url (correct length, no stray bits). */
export function isB64url(s: string): boolean {
	return B64URL_RE.test(s) && s.length % 4 !== 1;
}

export function decodeB64url(s: string): Uint8Array | null {
	if (!isB64url(s)) return null;
	const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
	let bin: string;
	try {
		bin = atob(b64);
	} catch {
		return null;
	}
	const out = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
	// Reject non-canonical encodings (non-zero trailing bits) by round-tripping.
	if (encodeB64url(out) !== s) return null;
	return out;
}

const CHUNK = 0x8000;

export function encodeB64url(bytes: Uint8Array | ArrayBuffer): string {
	const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
	let bin = "";
	for (let i = 0; i < view.length; i += CHUNK) {
		bin += String.fromCharCode(...view.subarray(i, i + CHUNK));
	}
	return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomB64url(byteLength: number): string {
	return encodeB64url(crypto.getRandomValues(new Uint8Array(byteLength)));
}

export async function sha256B64url(data: Uint8Array | string): Promise<string> {
	const input = typeof data === "string" ? new TextEncoder().encode(data) : data;
	return encodeB64url(await crypto.subtle.digest("SHA-256", input));
}

/** Constant-time comparison of two strings (lengths are not secret here). */
export function timingSafeEqualStr(a: string, b: string): boolean {
	const enc = new TextEncoder();
	const ab = enc.encode(a);
	const bb = enc.encode(b);
	if (ab.byteLength !== bb.byteLength) return false;
	return crypto.subtle.timingSafeEqual(ab, bb);
}
