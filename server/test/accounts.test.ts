import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { randomB64url, sha256B64url } from "../src/lib/b64url";
import worker from "../src/index";
import { SignupGuardDO } from "../src/do/signup-guard";
import { signupGuardStub } from "../src/lib/stubs";
import { BASE, accountDO, bearer, call, newAccount, randomIp, randomUuid } from "./helpers";

describe("health", () => {
	it("GET /healthz returns ok and version", async () => {
		const res = await call("/healthz");
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ ok: true, version: "test" });
	});

	it("unknown routes are 404 not_found", async () => {
		const res = await call("/v1/nope");
		expect(res.status).toBe(404);
		expect(await res.json()).toMatchObject({ error: "not_found" });
	});
});

describe("accounts", () => {
	it("creates an account and reads it back", async () => {
		const acct = await newAccount();
		expect(acct.accountId).toMatch(/^[A-Za-z0-9_-]{22}$/);
		const res = await call("/v1/accounts/me", { headers: acct.headers() });
		expect(res.status).toBe(200);
		const body = await res.json<Record<string, unknown>>();
		expect(body).toMatchObject({ accountId: acct.accountId, usedBytes: 0, recordCount: 0, nextSeq: 1 });
		expect(typeof body["createdAt"]).toBe("number");
	});

	it("rejects a malformed verifier", async () => {
		const res = await call("/v1/accounts", { method: "POST", body: JSON.stringify({ authVerifier: "short" }) });
		expect(res.status).toBe(400);
		expect(await res.json()).toMatchObject({ error: "bad_request" });
	});

	it("rejects malformed JSON", async () => {
		const res = await call("/v1/accounts", { method: "POST", body: "{nope" });
		expect(res.status).toBe(400);
	});

	it("rejects a wrong auth key with bad_auth", async () => {
		const acct = await newAccount();
		const wrong = crypto.getRandomValues(new Uint8Array(32));
		const res = await call("/v1/accounts/me", {
			headers: { authorization: bearer(acct.accountId, wrong), "x-lume-device": acct.deviceId },
		});
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({ error: "bad_auth" });
	});

	it("rejects missing or malformed Authorization with bad_auth", async () => {
		const missing = await call("/v1/accounts/me", { headers: { "x-lume-device": randomUuid() } });
		expect(missing.status).toBe(401);
		const garbage = await call("/v1/accounts/me", {
			headers: { authorization: "Bearer nonsense", "x-lume-device": randomUuid() },
		});
		expect(garbage.status).toBe(401);
		expect(await garbage.json()).toMatchObject({ error: "bad_auth" });
	});

	it("requires X-Lume-Device on authenticated routes", async () => {
		const acct = await newAccount();
		const res = await call("/v1/accounts/me", { headers: acct.headers(null) });
		expect(res.status).toBe(400);
	});

	it("delete → every later call returns account_deleted", async () => {
		const acct = await newAccount();
		const del = await call("/v1/accounts/me", { method: "DELETE", headers: acct.headers() });
		expect(del.status).toBe(204);

		for (const [path, init] of [
			["/v1/accounts/me", {}],
			["/v1/devices", {}],
			["/v1/changes?since=0", {}],
		] as const) {
			const res = await call(path, { ...init, headers: acct.headers() });
			expect(res.status).toBe(404);
			expect(await res.json()).toMatchObject({ error: "account_deleted" });
		}

		// Storage is really gone, alarm included.
		await runInDurableObject(accountDO(acct.accountId), async (_instance, state) => {
			expect(state.storage.sql.exec("SELECT name FROM sqlite_master").toArray()).toEqual([]);
			expect(await state.storage.getAlarm()).toBeNull();
		});
	});

	it("an unknown account id returns account_deleted and creates no storage", async () => {
		const accountId = randomB64url(16);
		const authKey = crypto.getRandomValues(new Uint8Array(32));
		const headers = { authorization: bearer(accountId, authKey), "x-lume-device": randomUuid() };

		const reads = [
			await call("/v1/accounts/me", { headers }),
			await call("/v1/changes?since=0", { headers }),
			await call("/v1/push", { method: "POST", headers, body: JSON.stringify({ records: [] }) }),
			await call("/v1/devices", {
				method: "POST",
				headers,
				body: JSON.stringify({ id: randomUuid(), name: "x", platform: "ios" }),
			}),
		];
		for (const res of reads) {
			expect(res.status).toBe(404);
			expect(await res.json()).toMatchObject({ error: "account_deleted" });
		}

		await runInDurableObject(accountDO(accountId), async (_instance, state) => {
			expect(state.storage.sql.exec("SELECT name FROM sqlite_master").toArray()).toEqual([]);
			expect(state.storage.sql.databaseSize).toBeLessThanOrEqual(8192);
			expect(await state.storage.getAlarm()).toBeNull();
		});
	});

	it("account creation arms the inactivity alarm", async () => {
		const acct = await newAccount();
		await runInDurableObject(accountDO(acct.accountId), async (_instance, state) => {
			const alarm = await state.storage.getAlarm();
			expect(alarm).not.toBeNull();
			expect(alarm ?? 0).toBeGreaterThan(Date.now() + 364 * 24 * 3600 * 1000);
		});
	});
});

describe("signup controls", () => {
	async function signup(envOverride: Partial<Env>, invite?: string): Promise<Response> {
		const authKey = crypto.getRandomValues(new Uint8Array(32));
		const body: Record<string, string> = { authVerifier: await sha256B64url(authKey) };
		if (invite !== undefined) body["invite"] = invite;
		const request = new Request(`${BASE}/v1/accounts`, {
			method: "POST",
			headers: { "content-type": "application/json", "cf-connecting-ip": randomIp() },
			body: JSON.stringify(body),
		});
		return worker.fetch(request, { ...env, ...envOverride });
	}

	it("SIGNUP=invite without an invite code is signup_closed", async () => {
		const res = await signup({ SIGNUP: "invite" });
		expect(res.status).toBe(403);
		expect(await res.json()).toMatchObject({ error: "signup_closed" });
	});

	it("SIGNUP=invite with a wrong invite is signup_closed", async () => {
		const res = await signup({ SIGNUP: "invite", INVITE_CODE: "family-2026" }, "guess");
		expect(res.status).toBe(403);
		expect(await res.json()).toMatchObject({ error: "signup_closed" });
	});

	it("SIGNUP=invite with no INVITE_CODE configured refuses everyone", async () => {
		const res = await signup({ SIGNUP: "invite" }, "");
		expect(res.status).toBe(403);
	});

	it("SIGNUP=invite with the right invite creates the account", async () => {
		const res = await signup({ SIGNUP: "invite", INVITE_CODE: "family-2026" }, "family-2026");
		expect(res.status).toBe(201);
	});

	it("the per-IP burst limit returns 429 with Retry-After", async () => {
		const ip = randomIp();
		const statuses: number[] = [];
		let retryAfter: string | null = null;
		for (let i = 0; i < 7; i++) {
			const authKey = crypto.getRandomValues(new Uint8Array(32));
			const res = await call("/v1/accounts", {
				method: "POST",
				headers: { "cf-connecting-ip": ip },
				body: JSON.stringify({ authVerifier: await sha256B64url(authKey) }),
			});
			statuses.push(res.status);
			if (res.status === 429) retryAfter = res.headers.get("retry-after");
		}
		expect(statuses.slice(0, 5)).toEqual([201, 201, 201, 201, 201]);
		expect(statuses).toContain(429);
		expect(Number(retryAfter)).toBeGreaterThan(0);
	});

	it("the daily cap allows 10 signups per IP, then refuses until UTC midnight", async () => {
		const stub = await signupGuardStub(env, `test-${randomB64url(8)}`);
		const now = Date.now();
		for (let i = 0; i < 10; i++) expect((await stub.consume(now)).allowed).toBe(true);
		const refused = await stub.consume(now);
		expect(refused.allowed).toBe(false);
		expect(refused.retryAfter).toBeGreaterThan(0);
		expect(refused.retryAfter).toBeLessThanOrEqual(86_400);
		// Next UTC day resets.
		expect((await stub.consume(now + 86_400_000)).allowed).toBe(true);
		await runInDurableObject(stub, async (instance) => {
			expect(instance).toBeInstanceOf(SignupGuardDO);
		});
	});

});
