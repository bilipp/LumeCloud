import Foundation
@testable import LumeCloudKit
import Testing

@Suite("JSONValue & payload")
struct PayloadTests {
    private static func string(_ value: JSONValue) throws -> String {
        String(bytes: try value.canonicalJSON(), encoding: .utf8)!
    }

    // MARK: JSONValue

    @Test func codableRoundTripKeepsIntegersIntegral() throws {
        let value: JSONValue = ["a": 1, "b": 1.5, "c": -3, "d": 1_760_000_000_000, "e": [true, nil, "x"]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(bytes: try encoder.encode(value), encoding: .utf8)!
        #expect(json == #"{"a":1,"b":1.5,"c":-3,"d":1760000000000,"e":[true,null,"x"]}"#)
        #expect(!json.contains("1.0"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) == value)
    }

    @Test func decodingDistinguishesBoolsAndNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true,1,0,false,1.0,"1"]"#.utf8))
        #expect(value == [.bool(true), .number(1), .number(0), .bool(false), .number(1), .string("1")])
    }

    @Test func accessors() {
        let value: JSONValue = ["n": 3, "f": 2.5, "s": "x", "b": true, "z": nil]
        #expect(value["n"]?.intValue == 3)
        #expect(value["f"]?.intValue == nil)
        #expect(value["f"]?.doubleValue == 2.5)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == true)
        #expect(value["z"]?.isNull == true)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["n"] == nil)
    }

    // MARK: Canonical JSON (RFC 8785 rules)

    @Test func canonicalSortsKeysAtEveryLevel() throws {
        let value: JSONValue = ["b": ["z": 1, "a": [["y": 2, "x": 1]]], "a": nil, "B": true]
        #expect(try Self.string(value) == #"{"B":true,"a":null,"b":{"a":[{"x":1,"y":2}],"z":1}}"#)
    }

    @Test func canonicalKeyOrderIsUTF16() throws {
        // By scalar value U+E000 < U+1F600, but in UTF-16 the emoji starts
        // with the high surrogate 0xD83D < 0xE000, so it sorts first.
        let value: JSONValue = ["\u{E000}": 1, "😀": 2, "z": 3, "é": 4]
        #expect(try Self.string(value) == "{\"z\":3,\"é\":4,\"😀\":2,\"\u{E000}\":1}")
    }

    @Test func canonicalStringEscaping() throws {
        let value = JSONValue.string("a\"b\\c/d\u{08}\u{0C}\n\r\t\u{01}\u{1F}é😀\u{2028}")
        #expect(try Self.string(value) == "\"a\\\"b\\\\c/d\\b\\f\\n\\r\\t\\u0001\\u001fé😀\u{2028}\"")
    }

    @Test(arguments: [
        (0.0, "0"), (-0.0, "0"), (1.0, "1"), (-1.0, "-1"), (1234.5, "1234.5"), (0.1, "0.1"),
        (1_760_000_000_000.0, "1760000000000"), (9_007_199_254_740_993.0, "9007199254740992"),
        (0.00001, "0.00001"), (0.000001, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"),
        (1e21, "1e+21"), (1e20, "100000000000000000000"), (1.2345e21, "1.2345e+21"),
        (123_456_789_012_345_680_000.0, "123456789012345680000"), (5e-324, "5e-324"),
        (1.7976931348623157e308, "1.7976931348623157e+308"), (-2.5e-8, "-2.5e-8"),
    ])
    func canonicalNumbersMatchECMAScript(value: Double, expected: String) throws {
        #expect(try JSONValue.formatNumber(value) == expected)
    }

    @Test func canonicalRejectsNonFiniteNumbers() {
        #expect(throws: LumeCloudCryptoError.nonFiniteNumber) { try JSONValue.number(.nan).canonicalJSON() }
        #expect(throws: LumeCloudCryptoError.nonFiniteNumber) { try JSONValue.number(.infinity).canonicalJSON() }
    }

    // MARK: Payload

    @Test func payloadEncodingIsCanonical() throws {
        let payload = LumeCloudPayload(
            type: "content",
            key: "content/none/movie-1",
            data: ["watchProgress": 12.25, "isWatched": false, "favoriteOrder": 3, "updatedAt": 1_760_000_000_000, "lastWatchedDate": nil]
        )
        let json = try #require(String(bytes: payload.encoded(), encoding: .utf8))
        #expect(json == #"{"data":{"favoriteOrder":3,"isWatched":false,"lastWatchedDate":null,"updatedAt":1760000000000,"watchProgress":12.25},"key":"content/none/movie-1","type":"content","v":1}"#)
    }

    @Test func payloadPreservesUnknownFields() throws {
        let incoming = #"{"v":1,"type":"profile","key":"profile/X","future":{"k":[1,2]},"data":{"name":"Kid","sortOrder":2,"newField":{"z":1,"a":[true,null,0.5]},"color":"red"}}"#
        let payload = try LumeCloudPayload.decode(Data(incoming.utf8))
        #expect(payload.v == 1)
        #expect(payload.type == "profile")
        #expect(payload.key == "profile/X")
        #expect(payload.data["newField"] == ["z": 1, "a": [true, nil, 0.5]])
        #expect(payload.extra == ["future": ["k": [1, 2]]])

        var edited = payload
        edited.data["name"] = "Kids"
        let json = try #require(String(bytes: edited.encoded(), encoding: .utf8))
        #expect(json == #"{"data":{"color":"red","name":"Kids","newField":{"a":[true,null,0.5],"z":1},"sortOrder":2},"future":{"k":[1,2]},"key":"profile/X","type":"profile","v":1}"#)
        #expect(try LumeCloudPayload.decode(edited.encoded()) == edited)
    }

    @Test func payloadRejectsMissingFields() {
        for bad in [#"[]"#, #"{"type":"t","key":"k","data":{}}"#, #"{"v":1.5,"type":"t","key":"k","data":{}}"#,
                    #"{"v":1,"key":"k","data":{}}"#, #"{"v":1,"type":"t","data":{}}"#, #"{"v":1,"type":"t","key":"k"}"#,
                    #"{"v":1,"type":"t","key":"k","data":[]}"#, "not json"]
        {
            #expect(throws: LumeCloudCryptoError.self) { try LumeCloudPayload.decode(Data(bad.utf8)) }
        }
    }

    @Test func extraCannotShadowReservedKeys() throws {
        let payload = LumeCloudPayload(type: "t", key: "k", data: [:], extra: ["v": 9, "key": "evil", "x": 1])
        #expect(payload.extra == ["x": 1])
        #expect(try LumeCloudPayload.decode(payload.encoded()).key == "k")
    }

    @Test func sealAndOpenPayload() throws {
        let keys = LumeCloudKeys.generate()
        let payload = LumeCloudPayload(type: "liveTVPrefs", key: "liveTVPrefs", data: ["showsFavorites": true, "updatedAt": 1])
        let (rid, ciphertext) = try keys.seal(payload)
        #expect(rid == keys.recordID(for: "liveTVPrefs"))
        #expect(try keys.openPayload(ciphertext, rid: rid) == payload)
    }
}
