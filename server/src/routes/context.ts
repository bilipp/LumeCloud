// Shared plumbing for authenticated routes.

import type { AccountDO } from "../do/account";
import { readCredentials } from "../lib/auth";
import { enforce } from "../lib/ratelimit";
import { accountStub } from "../lib/stubs";
import type { AuthContext } from "../lib/types";

export interface Authed {
	accountId: string;
	auth: AuthContext;
	account: DurableObjectStub<AccountDO>;
}

/**
 * Validates the auth headers, applies the per-account rate limit, and returns
 * the account stub. The verifier itself is checked inside AccountDO.
 */
export async function authenticate(request: Request, env: Env, requireDevice: boolean): Promise<Authed> {
	const { accountId, auth } = await readCredentials(request, requireDevice);
	await enforce(env.RL_ACCOUNT, `account:${accountId}`, 60);
	return { accountId, auth, account: accountStub(env, accountId) };
}
