import { describe, expect, it } from "vitest";
import { call, ciphertext, newAccount, push, rid } from "./helpers";

function nextMessage(ws: WebSocket, timeoutMs = 2000): Promise<string> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("timed out waiting for a message")), timeoutMs);
		ws.addEventListener(
			"message",
			(event) => {
				clearTimeout(timer);
				resolve(typeof event.data === "string" ? event.data : "<binary>");
			},
			{ once: true },
		);
	});
}

async function openSocket(acct: Awaited<ReturnType<typeof newAccount>>): Promise<WebSocket> {
	const res = await call("/v1/socket", { headers: { ...acct.headers(), upgrade: "websocket" } });
	expect(res.status).toBe(101);
	const ws = res.webSocket;
	if (ws === null) throw new Error("no webSocket on 101 response");
	ws.accept();
	return ws;
}

describe("realtime socket", () => {
	it("receives a seq poke after a push", async () => {
		const acct = await newAccount();
		const ws = await openSocket(acct);
		const message = nextMessage(ws);
		const res = await push(acct, [
			{ rid: await rid(`${acct.accountId}/a`), baseVersion: 0, deleted: false, ciphertext: ciphertext() },
			{ rid: await rid(`${acct.accountId}/b`), baseVersion: 0, deleted: false, ciphertext: ciphertext() },
		]);
		expect(res.status).toBe(200);
		expect(JSON.parse(await message)).toEqual({ type: "seq", seq: 2 });
		ws.close(1000, "done");
	});

	it("does not poke when a push changed nothing", async () => {
		const acct = await newAccount();
		const ws = await openSocket(acct);
		const message = nextMessage(ws, 300);
		await push(acct, [
			{ rid: await rid(`${acct.accountId}/x`), baseVersion: 9, deleted: false, ciphertext: ciphertext() },
		]);
		await expect(message).rejects.toThrow("timed out");
		ws.close(1000, "done");
	});

	it("answers ping with pong", async () => {
		const acct = await newAccount();
		const ws = await openSocket(acct);
		const message = nextMessage(ws);
		ws.send("ping");
		expect(await message).toBe("pong");
		ws.close(1000, "done");
	});

	it("refuses an upgrade with bad credentials", async () => {
		const acct = await newAccount();
		const res = await call("/v1/socket", {
			headers: {
				authorization: `Bearer ${acct.accountId}.${"A".repeat(43)}`,
				"x-lume-device": acct.deviceId,
				upgrade: "websocket",
			},
		});
		expect(res.status).toBe(401);
		expect(res.webSocket).toBeNull();
	});

	it("closes the socket when the account is deleted", async () => {
		const acct = await newAccount();
		const ws = await openSocket(acct);
		const closed = new Promise<number>((resolve) => ws.addEventListener("close", (e) => resolve(e.code)));
		expect((await call("/v1/accounts/me", { method: "DELETE", headers: acct.headers() })).status).toBe(204);
		expect(await closed).toBe(4404);
	});
});
