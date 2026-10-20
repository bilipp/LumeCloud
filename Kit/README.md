# LumeCloudKit

The Swift client for Lume Cloud: key derivation, the record envelope,
canonical payloads, recovery keys, HPKE pairing, and a small async
HTTP/WebSocket client. It uses **Foundation and CryptoKit only**, with no
third-party dependencies.

- Platforms: iOS 18, tvOS 18, macOS 15, visionOS 2. Swift 6 language mode.
- The wire contract is [`../spec/PROTOCOL.md`](../spec/PROTOCOL.md). The
  known-answer vectors are in [`../spec/vectors/`](../spec/vectors/README.md).
- Lume consumes it as a **local package** at `../LumeCloud/Kit` (product
  `LumeCloudKit`, linked statically), like `../LumeRecorder/Kit`.

The Kit knows nothing about Lume's SwiftData models and doesn't run the sync
loop. Mapping models to payloads, the per-record bookkeeping, and the 3-way
merge (§6) belong to the app. Every type is `Sendable` and nonisolated, so call
it from a background actor.

## API overview

| Type | Purpose |
|---|---|
| `LumeCloudKeys` | `init(rootKey:)` / `generate()`. Derives `encKey`, `idKey`, `authKey`; provides `authVerifier`, `authToken`, `recordID(for:)`, `seal(_:rid:)`, `open(_:rid:)`, and `seal(_ payload:)` / `openPayload(_:rid:)`. Its description is redacted. |
| `LumeCloudRecoveryKey` | `encode(_:)` / `decode(_:)` / `keys(from:)`: the root key as grouped Crockford base32 with a mod-37 check symbol. |
| `JSONValue` | Any JSON value. Codable, Hashable, with literals and accessors. `canonicalJSON()` writes RFC 8785 JSON. |
| `LumeCloudPayload` | `{v, type, key, data}` plus `extra` (unknown top-level fields). `encoded()` is canonical; `decode(_:)` keeps unknown fields. |
| `LumeCloudPairing`, `LumeCloudGrant`, `SealedGrant` | HPKE handoff of `{accountId, rootKey, serverURL}` to a new device. |
| `LumeCloudClient` | Every endpoint of §4 plus `events()` (the WebSocket) and `allChanges(since:)`. |
| `LumeCloudError` | One case per protocol error code, plus `.server`, `.transport`, `.decoding` and `.missingCredentials`. |
| `LumeCloudCryptoError` | Local failures: key length, base64url, envelope, recovery key, payload. |

### Rules the Kit keeps

- **No retries.** The client never retries a request, never reconnects the
  socket, and never resends a `POST`/`DELETE`. Backoff (including
  `.rateLimited(retryAfter:)`), conflict rounds and reconnects are the app's
  decision.
- **No secrets in errors or logs.** Tokens travel only in the `Authorization`
  header. `LumeCloudKeys`, `LumeCloudGrant`, `Credentials` and `PairingTicket`
  redact their descriptions and mirrors. A `.transport` `URLError` is rebuilt
  without its failing URL, because the pairing poll URL carries the poll token.
  `.decoding` names only the coding path.
- **Unknown envelope versions** throw `.unsupportedEnvelopeVersion`. Skip such a
  record and keep it; never overwrite or delete it (§2.4).

## Usage

```swift
import LumeCloudKit

// Create an account on the first device.
let keys = LumeCloudKeys.generate()                 // store keys.rootKey in the Keychain
let anonymous = LumeCloudClient(baseURL: LumeCloudAPI.officialURL, credentials: nil)
let account = try await anonymous.createAccount(authVerifier: keys.authVerifier)
let deviceID = UUID()
let client = anonymous.withCredentials(.init(accountId: account.accountId, keys: keys, deviceID: deviceID))
_ = try await client.registerDevice(id: deviceID, name: "Philipp's iPhone", platform: .current)

// Push a record.
let payload = LumeCloudPayload(type: "content", key: "content/\(profileID)/\(contentID)", data: [
    "contentId": .string(contentID), "watchProgress": 812.5, "isWatched": false, "updatedAt": 1_760_000_000_000,
])
let (rid, ciphertext) = try keys.seal(payload)
let response = try await client.push([.upsert(rid: rid, baseVersion: 0, ciphertext: ciphertext)])
for result in response.results {
    switch result {
    case let .ok(rid, version, _): break             // store version + payload as the merge base
    case let .conflict(rid, current): break          // merge with current, then push again
    }
}

// Pull.
let page = try await client.allChanges(since: storedNextSeq)
for record in page.records {
    guard let ciphertext = record.ciphertext else { continue /* tombstone */ }
    do {
        let payload = try keys.openPayload(ciphertext, rid: record.rid)
    } catch LumeCloudCryptoError.unsupportedEnvelopeVersion {
        // Written by a newer client: skip it and keep it.
    }
}

// Realtime hints. The app owns the reconnect policy.
for try await seq in client.events() { /* pull /changes */ }
```

Pairing a new device:

```swift
// New device (no credentials yet).
let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
let ticket = try await anonymous.startPairing(publicKey: publicKey, deviceName: "Living Room", platform: .tvOS)
// Show ticket.code, then poll every 2 s:
if case let .sealed(sealed) = try await anonymous.pairingResult(code: ticket.code, pollToken: ticket.pollToken) {
    let grant = try LumeCloudPairing.open(sealed, privateKey: privateKey, code: ticket.code)
    let keys = try grant.keys()                     // then registerDevice with these credentials
}

// Joined device, after the user typed the code and confirmed the name.
let request = try await client.pairingRequest(code: code)
let grant = LumeCloudGrant(accountId: accountId, rootKey: keys.rootKey, serverURL: client.baseURL)
try await client.sealPairing(code: code, sealed: LumeCloudPairing.seal(grant, to: request.publicKey, code: code))
```

The pairing `code` is the HPKE AAD, so both sides must pass the same string.
Normalize what the user typed (strip spaces) before calling `pairingRequest`.

## Tests

```bash
cd Kit
swift test
```

The suite covers:

- known answers for HKDF, HMAC and AES-GCM, checked against RFC vectors and
  values computed independently in Python;
- envelope failure modes;
- the recovery key, including every single-symbol typo and adjacent swap;
- canonical JSON;
- the HPKE round trip and a wrong-code failure;
- every endpoint's method, path, headers and body, through a `URLProtocol`
  stub, plus status → error mapping including `Retry-After`;
- `spec/vectors/crypto.json`, re-verified on every run.

Regenerate the vectors after an intentional change:

```bash
LUME_CLOUD_WRITE_VECTORS=1 swift test --filter CryptoVectorTests
```

### Live end-to-end test

`LiveE2ETests` is skipped unless `LUME_CLOUD_E2E_URL` is set. It covers this
sequence:

1. Create an account with fresh keys and register a device.
2. Push two sealed payloads, pull them, and decrypt them.
3. Push a stale `baseVersion` and check the conflict.
4. Delete a record and check its tombstone.
5. Observe a socket poke.
6. Run a full pairing round trip; the second device must read the records.
7. Revoke the second device.
8. Delete the account and check that later calls fail with `.accountDeleted`.

```bash
# Staging
LUME_CLOUD_E2E_URL=https://cloud-staging.getlume.org swift test --filter LiveE2ETests

# Local server (cd ../server && npx wrangler dev --port 8787)
LUME_CLOUD_E2E_URL=http://127.0.0.1:8787 swift test --filter LiveE2ETests
```

If the instance runs `SIGNUP=invite`, also set `LUME_CLOUD_E2E_INVITE`. The
test deletes its account at the end, even when it fails.
