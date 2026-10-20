# Lume Cloud

Free, **end-to-end encrypted** sync for the [Lume](https://github.com/bilipp/Lume)
IPTV player across Apple platforms and Android. Data is stored in the EU.

The server is zero-knowledge. It stores opaque, versioned, encrypted records and
a per-account change feed. Keys, playlists, credentials and watch history never
leave the devices unencrypted. The account is a 32-byte key, not an email
address. New devices join with a 6-digit pairing code (HPKE key handoff).

| Directory | What |
|---|---|
| [`spec/`](spec/) | The wire contract ([`PROTOCOL.md`](spec/PROTOCOL.md)) and cross-platform test vectors. Normative for every client. |
| [`server/`](server/) | Cloudflare Worker + SQLite-backed Durable Objects (TypeScript). The official instance runs at `cloud.getlume.org`, staging at `cloud-staging.getlume.org`. |
| [`Kit/`](Kit/) | `LumeCloudKit`, the zero-dependency Swift client (CryptoKit). The Lume app consumes it as a local SPM package at `../LumeCloud/Kit`. |

The Android client (Kotlin) lives in `bilipp/LumeAndroid` and consumes `spec/`
as a git submodule.

## Self-hosting

Deploy `server/` to your own Cloudflare account; the free plan is enough for a
household. See [`server/README.md`](server/README.md).

## License

AGPL-3.0. See [LICENSE](LICENSE).
