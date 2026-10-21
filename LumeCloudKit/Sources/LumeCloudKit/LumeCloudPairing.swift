import CryptoKit
import Foundation

/// What the joined device hands a new device during pairing (PROTOCOL.md §4.5).
/// Its JSON form is canonical: `{"accountId":…,"rootKey":"<b64url>","serverURL":…}`.
public struct LumeCloudGrant: Sendable, Hashable {
    public var accountId: String
    public var rootKey: Data
    public var serverURL: URL

    public init(accountId: String, rootKey: Data, serverURL: URL) {
        self.accountId = accountId
        self.rootKey = rootKey
        self.serverURL = serverURL
    }

    /// Canonical JSON (keys sorted, no whitespace).
    public func encoded() throws -> Data {
        try JSONValue.object([
            "accountId": .string(accountId),
            "rootKey": .string(Base64URL.encode(rootKey)),
            "serverURL": .string(serverURL.absoluteString),
        ]).canonicalJSON()
    }

    /// Parses a grant; unknown keys are ignored.
    public static func decode(_ data: Data) throws -> LumeCloudGrant {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let accountId = value["accountId"]?.stringValue,
              let rootKeyString = value["rootKey"]?.stringValue,
              let serverURLString = value["serverURL"]?.stringValue,
              let serverURL = URL(string: serverURLString)
        else {
            throw LumeCloudCryptoError.invalidPayload("not a pairing grant")
        }
        guard let rootKey = Base64URL.decode(rootKeyString) else {
            throw LumeCloudCryptoError.invalidBase64
        }
        guard rootKey.count == LumeCloudKeys.keyByteCount else {
            throw LumeCloudCryptoError.invalidKeyLength(expected: LumeCloudKeys.keyByteCount)
        }
        return LumeCloudGrant(accountId: accountId, rootKey: rootKey, serverURL: serverURL)
    }

    /// The keys derived from `rootKey`.
    public func keys() throws -> LumeCloudKeys {
        try LumeCloudKeys(rootKey: rootKey)
    }
}

extension LumeCloudGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "LumeCloudGrant(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// An HPKE-sealed `LumeCloudGrant`: the body of `POST /v1/pairings/{code}/seal`
/// and of a `sealed` poll result. Both fields are base64url.
public struct SealedGrant: Codable, Sendable, Hashable {
    /// The HPKE encapsulated key (the sender's ephemeral X25519 public key).
    public var enc: String
    public var ciphertext: String

    public init(enc: String, ciphertext: String) {
        self.enc = enc
        self.ciphertext = ciphertext
    }
}

/// HPKE base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM,
/// `info = "lume-cloud/v1/pairing"`, `aad = UTF8(code)` (PROTOCOL.md §4.5).
public enum LumeCloudPairing {
    /// CryptoKit has no predefined constant for this suite (only the
    /// ChaChaPoly variant), so it is assembled from its parts.
    public static let ciphersuite = HPKE.Ciphersuite(
        kem: .Curve25519_HKDF_SHA256,
        kdf: .HKDF_SHA256,
        aead: .AES_GCM_256
    )
    static let info = Data("lume-cloud/v1/pairing".utf8)

    /// A fresh X25519 key pair for the new device. Keep the private key in
    /// memory until the poll finishes; send `publicKey` to `startPairing`.
    public static func makeKeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: String) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (privateKey, Base64URL.encode(privateKey.publicKey.rawRepresentation))
    }

    /// Seals `grant` to the new device's public key (raw 32-byte X25519,
    /// base64url), binding it to the pairing `code`.
    public static func seal(_ grant: LumeCloudGrant, to publicKeyB64: String, code: String) throws -> SealedGrant {
        guard let raw = Base64URL.decode(publicKeyB64) else {
            throw LumeCloudCryptoError.invalidBase64
        }
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            throw LumeCloudCryptoError.invalidKeyLength(expected: 32)
        }
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: ciphersuite, info: info)
        let ciphertext = try sender.seal(grant.encoded(), authenticating: Data(code.utf8))
        return SealedGrant(
            enc: Base64URL.encode(sender.encapsulatedKey),
            ciphertext: Base64URL.encode(ciphertext)
        )
    }

    /// Opens a sealed grant with the new device's private key. Throws
    /// `.authenticationFailed` for a wrong code, wrong key or tampered data.
    public static func open(
        _ sealed: SealedGrant,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        code: String
    ) throws -> LumeCloudGrant {
        guard let enc = Base64URL.decode(sealed.enc), let ciphertext = Base64URL.decode(sealed.ciphertext) else {
            throw LumeCloudCryptoError.invalidBase64
        }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: ciphersuite,
                info: info,
                encapsulatedKey: enc
            )
            plaintext = try recipient.open(ciphertext, authenticating: Data(code.utf8))
        } catch {
            throw LumeCloudCryptoError.authenticationFailed
        }
        return try LumeCloudGrant.decode(plaintext)
    }
}
