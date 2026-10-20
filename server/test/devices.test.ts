import { describe, expect, it } from "vitest";
import { call, changes, newAccount, randomUuid } from "./helpers";

interface DeviceBody {
	id: string;
	name: string;
	platform: string;
	createdAt: number;
	lastSeen: number;
	revoked: boolean;
}

async function register(acct: Awaited<ReturnType<typeof newAccount>>, id: string, name = "Philipp's iPhone", platform = "ios") {
	return call("/v1/devices", {
		method: "POST",
		headers: acct.headers(null),
		body: JSON.stringify({ id, name, platform }),
	});
}

describe("devices", () => {
	it("registers idempotently and lists devices", async () => {
		const acct = await newAccount();
		const first = await register(acct, acct.deviceId);
		expect(first.status).toBe(200);
		const d1 = await first.json<DeviceBody>();
		expect(d1).toMatchObject({ id: acct.deviceId, name: "Philipp's iPhone", platform: "ios", revoked: false });
		expect(typeof d1.createdAt).toBe("number");
		expect(typeof d1.lastSeen).toBe("number");

		const again = await register(acct, acct.deviceId, "Renamed iPhone");
		const d2 = await again.json<DeviceBody>();
		expect(d2.createdAt).toBe(d1.createdAt);
		expect(d2.name).toBe("Renamed iPhone");

		const tv = randomUuid();
		expect((await register(acct, tv, "Living Room", "tvos")).status).toBe(200);

		const list = await call("/v1/devices", { headers: acct.headers() });
		expect(list.status).toBe(200);
		const { devices } = await list.json<{ devices: DeviceBody[] }>();
		expect(devices.map((d) => d.id).sort()).toEqual([acct.deviceId, tv].sort());
	});

	it("normalises lowercase UUIDs to uppercase", async () => {
		const acct = await newAccount();
		const id = randomUuid();
		const res = await register(acct, id.toLowerCase());
		expect((await res.json<DeviceBody>()).id).toBe(id);
	});

	it("validates the body", async () => {
		const acct = await newAccount();
		expect((await register(acct, "not-a-uuid")).status).toBe(400);
		expect((await register(acct, randomUuid(), "")).status).toBe(400);
		expect((await register(acct, randomUuid(), "x", "Bad Platform")).status).toBe(400);
	});

	it("accepts an unregistered device id on authenticated routes", async () => {
		const acct = await newAccount();
		const res = await call("/v1/accounts/me", { headers: acct.headers(randomUuid()) });
		expect(res.status).toBe(200);
	});

	it("revoke → that device gets device_revoked, others keep working", async () => {
		const acct = await newAccount();
		const phone = acct.deviceId;
		const tv = randomUuid();
		await register(acct, phone);
		await register(acct, tv, "Living Room", "tvos");

		const del = await call(`/v1/devices/${tv}`, { method: "DELETE", headers: acct.headers(phone) });
		expect(del.status).toBe(204);

		const asTv = await call("/v1/accounts/me", { headers: acct.headers(tv) });
		expect(asTv.status).toBe(401);
		expect(await asTv.json()).toMatchObject({ error: "device_revoked" });

		const tvChanges = await call("/v1/changes?since=0", { headers: acct.headers(tv) });
		expect(tvChanges.status).toBe(401);
		expect(await tvChanges.json()).toMatchObject({ error: "device_revoked" });

		// Re-registering a revoked id does not un-revoke it.
		const reRegister = await call("/v1/devices", {
			method: "POST",
			headers: acct.headers(null),
			body: JSON.stringify({ id: tv, name: "Living Room", platform: "tvos" }),
		});
		expect(reRegister.status).toBe(401);
		expect(await reRegister.json()).toMatchObject({ error: "device_revoked" });

		expect((await changes(acct, 0)).status).toBe(200);
		const { devices } = await (await call("/v1/devices", { headers: acct.headers(phone) })).json<{
			devices: DeviceBody[];
		}>();
		expect(devices.find((d) => d.id === tv)?.revoked).toBe(true);
	});

	it("revoking an unknown device is not_found", async () => {
		const acct = await newAccount();
		const res = await call(`/v1/devices/${randomUuid()}`, { method: "DELETE", headers: acct.headers() });
		expect(res.status).toBe(404);
		expect(await res.json()).toMatchObject({ error: "not_found" });
	});
});
