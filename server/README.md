# Lume Cloud — server

The sync backend for [Lume](https://github.com/bilipp/Lume): an end-to-end
encrypted, zero-knowledge store for user data (playlists, watch progress,
favorites, profiles, …). It runs on **Cloudflare Workers + SQLite-backed
Durable Objects**, written in TypeScript.

The server only ever sees opaque ciphertext, record ids (HMACs) and a per-account
change feed. It never sees keys, plaintext, logical keys or catalog ids. The
wire contract is [`../spec/PROTOCOL.md`](../spec/PROTOCOL.md); it is normative.

```
client ──HTTPS / WebSocket──▶ Worker (src/index.ts, router, auth, rate limits)
                               ├─▶ AccountDO     one per account   (idFromName(accountId), EU)
                               ├─▶ PairingDO     one per 6-digit code, 10-min alarm (EU)
                               └─▶ SignupGuardDO one per client IP /64, daily signup cap (EU)
```

| Path | What |
|---|---|
| `src/index.ts` | Worker entry: routing, error envelope, one structured log line per request |
| `src/router.ts` | Route table |
| `src/routes/` | Request parsing and validation per endpoint group |
| `src/do/account.ts` | Accounts, devices, records + change feed, quotas, compaction, inactivity purge, sockets, PITR |
| `src/do/pairing.ts` | HPKE pairing handoff (first seal wins, deleted after one fetch or on expiry) |
| `src/do/signup-guard.ts` | Daily signup counter per IP |
| `src/lib/` | base64url, auth parsing, IP keying, limits, stubs (jurisdiction), types |
| `admin/` | Temporary operator Worker for point-in-time restores (not normally deployed) |
| `test/` | `@cloudflare/vitest-plugin` tests, run inside workerd |

## Requirements

- **Node 22** or newer. Wrangler 4.15x refuses Node 20.
  With nvm: `nvm use 22` (there is an `.nvmrc`).
- `npm install`

## Local development

```bash
npx wrangler dev          # http://localhost:8787
curl localhost:8787/healthz
```

Local workerd does not implement Durable Object jurisdictions, so the top-level
(dev) config sets `DO_JURISDICTION=none`. Deployed environments use `eu`.
Local state lives in `.wrangler/` (gitignored).

## Tests

```bash
npx vitest run            # or: npm test
npm run typecheck         # tsc --noEmit for src/ + admin/, and for test/
```

The suite covers accounts (create/auth/bad auth/delete, unknown ids never
allocate storage), signup controls (invite mode, burst limit, daily cap),
devices (register/list/revoke, revoked ids can't re-register), push/changes
(ordering, pagination, conflicts, duplicates, tombstones, `since=0`),
limits (`413` record/body/count, `507` bytes/records, nothing applied),
compaction + `410`, the inactivity purge, the once-a-day `lastSeen` write,
the full pairing round trip (`409`, expiry, poll token, code shape, rate
limit) and the WebSocket (seq poke, ping/pong, close on delete).

After changing `wrangler.jsonc`, regenerate binding types: `npm run types`.

## Configuration

| Name | Kind | Values | Meaning |
|---|---|---|---|
| `SIGNUP` | var | `open` \| `invite` | `invite` requires `INVITE_CODE` on `POST /v1/accounts`. Any other value is treated as `invite` (fail closed). |
| `INVITE_CODE` | secret, optional | string | Shared invite code for private instances. With `SIGNUP=invite` and no code set, signup is closed for everyone. |
| `VERSION` | var | string | Reported by `/healthz`. The deploy scripts set it to the git sha / tag. |
| `DO_JURISDICTION` | var | `eu` \| `us` \| `fedramp` \| `fedramp-high` \| `none` | Jurisdiction for every Durable Object. Missing or unknown → `eu`. Only `none` (local dev) disables it. **Never change it on a live instance**: objects don't move, so existing accounts would become unreachable. |

Rate limits (Workers Rate Limiting binding; counters are per Cloudflare
location, windows of 10 or 60 s):

| Binding | Key | Limit |
|---|---|---|
| `RL_SIGNUP` | client IP (/64) | 5 / 60 s |
| `RL_PAIRING_CREATE` | client IP (/64) | 10 / 60 s |
| `RL_PAIRING_LOOKUP` | account | 10 / 60 s |
| `RL_PAIRING_POLL` | client IP (/64) | 120 / 60 s |
| `RL_ACCOUNT` | account (every authenticated request) | 300 / 60 s |

The daily cap of 10 signups per IP lives in `SignupGuardDO`. `namespace_id`s
must be unique per Cloudflare account; staging uses `710x`, production `720x`.

Limits and lifetimes are in `src/lib/limits.ts`: 64 KiB per record, 500
records / 4 MiB per push, 10 MiB and 100,000 live records per account,
100,000 pending tombstones, 100 devices, tombstones purged after 90 days,
accounts purged after 365 days without an authenticated request.

## Deploy

Environments live in `wrangler.jsonc`. The top level is local-only.

| Env | Worker | Domain |
|---|---|---|
| `staging` | `lume-cloud-staging` | `https://cloud-staging.getlume.org` |
| `production` | `lume-cloud` | `https://cloud.getlume.org` |

```bash
npx wrangler login                      # once, or export CLOUDFLARE_API_TOKEN
npm test && npm run typecheck
npm run deploy:staging                  # wrangler deploy --env staging
npm run deploy:production               # wrangler deploy --env production
```

The custom domain (`routes[].custom_domain`) creates the DNS record and
certificate on first deploy. `workers_dev` and preview URLs are off.

Durable Object classes are declared with the declarative `exports` field (not
the legacy `migrations` array). Renaming or removing a class later is a change
to `exports` (`state: "renamed" | "deleted"`); never just delete an entry.

Secrets: `npx wrangler secret put INVITE_CODE --env <env>` (only for invite-only
instances). Note `secret put` deploys immediately.

Logging: Workers Logs is on with sampling (staging 100 %, production 5 %),
**invocation logs are off** (they include request headers, i.e. the
`Authorization` header), query strings are redacted, traces are off. The Worker
itself logs one JSON line per request: method + route template, status,
duration. It never logs bodies, headers, keys, tokens, ciphertext, raw paths or
IPs.

## Self-hosting

Anyone can run their own instance on their own Cloudflare account; the Workers
Free plan is plenty for a household (SQLite-backed Durable Objects are
available on Free).

1. Fork/clone, `cd server && npm install`.
2. In `wrangler.jsonc`, give the `production` env your own `name`, your own
   domain in `routes`, and your own rate-limit `namespace_id`s.
3. For a private instance set `"SIGNUP": "invite"` and
   `npx wrangler secret put INVITE_CODE --env production`.
4. Keep `DO_JURISDICTION` at `eu` unless you have a reason to pick another
   jurisdiction, and decide **before** the first account is created.
5. `npm run deploy:production`, then enter your URL in the app.

There is no Docker image. Running workerd on your own hardware is possible in
principle but not supported.

## PITR restore runbook

SQLite-backed Durable Objects keep 30 days of point-in-time history per object,
so restores happen **per account**. There is no admin route in the public
Worker. A restore uses a small, temporary operator Worker (`admin/`) that binds
to the main Worker's `AccountDO` class and calls its `pitrRestore()` RPC. PITR
isn't available locally; rehearse on staging first.

1. Get the `accountId` from the user (Settings ▸ Lume Cloud shows it) and the
   UTC time to restore to. Restoring rewinds **everything** in that account:
   records, devices, revocations, the change feed. Clients then see older
   `seq`s, so tell the user to expect a full resync.
2. Deploy the operator Worker with a fresh, long token:

   ```bash
   cd server
   npx wrangler deploy -c admin/wrangler.jsonc            # staging; add --env production for prod
   openssl rand -base64 48 | npx wrangler secret put ADMIN_TOKEN -c admin/wrangler.jsonc
   ```

3. Restore (it prints the bookmark used and an `undoBookmark`; keep both):

   ```bash
   curl -X POST https://lume-cloud-admin-staging.<subdomain>.workers.dev/restore \
     -H "Authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
     -d '{"accountId":"<22-char id>","at":<epoch ms>}'
   ```

   To revert, call it again with `{"accountId":"…","bookmark":"<undoBookmark>"}`.
   A deleted account (≤ 30 days ago) can be brought back the same way with a
   time before the deletion.
4. Verify with the user's device (or `GET /v1/accounts/me`), then **delete the
   operator Worker**: `npx wrangler delete -c admin/wrangler.jsonc` (and
   `--env production` if used). Never leave it deployed.

The restore restarts the object; the inactivity/compaction alarm is re-armed by
the next authenticated request on a new UTC day, or by the next alarm.

## Cost notes

- Each account is kilobytes to ~1 MB of SQLite, so storage is negligible
  (Paid: 5 GB-month included, then $0.20/GB-month).
- The real drivers are requests and **row writes** (Paid: 50 M/month included,
  then $1/M; Free: 100k/day). The server keeps them low on purpose:
  - `lastSeen` (account and device) is written at most once per UTC day;
  - the alarm is set at account creation, re-armed only by the alarm itself,
    and pulled forward by a delete only when needed (each `setAlarm` is a row
    write);
  - a push writes one row per changed record plus at most four counter rows;
    re-registering an unchanged device writes nothing;
  - lookups of unknown accounts or pairing codes never create storage.
- WebSockets use the Hibernation API, and `ping` is auto-answered without
  waking the object, so idle sockets don't accrue duration charges.
- Rate-limit and signup checks happen in the Worker before any Durable Object
  is touched where possible.
- The Workers Free plan fails hard at its daily limits (requests error until
  00:00 UTC). Move the official instance to Workers Paid before public launch
  and set a billing alert.
