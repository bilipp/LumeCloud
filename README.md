# Lume Cloud

Free, **end-to-end encrypted** sync for the [Lume](https://github.com/bilipp/Lume)
IPTV player across Apple platforms and Android. Playlists, credentials, watch
progress, favorites and profiles stay in step on every device. The official
instance stores data in the EU, and anyone can run their own server: on
Cloudflare or in Docker.

- **Zero-knowledge.** The server stores opaque, versioned, encrypted records
  and a per-account change feed. Keys, playlists, credentials and watch history
  never leave the devices unencrypted.
- **No email, no password.** The account is a random 32-byte root key. The
  account id and the auth token are derived from it, and the user keeps it as a
  recovery key.
- **Pairing by code.** A new device shows a 6-digit code; a device that is
  already signed in hands the key over with HPKE.
- **Realtime.** Devices hold a WebSocket and pull changes when they're poked.

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Self-hosting](#self-hosting)
  - [Docker](#option-a-docker)
  - [Cloudflare Workers](#option-b-cloudflare-workers)
  - [Configuration](#configuration)
  - [Connecting the app](#connecting-the-app)
  - [Moving an account between servers](#moving-an-account-between-servers)
- [Development](#development)
- [Limits](#limits)
- [License](#license)

## How it works

```
 device ──HTTPS / WebSocket──▶ Worker (routing, auth, rate limits)
                                ├─▶ AccountDO     one SQLite database per account
                                ├─▶ PairingDO     one per 6-digit code, gone after 10 minutes
                                └─▶ SignupGuardDO one per client IP, daily signup cap
```

The server is a Cloudflare Worker with SQLite-backed Durable Objects, written
in TypeScript. In Docker the same code runs on
[workerd](https://github.com/cloudflare/workerd), the open-source Workers
runtime, with every object stored as a SQLite file on a volume.

Every client derives three keys from the root key with HKDF: one encrypts
records (AES-256-GCM), one turns logical keys into opaque record ids (HMAC),
and one authenticates to the server. The server only ever sees the record id,
a version number and ciphertext. Conflicts are resolved on the devices with a
3-way merge. The full contract, including key derivation, endpoints, limits and
the sync algorithm, is [`spec/PROTOCOL.md`](spec/PROTOCOL.md).

## Repository layout

| Directory | What |
|---|---|
| [`spec/`](spec/) | The wire contract ([`PROTOCOL.md`](spec/PROTOCOL.md)) and cross-platform test vectors. Normative for every client. |
| [`server/`](server/) | The server (TypeScript): Cloudflare Worker + Durable Objects, plus the Docker image. The official instance runs at `cloud.getlume.org`, staging at `cloud-staging.getlume.org`. Operator docs: [`server/README.md`](server/README.md). |
| [`LumeCloudKit/`](LumeCloudKit/) | `LumeCloudKit`, the zero-dependency Swift client (CryptoKit). The Lume app consumes it as a local SPM package at `../LumeCloud/LumeCloudKit`. See [`LumeCloudKit/README.md`](LumeCloudKit/README.md). |

The Android client (Kotlin) lives in `bilipp/LumeAndroid` and consumes `spec/`
as a git submodule.

## Self-hosting

There are two ways to run your own server. Both run the same code and speak
the same protocol, so the apps don't care which one you pick.

| | Docker | Cloudflare Workers |
|---|---|---|
| Runs on | Any Linux host with Docker (amd64 or arm64) | Your Cloudflare account (the Free plan is enough for a household) |
| Data lives | In a Docker volume on your machine | In Cloudflare Durable Objects, in a jurisdiction you choose (default EU) |
| HTTPS | Bring a reverse proxy (a Caddy setup is included) | Automatic on your custom domain |
| Backups | Copy the volume | 30 days of point-in-time recovery per account |
| Rate limits | In memory, reset on restart | Cloudflare Rate Limiting, per location |

### Option A: Docker

Requirements: Docker with Compose v2. For HTTPS, a domain whose DNS points at
the host and ports 80 and 443 reachable from the internet.

```bash
git clone https://github.com/bilipp/LumeCloud.git
cd LumeCloud/server
cp .env.example .env
```

Edit `.env`: set `LUME_DOMAIN` to your domain and decide on `SIGNUP` (see
[Configuration](#configuration); the apps can't send invite codes yet, so
`open` is the setting that works with them today).

```bash
# Server plus Caddy, which obtains a certificate for LUME_DOMAIN:
docker compose --profile caddy up -d

curl https://cloud.example.com/healthz        # {"ok":true,"version":"docker"}
```

To use your own reverse proxy instead, start only the server
(`docker compose up -d`). It listens on `127.0.0.1:8787`. Forward to it, allow
WebSocket upgrades on `/v1/socket`, and set the `CF-Connecting-IP` request
header to the client's address. The server keys its per-IP limits on that
header, so the proxy must overwrite whatever the client sent.

Data lives in the `lume-cloud_lume-data` volume. Updating:

```bash
git pull
docker compose --profile caddy up -d --build
```

Backups, logs, running without Compose and how the image works are in
[`server/README.md`](server/README.md#docker).

### Option B: Cloudflare Workers

Requirements: Node 22 or newer, a Cloudflare account and a domain on
Cloudflare.

```bash
git clone https://github.com/bilipp/LumeCloud.git
cd LumeCloud/server
npm install
npx wrangler login
```

1. In `server/wrangler.jsonc`, give the `production` env your own `name`, your
   own domain in `routes`, and your own rate-limit `namespace_id`s.
2. Decide on `SIGNUP` there (see [Configuration](#configuration)). For
   `invite`, also run `npx wrangler secret put INVITE_CODE --env production`.
3. Keep `DO_JURISDICTION` at `eu` unless you need another jurisdiction, and
   decide **before** the first account is created. It can't be changed later.
4. Deploy:

   ```bash
   npm test && npm run deploy:production
   curl https://cloud.example.com/healthz
   ```

The custom domain gets its DNS record and certificate on the first deploy.
Logging, point-in-time restores and cost notes are in
[`server/README.md`](server/README.md).

### Configuration

| Setting | Docker (`.env`) | Cloudflare (`wrangler.jsonc` / secret) | Meaning |
|---|---|---|---|
| `SIGNUP` | `open` or `invite` | var | `open` lets anyone who can reach the server create an account. `invite` requires `INVITE_CODE`. Unset or any other value counts as `invite`. |
| `INVITE_CODE` | string | secret | The shared invite code. With `SIGNUP=invite` and no code, signup is closed for everyone. Existing accounts keep working. |
| `VERSION` | string | set by the deploy scripts | Reported by `/healthz`. |
| `LUME_DOMAIN` | domain | (`routes` in `wrangler.jsonc`) | Public hostname. Docker: used by the Caddy profile. |
| `PORT` | default `8787` | n/a | Docker: the host port the server binds on `127.0.0.1`. |
| `DO_JURISDICTION` | fixed to `none` | var, default `eu` | Where Durable Objects live. workerd has no jurisdictions. |

**Open or invite?** The Lume apps don't send an invite code yet, so on an
`invite` server the apps can't create accounts. Accounts can still arrive
there through [`migrate-account.mjs --invite`](#moving-an-account-between-servers),
and once an account exists, devices sign in with its recovery key or by pairing
as usual. If the apps should create accounts directly, use `open` and keep
strangers out at the network level instead: a LAN or VPN, or an allow list in
your reverse proxy. Even when open, signups are capped at 5 per minute and 10
per day per IP.

Server limits (record size, quotas, retention) are fixed in code; see
[Limits](#limits).

### Connecting the app

The apps pick their server at build time; there is no setting for it in the
app. To use your own server, build the app yourself with `LUME_CLOUD_URL` set
to its base URL, e.g. `https://cloud.example.com`:

- **Apple** ([`bilipp/Lume`](https://github.com/bilipp/Lume)): put
  `LUME_CLOUD_URL=…` in the app's `.env`. `Scripts/inject-env.sh` writes it
  into the Info.plist for every build configuration.
- **Android** (`bilipp/LumeAndroid`): put `LUME_CLOUD_URL=…` in
  `local.properties`. Only debug builds honor it; release builds always use
  `https://cloud.getlume.org`.

Use HTTPS for anything that leaves your LAN. Apple platforms refuse plain-HTTP
connections by default (App Transport Security).

### Moving an account between servers

`server/scripts/migrate-account.mjs` copies one account from one server to
another, e.g. from the official instance to your own. It needs only the
account's recovery key and copies ciphertext byte for byte without decrypting
anything. It works across Cloudflare and Docker servers alike.

```bash
cd server
LUME_RECOVERY_KEY='XXXX-XXXX-…' node scripts/migrate-account.mjs \
  --from https://cloud.getlume.org --to https://cloud.example.com --invite <code> --dry-run
# then run again without --dry-run; add --delete-source to remove the old copy
```

Afterwards every device needs the new server URL and a full resync. Details in
[`server/README.md`](server/README.md#moving-an-account-between-servers).

## Development

### Server

```bash
cd server
nvm use                 # Node 22 (.nvmrc)
npm install
npx wrangler dev        # http://localhost:8787
npm test                # vitest inside workerd
npm run typecheck
```

To try the Docker image locally: `cp .env.example .env && docker compose up -d --build`.

### Swift client

```bash
cd LumeCloudKit
swift test

# Against a running server (wrangler dev, Docker or staging):
LUME_CLOUD_E2E_URL=http://127.0.0.1:8787 swift test --filter LiveE2ETests
```

### Changing the protocol

`spec/PROTOCOL.md` is normative for the server, the Swift Kit and the Android
client. Change the spec first, then the server and both clients. The vectors in
`spec/vectors/` are shared by all clients; regenerate them as described in
[`spec/vectors/README.md`](spec/vectors/README.md).

## Limits

| | |
|---|---|
| Record size | 64 KiB of ciphertext |
| Per push | 500 records, 4 MiB |
| Per account | 10 MiB and 100,000 live records, 100 devices |
| Tombstones | purged after 90 days |
| Inactive accounts | purged after 365 days without an authenticated request |
| Signups | 5 per minute and 10 per day per IP |

Rate limits per endpoint are listed in
[`server/README.md`](server/README.md#configuration).

## License

AGPL-3.0. See [LICENSE](LICENSE). If you run a modified server for other
people, the AGPL requires you to offer them its source.
