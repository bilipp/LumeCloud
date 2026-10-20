// Error codes and the JSON error envelope (PROTOCOL.md §1).

export type ErrorCode =
	| "bad_request"
	| "bad_auth"
	| "device_revoked"
	| "signup_closed"
	| "account_deleted"
	| "not_found"
	| "pairing_already_sealed"
	| "resync_required"
	| "record_too_large"
	| "rate_limited"
	| "quota_exceeded"
	| "unavailable"
	| "internal";

/** A failure that crosses the Durable Object RPC boundary as plain data. */
export interface Failure {
	ok: false;
	status: number;
	error: ErrorCode;
	message?: string;
	retryAfter?: number;
}

export interface Success<T> {
	ok: true;
	value: T;
}

/** Result type returned by every Durable Object RPC method. */
export type Outcome<T> = Success<T> | Failure;

export function ok<T>(value: T): Success<T> {
	return { ok: true, value };
}

export function fail(status: number, error: ErrorCode, message?: string): Failure {
	return message === undefined ? { ok: false, status, error } : { ok: false, status, error, message };
}

/** Thrown inside the Worker; turned into a JSON error response by the router. */
export class ApiError extends Error {
	readonly status: number;
	readonly code: ErrorCode;
	readonly retryAfter: number | undefined;

	constructor(status: number, code: ErrorCode, message?: string, retryAfter?: number) {
		super(message ?? code);
		this.name = "ApiError";
		this.status = status;
		this.code = code;
		this.retryAfter = retryAfter;
	}

	static from(failure: Failure): ApiError {
		return new ApiError(failure.status, failure.error, failure.message, failure.retryAfter);
	}
}

export function errorResponse(err: ApiError): Response {
	const body: { error: ErrorCode; message?: string } = { error: err.code };
	if (err.message !== err.code) body.message = err.message;
	const headers = new Headers({ "content-type": "application/json; charset=utf-8" });
	if (err.retryAfter !== undefined) headers.set("retry-after", String(Math.max(1, Math.ceil(err.retryAfter))));
	return new Response(JSON.stringify(body), { status: err.status, headers });
}

/** Unwraps a DO outcome or throws the failure as an ApiError. */
export function unwrap<T>(outcome: Outcome<T>): T {
	if (outcome.ok) return outcome.value;
	throw ApiError.from(outcome);
}

export const badRequest = (message: string): ApiError => new ApiError(400, "bad_request", message);
export const notFound = (message?: string): ApiError => new ApiError(404, "not_found", message);
export const rateLimited = (retryAfter: number): ApiError => new ApiError(429, "rate_limited", undefined, retryAfter);
