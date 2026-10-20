import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { encodeB64url } from "../src/lib/b64url";
import { call, newAccount, pairingDO, randomIp } from "./helpers";

const publicKey = () => encodeB64url(crypto.getRandomValues(new Uint8Array(32)));

async function startPairing(ip = randomIp()) {
	const res = await call("/v1/pairings", {
		method: "POST",
		headers: { "cf-connecting-ip": ip },
		body: JSON.stringify({ publicKey: publicKey(), deviceName: "Living Room", platform: "tvos" }),
	});
	expect(res.status).toBe(201);
	return res.json<{ code: string; pollToken: string; expiresAt: number }>();
}

const poll = (code: string, pollToken: string) =>
	call(`/v1/pairings/${code}/result?pollToken=${encodeURIComponent(pollToken)}`);

describe("pairing", () => {
	it("completes the full round trip", async () => {
		const joined = await newAccount();
		const { code, pollToken, expiresAt } = await startPairing();
		expect(code).toMatch(/^[0-9]{6}$/);
		expect(pollToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
		expect(expiresAt).toBeGreaterThan(Date.now() + 9 * 60 * 1000);

		expect(await (await poll(code, pollToken)).json()).toEqual({ status: "pending" });

		const lookup = await call(`/v1/pairings/${code}`, { headers: joined.headers() });
		expect(lookup.status).toBe(200);
		expect(await lookup.json()).toMatchObject({ deviceName: "Living Room", platform: "tvos", expiresAt });

		const enc = encodeB64url(crypto.getRandomValues(new Uint8Array(32)));
		const sealed = encodeB64url(crypto.getRandomValues(new Uint8Array(150)));
		const seal = await call(`/v1/pairings/${code}/seal`, {
			method: "POST",
			headers: joined.headers(),
			body: JSON.stringify({ enc, ciphertext: sealed }),
		});
		expect(seal.status).toBe(204);

		const second = await call(`/v1/pairings/${code}/seal`, {
			method: "POST",
			headers: joined.headers(),
			body: JSON.stringify({ enc, ciphertext: sealed }),
		});
		expect(second.status).toBe(409);
		expect(await second.json()).toMatchObject({ error: "pairing_already_sealed" });

		expect(await (await poll(code, pollToken)).json()).toEqual({ status: "sealed", enc, ciphertext: sealed });

		// Fetched once → gone.
		const again = await poll(code, pollToken);
		expect(again.status).toBe(404);
		expect(await again.json()).toMatchObject({ error: "not_found" });
		await runInDurableObject(pairingDO(code), (_i, state) => {
			expect(state.storage.sql.exec("SELECT name FROM sqlite_master").toArray()).toEqual([]);
		});
	});

	it("a wrong poll token looks like an unknown code", async () => {
		const { code } = await startPairing();
		const res = await poll(code, encodeB64url(crypto.getRandomValues(new Uint8Array(32))));
		expect(res.status).toBe(404);
	});

	it("expires via alarm after 10 minutes", async () => {
		const joined = await newAccount();
		const { code, pollToken } = await startPairing();
		const stub = pairingDO(code);
		await runInDurableObject(stub, async (_i, state) => {
			const alarm = (await state.storage.getAlarm()) ?? 0;
			expect(alarm).toBeGreaterThan(Date.now() + 9 * 60 * 1000);
			expect(alarm).toBeLessThanOrEqual(Date.now() + 10 * 60 * 1000);
		});
		expect(await runDurableObjectAlarm(stub)).toBe(true);
		expect((await call(`/v1/pairings/${code}`, { headers: joined.headers() })).status).toBe(404);
		expect((await poll(code, pollToken)).status).toBe(404);
	});

	it("an expired code is not found even before the alarm fires", async () => {
		const joined = await newAccount();
		const { code } = await startPairing();
		await runInDurableObject(pairingDO(code), (_i, state) => {
			state.storage.sql.exec("UPDATE pairing SET expires_at = ?", Date.now() - 1);
		});
		const res = await call(`/v1/pairings/${code}`, { headers: joined.headers() });
		expect(res.status).toBe(404);
		expect(await res.json()).toMatchObject({ error: "not_found" });
	});

	it("lookup and seal require authentication", async () => {
		const { code } = await startPairing();
		expect((await call(`/v1/pairings/${code}`)).status).toBe(401);
		const seal = await call(`/v1/pairings/${code}/seal`, {
			method: "POST",
			body: JSON.stringify({ enc: publicKey(), ciphertext: publicKey() }),
		});
		expect(seal.status).toBe(401);
	});

	it("unknown codes are not_found and create no storage", async () => {
		const joined = await newAccount();
		const res = await call("/v1/pairings/000001", { headers: joined.headers() });
		expect(res.status).toBe(404);
		await runInDurableObject(pairingDO("000001"), (_i, state) => {
			expect(state.storage.sql.exec("SELECT name FROM sqlite_master").toArray()).toEqual([]);
		});
		expect((await call("/v1/pairings/abc", { headers: joined.headers() })).status).toBe(404);
	});

	it("rejects any code that is not exactly six digits with not_found", async () => {
		const joined = await newAccount();
		const { pollToken } = await startPairing();
		const body = JSON.stringify({ enc: publicKey(), ciphertext: publicKey() });
		for (const code of ["12345", "1234567", "12345a", "١٢٣٤٥٦", "12%2034"]) {
			const lookup = await call(`/v1/pairings/${code}`, { headers: joined.headers() });
			expect(lookup.status).toBe(404);
			expect(await lookup.json()).toMatchObject({ error: "not_found" });
			const seal = await call(`/v1/pairings/${code}/seal`, { method: "POST", headers: joined.headers(), body });
			expect(seal.status).toBe(404);
			expect((await poll(code, pollToken)).status).toBe(404);
		}
	});

	it("validates the new device's request", async () => {
		const res = await call("/v1/pairings", {
			method: "POST",
			body: JSON.stringify({ publicKey: "AAAA", deviceName: "TV", platform: "tvos" }),
		});
		expect(res.status).toBe(400);
	});

	it("rate-limits lookups to 10 per minute per account", async () => {
		const joined = await newAccount();
		const statuses: number[] = [];
		for (let i = 0; i < 12; i++) {
			statuses.push((await call("/v1/pairings/123456", { headers: joined.headers() })).status);
		}
		expect(statuses.slice(0, 10).every((s) => s === 404)).toBe(true);
		expect(statuses.slice(10)).toEqual([429, 429]);
	});
});
