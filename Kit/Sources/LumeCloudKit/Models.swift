import Foundation

// Wire DTOs of PROTOCOL.md §4. JSON keys are camelCase and match the property
// names. Times are epoch milliseconds (UTC); `seq` and `version` are integers.
// Unknown response keys are ignored by `Decodable`.

// MARK: - Constants

/// Version and header constants of the protocol this Kit speaks.
public enum LumeCloudAPI {
    /// The protocol version (the path prefix is `/v1`).
    public static let version = 1
    /// The official instance.
    public static let officialURL = URL(string: "https://cloud.getlume.org")!
    /// The staging instance.
    public static let stagingURL = URL(string: "https://cloud-staging.getlume.org")!
    /// Header carrying this device's id on authenticated routes.
    public static let deviceHeader = "X-Lume-Device"
    /// Largest page `changes(since:limit:)` may request.
    public static let maxChangesLimit = 1000
    /// Most records one `push` may carry.
    public static let maxPushRecords = 500
    /// Largest decoded ciphertext per record, in bytes.
    public static let maxRecordBytes = 65536
}

/// The `error` codes of PROTOCOL.md §1.
public enum LumeCloudErrorCode {
    public static let badRequest = "bad_request"
    public static let badAuth = "bad_auth"
    public static let deviceRevoked = "device_revoked"
    public static let signupClosed = "signup_closed"
    public static let accountDeleted = "account_deleted"
    public static let notFound = "not_found"
    public static let pairingAlreadySealed = "pairing_already_sealed"
    public static let resyncRequired = "resync_required"
    public static let recordTooLarge = "record_too_large"
    public static let rateLimited = "rate_limited"
    public static let quotaExceeded = "quota_exceeded"
}

/// A device platform as the server stores it. A value this Kit doesn't know
/// (from a newer client) decodes and re-encodes unchanged.
public struct LumeCloudPlatform: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let iOS = LumeCloudPlatform(rawValue: "ios")
    public static let tvOS = LumeCloudPlatform(rawValue: "tvos")
    public static let macOS = LumeCloudPlatform(rawValue: "macos")
    public static let visionOS = LumeCloudPlatform(rawValue: "visionos")
    public static let android = LumeCloudPlatform(rawValue: "android")
    public static let androidTV = LumeCloudPlatform(rawValue: "androidtv")

    /// The platform this code was compiled for.
    public static var current: LumeCloudPlatform {
        #if os(tvOS)
            .tvOS
        #elseif os(visionOS)
            .visionOS
        #elseif os(macOS)
            .macOS
        #else
            .iOS
        #endif
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Accounts (§4.1)

public struct AccountCreated: Codable, Sendable, Hashable {
    /// 22-char base64url account id. Not secret on its own, but pair it with
    /// the root key in the Keychain.
    public var accountId: String
    public var createdAt: Int

    public init(accountId: String, createdAt: Int) {
        self.accountId = accountId
        self.createdAt = createdAt
    }
}

public struct AccountInfo: Codable, Sendable, Hashable {
    public var accountId: String
    public var createdAt: Int
    /// Live ciphertext bytes counted against the 10 MiB quota.
    public var usedBytes: Int
    /// Live records counted against the 100,000-record quota.
    public var recordCount: Int
    public var nextSeq: Int

    public init(accountId: String, createdAt: Int, usedBytes: Int, recordCount: Int, nextSeq: Int) {
        self.accountId = accountId
        self.createdAt = createdAt
        self.usedBytes = usedBytes
        self.recordCount = recordCount
        self.nextSeq = nextSeq
    }
}

struct CreateAccountBody: Encodable {
    var authVerifier: String
    var invite: String?
}

// MARK: - Devices (§4.2)

public struct Device: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var platform: LumeCloudPlatform
    public var createdAt: Int
    public var lastSeen: Int
    public var revoked: Bool

    public init(id: UUID, name: String, platform: LumeCloudPlatform, createdAt: Int, lastSeen: Int, revoked: Bool) {
        self.id = id
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeen = lastSeen
        self.revoked = revoked
    }
}

struct RegisterDeviceBody: Encodable {
    var id: String
    var name: String
    var platform: LumeCloudPlatform
}

struct DeviceList: Decodable {
    var devices: [Device]
}

// MARK: - Change feed (§4.3)

/// A record as the server stores it. `ciphertext` is `nil` for a tombstone.
public struct RemoteRecord: Codable, Sendable, Hashable {
    public var rid: String
    public var version: Int
    public var seq: Int
    public var deleted: Bool
    /// The base64url envelope; open it with `LumeCloudKeys.open(_:rid:)`.
    public var ciphertext: String?
    public var updatedAt: Int

    public init(rid: String, version: Int, seq: Int, deleted: Bool, ciphertext: String?, updatedAt: Int) {
        self.rid = rid
        self.version = version
        self.seq = seq
        self.deleted = deleted
        self.ciphertext = ciphertext
        self.updatedAt = updatedAt
    }
}

public struct ChangesPage: Codable, Sendable, Hashable {
    /// Ascending by `seq`; each record appears once, at its latest `seq`.
    public var records: [RemoteRecord]
    /// Send this as `since` next time.
    public var nextSeq: Int
    public var hasMore: Bool

    public init(records: [RemoteRecord], nextSeq: Int, hasMore: Bool) {
        self.records = records
        self.nextSeq = nextSeq
        self.hasMore = hasMore
    }
}

// MARK: - Push (§4.4)

/// One write in a push. Use `upsert` or `delete` rather than the memberwise init.
public struct PushRecord: Codable, Sendable, Hashable {
    public var rid: String
    /// The version this client last saw; `0` for a record it has never seen.
    public var baseVersion: Int
    public var deleted: Bool
    /// The base64url envelope, or `nil` for a delete (encoded as JSON `null`).
    public var ciphertext: String?

    public init(rid: String, baseVersion: Int, deleted: Bool, ciphertext: String?) {
        self.rid = rid
        self.baseVersion = baseVersion
        self.deleted = deleted
        self.ciphertext = ciphertext
    }

    /// Writes `ciphertext` over the record at `baseVersion`.
    public static func upsert(rid: String, baseVersion: Int, ciphertext: String) -> PushRecord {
        PushRecord(rid: rid, baseVersion: baseVersion, deleted: false, ciphertext: ciphertext)
    }

    /// Replaces the record at `baseVersion` with a tombstone.
    public static func delete(rid: String, baseVersion: Int) -> PushRecord {
        PushRecord(rid: rid, baseVersion: baseVersion, deleted: true, ciphertext: nil)
    }

    enum CodingKeys: String, CodingKey {
        case rid, baseVersion, deleted, ciphertext
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rid, forKey: .rid)
        try container.encode(baseVersion, forKey: .baseVersion)
        try container.encode(deleted, forKey: .deleted)
        // Always present: `null` for a delete, as PROTOCOL.md §4.4 shows.
        try container.encode(ciphertext, forKey: .ciphertext)
    }
}

struct PushBody: Encodable {
    var records: [PushRecord]
}

/// The outcome of one record in a push.
public enum PushResult: Sendable, Hashable {
    /// Applied: the record now has `version` and `seq`.
    case ok(rid: String, version: Int, seq: Int)
    /// `baseVersion` didn't match; `current` is the server's record (treat it
    /// as pulled, merge, and retry).
    case conflict(rid: String, current: RemoteRecord)

    public var rid: String {
        switch self {
        case let .ok(rid, _, _), let .conflict(rid, _): rid
        }
    }
}

extension PushResult: Codable {
    enum CodingKeys: String, CodingKey {
        case rid, status, version, seq, current
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rid = try container.decode(String.self, forKey: .rid)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "ok":
            self = try .ok(
                rid: rid,
                version: container.decode(Int.self, forKey: .version),
                seq: container.decode(Int.self, forKey: .seq)
            )
        case "conflict":
            self = try .conflict(rid: rid, current: container.decode(RemoteRecord.self, forKey: .current))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Unknown push status"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ok(rid, version, seq):
            try container.encode(rid, forKey: .rid)
            try container.encode("ok", forKey: .status)
            try container.encode(version, forKey: .version)
            try container.encode(seq, forKey: .seq)
        case let .conflict(rid, current):
            try container.encode(rid, forKey: .rid)
            try container.encode("conflict", forKey: .status)
            try container.encode(current, forKey: .current)
        }
    }
}

public struct PushResponse: Codable, Sendable, Hashable {
    /// One result per pushed record, in request order.
    public var results: [PushResult]
    public var nextSeq: Int

    public init(results: [PushResult], nextSeq: Int) {
        self.results = results
        self.nextSeq = nextSeq
    }
}

// MARK: - Pairing (§4.5)

struct StartPairingBody: Encodable {
    var publicKey: String
    var deviceName: String
    var platform: LumeCloudPlatform
}

/// Returned to the new device by `startPairing`. Show `code`; keep `pollToken`
/// secret (it only travels to `pairingResult`).
public struct PairingTicket: Codable, Sendable, Hashable {
    /// Six decimal digits.
    public var code: String
    public var pollToken: String
    public var expiresAt: Int

    public init(code: String, pollToken: String, expiresAt: Int) {
        self.code = code
        self.pollToken = pollToken
        self.expiresAt = expiresAt
    }
}

extension PairingTicket: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PairingTicket(code: \(code), expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

/// What the joined device sees for a code before it confirms and seals.
public struct PairingRequest: Codable, Sendable, Hashable {
    /// The new device's raw X25519 public key, base64url.
    public var publicKey: String
    public var deviceName: String
    public var platform: LumeCloudPlatform
    public var expiresAt: Int

    public init(publicKey: String, deviceName: String, platform: LumeCloudPlatform, expiresAt: Int) {
        self.publicKey = publicKey
        self.deviceName = deviceName
        self.platform = platform
        self.expiresAt = expiresAt
    }
}

/// One poll of `GET /v1/pairings/{code}/result`.
public enum PairingPollResult: Sendable, Hashable {
    case pending
    case sealed(SealedGrant)
}

extension PairingPollResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case status, enc, ciphertext
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "pending":
            self = .pending
        case "sealed":
            self = try .sealed(SealedGrant(
                enc: container.decode(String.self, forKey: .enc),
                ciphertext: container.decode(String.self, forKey: .ciphertext)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Unknown pairing status"
            )
        }
    }
}

// MARK: - Health (§4.7)

public struct HealthStatus: Codable, Sendable, Hashable {
    public var ok: Bool
    /// Git SHA or semver of the deployed server.
    public var version: String

    public init(ok: Bool, version: String) {
        self.ok = ok
        self.version = version
    }
}

// MARK: - Errors

/// The JSON body of every non-2xx response.
struct ErrorBody: Decodable {
    var error: String
    var message: String?
}
