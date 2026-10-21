import CryptoKit
import Foundation
@testable import LumeCloudKit
import Testing

/// `spec/vectors/crypto.json` — the cross-platform known answers.
///
/// `committedVectorsMatch` regenerates every deterministic value from the
/// fixed inputs below and compares it with the committed file, so any drift in
/// the Kit (or a hand edit of the file) fails. The HPKE section can't be
/// regenerated (CryptoKit picks the ephemeral key), so it is verified by
/// opening it instead.
///
/// Regenerate after an intentional change with:
///
///     LUME_CLOUD_WRITE_VECTORS=1 swift test --filter CryptoVectorTests
@Suite("Crypto vectors")
struct CryptoVectorTests {
    static let fileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LumeCloudKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LumeCloudKit
        .deletingLastPathComponent() // repo root
        .appending(path: "spec/vectors/crypto.json")

    // MARK: Fixed inputs

    static let rootKey = Data(0 ..< 32)
    /// Derived from `rootKey` (§2.1), like every real account id.
    static var accountId: String { try! LumeCloudKeys(rootKey: rootKey).accountId } // swiftlint:disable:this force_try
    static let profileUUID = "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
    static let pairingPrivateKey = Data(0x20 ..< 0x40)
    static let pairingCode = "483920"

    static var payloads: [(payload: LumeCloudPayload, nonce: Data)] {
        [
            (
                LumeCloudPayload(type: "profile", key: "profile/\(profileUUID)", data: [
                    "id": .string(profileUUID),
                    "name": "Zoë's \"Room\"",
                    "symbolName": "star.fill",
                    "colorRaw": "blue",
                    "createdAt": 1_760_000_000_000,
                    "sortOrder": 1,
                    "isChild": true,
                    "updatedAt": 1_760_000_123_456,
                ]),
                Data(0xA0 ..< 0xAC)
            ),
            (
                LumeCloudPayload(type: "content", key: "content/\(profileUUID)/movie-1001", data: [
                    "contentId": "movie-1001",
                    "kindRaw": "movie",
                    "profileID": .string(profileUUID),
                    "watchProgress": 1234.5,
                    "isWatched": false,
                    "lastWatchedDate": 1_760_000_200_000,
                    "isFavorite": true,
                    "addedToWatchlistDate": nil,
                    "favoriteOrder": 3,
                    "isHidden": false,
                    "customOrder": nil,
                    "recommendationVoteRaw": -1,
                    "updatedAt": 1_760_000_200_000,
                    // An unknown field that pins the canonical-JSON corner cases.
                    "futureField": ["nested": ["é", "a/b", "line\nbreak\u{01}", 0.00001, 1e-7, 1e21]],
                ]),
                Data(0xB0 ..< 0xBC)
            ),
        ]
    }

    // MARK: Document

    struct Vectors: Codable, Equatable {
        struct Derived: Codable, Equatable {
            var info: String
            var value: String
        }

        struct Keys: Codable, Equatable {
            var rootKeyHex: String
            var rootKey: String
            var hkdf: String
            var encKey: Derived
            var idKey: Derived
            var authKey: Derived
            var authVerifier: String
            var authToken: String
            /// HKDF `info` of the 16-byte account id.
            var accountIdInfo: String
            var accountId: String
            var authorizationHeader: String
        }

        struct RecoveryKey: Codable, Equatable {
            var rendering: String
            /// Inputs that must decode to `rootKey`.
            var acceptedVariants: [String]
            /// Inputs with a single-symbol typo that must fail the checksum.
            var rejectedTypos: [String]
        }

        struct Record: Codable, Equatable {
            var logicalKey: String
            var rid: String
            var payload: JSONValue
            var canonicalPayload: String
            var nonceHex: String
            var envelope: String
        }

        struct UnsupportedEnvelope: Codable, Equatable {
            var rid: String
            var envelope: String
            var versionByte: Int
        }

        struct Pairing: Codable, Equatable {
            var suite: String
            var info: String
            var code: String
            var recipientPrivateKey: String
            var recipientPublicKey: String
            var grant: JSONValue
            var canonicalGrant: String
            var enc: String
            var ciphertext: String
        }

        var format: String
        var version: Int
        var notes: [String]
        var keys: Keys
        var recoveryKey: RecoveryKey
        var records: [Record]
        var unsupportedEnvelope: UnsupportedEnvelope
        var pairing: Pairing
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func string(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8)!
    }

    static func pairingKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pairingPrivateKey)
    }

    static var grant: LumeCloudGrant {
        LumeCloudGrant(accountId: accountId, rootKey: rootKey, serverURL: LumeCloudAPI.stagingURL)
    }

    /// Everything deterministic, plus the given (random) HPKE `enc` and `ciphertext`.
    static func generate(sealed: SealedGrant) throws -> Vectors {
        let keys = try LumeCloudKeys(rootKey: rootKey)
        let rendering = LumeCloudRecoveryKey.encode(keys)

        let records = try payloads.map { payload, nonce in
            let rid = keys.recordID(for: payload.key)
            let canonical = try payload.encoded()
            return try Vectors.Record(
                logicalKey: payload.key,
                rid: rid,
                payload: JSONDecoder().decode(JSONValue.self, from: canonical),
                canonicalPayload: string(canonical),
                nonceHex: hex(nonce),
                envelope: keys.seal(canonical, rid: rid, nonce: nonce)
            )
        }

        guard var unsupported = Base64URL.decode(records[0].envelope) else {
            throw LumeCloudCryptoError.invalidBase64
        }
        unsupported[0] = 0x02

        let compact = rendering.replacingOccurrences(of: "-", with: "")
        var typo = Array(compact)
        typo[0] = typo[0] == "0" ? "1" : "0"
        var swapped = Array(compact)
        let swapIndex = swapped.indices.first { swapped[$0] != swapped[$0 + 1] }!
        swapped.swapAt(swapIndex, swapIndex + 1)

        let privateKey = try pairingKey()
        let grant = Self.grant
        return try Vectors(
            format: "lume-cloud-crypto-vectors",
            version: 1,
            notes: [
                "Binary values are base64url without padding unless the field name ends in Hex.",
                "Derived keys: HKDF-SHA256(IKM = rootKey, salt = empty, info, L = 32).",
                "accountId = base64url(HKDF-SHA256(IKM = rootKey, salt = empty, info = accountIdInfo, L = 16)).",
                "rid = base64url(HMAC-SHA256(idKey, UTF8(logicalKey))).",
                "envelope = base64url(0x01 || nonce || AES-256-GCM(encKey, nonce, canonicalPayload, AAD = UTF8(rid)) || tag).",
                "canonicalPayload is RFC 8785 (JCS) JSON: keys sorted by UTF-16 code units, ECMAScript number formatting, JSON.stringify string escaping.",
                "A client MUST skip (and keep) unsupportedEnvelope rather than fail or delete it.",
                "Pairing: HPKE base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM, info and aad = UTF8(code). enc/ciphertext were sealed once with a random ephemeral key; verify by opening, not by re-sealing.",
                "Recovery key: Crockford base32 of the 256 key bits (big-endian, 4 zero pad bits), plus the Crockford mod-37 check symbol, grouped by 4.",
            ],
            keys: Vectors.Keys(
                rootKeyHex: hex(rootKey),
                rootKey: Base64URL.encode(rootKey),
                hkdf: "HKDF-SHA256, salt = empty, L = 32",
                encKey: .init(info: LumeCloudKeys.Info.enc, value: Base64URL.encode(keys.encKey)),
                idKey: .init(info: LumeCloudKeys.Info.id, value: Base64URL.encode(keys.idKey)),
                authKey: .init(info: LumeCloudKeys.Info.auth, value: Base64URL.encode(keys.authKey)),
                authVerifier: keys.authVerifier,
                authToken: keys.authToken,
                accountIdInfo: LumeCloudKeys.Info.account,
                accountId: keys.accountId,
                authorizationHeader: LumeCloudClient.Credentials(keys: keys, deviceID: UUID()).authorizationHeader
            ),
            recoveryKey: Vectors.RecoveryKey(
                rendering: rendering,
                acceptedVariants: [
                    compact,
                    rendering.lowercased().replacingOccurrences(of: "-", with: " "),
                    rendering.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l"),
                ],
                rejectedTypos: [String(typo), String(swapped)]
            ),
            records: records,
            unsupportedEnvelope: Vectors.UnsupportedEnvelope(
                rid: records[0].rid,
                envelope: Base64URL.encode(unsupported),
                versionByte: 2
            ),
            pairing: Vectors.Pairing(
                suite: "DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM",
                info: string(LumeCloudPairing.info),
                code: pairingCode,
                recipientPrivateKey: Base64URL.encode(privateKey.rawRepresentation),
                recipientPublicKey: Base64URL.encode(privateKey.publicKey.rawRepresentation),
                grant: JSONDecoder().decode(JSONValue.self, from: grant.encoded()),
                canonicalGrant: string(grant.encoded()),
                enc: sealed.enc,
                ciphertext: sealed.ciphertext
            )
        )
    }

    static func encode(_ vectors: Vectors) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(vectors) + Data("\n".utf8)
    }

    static func load() throws -> Vectors? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    /// The committed pairing ciphertext, if it still opens to the expected grant.
    static func validSealed(in vectors: Vectors?) -> SealedGrant? {
        guard let pairing = vectors?.pairing else { return nil }
        let sealed = SealedGrant(enc: pairing.enc, ciphertext: pairing.ciphertext)
        guard let grant = try? LumeCloudPairing.open(sealed, privateKey: pairingKey(), code: pairingCode),
              grant == Self.grant else { return nil }
        return sealed
    }

    // MARK: Tests

    @Test func committedVectorsMatch() throws {
        if ProcessInfo.processInfo.environment["LUME_CLOUD_WRITE_VECTORS"] == "1" {
            // An older file may not decode any more; then the pairing is resealed too.
            let committed = (try? Self.load()) ?? nil
            let sealed = try Self.validSealed(in: committed)
                ?? LumeCloudPairing.seal(Self.grant, to: Base64URL.encode(Self.pairingKey().publicKey.rawRepresentation), code: Self.pairingCode)
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(Self.generate(sealed: sealed)).write(to: Self.fileURL, options: .atomic)
            return
        }

        let vectors = try #require(try Self.load(), "spec/vectors/crypto.json is missing; run with LUME_CLOUD_WRITE_VECTORS=1")
        let sealed = try #require(Self.validSealed(in: vectors), "the committed pairing vector doesn't open")
        let expected = try Self.generate(sealed: sealed)
        #expect(vectors.keys == expected.keys)
        #expect(vectors.recoveryKey == expected.recoveryKey)
        #expect(vectors.records == expected.records)
        #expect(vectors.unsupportedEnvelope == expected.unsupportedEnvelope)
        #expect(vectors.pairing == expected.pairing)
        #expect(vectors == expected)
        // Byte-for-byte, so formatting drift shows up too.
        #expect(try Data(contentsOf: Self.fileURL) == Self.encode(expected))
    }

    /// Consumes the committed file the way another implementation would:
    /// only through the public API and the file's own values.
    @Test func committedVectorsVerifyThroughPublicAPI() throws {
        let vectors = try #require(try Self.load())
        let rootKey = try #require(Base64URL.decode(vectors.keys.rootKey))
        let keys = try LumeCloudKeys(rootKey: rootKey)
        #expect(Base64URL.encode(keys.encKey) == vectors.keys.encKey.value)
        #expect(Base64URL.encode(keys.idKey) == vectors.keys.idKey.value)
        #expect(Base64URL.encode(keys.authKey) == vectors.keys.authKey.value)
        #expect(keys.authVerifier == vectors.keys.authVerifier)
        #expect(keys.accountId == vectors.keys.accountId)
        #expect(vectors.keys.authorizationHeader == "Bearer \(vectors.keys.accountId).\(keys.authToken)")

        #expect(LumeCloudRecoveryKey.encode(keys) == vectors.recoveryKey.rendering)
        for variant in vectors.recoveryKey.acceptedVariants {
            #expect(try LumeCloudRecoveryKey.decode(variant) == rootKey)
        }
        for typo in vectors.recoveryKey.rejectedTypos {
            #expect(throws: LumeCloudCryptoError.recoveryKeyChecksumMismatch) { try LumeCloudRecoveryKey.decode(typo) }
        }

        for record in vectors.records {
            #expect(keys.recordID(for: record.logicalKey) == record.rid)
            let plaintext = try keys.open(record.envelope, rid: record.rid)
            #expect(Self.string(plaintext) == record.canonicalPayload)
            let payload = try LumeCloudPayload.decode(plaintext)
            #expect(try Self.string(payload.encoded()) == record.canonicalPayload)
            #expect(try Self.string(record.payload.canonicalJSON()) == record.canonicalPayload)
        }

        #expect(throws: LumeCloudCryptoError.unsupportedEnvelopeVersion(UInt8(vectors.unsupportedEnvelope.versionByte))) {
            try keys.open(vectors.unsupportedEnvelope.envelope, rid: vectors.unsupportedEnvelope.rid)
        }

        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: #require(Base64URL.decode(vectors.pairing.recipientPrivateKey))
        )
        let sealed = SealedGrant(enc: vectors.pairing.enc, ciphertext: vectors.pairing.ciphertext)
        let grant = try LumeCloudPairing.open(sealed, privateKey: privateKey, code: vectors.pairing.code)
        #expect(try Self.string(grant.encoded()) == vectors.pairing.canonicalGrant)
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try LumeCloudPairing.open(sealed, privateKey: privateKey, code: "000000")
        }
    }
}
