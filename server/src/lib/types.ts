// Shared shapes between the Worker router and the Durable Objects.

/** Credentials checked by AccountDO on every authenticated call. */
export interface AuthContext {
	/** base64url(SHA-256(authKey)), computed by the Worker. */
	verifier: string;
	/** X-Lume-Device, or null on routes that don't require it. */
	deviceId: string | null;
}

export interface AccountInfo {
	accountId: string;
	createdAt: number;
	usedBytes: number;
	recordCount: number;
	nextSeq: number;
}

export interface Device {
	id: string;
	name: string;
	platform: string;
	createdAt: number;
	lastSeen: number;
	revoked: boolean;
}

export interface DeviceInput {
	id: string;
	name: string;
	platform: string;
}

/** A record as stored; ciphertext stays binary until the Worker encodes it. */
export interface StoredRecord {
	rid: string;
	version: number;
	seq: number;
	deleted: boolean;
	ciphertext: ArrayBuffer | null;
	updatedAt: number;
}

/** A record on the wire (/changes, push conflicts). */
export interface WireRecord {
	rid: string;
	version: number;
	seq: number;
	deleted: boolean;
	ciphertext: string | null;
	updatedAt: number;
}

export interface ChangesPage {
	records: StoredRecord[];
	nextSeq: number;
	hasMore: boolean;
}

export interface PushItem {
	rid: string;
	baseVersion: number;
	deleted: boolean;
	ciphertext: Uint8Array | null;
}

export type PushResult =
	| { rid: string; status: "ok"; version: number; seq: number }
	| { rid: string; status: "conflict"; current: StoredRecord };

export interface PushResponse {
	results: PushResult[];
	nextSeq: number;
}

export interface PairingRequest {
	publicKey: string;
	deviceName: string;
	platform: string;
}

export interface PairingInfo extends PairingRequest {
	expiresAt: number;
}

export type PairingResult = { status: "pending" } | { status: "sealed"; enc: string; ciphertext: string };
