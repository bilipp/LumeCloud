import CryptoKit
import Foundation
@testable import LumeCloudKit
import Testing

@Suite("HPKE pairing")
struct PairingTests {
    static let grant = LumeCloudGrant(
        accountId: "AAECAwQFBgcICQoLDA0ODw",
        rootKey: Data(0 ..< 32),
        serverURL: URL(string: "https://cloud.getlume.org")!
    )

    @Test func ciphersuiteIsX25519AESGCM256() {
        #expect(LumeCloudPairing.ciphersuite.kem == .Curve25519_HKDF_SHA256)
        #expect(LumeCloudPairing.ciphersuite.kdf == .HKDF_SHA256)
        #expect(LumeCloudPairing.ciphersuite.aead == .AES_GCM_256)
    }

    @Test func roundTrip() throws {
        let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
        #expect(Base64URL.decode(publicKey)?.count == 32)
        let sealed = try LumeCloudPairing.seal(Self.grant, to: publicKey, code: "483920")
        #expect(Base64URL.decode(sealed.enc)?.count == 32)
        let opened = try LumeCloudPairing.open(sealed, privateKey: privateKey, code: "483920")
        #expect(opened == Self.grant)
        #expect(try opened.keys() == LumeCloudKeys(rootKey: Data(0 ..< 32)))
    }

    @Test func wrongCodeFails() throws {
        let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
        let sealed = try LumeCloudPairing.seal(Self.grant, to: publicKey, code: "483920")
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try LumeCloudPairing.open(sealed, privateKey: privateKey, code: "483921")
        }
    }

    @Test func wrongPrivateKeyFails() throws {
        let (_, publicKey) = LumeCloudPairing.makeKeyPair()
        let sealed = try LumeCloudPairing.seal(Self.grant, to: publicKey, code: "1")
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try LumeCloudPairing.open(sealed, privateKey: Curve25519.KeyAgreement.PrivateKey(), code: "1")
        }
    }

    @Test func tamperedCiphertextFails() throws {
        let (privateKey, publicKey) = LumeCloudPairing.makeKeyPair()
        var sealed = try LumeCloudPairing.seal(Self.grant, to: publicKey, code: "1")
        var bytes = try #require(Base64URL.decode(sealed.ciphertext))
        bytes[0] ^= 0x80
        sealed.ciphertext = Base64URL.encode(bytes)
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try LumeCloudPairing.open(sealed, privateKey: privateKey, code: "1")
        }
    }

    @Test func badPublicKeyIsRejected() {
        #expect(throws: LumeCloudCryptoError.invalidBase64) {
            try LumeCloudPairing.seal(Self.grant, to: "not/base64url=", code: "1")
        }
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 32)) {
            try LumeCloudPairing.seal(Self.grant, to: Base64URL.encode(Data(count: 16)), code: "1")
        }
    }

    @Test func grantEncodingIsCanonical() throws {
        let json = String(bytes: try Self.grant.encoded(), encoding: .utf8)
        #expect(json == #"{"accountId":"AAECAwQFBgcICQoLDA0ODw","rootKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","serverURL":"https://cloud.getlume.org"}"#)
        #expect(try LumeCloudGrant.decode(Self.grant.encoded()) == Self.grant)
    }

    @Test func grantDecodingIgnoresUnknownKeysAndChecksTheKey() throws {
        let extra = #"{"accountId":"a","future":1,"rootKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","serverURL":"https://x.example"}"#
        #expect(try LumeCloudGrant.decode(Data(extra.utf8)).accountId == "a")
        let short = #"{"accountId":"a","rootKey":"AAEC","serverURL":"https://x.example"}"#
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 32)) { try LumeCloudGrant.decode(Data(short.utf8)) }
        #expect(throws: LumeCloudCryptoError.self) { try LumeCloudGrant.decode(Data("{}".utf8)) }
    }

    @Test func grantNeverPrintsTheRootKey() {
        var dumped = ""
        dump(Self.grant, to: &dumped)
        for text in ["\(Self.grant)", String(reflecting: Self.grant), dumped] {
            #expect(!text.contains("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
            #expect(!text.contains("32 bytes"))
        }
    }
}
