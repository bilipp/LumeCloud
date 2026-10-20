// Temporary operator Worker: point-in-time restore of one account.
//
//   POST /restore  Authorization: Bearer <ADMIN_TOKEN>
//   {"accountId":"…","at":<epoch ms>}   or   {"accountId":"…","bookmark":"…"}
//   ← {"bookmark":"…","undoBookmark":"…"}
//
// ADMIN_TOKEN is a secret set only for the lifetime of this Worker. There is
// no other route. Deploy, restore, delete (README: "PITR restore runbook").

import type { AccountDO } from "../src/do/account";

interface AdminEnv {
	ACCOUNT: DurableObjectNamespace<AccountDO>;
	ADMIN_TOKEN?: string;
	DO_JURISDICTION?: string;
}

async function digest(s: string): Promise<ArrayBuffer> {
	return crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
}

async function authorized(request: Request, env: AdminEnv): Promise<boolean> {
	const token = env.ADMIN_TOKEN;
	if (token === undefined || token.length < 32) return false; // refuse weak or missing tokens
	const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
	return crypto.subtle.timingSafeEqual(await digest(token), await digest(presented));
}

export default {
	async fetch(request: Request, env: AdminEnv): Promise<Response> {
		const url = new URL(request.url);
		if (request.method !== "POST" || url.pathname !== "/restore") return new Response(null, { status: 404 });
		if (!(await authorized(request, env))) return new Response(null, { status: 401 });

		const body: unknown = await request.json().catch(() => null);
		if (body === null || typeof body !== "object") return Response.json({ error: "bad_request" }, { status: 400 });
		const { accountId, at, bookmark } = body as { accountId?: unknown; at?: unknown; bookmark?: unknown };
		if (typeof accountId !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(accountId)) {
			return Response.json({ error: "bad_request", message: "accountId" }, { status: 400 });
		}
		let target: { at: number } | { bookmark: string };
		if (typeof bookmark === "string" && bookmark !== "") target = { bookmark };
		else if (typeof at === "number" && Number.isFinite(at)) target = { at };
		else return Response.json({ error: "bad_request", message: "at or bookmark" }, { status: 400 });

		const ns = env.DO_JURISDICTION === "none" ? env.ACCOUNT : env.ACCOUNT.jurisdiction("eu");
		const result = await ns.get(ns.idFromName(accountId)).pitrRestore(target);
		console.log(JSON.stringify({ event: "pitr_restore", bookmark: result.bookmark }));
		return Response.json(result);
	},
} satisfies ExportedHandler<AdminEnv>;
