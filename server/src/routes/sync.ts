// /v1/changes and /v1/push — the change feed and optimistic writes (§4.3, §4.4).

import { decodeB64url, encodeB64url } from "../lib/b64url";
import { ApiError, badRequest, unwrap } from "../lib/errors";
import { json, readJsonObject } from "../lib/http";
import { CHANGES_DEFAULT_LIMIT, CHANGES_MAX_LIMIT, MAX_PUSH_BODY_BYTES, MAX_PUSH_RECORDS, MAX_RECORD_BYTES } from "../lib/limits";
import type { PushItem, PushResult, StoredRecord, WireRecord } from "../lib/types";
import { isRid } from "../lib/validate";
import { authenticate } from "./context";

const tooLarge = (message: string): ApiError => new ApiError(413, "record_too_large", message);

function toWire(r: StoredRecord): WireRecord {
	return {
		rid: r.rid,
		version: r.version,
		seq: r.seq,
		deleted: r.deleted,
		ciphertext: r.ciphertext === null ? null : encodeB64url(r.ciphertext),
		updatedAt: r.updatedAt,
	};
}

function parseNonNegativeInt(raw: string | null, name: string, fallback: number): number {
	if (raw === null || raw === "") return fallback;
	if (!/^[0-9]{1,15}$/.test(raw)) throw badRequest(`"${name}" must be a non-negative integer`);
	return Number(raw);
}

export async function getChanges(request: Request, env: Env, url: URL): Promise<Response> {
	const since = parseNonNegativeInt(url.searchParams.get("since"), "since", 0);
	const limit = parseNonNegativeInt(url.searchParams.get("limit"), "limit", CHANGES_DEFAULT_LIMIT);
	if (limit < 1 || limit > CHANGES_MAX_LIMIT) throw badRequest(`"limit" must be 1…${CHANGES_MAX_LIMIT}`);

	const { account, auth } = await authenticate(request, env, true);
	const page = unwrap(await account.changes(auth, since, limit));
	return json({ records: page.records.map(toWire), nextSeq: page.nextSeq, hasMore: page.hasMore });
}

/** Validates the whole push body up front; any size violation rejects everything. */
function parsePushItems(body: Record<string, unknown>): PushItem[] {
	const raw = body["records"];
	if (!Array.isArray(raw)) throw badRequest('"records" must be an array');
	if (raw.length > MAX_PUSH_RECORDS) throw tooLarge(`At most ${MAX_PUSH_RECORDS} records per push`);

	return raw.map((entry: unknown, i): PushItem => {
		if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
			throw badRequest(`records[${i}] must be an object`);
		}
		const r = entry as Record<string, unknown>;
		const rid = r["rid"];
		if (typeof rid !== "string" || !isRid(rid)) throw badRequest(`records[${i}].rid is invalid`);
		const baseVersion = r["baseVersion"];
		if (typeof baseVersion !== "number" || !Number.isSafeInteger(baseVersion) || baseVersion < 0) {
			throw badRequest(`records[${i}].baseVersion must be a non-negative integer`);
		}
		const deleted = r["deleted"];
		if (typeof deleted !== "boolean") throw badRequest(`records[${i}].deleted must be a boolean`);

		const ct = r["ciphertext"];
		if (deleted) {
			if (ct !== null && ct !== undefined) throw badRequest(`records[${i}].ciphertext must be null for a delete`);
			return { rid, baseVersion, deleted, ciphertext: null };
		}
		if (typeof ct !== "string") throw badRequest(`records[${i}].ciphertext must be a base64url string`);
		// Cheap length bound before decoding: 4 chars carry 3 bytes.
		if (Math.floor((ct.length * 3) / 4) > MAX_RECORD_BYTES) {
			throw tooLarge(`records[${i}] exceeds ${MAX_RECORD_BYTES} bytes`);
		}
		const bytes = decodeB64url(ct);
		if (bytes === null) throw badRequest(`records[${i}].ciphertext is not valid base64url`);
		if (bytes.byteLength === 0) throw badRequest(`records[${i}].ciphertext is empty`);
		if (bytes.byteLength > MAX_RECORD_BYTES) throw tooLarge(`records[${i}] exceeds ${MAX_RECORD_BYTES} bytes`);
		return { rid, baseVersion, deleted, ciphertext: bytes };
	});
}

export async function push(request: Request, env: Env): Promise<Response> {
	const { account, auth } = await authenticate(request, env, true);
	const body = await readJsonObject(request, MAX_PUSH_BODY_BYTES, tooLarge("Push body exceeds 4 MiB"));
	const items = parsePushItems(body);
	const res = unwrap(await account.push(auth, items));
	const results = res.results.map((r: PushResult) =>
		r.status === "ok" ? r : { rid: r.rid, status: r.status, current: toWire(r.current) },
	);
	return json({ results, nextSeq: res.nextSeq });
}
