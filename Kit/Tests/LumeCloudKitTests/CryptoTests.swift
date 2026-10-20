import CryptoKit
import Foundation
@testable import LumeCloudKit
import Testing

/// Known answers computed independently (Python `cryptography` + `hmac`), not
/// by this Kit, plus the RFC test vectors of the primitives underneath.
@Suite("Keys & envelope")
struct CryptoTests {
    static let rootKey = Data(0 ..< 32)
    static let profileKey = "profile/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    private static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: Primitives

    @Test func hkdfMatchesRFC5869TestCase3() {
        // RFC 5869 A.3: SHA-256, zero-length salt and info.
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(repeating: 0x0B, count: 22)),
            salt: Data(),
            info: Data(),
            outputByteCount: 42
        ).withUnsafeBytes { Data($0) }
        #expect(okm == Self.hex("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"))
    }

    @Test func hmacMatchesRFC4231TestCase2() {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("what do ya want for nothing?".utf8),
            using: SymmetricKey(data: Data("Jefe".utf8))
        )
        #expect(Data(mac) == Self.hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    }

    // MARK: Derivation (§2.1–2.3)

    @Test func derivedKeysMatchKnownAnswers() throws {
        let keys = try LumeCloudKeys(rootKey: Self.rootKey)
        #expect(Base64URL.encode(keys.encKey) == "f18CI76RBI0GwrkRzvUTAmFlxasz6lkd0HsHKk3ShOU")
        #expect(Base64URL.encode(keys.idKey) == "f11yudjFP1b3yoGlAEH0IEM6iFrBAWwYadfc6qdH-qU")
        #expect(Base64URL.encode(keys.authKey) == "Wvn4bW0A86n6O6NDhVbKaher7xdHMctYYtNfr-KGkTY")
        #expect(keys.authToken == "Wvn4bW0A86n6O6NDhVbKaher7xdHMctYYtNfr-KGkTY")
        #expect(keys.authVerifier == "Xa2C5IEgh90MuDpcLkDA-i46mFdi_kaokB13ETS505I")
    }

    @Test func recordIDsMatchKnownAnswers() throws {
        let keys = try LumeCloudKeys(rootKey: Self.rootKey)
        let rid = keys.recordID(for: Self.profileKey)
        #expect(rid == "PL16O2-5dNWbrjCBeq5bS6zLK5jgKjVNTfKR_6h2dNI")
        #expect(rid.count == 43)
        #expect(keys.recordID(for: "content/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/movie-1001")
            == "9YJbgtJ3uJSRkKGuR5mt-G4F2HAwwufStcEpn8qwJCw")
    }

    @Test func rootKeyLengthIsChecked() {
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 32)) {
            try LumeCloudKeys(rootKey: Data(count: 31))
        }
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 32)) {
            try LumeCloudKeys(rootKey: Data(count: 33))
        }
    }

    @Test func generatedKeysAreFreshAndRoundTrip() throws {
        let a = LumeCloudKeys.generate()
        let b = LumeCloudKeys.generate()
        #expect(a.rootKey.count == 32)
        #expect(a.rootKey != b.rootKey)
        #expect(try LumeCloudKeys(rootKey: a.rootKey) == a)
    }

    @Test func keysNeverPrintSecrets() throws {
        let keys = try LumeCloudKeys(rootKey: Self.rootKey)
        var dumped = ""
        dump(keys, to: &dumped)
        for text in ["\(keys)", String(reflecting: keys), dumped] {
            #expect(!text.contains(keys.authToken))
            #expect(!text.contains(Base64URL.encode(keys.rootKey)))
            #expect(!text.contains("bytes"))
        }
    }

    // MARK: Envelope (§2.4)

    @Test func envelopeMatchesKnownAnswer() throws {
        let keys = try LumeCloudKeys(rootKey: Self.rootKey)
        let rid = keys.recordID(for: Self.profileKey)
        let payload = #"{"data":{"colorRaw":"blue","createdAt":1760000000000,"id":"6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","isChild":true,"name":"Zoë's \"Room\"","sortOrder":1,"symbolName":"star.fill","updatedAt":1760000123456},"key":"profile/6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","type":"profile","v":1}"#
        let wire = try keys.seal(Data(payload.utf8), rid: rid, nonce: Data(0xA0 ..< 0xAC))
        #expect(wire == "AaChoqOkpaanqKmqqx6LLxIUbE5abNmi4jGXsh4pbw4y-m7QxKIzh8VSQMJibg30F0s-CD-4mfXK5sEnMOw9X1nEtx8v_EH6XpBCi5uA9zMH0k0nfqfEhsdZRpX3IkhaIjiX9u6FiuB19Vu-tOa9Wl7VSOJHfXw8X5VOj2MyhQOyEeJGG5GaLKu2ZkIgA0zaRpAb4JhaTmryU-tobl7IDC3RcI53e3HtXIiMt3GLudbKLRM33ywAZrLla3SI9n-NtrwdP7mOyO0TWGOcIaEz2WbF6cvn4RGjlz-X7oGnTU0EqaP48x2jPUvIOePoz4dkpaPKW5shRN6UF0Fu0V2YXpCnt6orfVgUvS0H4nweWf35zBQ_TRB1cc-On6_su1LryFk8qwFIfPtWiZ1yP4Z5z1ZUw1g")
        #expect(try keys.open(wire, rid: rid) == Data(payload.utf8))
    }

    @Test func envelopeLayout() throws {
        let keys = LumeCloudKeys.generate()
        let wire = try keys.seal(Data("hello".utf8), rid: "r")
        let envelope = try #require(Base64URL.decode(wire))
        #expect(envelope.first == 0x01)
        #expect(envelope.count == 1 + 12 + 5 + 16)
        #expect(!wire.contains("=") && !wire.contains("+") && !wire.contains("/"))
    }

    @Test func envelopeRoundTripUsesFreshNonces() throws {
        let keys = LumeCloudKeys.generate()
        let plaintext = Data("{\"v\":1}".utf8)
        let first = try keys.seal(plaintext, rid: "rid-a")
        let second = try keys.seal(plaintext, rid: "rid-a")
        #expect(first != second)
        #expect(try keys.open(first, rid: "rid-a") == plaintext)
        #expect(try keys.open(second, rid: "rid-a") == plaintext)
        #expect(try keys.open(keys.seal(Data(), rid: "rid-a"), rid: "rid-a") == Data())
    }

    @Test func wrongRIDFailsToOpen() throws {
        let keys = LumeCloudKeys.generate()
        let wire = try keys.seal(Data("secret".utf8), rid: "rid-a")
        #expect(throws: LumeCloudCryptoError.authenticationFailed) { try keys.open(wire, rid: "rid-b") }
    }

    @Test func wrongKeyFailsToOpen() throws {
        let wire = try LumeCloudKeys.generate().seal(Data("secret".utf8), rid: "rid-a")
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try LumeCloudKeys.generate().open(wire, rid: "rid-a")
        }
    }

    @Test func tamperedEnvelopeFailsToOpen() throws {
        let keys = LumeCloudKeys.generate()
        let envelope = try #require(Base64URL.decode(keys.seal(Data("secret payload".utf8), rid: "r")))
        // Flip one bit in the nonce, the ciphertext and the tag in turn.
        for index in [1, 14, envelope.count - 1] {
            var tampered = envelope
            tampered[index] ^= 0x01
            #expect(throws: LumeCloudCryptoError.authenticationFailed) {
                try keys.open(Base64URL.encode(tampered), rid: "r")
            }
        }
        // Truncated.
        #expect(throws: LumeCloudCryptoError.authenticationFailed) {
            try keys.open(Base64URL.encode(envelope.dropLast()), rid: "r")
        }
    }

    @Test func unknownVersionIsTyped() throws {
        let keys = LumeCloudKeys.generate()
        var envelope = try #require(Base64URL.decode(keys.seal(Data("x".utf8), rid: "r")))
        envelope[0] = 0x02
        #expect(throws: LumeCloudCryptoError.unsupportedEnvelopeVersion(2)) {
            try keys.open(Base64URL.encode(envelope), rid: "r")
        }
        // Checked before the length, so a future short format still reads as "unknown version".
        #expect(throws: LumeCloudCryptoError.unsupportedEnvelopeVersion(0x7F)) {
            try keys.open(Base64URL.encode(Data([0x7F])), rid: "r")
        }
    }

    @Test func garbageIsRejected() {
        let keys = LumeCloudKeys.generate()
        #expect(throws: LumeCloudCryptoError.invalidBase64) { try keys.open("not base64!", rid: "r") }
        #expect(throws: LumeCloudCryptoError.malformedEnvelope) { try keys.open("", rid: "r") }
        #expect(throws: LumeCloudCryptoError.malformedEnvelope) {
            try keys.open(Base64URL.encode(Data([0x01, 0, 0])), rid: "r")
        }
    }

    @Test func nonceLengthIsChecked() {
        let keys = LumeCloudKeys.generate()
        #expect(throws: LumeCloudCryptoError.invalidKeyLength(expected: 12)) {
            try keys.seal(Data(), rid: "r", nonce: Data(count: 8))
        }
    }

    // MARK: Base64url

    @Test func base64URLIsUnpaddedAndStrict() {
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
        #expect(Base64URL.encode(Data()) == "")
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
        #expect(Base64URL.decode("+/8") == nil)
        #expect(Base64URL.decode("-_8=") == nil)
        #expect(Base64URL.decode("A") == nil)
        #expect(Base64URL.decode("") == Data())
        for length in 0 ..< 40 {
            let data = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 37) })
            #expect(Base64URL.decode(Base64URL.encode(data)) == data)
        }
    }
}
