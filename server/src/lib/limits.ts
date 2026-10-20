// Server-side limits and lifecycle constants (PROTOCOL.md §5).

export const MAX_RECORD_BYTES = 65_536; // decoded ciphertext per record
export const MAX_PUSH_RECORDS = 500;
export const MAX_PUSH_BODY_BYTES = 4 * 1024 * 1024; // 4 MiB request body
export const MAX_ACCOUNT_BYTES = 10 * 1024 * 1024; // 10 MiB live ciphertext
export const MAX_ACCOUNT_RECORDS = 100_000; // live records
/** Tombstones are small but unbounded otherwise; cap them as abuse control. */
export const MAX_ACCOUNT_TOMBSTONES = 100_000;
export const MAX_DEVICES = 100;

export const CHANGES_DEFAULT_LIMIT = 500;
export const CHANGES_MAX_LIMIT = 1000;

export const DAY_MS = 24 * 60 * 60 * 1000;
export const TOMBSTONE_TTL_MS = 90 * DAY_MS;
export const INACTIVITY_TTL_MS = 365 * DAY_MS;

export const PAIRING_TTL_MS = 10 * 60 * 1000;
export const PAIRING_CODE_ATTEMPTS = 8;
export const MAX_SEALED_BYTES = 8 * 1024;

export const SIGNUP_DAILY_CAP = 10;

/** Upper bound for small JSON bodies (accounts, devices, pairings). */
export const MAX_SMALL_BODY_BYTES = 16 * 1024;

export const MAX_DEVICE_NAME_CHARS = 100;
