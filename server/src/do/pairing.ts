// PairingDO: one object per live 6-digit pairing code (EU).
//
// Holds the new device's public key and display info, a hash of its poll
// token, and — once a joined device seals it — the HPKE result. The first seal
// wins. An alarm deletes the object when the code expires, and the object
// deletes itself right after the sealed result has been fetched once.

import { DurableObject } from "cloudflare:workers";
import { sha256B64url, timingSafeEqualStr } from "../lib/b64url";
import { type Outcome, fail, ok } from "../lib/errors";
import type { PairingInfo, PairingRequest, PairingResult } from "../lib/types";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS pairing (
	id              INTEGER PRIMARY KEY CHECK (id = 1),
	public_key      TEXT NOT NULL,
	device_name     TEXT NOT NULL,
	platform        TEXT NOT NULL,
	poll_token_hash TEXT NOT NULL,
	expires_at      INTEGER NOT NULL,
	sealed_enc      TEXT,
	sealed_ct       TEXT
);
`;

type PairingRow = {
	public_key: string;
	device_name: string;
	platform: string;
	poll_token_hash: string;
	expires_at: number;
	sealed_enc: string | null;
	sealed_ct: string | null;
};

const expired = (): Outcome<never> => fail(404, "not_found", "Pairing code expired or unknown");

export class PairingDO extends DurableObject<Env> {
	/** Starts a pairing. Returns false when this code already holds a live pairing. */
	async open(request: PairingRequest, pollToken: string, expiresAt: number): Promise<{ created: boolean }> {
		// Hash first: no awaits that could let a concurrent open() interleave
		// between the liveness check and the insert.
		const pollTokenHash = await sha256B64url(pollToken);
		const live = await this.load();
		if (live !== null) return { created: false };
		this.ctx.storage.transactionSync(() => {
			this.ctx.storage.sql.exec(SCHEMA);
			this.ctx.storage.sql.exec(
				"INSERT INTO pairing (id, public_key, device_name, platform, poll_token_hash, expires_at) VALUES (1, ?, ?, ?, ?, ?)",
				request.publicKey,
				request.deviceName,
				request.platform,
				pollTokenHash,
				expiresAt,
			);
		});
		await this.ctx.storage.setAlarm(expiresAt);
		return { created: true };
	}

	async lookup(): Promise<Outcome<PairingInfo>> {
		const row = await this.load();
		if (row === null) return expired();
		return ok({
			publicKey: row.public_key,
			deviceName: row.device_name,
			platform: row.platform,
			expiresAt: row.expires_at,
		});
	}

	async seal(enc: string, ciphertext: string): Promise<Outcome<null>> {
		const row = await this.load();
		if (row === null) return expired();
		if (row.sealed_enc !== null) return fail(409, "pairing_already_sealed");
		this.ctx.storage.sql.exec("UPDATE pairing SET sealed_enc = ?, sealed_ct = ? WHERE id = 1", enc, ciphertext);
		return ok(null);
	}

	async result(pollToken: string): Promise<Outcome<PairingResult>> {
		const presented = await sha256B64url(pollToken);
		const row = await this.load();
		if (row === null) return expired();
		// A wrong token looks exactly like an unknown code.
		if (!timingSafeEqualStr(row.poll_token_hash, presented)) return expired();
		if (row.sealed_enc === null || row.sealed_ct === null) return ok({ status: "pending" });
		await this.ctx.storage.deleteAll();
		return ok({ status: "sealed", enc: row.sealed_enc, ciphertext: row.sealed_ct });
	}

	override async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}

	/** The live pairing, or null. Never creates storage; drops expired state. */
	private async load(): Promise<PairingRow | null> {
		const sql = this.ctx.storage.sql;
		const hasTable =
			sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'pairing'").toArray().length > 0;
		if (!hasTable) return null;
		const row = sql.exec<PairingRow>("SELECT * FROM pairing WHERE id = 1").toArray()[0];
		if (row === undefined) return null;
		if (row.expires_at <= Date.now()) {
			await this.ctx.storage.deleteAll();
			return null;
		}
		return row;
	}
}
