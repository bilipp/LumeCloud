// AccountDO: one SQLite-backed object per account (idFromName(accountId), EU).
//
// It owns the auth verifier, the device list, the record store and change
// feed, quotas, tombstone compaction, the inactivity purge and the realtime
// sockets. Every RPC returns an `Outcome` so failures cross the RPC boundary as
// data instead of exceptions.
//
// Storage is only ever created by `create()`. Every other entry point first
// checks that the schema exists and answers `404 account_deleted` otherwise,
// so probing an unknown account id never allocates (billable) storage.

import { DurableObject } from "cloudflare:workers";
import { timingSafeEqualStr } from "../lib/b64url";
import { type Outcome, fail, ok } from "../lib/errors";
import {
	CHANGES_MAX_LIMIT,
	DAY_MS,
	INACTIVITY_TTL_MS,
	MAX_ACCOUNT_BYTES,
	MAX_ACCOUNT_RECORDS,
	MAX_ACCOUNT_TOMBSTONES,
	MAX_DEVICES,
	TOMBSTONE_TTL_MS,
} from "../lib/limits";
import type {
	AccountInfo,
	AuthContext,
	ChangesPage,
	Device,
	DeviceInput,
	PushItem,
	PushResponse,
	PushResult,
	StoredRecord,
} from "../lib/types";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS devices (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	platform   TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	last_seen  INTEGER NOT NULL,
	revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS records (
	rid        TEXT PRIMARY KEY,
	version    INTEGER NOT NULL,
	seq        INTEGER NOT NULL,
	deleted    INTEGER NOT NULL,
	ciphertext BLOB,
	size       INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS records_seq ON records(seq);
CREATE INDEX IF NOT EXISTS records_tombstones ON records(updated_at) WHERE deleted = 1;
`;

/** Internal headers the Worker sets when it forwards the socket upgrade. */
export const SOCKET_VERIFIER_HEADER = "x-lume-internal-verifier";
export const SOCKET_DEVICE_HEADER = "x-lume-internal-device";

/** WebSocket close codes (application range). */
const CLOSE_DEVICE_REVOKED = 4401;
const CLOSE_ACCOUNT_DELETED = 4404;

interface Meta {
	accountId: string;
	verifier: string;
	createdAt: number;
	nextSeq: number;
	usedBytes: number;
	recordCount: number;
	tombstoneCount: number;
	compactedSeq: number;
	lastSeen: number;
}

const META_KEYS: Record<keyof Meta, string> = {
	accountId: "account_id",
	verifier: "auth_verifier",
	createdAt: "created_at",
	nextSeq: "next_seq",
	usedBytes: "used_bytes",
	recordCount: "record_count",
	tombstoneCount: "tombstone_count",
	compactedSeq: "compacted_seq",
	lastSeen: "last_seen",
};

type MetaRow = { key: string; value: SqlStorageValue };
type DeviceRow = {
	id: string;
	name: string;
	platform: string;
	created_at: number;
	last_seen: number;
	revoked: number;
};
type RecordRow = {
	rid: string;
	version: number;
	seq: number;
	deleted: number;
	ciphertext: ArrayBuffer | null;
	updated_at: number;
};
type RecordStateRow = { rid: string; version: number; deleted: number; size: number };

const utcDay = (ms: number): number => Math.floor(ms / DAY_MS);

function toDevice(row: DeviceRow): Device {
	return {
		id: row.id,
		name: row.name,
		platform: row.platform,
		createdAt: row.created_at,
		lastSeen: row.last_seen,
		revoked: row.revoked !== 0,
	};
}

function toRecord(row: RecordRow): StoredRecord {
	return {
		rid: row.rid,
		version: row.version,
		seq: row.seq,
		deleted: row.deleted !== 0,
		ciphertext: row.deleted !== 0 ? null : row.ciphertext,
		updatedAt: row.updated_at,
	};
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
	const copy = new Uint8Array(bytes.byteLength);
	copy.set(bytes);
	return copy.buffer;
}

export class AccountDO extends DurableObject<Env> {
	/** Cached "schema exists" flag; reset whenever storage is wiped. */
	private present: boolean | undefined;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		// Heartbeats are answered by the runtime without waking the object.
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
	}

	private get sql(): SqlStorage {
		return this.ctx.storage.sql;
	}

	// MARK: - Lifecycle

	/** Initialises a fresh account. Returns false when the id is already taken. */
	async create(accountId: string, verifier: string, now: number): Promise<{ created: boolean }> {
		if (this.exists()) return { created: false };
		this.ctx.storage.transactionSync(() => {
			this.sql.exec(SCHEMA);
			const initial: Meta = {
				accountId,
				verifier,
				createdAt: now,
				nextSeq: 1,
				usedBytes: 0,
				recordCount: 0,
				tombstoneCount: 0,
				compactedSeq: 0,
				lastSeen: now,
			};
			for (const [field, key] of Object.entries(META_KEYS) as [keyof Meta, string][]) {
				this.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?)", key, initial[field]);
			}
		});
		this.present = true;
		await this.ctx.storage.setAlarm(now + INACTIVITY_TTL_MS);
		return { created: true };
	}

	async info(auth: AuthContext): Promise<Outcome<AccountInfo>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const m = authed.value;
		return ok({
			accountId: m.accountId,
			createdAt: m.createdAt,
			usedBytes: m.usedBytes,
			recordCount: m.recordCount,
			nextSeq: m.nextSeq,
		});
	}

	async deleteAccount(auth: AuthContext): Promise<Outcome<null>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		await this.wipe();
		return ok(null);
	}

	// MARK: - Devices

	async registerDevice(auth: AuthContext, input: DeviceInput): Promise<Outcome<Device>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const now = Date.now();
		const existing = this.sql.exec<DeviceRow>("SELECT * FROM devices WHERE id = ?", input.id).toArray()[0];

		if (existing === undefined) {
			const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM devices").one().n;
			if (count >= MAX_DEVICES) return fail(507, "quota_exceeded", "Too many devices on this account");
			this.sql.exec(
				"INSERT INTO devices (id, name, platform, created_at, last_seen, revoked) VALUES (?, ?, ?, ?, ?, 0)",
				input.id,
				input.name,
				input.platform,
				now,
				now,
			);
			return ok({ id: input.id, name: input.name, platform: input.platform, createdAt: now, lastSeen: now, revoked: false });
		}

		if (existing.revoked !== 0) return fail(401, "device_revoked");
		// Idempotent: only write when something actually changed (row writes are billed).
		const stale = utcDay(existing.last_seen) !== utcDay(now);
		if (existing.name !== input.name || existing.platform !== input.platform || stale) {
			const lastSeen = stale ? now : existing.last_seen;
			this.sql.exec(
				"UPDATE devices SET name = ?, platform = ?, last_seen = ? WHERE id = ?",
				input.name,
				input.platform,
				lastSeen,
				input.id,
			);
			return ok(toDevice({ ...existing, name: input.name, platform: input.platform, last_seen: lastSeen }));
		}
		return ok(toDevice(existing));
	}

	async listDevices(auth: AuthContext): Promise<Outcome<Device[]>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const rows = this.sql.exec<DeviceRow>("SELECT * FROM devices ORDER BY created_at, id").toArray();
		return ok(rows.map(toDevice));
	}

	async revokeDevice(auth: AuthContext, deviceId: string): Promise<Outcome<null>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const row = this.sql.exec<{ revoked: number }>("SELECT revoked FROM devices WHERE id = ?", deviceId).toArray()[0];
		if (row === undefined) return fail(404, "not_found", "Unknown device");
		if (row.revoked === 0) this.sql.exec("UPDATE devices SET revoked = 1 WHERE id = ?", deviceId);
		for (const ws of this.ctx.getWebSockets(deviceTag(deviceId))) {
			ws.close(CLOSE_DEVICE_REVOKED, "device_revoked");
		}
		return ok(null);
	}

	// MARK: - Change feed

	async changes(auth: AuthContext, since: number, limit: number): Promise<Outcome<ChangesPage>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const { compactedSeq } = authed.value;
		if (since > 0 && since < compactedSeq) return fail(410, "resync_required");

		let pageSize = Math.min(Math.max(limit, 1), CHANGES_MAX_LIMIT);
		if (since === 0 && compactedSeq > 0) {
			// A full snapshot is paged with `since=<last seq>`. If a page ended below
			// compactedSeq, the follow-up request would be answered with 410 and the
			// client could never finish its resync. So the first snapshot page always
			// reaches past compactedSeq (bounded by the 10 MiB account quota).
			const below = this.sql
				.exec<{ n: number }>("SELECT COUNT(*) AS n FROM records WHERE deleted = 0 AND seq <= ?", compactedSeq)
				.one().n;
			pageSize = Math.max(pageSize, below);
		}

		const rows =
			since === 0
				? this.sql
						.exec<RecordRow>(
							"SELECT rid, version, seq, deleted, ciphertext, updated_at FROM records WHERE deleted = 0 ORDER BY seq LIMIT ?",
							pageSize + 1,
						)
						.toArray()
				: this.sql
						.exec<RecordRow>(
							"SELECT rid, version, seq, deleted, ciphertext, updated_at FROM records WHERE seq > ? ORDER BY seq LIMIT ?",
							since,
							pageSize + 1,
						)
						.toArray();

		const hasMore = rows.length > pageSize;
		const page = hasMore ? rows.slice(0, pageSize) : rows;
		const last = page[page.length - 1];
		return ok({ records: page.map(toRecord), nextSeq: last === undefined ? since : last.seq, hasMore });
	}

	// MARK: - Push

	async push(auth: AuthContext, items: PushItem[]): Promise<Outcome<PushResponse>> {
		const authed = await this.authenticate(auth);
		if (!authed.ok) return authed;
		const meta = authed.value;
		const now = Date.now();

		// 1. Plan every write against a working copy of the current state, so
		//    duplicate rids within one request behave as if applied in order.
		const state = new Map<string, { version: number; deleted: boolean; size: number; exists: boolean }>();
		const distinct = [...new Set(items.map((i) => i.rid))];
		for (const row of this.sql
			.exec<RecordStateRow>(
				"SELECT r.rid AS rid, r.version AS version, r.deleted AS deleted, r.size AS size FROM records r JOIN json_each(?) j ON r.rid = j.value",
				JSON.stringify(distinct),
			)
			.toArray()) {
			state.set(row.rid, { version: row.version, deleted: row.deleted !== 0, size: row.size, exists: true });
		}

		type Planned = { index: number; item: PushItem; version: number } | { index: number; item: PushItem; conflict: true };
		const plan: Planned[] = [];
		let dBytes = 0;
		let dRecords = 0;
		let dTombstones = 0;
		items.forEach((item, index) => {
			const cur = state.get(item.rid) ?? { version: 0, deleted: true, size: 0, exists: false };
			if (item.baseVersion !== cur.version) {
				plan.push({ index, item, conflict: true });
				return;
			}
			const newSize = item.deleted || item.ciphertext === null ? 0 : item.ciphertext.byteLength;
			const wasLive = cur.exists && !cur.deleted;
			const wasTombstone = cur.exists && cur.deleted;
			dBytes += newSize - (wasLive ? cur.size : 0);
			dRecords += (item.deleted ? 0 : 1) - (wasLive ? 1 : 0);
			dTombstones += (item.deleted ? 1 : 0) - (wasTombstone ? 1 : 0);
			state.set(item.rid, { version: cur.version + 1, deleted: item.deleted, size: newSize, exists: true });
			plan.push({ index, item, version: cur.version + 1 });
		});

		// 2. Quota is checked for the whole request before anything is applied.
		//    A request that only shrinks usage is always allowed.
		if (
			(dBytes > 0 && meta.usedBytes + dBytes > MAX_ACCOUNT_BYTES) ||
			(dRecords > 0 && meta.recordCount + dRecords > MAX_ACCOUNT_RECORDS)
		) {
			return fail(507, "quota_exceeded");
		}
		if (dTombstones > 0 && meta.tombstoneCount + dTombstones > MAX_ACCOUNT_TOMBSTONES) {
			return fail(507, "quota_exceeded", "Too many deleted records pending compaction");
		}

		// 3. Apply atomically.
		const results: PushResult[] = new Array(items.length);
		let nextSeq = meta.nextSeq;
		const conflicts: { index: number; rid: string }[] = [];
		this.ctx.storage.transactionSync(() => {
			for (const p of plan) {
				if ("conflict" in p) {
					conflicts.push({ index: p.index, rid: p.item.rid });
					continue;
				}
				const seq = nextSeq++;
				const ct = p.item.deleted || p.item.ciphertext === null ? null : toArrayBuffer(p.item.ciphertext);
				this.sql.exec(
					`INSERT INTO records (rid, version, seq, deleted, ciphertext, size, updated_at)
					 VALUES (?, ?, ?, ?, ?, ?, ?)
					 ON CONFLICT(rid) DO UPDATE SET
					   version = excluded.version, seq = excluded.seq, deleted = excluded.deleted,
					   ciphertext = excluded.ciphertext, size = excluded.size, updated_at = excluded.updated_at`,
					p.item.rid,
					p.version,
					seq,
					p.item.deleted ? 1 : 0,
					ct,
					ct === null ? 0 : ct.byteLength,
					now,
				);
				results[p.index] = { rid: p.item.rid, status: "ok", version: p.version, seq };
			}
			if (nextSeq !== meta.nextSeq) {
				this.setMeta("nextSeq", nextSeq);
				if (dBytes !== 0) this.setMeta("usedBytes", meta.usedBytes + dBytes);
				if (dRecords !== 0) this.setMeta("recordCount", meta.recordCount + dRecords);
				if (dTombstones !== 0) this.setMeta("tombstoneCount", meta.tombstoneCount + dTombstones);
			}
		});

		// Conflicts report the record as it stands after this request's own writes.
		for (const c of conflicts) {
			const row = this.sql
				.exec<RecordRow>("SELECT rid, version, seq, deleted, ciphertext, updated_at FROM records WHERE rid = ?", c.rid)
				.toArray()[0];
			const current: StoredRecord =
				row === undefined
					? { rid: c.rid, version: 0, seq: 0, deleted: true, ciphertext: null, updatedAt: 0 }
					: toRecord(row);
			results[c.index] = { rid: c.rid, status: "conflict", current };
		}

		if (nextSeq !== meta.nextSeq) {
			this.broadcast(nextSeq - 1);
			if (dTombstones > 0) await this.ensureCompactionAlarm(now);
		}
		return ok({ results, nextSeq });
	}

	// MARK: - Realtime

	override async fetch(request: Request): Promise<Response> {
		const verifier = request.headers.get(SOCKET_VERIFIER_HEADER);
		if (verifier === null || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
			return Response.json({ error: "bad_request" }, { status: 400 });
		}
		const deviceId = request.headers.get(SOCKET_DEVICE_HEADER);
		const authed = await this.authenticate({ verifier, deviceId });
		if (!authed.ok) {
			return Response.json({ error: authed.error }, { status: authed.status });
		}
		const [client, server] = Object.values(new WebSocketPair()) as [WebSocket, WebSocket];
		this.ctx.acceptWebSocket(server, deviceId === null ? [] : [deviceTag(deviceId)]);
		return new Response(null, { status: 101, webSocket: client });
	}

	override async webSocketMessage(): Promise<void> {
		// Clients only send "ping", which the auto-response answers without
		// waking the object. Anything else is ignored.
	}

	override async webSocketClose(): Promise<void> {
		// The runtime completes the close handshake (web_socket_auto_reply_to_close).
	}

	override async webSocketError(): Promise<void> {}

	private broadcast(seq: number): void {
		const message = JSON.stringify({ type: "seq", seq });
		for (const ws of this.ctx.getWebSockets()) {
			try {
				ws.send(message);
			} catch {
				// A socket that is closing can throw; the client will pull on reconnect.
			}
		}
	}

	// MARK: - Alarms

	override async alarm(): Promise<void> {
		if (!this.exists()) return;
		const now = Date.now();
		const meta = this.readMeta();
		if (now - meta.lastSeen >= INACTIVITY_TTL_MS) {
			await this.wipe();
			return;
		}
		this.compact(now, meta);
		await this.ctx.storage.setAlarm(this.nextAlarmTime(now));
	}

	/** Purges tombstones older than the TTL and advances compactedSeq. */
	private compact(now: number, meta: Meta): void {
		const cutoff = now - TOMBSTONE_TTL_MS;
		const purge = this.sql
			.exec<{ n: number; maxSeq: number | null }>(
				"SELECT COUNT(*) AS n, MAX(seq) AS maxSeq FROM records WHERE deleted = 1 AND updated_at <= ?",
				cutoff,
			)
			.one();
		if (purge.n === 0 || purge.maxSeq === null) return;
		const maxSeq = purge.maxSeq;
		this.ctx.storage.transactionSync(() => {
			this.sql.exec("DELETE FROM records WHERE deleted = 1 AND updated_at <= ?", cutoff);
			this.setMeta("compactedSeq", Math.max(meta.compactedSeq, maxSeq));
			this.setMeta("tombstoneCount", Math.max(0, meta.tombstoneCount - purge.n));
		});
	}

	/** Earliest of: inactivity deadline, oldest tombstone expiry; at most daily. */
	private nextAlarmTime(now: number): number {
		const meta = this.readMeta();
		const oldest = this.sql
			.exec<{ t: number | null }>("SELECT MIN(updated_at) AS t FROM records WHERE deleted = 1")
			.one().t;
		const inactivityDue = meta.lastSeen + INACTIVITY_TTL_MS;
		const tombstoneDue = oldest === null ? Number.POSITIVE_INFINITY : oldest + TOMBSTONE_TTL_MS;
		return Math.max(Math.min(inactivityDue, tombstoneDue), now + DAY_MS);
	}

	/** Makes sure a new tombstone gets compacted on time, without re-arming per push. */
	private async ensureCompactionAlarm(now: number): Promise<void> {
		const due = now + TOMBSTONE_TTL_MS + DAY_MS;
		const current = await this.ctx.storage.getAlarm();
		if (current === null || current > due) await this.ctx.storage.setAlarm(due);
	}

	// MARK: - Point-in-time recovery (operator only)

	/**
	 * Restores this account's whole SQLite database to a point in the last 30
	 * days, then restarts the object. Not reachable through any public route:
	 * only the temporary admin Worker in `admin/` calls it (see README).
	 * Returns the bookmark restored to and an undo bookmark (the state just
	 * before the restore), which can be passed back in to revert.
	 */
	async pitrRestore(target: { at: number } | { bookmark: string }): Promise<{ bookmark: string; undoBookmark: string }> {
		const storage = this.ctx.storage;
		const bookmark = "bookmark" in target ? target.bookmark : await storage.getBookmarkForTime(target.at);
		const undoBookmark = await storage.onNextSessionRestoreBookmark(bookmark);
		// Restart after this call returns so the caller still gets the bookmarks.
		setTimeout(() => this.ctx.abort("pitr-restore"), 0);
		return { bookmark, undoBookmark };
	}

	// MARK: - Auth & bookkeeping

	/**
	 * Existence → verifier (constant time) → device revocation, then the
	 * once-per-UTC-day lastSeen bookkeeping.
	 */
	private async authenticate(auth: AuthContext): Promise<Outcome<Meta>> {
		if (!this.exists()) return fail(404, "account_deleted");
		const meta = this.readMeta();
		if (!timingSafeEqualStr(meta.verifier, auth.verifier)) return fail(401, "bad_auth");

		const now = Date.now();
		const today = utcDay(now);
		if (auth.deviceId !== null) {
			const device = this.sql
				.exec<{ revoked: number; last_seen: number }>("SELECT revoked, last_seen FROM devices WHERE id = ?", auth.deviceId)
				.toArray()[0];
			if (device !== undefined) {
				if (device.revoked !== 0) return fail(401, "device_revoked");
				if (utcDay(device.last_seen) !== today) {
					this.sql.exec("UPDATE devices SET last_seen = ? WHERE id = ?", now, auth.deviceId);
				}
			}
		}

		if (utcDay(meta.lastSeen) !== today) {
			this.setMeta("lastSeen", now);
			meta.lastSeen = now;
			// The alarm handler re-arms itself; this only repairs a missing alarm.
			if ((await this.ctx.storage.getAlarm()) === null) {
				await this.ctx.storage.setAlarm(this.nextAlarmTime(now));
			}
		}
		return ok(meta);
	}

	private exists(): boolean {
		if (this.present === undefined) {
			this.present =
				this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").toArray().length > 0;
		}
		return this.present;
	}

	private readMeta(): Meta {
		const byKey = new Map<string, SqlStorageValue>();
		for (const row of this.sql.exec<MetaRow>("SELECT key, value FROM meta")) byKey.set(row.key, row.value);
		const num = (k: keyof Meta): number => {
			const v = byKey.get(META_KEYS[k]);
			return typeof v === "number" ? v : 0;
		};
		const str = (k: keyof Meta): string => {
			const v = byKey.get(META_KEYS[k]);
			return typeof v === "string" ? v : "";
		};
		return {
			accountId: str("accountId"),
			verifier: str("verifier"),
			createdAt: num("createdAt"),
			nextSeq: num("nextSeq"),
			usedBytes: num("usedBytes"),
			recordCount: num("recordCount"),
			tombstoneCount: num("tombstoneCount"),
			compactedSeq: num("compactedSeq"),
			lastSeen: num("lastSeen"),
		};
	}

	private setMeta(field: keyof Meta, value: number | string): void {
		this.sql.exec("UPDATE meta SET value = ? WHERE key = ?", value, META_KEYS[field]);
	}

	/** Deletes everything (data and alarm) and disconnects every socket. */
	private async wipe(): Promise<void> {
		for (const ws of this.ctx.getWebSockets()) {
			try {
				ws.close(CLOSE_ACCOUNT_DELETED, "account_deleted");
			} catch {
				// already closing
			}
		}
		await this.ctx.storage.deleteAll();
		this.present = false;
	}
}

function deviceTag(deviceId: string): string {
	return `device:${deviceId}`;
}
