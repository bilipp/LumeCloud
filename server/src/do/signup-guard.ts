// SignupGuardDO: one object per client IP key (hashed; IPv6 /64), EU.
//
// Enforces the daily signup cap. The counter resets at 00:00 UTC, and an alarm
// deletes the object's storage after the day ends so guards don't pile up.

import { DurableObject } from "cloudflare:workers";
import { DAY_MS, SIGNUP_DAILY_CAP } from "../lib/limits";

const SCHEMA = "CREATE TABLE IF NOT EXISTS counter (id INTEGER PRIMARY KEY CHECK (id = 1), day INTEGER NOT NULL, n INTEGER NOT NULL)";

export interface SignupDecision {
	allowed: boolean;
	/** Seconds until the cap resets (only meaningful when not allowed). */
	retryAfter: number;
}

export class SignupGuardDO extends DurableObject<Env> {
	/** Counts one signup attempt for today; refuses once the cap is reached. */
	async consume(now: number): Promise<SignupDecision> {
		const day = Math.floor(now / DAY_MS);
		const resetAt = (day + 1) * DAY_MS;
		const retryAfter = Math.ceil((resetAt - now) / 1000);
		const sql = this.ctx.storage.sql;
		sql.exec(SCHEMA);
		const row = sql.exec<{ day: number; n: number }>("SELECT day, n FROM counter WHERE id = 1").toArray()[0];
		const count = row !== undefined && row.day === day ? row.n : 0;
		if (count >= SIGNUP_DAILY_CAP) return { allowed: false, retryAfter };
		sql.exec(
			"INSERT INTO counter (id, day, n) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET day = excluded.day, n = excluded.n",
			day,
			count + 1,
		);
		if (count === 0) await this.ctx.storage.setAlarm(resetAt + 60_000);
		return { allowed: true, retryAfter };
	}

	override async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}
}
