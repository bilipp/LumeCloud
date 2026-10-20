// Bindings that `wrangler types` cannot see. INVITE_CODE is an optional
// secret (`wrangler secret put INVITE_CODE --env …`), only read when
// SIGNUP=invite.
interface __BaseEnv_Env {
	INVITE_CODE?: string;
}
