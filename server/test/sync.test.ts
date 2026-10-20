import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_ACCOUNT_BYTES, MAX_ACCOUNT_RECORDS, MAX_RECORD_BYTES } from "../src/lib/limits";
import {
	type ChangesBody,
	type PushBody,
	accountDO,
	call,
	changes,
	ciphertext,
	newAccount,
	push,
	rid,
} from "./helpers";

const DAY = 24 * 60 * 60 * 1000;

async function seed(acct: Awaited<ReturnType<typeof newAccount>>, labels: string[]) {
	const rids = await Promise.all(labels.map((l) => rid(`${acct.accountId}/${l}`)));
	const res = await push(
		acct,
		rids.map((r) => ({ rid: r, baseVersion: 0, deleted: false, ciphertext: ciphertext() })),
	);
	expect(res.status).toBe(200);
	return { rids, body: await res.json<PushBody>() };
}

async function meInfo(acct: Awaited<ReturnType<typeof newAccount>>) {
	return (await call("/v1/accounts/me", { headers: acct.headers() })).json<{
		usedBytes: number;
		recordCount: number;
		nextSeq: number;
	}>();
}

describe("push & changes", () => {
	it("assigns versions and seqs; changes returns them in seq order", async () => {
		const acct = await newAccount();
		const { rids, body } = await seed(acct, ["a", "b", "c"]);
		expect(body.results.map((r) => r.status)).toEqual(["ok", "ok", "ok"]);
		expect(body.results.map((r) => (r.status === "ok" ? [r.version, r.seq] : null))).toEqual([
			[1, 1],
			[1, 2],
			[1, 3],
		]);
		expect(body.nextSeq).toBe(4);

		const page = await (await changes(acct, 0)).json<ChangesBody>();
		expect(page.records.map((r) => r.rid)).toEqual(rids);
		expect(page.records.map((r) => r.seq)).toEqual([1, 2, 3]);
		expect(page.nextSeq).toBe(3);
		expect(page.hasMore).toBe(false);
		expect(page.records[0]?.ciphertext).toMatch(/^[A-Za-z0-9_-]+$/);

		const info = await meInfo(acct);
		expect(info).toMatchObject({ recordCount: 3, usedBytes: 3 * 64, nextSeq: 4 });
	});

	it("an update moves the record to its latest seq and it appears once", async () => {
		const acct = await newAccount();
		const { rids } = await seed(acct, ["a", "b", "c"]);
		const updated = ciphertext(32);
		const res = await push(acct, [{ rid: rids[0] ?? "", baseVersion: 1, deleted: false, ciphertext: updated }]);
		const body = await res.json<PushBody>();
		expect(body.results[0]).toMatchObject({ status: "ok", version: 2, seq: 4 });

		const all = await (await changes(acct, 0)).json<ChangesBody>();
		expect(all.records.map((r) => r.rid)).toEqual([rids[1], rids[2], rids[0]]);
		expect(all.records[2]).toMatchObject({ version: 2, seq: 4, ciphertext: updated, deleted: false });

		const delta = await (await changes(acct, 3)).json<ChangesBody>();
		expect(delta.records.map((r) => r.rid)).toEqual([rids[0]]);
		expect(delta.nextSeq).toBe(4);

		const empty = await (await changes(acct, 4)).json<ChangesBody>();
		expect(empty).toEqual({ records: [], nextSeq: 4, hasMore: false });

		expect((await meInfo(acct)).usedBytes).toBe(64 + 64 + 32);
	});

	it("pages with limit and hasMore", async () => {
		const acct = await newAccount();
		await seed(acct, ["a", "b", "c", "d", "e"]);
		const p1 = await (await changes(acct, 0, 2)).json<ChangesBody>();
		expect(p1.records.map((r) => r.seq)).toEqual([1, 2]);
		expect(p1.hasMore).toBe(true);
		const p2 = await (await changes(acct, p1.nextSeq, 2)).json<ChangesBody>();
		expect(p2.records.map((r) => r.seq)).toEqual([3, 4]);
		const p3 = await (await changes(acct, p2.nextSeq, 2)).json<ChangesBody>();
		expect(p3.records.map((r) => r.seq)).toEqual([5]);
		expect(p3.hasMore).toBe(false);
	});

	it("validates since/limit", async () => {
		const acct = await newAccount();
		expect((await changes(acct, 0, 0)).status).toBe(400);
		expect((await changes(acct, 0, 1001)).status).toBe(400);
		const neg = await call("/v1/changes?since=-1", { headers: acct.headers() });
		expect(neg.status).toBe(400);
	});

	it("a stale baseVersion conflicts without failing the rest", async () => {
		const acct = await newAccount();
		const { rids } = await seed(acct, ["a", "b"]);
		const fresh = await rid(`${acct.accountId}/fresh`);
		const res = await push(acct, [
			{ rid: rids[0] ?? "", baseVersion: 0, deleted: false, ciphertext: ciphertext() }, // stale
			{ rid: rids[1] ?? "", baseVersion: 1, deleted: false, ciphertext: ciphertext() }, // ok
			{ rid: fresh, baseVersion: 5, deleted: false, ciphertext: ciphertext() }, // never existed
		]);
		expect(res.status).toBe(200);
		const body = await res.json<PushBody>();
		const [c0, ok1, c2] = body.results;
		expect(c0).toMatchObject({ rid: rids[0], status: "conflict", current: { version: 1, seq: 1, deleted: false } });
		expect(c0?.status === "conflict" && c0.current.ciphertext).toBeTruthy();
		expect(ok1).toMatchObject({ status: "ok", version: 2, seq: 3 });
		expect(c2).toMatchObject({ status: "conflict", current: { rid: fresh, version: 0, deleted: true, ciphertext: null } });
		expect(body.nextSeq).toBe(4);
	});

	it("duplicate rids in one push apply in order", async () => {
		const acct = await newAccount();
		const r = await rid(`${acct.accountId}/dup`);
		const body = await (
			await push(acct, [
				{ rid: r, baseVersion: 0, deleted: false, ciphertext: ciphertext() },
				{ rid: r, baseVersion: 1, deleted: false, ciphertext: ciphertext() },
				{ rid: r, baseVersion: 1, deleted: false, ciphertext: ciphertext() },
			])
		).json<PushBody>();
		expect(body.results.map((x) => x.status)).toEqual(["ok", "ok", "conflict"]);
		expect(body.results[2]).toMatchObject({ current: { version: 2, seq: 2 } });
		expect((await meInfo(acct)).recordCount).toBe(1);
	});

	it("deletes leave tombstones; since=0 omits them", async () => {
		const acct = await newAccount();
		const { rids } = await seed(acct, ["a", "b"]);
		const del = await (
			await push(acct, [{ rid: rids[0] ?? "", baseVersion: 1, deleted: true, ciphertext: null }])
		).json<PushBody>();
		expect(del.results[0]).toMatchObject({ status: "ok", version: 2, seq: 3 });

		const delta = await (await changes(acct, 2)).json<ChangesBody>();
		expect(delta.records).toHaveLength(1);
		expect(delta.records[0]).toMatchObject({ rid: rids[0], deleted: true, ciphertext: null, version: 2, seq: 3 });

		const full = await (await changes(acct, 0)).json<ChangesBody>();
		expect(full.records.map((r) => r.rid)).toEqual([rids[1]]);

		expect(await meInfo(acct)).toMatchObject({ recordCount: 1, usedBytes: 64 });

		// A tombstone keeps its version: re-creating needs baseVersion 2.
		const stale = await (
			await push(acct, [{ rid: rids[0] ?? "", baseVersion: 0, deleted: false, ciphertext: ciphertext() }])
		).json<PushBody>();
		expect(stale.results[0]).toMatchObject({ status: "conflict", current: { version: 2, deleted: true } });
		const revived = await (
			await push(acct, [{ rid: rids[0] ?? "", baseVersion: 2, deleted: false, ciphertext: ciphertext() }])
		).json<PushBody>();
		expect(revived.results[0]).toMatchObject({ status: "ok", version: 3 });
		expect((await meInfo(acct)).recordCount).toBe(2);
	});

	it("rejects invalid records with bad_request", async () => {
		const acct = await newAccount();
		const r = await rid("x");
		for (const record of [
			{ rid: "short", baseVersion: 0, deleted: false, ciphertext: ciphertext() },
			{ rid: r, baseVersion: -1, deleted: false, ciphertext: ciphertext() },
			{ rid: r, baseVersion: 0, deleted: false, ciphertext: null },
			{ rid: r, baseVersion: 0, deleted: true, ciphertext: ciphertext() },
			{ rid: r, baseVersion: 0, deleted: false, ciphertext: "not base64url!" },
		]) {
			const res = await push(acct, [record]);
			expect(res.status).toBe(400);
			expect(await res.json()).toMatchObject({ error: "bad_request" });
		}
	});
});

describe("limits", () => {
	it("a record over 64 KiB rejects the whole push with 413", async () => {
		const acct = await newAccount();
		const res = await push(acct, [
			{ rid: await rid(`${acct.accountId}/ok`), baseVersion: 0, deleted: false, ciphertext: ciphertext() },
			{ rid: await rid(`${acct.accountId}/big`), baseVersion: 0, deleted: false, ciphertext: ciphertext(MAX_RECORD_BYTES + 1) },
		]);
		expect(res.status).toBe(413);
		expect(await res.json()).toMatchObject({ error: "record_too_large" });
		expect(await meInfo(acct)).toMatchObject({ recordCount: 0, nextSeq: 1 });
	});

	it("exactly 64 KiB is accepted", async () => {
		const acct = await newAccount();
		const res = await push(acct, [
			{ rid: await rid(`${acct.accountId}/max`), baseVersion: 0, deleted: false, ciphertext: ciphertext(MAX_RECORD_BYTES) },
		]);
		expect(res.status).toBe(200);
	});

	it("more than 500 records is 413", async () => {
		const acct = await newAccount();
		const records = await Promise.all(
			Array.from({ length: 501 }, async (_, i) => ({
				rid: await rid(`${acct.accountId}/${i}`),
				baseVersion: 0,
				deleted: false,
				ciphertext: ciphertext(4),
			})),
		);
		const res = await push(acct, records);
		expect(res.status).toBe(413);
		expect(await res.json()).toMatchObject({ error: "record_too_large" });
	});

	it("a body over 4 MiB is 413", async () => {
		const acct = await newAccount();
		const records = await Promise.all(
			Array.from({ length: 70 }, async (_, i) => ({
				rid: await rid(`${acct.accountId}/${i}`),
				baseVersion: 0,
				deleted: false,
				ciphertext: ciphertext(MAX_RECORD_BYTES),
			})),
		);
		const res = await push(acct, records);
		expect(res.status).toBe(413);
		expect(await meInfo(acct)).toMatchObject({ recordCount: 0 });
	});

	it("exceeding 10 MiB of ciphertext is 507 and nothing is applied", async () => {
		const acct = await newAccount();
		await seed(acct, ["a"]);
		await runInDurableObject(accountDO(acct.accountId), (_i, state) => {
			state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'used_bytes'", MAX_ACCOUNT_BYTES - 100);
		});
		const res = await push(acct, [
			{ rid: await rid(`${acct.accountId}/small`), baseVersion: 0, deleted: false, ciphertext: ciphertext(50) },
			{ rid: await rid(`${acct.accountId}/tips`), baseVersion: 0, deleted: false, ciphertext: ciphertext(60) },
		]);
		expect(res.status).toBe(507);
		expect(await res.json()).toMatchObject({ error: "quota_exceeded" });
		expect(await meInfo(acct)).toMatchObject({ recordCount: 1, nextSeq: 2 });

		// A push that shrinks usage is still allowed.
		const r = await rid(`${acct.accountId}/a`);
		const shrink = await push(acct, [{ rid: r, baseVersion: 1, deleted: true, ciphertext: null }]);
		expect(shrink.status).toBe(200);
	});

	it("exceeding 100,000 live records is 507", async () => {
		const acct = await newAccount();
		await runInDurableObject(accountDO(acct.accountId), (_i, state) => {
			state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'record_count'", MAX_ACCOUNT_RECORDS);
		});
		const res = await push(acct, [
			{ rid: await rid(`${acct.accountId}/one-more`), baseVersion: 0, deleted: false, ciphertext: ciphertext() },
		]);
		expect(res.status).toBe(507);
	});
});

describe("compaction & lifecycle", () => {
	it("purges tombstones after 90 days and answers 410 for older cursors", async () => {
		const acct = await newAccount();
		const { rids } = await seed(acct, ["a", "b", "c"]); // seqs 1..3
		await push(acct, [{ rid: rids[0] ?? "", baseVersion: 1, deleted: true, ciphertext: null }]); // seq 4
		await push(acct, [{ rid: rids[1] ?? "", baseVersion: 1, deleted: false, ciphertext: ciphertext() }]); // seq 5

		const stub = accountDO(acct.accountId);
		await runInDurableObject(stub, async (_i, state) => {
			// A tombstone forces the alarm to the compaction horizon, not a year out.
			const alarm = (await state.storage.getAlarm()) ?? 0;
			expect(alarm).toBeLessThanOrEqual(Date.now() + 92 * DAY);
			state.storage.sql.exec("UPDATE records SET updated_at = ? WHERE deleted = 1", Date.now() - 91 * DAY);
		});
		expect(await runDurableObjectAlarm(stub)).toBe(true);

		const gone = await changes(acct, 1);
		expect(gone.status).toBe(410);
		expect(await gone.json()).toMatchObject({ error: "resync_required" });
		expect((await changes(acct, 3)).status).toBe(410);

		// since == compactedSeq is fine, and since=0 is always allowed.
		const atHorizon = await changes(acct, 4);
		expect(atHorizon.status).toBe(200);
		expect((await atHorizon.json<ChangesBody>()).records.map((r) => r.seq)).toEqual([5]);
		const full = await (await changes(acct, 0)).json<ChangesBody>();
		expect(full.records.map((r) => r.rid)).toEqual([rids[2], rids[1]]);

		await runInDurableObject(stub, async (_i, state) => {
			expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM records WHERE deleted = 1").one()["n"]).toBe(0);
			expect(await state.storage.getAlarm()).not.toBeNull();
		});
	});

	it("a since=0 snapshot after compaction never pages into the 410 range", async () => {
		const acct = await newAccount();
		const { rids } = await seed(acct, ["a", "b", "c", "d"]); // 1..4
		await push(acct, [{ rid: rids[3] ?? "", baseVersion: 1, deleted: true, ciphertext: null }]); // 5
		const stub = accountDO(acct.accountId);
		await runInDurableObject(stub, (_i, state) => {
			state.storage.sql.exec("UPDATE records SET updated_at = ? WHERE deleted = 1", Date.now() - 91 * DAY);
		});
		await runDurableObjectAlarm(stub); // compactedSeq = 5

		const first = await (await changes(acct, 0, 1)).json<ChangesBody>();
		expect(first.records.map((r) => r.seq)).toEqual([1, 2, 3]);
		expect(first.nextSeq).toBeGreaterThanOrEqual(3);
		const next = await changes(acct, 5, 1);
		expect(next.status).toBe(200);
	});

	it("deletes an account after 365 days without an authenticated request", async () => {
		const acct = await newAccount();
		await seed(acct, ["a"]);
		const stub = accountDO(acct.accountId);
		await runInDurableObject(stub, (_i, state) => {
			state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'last_seen'", Date.now() - 366 * DAY);
		});
		expect(await runDurableObjectAlarm(stub)).toBe(true);

		const res = await call("/v1/accounts/me", { headers: acct.headers() });
		expect(res.status).toBe(404);
		expect(await res.json()).toMatchObject({ error: "account_deleted" });
		await runInDurableObject(stub, async (_i, state) => {
			expect(state.storage.sql.exec("SELECT name FROM sqlite_master").toArray()).toEqual([]);
			expect(await state.storage.getAlarm()).toBeNull();
		});
	});

	it("an active account's alarm re-arms instead of purging", async () => {
		const acct = await newAccount();
		const stub = accountDO(acct.accountId);
		expect(await runDurableObjectAlarm(stub)).toBe(true);
		expect((await call("/v1/accounts/me", { headers: acct.headers() })).status).toBe(200);
		await runInDurableObject(stub, async (_i, state) => {
			expect(await state.storage.getAlarm()).not.toBeNull();
		});
	});

	it("persists lastSeen at most once per UTC day", async () => {
		const acct = await newAccount();
		const stub = accountDO(acct.accountId);
		const read = () =>
			runInDurableObject(stub, (_i, state) =>
				Number(state.storage.sql.exec("SELECT value FROM meta WHERE key = 'last_seen'").one()["value"]),
			);
		const yesterday = Date.now() - DAY;
		await runInDurableObject(stub, (_i, state) => {
			state.storage.sql.exec("UPDATE meta SET value = ? WHERE key = 'last_seen'", yesterday);
		});
		await call("/v1/accounts/me", { headers: acct.headers() });
		const touched = await read();
		expect(touched).toBeGreaterThan(yesterday);
		await call("/v1/accounts/me", { headers: acct.headers() });
		expect(await read()).toBe(touched);
	});
});
