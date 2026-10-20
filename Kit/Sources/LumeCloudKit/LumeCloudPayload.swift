import Foundation

/// The plaintext inside a record envelope (PROTOCOL.md §2.5):
///
///     {"data":{...},"key":"content/<PROFILE-UUID>/<contentId>","type":"content","v":1}
///
/// The Kit doesn't interpret `type` or `data`; mapping them to and from app
/// models is the app's job. Unknown fields inside `data` survive a
/// `decode` → `encoded()` round trip verbatim, and so do unknown top-level
/// fields (kept in `extra`), so a newer client's additions are never lost.
public struct LumeCloudPayload: Sendable, Hashable {
    /// The payload schema version this Kit writes.
    public static let currentVersion = 1

    /// Payload schema version.
    public var v: Int
    /// The collection, e.g. `content` or `profile` (§3).
    public var type: String
    /// The logical key; `rid` is derived from it and can't be reversed.
    public var key: String
    /// The collection's fields, including any this app version doesn't know.
    public var data: [String: JSONValue]
    /// Top-level fields other than `v`, `type`, `key` and `data`, preserved
    /// for forward compatibility. Normally empty.
    public var extra: [String: JSONValue]

    static let reservedKeys: Set<String> = ["v", "type", "key", "data"]

    public init(
        v: Int = LumeCloudPayload.currentVersion,
        type: String,
        key: String,
        data: [String: JSONValue],
        extra: [String: JSONValue] = [:]
    ) {
        self.v = v
        self.type = type
        self.key = key
        self.data = data
        self.extra = extra.filter { !Self.reservedKeys.contains($0.key) }
    }

    /// Canonical UTF-8 JSON: keys sorted at every level, no whitespace.
    /// Equal payloads always produce identical bytes.
    public func encoded() throws -> Data {
        var object = extra.filter { !Self.reservedKeys.contains($0.key) }
        object["v"] = .number(Double(v))
        object["type"] = .string(type)
        object["key"] = .string(key)
        object["data"] = .object(data)
        return try JSONValue.object(object).canonicalJSON()
    }

    /// Parses a decrypted payload. Throws `.invalidPayload` when it isn't a
    /// JSON object with an integer `v`, string `type` and `key`, and an object
    /// `data`.
    public static func decode(_ data: Data) throws -> LumeCloudPayload {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw LumeCloudCryptoError.invalidPayload("not JSON")
        }
        guard case let .object(object) = value else {
            throw LumeCloudCryptoError.invalidPayload("not an object")
        }
        guard let version = object["v"]?.intValue else {
            throw LumeCloudCryptoError.invalidPayload("missing v")
        }
        guard let type = object["type"]?.stringValue else {
            throw LumeCloudCryptoError.invalidPayload("missing type")
        }
        guard let key = object["key"]?.stringValue else {
            throw LumeCloudCryptoError.invalidPayload("missing key")
        }
        guard let fields = object["data"]?.objectValue else {
            throw LumeCloudCryptoError.invalidPayload("missing data")
        }
        return LumeCloudPayload(
            v: version,
            type: type,
            key: key,
            data: fields,
            extra: object.filter { !reservedKeys.contains($0.key) }
        )
    }
}

extension LumeCloudKeys {
    /// Canonically encodes `payload`, derives its `rid` from `payload.key`,
    /// and seals it. Returns both, ready for a `PushRecord`.
    public func seal(_ payload: LumeCloudPayload) throws -> (rid: String, ciphertext: String) {
        let rid = recordID(for: payload.key)
        return try (rid, seal(payload.encoded(), rid: rid))
    }

    /// Opens and parses a record's ciphertext.
    public func openPayload(_ wire: String, rid: String) throws -> LumeCloudPayload {
        try LumeCloudPayload.decode(open(wire, rid: rid))
    }
}
