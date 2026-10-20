// Request/response helpers for the Worker.

import { ApiError, badRequest } from "./errors";

export function json(body: unknown, status = 200, headers?: HeadersInit): Response {
	const h = new Headers(headers);
	h.set("content-type", "application/json; charset=utf-8");
	return new Response(JSON.stringify(body), { status, headers: h });
}

export function noContent(): Response {
	return new Response(null, { status: 204 });
}

/**
 * Reads the request body as bytes, refusing to buffer more than `maxBytes`.
 * `tooLarge` is the error to raise when the cap is exceeded.
 */
export async function readBody(request: Request, maxBytes: number, tooLarge: ApiError): Promise<Uint8Array> {
	const declared = request.headers.get("content-length");
	if (declared !== null && Number(declared) > maxBytes) throw tooLarge;
	if (request.body === null) return new Uint8Array(0);

	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		total += value.byteLength;
		if (total > maxBytes) {
			await reader.cancel();
			throw tooLarge;
		}
		chunks.push(value);
	}
	const out = new Uint8Array(total);
	let offset = 0;
	for (const c of chunks) {
		out.set(c, offset);
		offset += c.byteLength;
	}
	return out;
}

/** Parses a JSON object body. Unknown keys are kept and ignored by callers. */
export async function readJsonObject(
	request: Request,
	maxBytes: number,
	tooLarge: ApiError = badRequest("Request body too large"),
): Promise<Record<string, unknown>> {
	const bytes = await readBody(request, maxBytes, tooLarge);
	let parsed: unknown;
	try {
		parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
	} catch {
		throw badRequest("Malformed JSON");
	}
	if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
		throw badRequest("Expected a JSON object");
	}
	return parsed as Record<string, unknown>;
}
