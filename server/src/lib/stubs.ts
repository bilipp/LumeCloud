// Durable Object addressing. Every object is created in the jurisdiction named
// by DO_JURISDICTION ("eu" on the official instance). Only the explicit value
// "none" opts out, because local workerd (wrangler dev, tests) does not
// implement jurisdictions. A missing var falls back to "eu" (fail-safe).

import type { AccountDO } from "../do/account";
import type { PairingDO } from "../do/pairing";
import type { SignupGuardDO } from "../do/signup-guard";
import { sha256B64url } from "./b64url";

const JURISDICTIONS: readonly DurableObjectJurisdiction[] = ["eu", "us", "fedramp", "fedramp-high"];

function isJurisdiction(value: string): value is DurableObjectJurisdiction {
	return (JURISDICTIONS as readonly string[]).includes(value);
}

function scoped<T extends Rpc.DurableObjectBranded | undefined>(
	env: Env,
	ns: DurableObjectNamespace<T>,
): DurableObjectNamespace<T> {
	const configured: string = env.DO_JURISDICTION || "eu";
	if (configured === "none") return ns;
	// An unknown value fails closed to the EU rather than to "no restriction".
	return ns.jurisdiction(isJurisdiction(configured) ? configured : "eu");
}

export function accountStub(env: Env, accountId: string): DurableObjectStub<AccountDO> {
	const ns = scoped(env, env.ACCOUNT);
	return ns.get(ns.idFromName(accountId));
}

export function pairingStub(env: Env, code: string): DurableObjectStub<PairingDO> {
	const ns = scoped(env, env.PAIRING);
	return ns.get(ns.idFromName(`pairing:${code}`));
}

/** The guard is keyed by a hash of the IP key so raw IPs never become object names. */
export async function signupGuardStub(env: Env, ipKey: string): Promise<DurableObjectStub<SignupGuardDO>> {
	const ns = scoped(env, env.SIGNUP_GUARD);
	return ns.get(ns.idFromName(`signup:${await sha256B64url(`lume-cloud/v1/signup-guard:${ipKey}`)}`));
}
