#!/usr/bin/env node
// Copies one Lume Cloud account from one server to another (e.g. staging →
// production). Runs entirely on the client side with the account's recovery
// key: the account id and auth are derived from the root key (PROTOCOL §2.1),
// and envelopes are bound to their rid only (§2.4), so ciphertext is copied
// verbatim. Nothing is decrypted.
//
//   LUME_RECOVERY_KEY='XXXX-XXXX-…' node scripts/migrate-account.mjs \
//     --from https://cloud-staging.getlume.org --to https://cloud.getlume.org
//
// Without LUME_RECOVERY_KEY the key is read from stdin (hidden when it's a TTY).
// No dependencies; Node 20+.

import { createHash, hkdfSync, randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const USAGE = `Usage: node scripts/migrate-account.mjs --from <url> --to <url> [options]

Options:
  --from <url>       Source server, e.g. https://cloud-staging.getlume.org
  --to <url>         Destination server, e.g. https://cloud.getlume.org
  --invite <code>    Invite code, if the destination has SIGNUP=invite
  --overwrite        Records that differ on the destination are replaced by the
                     source copy (records only on the destination are kept)
  --delete-source    Delete the source account after a verified copy
  --dry-run          Read both sides and report; write nothing
  -h, --help         Show this help

The recovery key comes from $LUME_RECOVERY_KEY or stdin.`;

// Push limits (§4.4): 500 records and 4 MiB per request. Stay below the byte cap.
const PUSH_MAX_RECORDS = 500;
const PUSH_MAX_BYTES = 4_000_000;
const CHANGES_LIMIT = 1000;
const MAX_ATTEMPTS = 6;

// ---- Keys (§2.1, §2.2, §4.8) ----

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CHECK_ALPHABET = `${CROCKFORD}*~$=U`;

/** Decodes a recovery key to the 32-byte root key. Throws on a bad key or checksum. */
export function decodeRecoveryKey(input) {
	const s = input
		.toUpperCase()
		.replace(/[\s-]/g, "")
		.replace(/[IL]/g, "1")
		.replace(/O/g, "0");
	if (s.length !== 53) throw new Error("Recovery key must have 53 symbols");

	let bits = 0n;
	let check = 0;
	for (const ch of s.slice(0, 52)) {
		const d = CROCKFORD.indexOf(ch);
		if (d < 0) throw new Error(`Invalid character in recovery key: ${ch}`);
		bits = (bits << 5n) | BigInt(d);
		check = (check * 32 + d) % 37;
	}
	if (CHECK_ALPHABET.indexOf(s[52]) !== check) throw new Error("Recovery key checksum mismatch (typo?)");
	if ((bits & 0xfn) !== 0n) throw new Error("Recovery key has non-zero padding bits");

	const hex = (bits >> 4n).toString(16).padStart(64, "0");
	return Buffer.from(hex, "hex");
}

const hkdf = (rootKey, info, length) =>
	Buffer.from(hkdfSync("sha256", rootKey, Buffer.alloc(0), Buffer.from(info, "utf8"), length));

/** Derives the account id, auth token and verifier from the root key. */
export function deriveAccount(rootKey) {
	const authKey = hkdf(rootKey, "lume-cloud/v1/auth", 32);
	return {
		accountId: hkdf(rootKey, "lume-cloud/v1/account", 16).toString("base64url"),
		authToken: authKey.toString("base64url"),
		authVerifier: createHash("sha256").update(authKey).digest("base64url"),
	};
}

// ---- HTTP ----

class ApiError extends Error {
	constructor(status, code, message) {
		super(`${status} ${code}${message ? `: ${message}` : ""}`);
		this.status = status;
		this.code = code;
	}
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** One server, authenticated as `account` with a throwaway, never-registered device id (§2.2). */
function server(baseURL, account, deviceId) {
	const base = baseURL.replace(/\/+$/, "");

	async function call(method, path, body, { authenticated = true } = {}) {
		const headers = { accept: "application/json" };
		if (authenticated) {
			headers.authorization = `Bearer ${account.accountId}.${account.authToken}`;
			headers["x-lume-device"] = deviceId;
		}
		if (body !== undefined) headers["content-type"] = "application/json";

		for (let attempt = 1; ; attempt++) {
			const res = await fetch(`${base}/v1${path}`, {
				method,
				headers,
				body: body === undefined ? undefined : JSON.stringify(body),
			});
			if ((res.status === 429 || res.status === 503) && attempt < MAX_ATTEMPTS) {
				const wait = Number(res.headers.get("retry-after")) || 2 ** attempt;
				log(`  ${res.status} from ${base}, retrying in ${wait}s`);
				await sleep(wait * 1000);
				continue;
			}
			const text = await res.text();
			const json = text === "" ? null : JSON.parse(text);
			if (!res.ok) throw new ApiError(res.status, json?.error ?? "unknown", json?.message);
			return json;
		}
	}

	return {
		base,
		account: () => call("GET", "/accounts/me"),
		createAccount: (invite) =>
			call(
				"POST",
				"/accounts",
				{ accountId: account.accountId, authVerifier: account.authVerifier, ...(invite ? { invite } : {}) },
				{ authenticated: false },
			),
		deleteAccount: () => call("DELETE", "/accounts/me"),
		push: (records) => call("POST", "/push", { records }),
		devices: async () => (await call("GET", "/devices")).devices,
		registerDevice: ({ id, name, platform }) => call("POST", "/devices", { id, name, platform }),
		revokeDevice: (id) => call("DELETE", `/devices/${id}`),

		/** The full live set as a Map rid → record (§4.3, since=0 paged to the end). */
		async snapshot() {
			const live = new Map();
			let since = 0;
			for (;;) {
				const page = await call("GET", `/changes?since=${since}&limit=${CHANGES_LIMIT}`);
				for (const r of page.records) {
					if (r.deleted) live.delete(r.rid);
					else live.set(r.rid, r);
				}
				if (!page.hasMore) return live;
				since = page.nextSeq;
			}
		},
	};
}

// ---- Migration ----

const log = (...args) => console.error(...args);

/**
 * Registers the source's devices on the destination (same id, name, platform)
 * and carries revocations over, so a revoked device stays revoked. A device
 * revoked on the destination stays revoked: revocation can't be undone (§4.2).
 */
async function copyDevices(src, dst) {
	const existing = new Map((await dst.devices()).map((d) => [d.id, d]));
	let registered = 0;
	let revoked = 0;
	for (const d of await src.devices()) {
		const there = existing.get(d.id);
		if (there?.revoked) continue;
		if (!d.revoked || there === undefined) {
			await dst.registerDevice(d);
			if (!d.revoked) registered++;
		}
		if (d.revoked) {
			await dst.revokeDevice(d.id);
			revoked++;
		}
	}
	log(`Devices: ${registered} registered, ${revoked} revoked on the destination`);
}

/** Splits push records into requests within the record and byte limits. */
function batches(records) {
	const out = [];
	let current = [];
	let bytes = 0;
	for (const r of records) {
		const size = JSON.stringify(r).length + 1;
		if (current.length > 0 && (current.length === PUSH_MAX_RECORDS || bytes + size > PUSH_MAX_BYTES)) {
			out.push(current);
			current = [];
			bytes = 0;
		}
		current.push(r);
		bytes += size;
	}
	if (current.length > 0) out.push(current);
	return out;
}

export async function migrate({ from, to, recoveryKey, invite, overwrite = false, deleteSource = false, dryRun = false }) {
	const account = deriveAccount(decodeRecoveryKey(recoveryKey));
	const deviceId = randomUUID().toUpperCase();
	const src = server(from, account, deviceId);
	const dst = server(to, account, deviceId);
	log(`Account ${account.accountId}`);
	log(`  from ${src.base}`);
	log(`  to   ${dst.base}`);

	const srcInfo = await src.account().catch((err) => {
		if (err instanceof ApiError && err.code === "account_deleted") {
			throw new Error(`The account doesn't exist on ${src.base}`);
		}
		throw err;
	});
	const records = await src.snapshot();
	log(`Source: ${records.size} live records, ${srcInfo.usedBytes} bytes`);

	// Does the destination already have this account?
	let dstExists = true;
	await dst.account().catch((err) => {
		if (err instanceof ApiError && err.code === "account_deleted") dstExists = false;
		else throw err;
	});
	const dstRecords = dstExists ? await dst.snapshot() : new Map();
	if (dstExists) log(`Destination: account exists with ${dstRecords.size} live records`);

	// Ciphertext is copied verbatim, so a record that is already identical on the
	// destination (e.g. from an interrupted earlier run) is skipped. Only records
	// that differ there would be overwritten.
	const todo = [...records.values()].filter((r) => dstRecords.get(r.rid)?.ciphertext !== r.ciphertext);
	const differing = todo.filter((r) => dstRecords.has(r.rid)).length;

	if (dryRun) {
		const devices = await src.devices();
		const revoked = devices.filter((d) => d.revoked).length;
		log(`Dry run: would ${dstExists ? "push into the existing" : "create the"} account and push ${todo.length} records`);
		if (records.size > todo.length) log(`  ${records.size - todo.length} are already identical on the destination`);
		if (differing > 0) log(`  ${differing} differ on the destination and need --overwrite`);
		log(`  and copy ${devices.length - revoked} active and ${revoked} revoked devices`);
		return { ok: true, dryRun: true };
	}

	if (differing > 0 && !overwrite) {
		throw new Error(
			`${differing} records differ on the destination. Rerun with --overwrite to make the ` +
				"source copy win for them (records only on the destination are kept).",
		);
	}
	if (!dstExists) {
		await dst.createAccount(invite);
		log("Destination: account created");
	}

	// baseVersion is the destination's version (0 for a new record). A conflict
	// means something changed in between; with --overwrite the source still wins
	// on one retry.
	const pending = todo.map((r) => ({
		rid: r.rid,
		baseVersion: dstRecords.get(r.rid)?.version ?? 0,
		deleted: false,
		ciphertext: r.ciphertext,
	}));
	let pushed = 0;
	const conflicts = [];
	for (const batch of batches(pending)) {
		const { results } = await dst.push(batch);
		const retry = [];
		for (const [i, result] of results.entries()) {
			if (result.status === "ok") pushed++;
			else if (result.status === "conflict" && overwrite) retry.push({ ...batch[i], baseVersion: result.current.version });
			else conflicts.push(result.rid);
		}
		if (retry.length > 0) {
			const again = await dst.push(retry);
			for (const result of again.results) {
				if (result.status === "ok") pushed++;
				else conflicts.push(result.rid);
			}
		}
		log(`  pushed ${pushed}/${pending.length}`);
	}

	// Verify: every source record is on the destination with identical ciphertext.
	const after = await dst.snapshot();
	const missing = [...records.values()].filter((r) => after.get(r.rid)?.ciphertext !== r.ciphertext);
	if (missing.length > 0 || conflicts.length > 0) {
		log(`Verification FAILED: ${missing.length} records missing or different, ${conflicts.length} conflicts.`);
		log("The source was left untouched. Rerun with --overwrite to retry.");
		return { ok: false, pushed, missing: missing.map((r) => r.rid), conflicts };
	}
	log(`Verified: all ${records.size} records are on the destination (${after.size} live there in total)`);
	await copyDevices(src, dst);

	if (deleteSource) {
		await src.deleteAccount();
		log("Source account deleted");
	} else {
		log("Source account kept. Delete it later with --delete-source, or let the inactivity purge remove it.");
	}
	log("Next: point every device at the destination URL and do a full resync (since=0, PROTOCOL §6.3).");
	return { ok: true, pushed };
}

// ---- CLI ----

/** Reads one line from stdin, without echo when stdin is a terminal. */
async function readSecret(prompt) {
	const { stdin } = process;
	if (!stdin.isTTY) {
		let data = "";
		for await (const chunk of stdin) data += chunk;
		return data.split("\n")[0];
	}
	process.stderr.write(prompt);
	stdin.setRawMode(true);
	stdin.setEncoding("utf8");
	return new Promise((resolve) => {
		let value = "";
		const onData = (chars) => {
			for (const ch of chars) {
				if (ch === "\r" || ch === "\n") {
					stdin.setRawMode(false);
					stdin.pause();
					stdin.off("data", onData);
					process.stderr.write("\n");
					resolve(value);
					return;
				}
				if (ch === "\u0003") process.exit(130); // Ctrl-C
				if (ch === "\u007f" || ch === "\b") value = value.slice(0, -1);
				else value += ch;
			}
		};
		stdin.on("data", onData);
		stdin.resume();
	});
}

async function main() {
	const { values } = parseArgs({
		options: {
			from: { type: "string" },
			to: { type: "string" },
			invite: { type: "string" },
			overwrite: { type: "boolean", default: false },
			"delete-source": { type: "boolean", default: false },
			"dry-run": { type: "boolean", default: false },
			help: { type: "boolean", short: "h", default: false },
		},
	});
	if (values.help || !values.from || !values.to) {
		log(USAGE);
		process.exit(values.help ? 0 : 2);
	}
	if (new URL(values.from).origin === new URL(values.to).origin) {
		log("--from and --to are the same server");
		process.exit(2);
	}

	const recoveryKey = process.env.LUME_RECOVERY_KEY ?? (await readSecret("Recovery key: "));
	const result = await migrate({
		from: values.from,
		to: values.to,
		recoveryKey,
		invite: values.invite,
		overwrite: values.overwrite,
		deleteSource: values["delete-source"],
		dryRun: values["dry-run"],
	});
	process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
	main().catch((err) => {
		log(`Error: ${err.message}`);
		process.exit(1);
	});
}
