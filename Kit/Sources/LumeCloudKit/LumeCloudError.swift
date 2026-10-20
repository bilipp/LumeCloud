import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Every failure `LumeCloudClient` can throw. Each `error` code of
/// PROTOCOL.md §1 has its own case. No case carries a token, key or URL.
public enum LumeCloudError: Error, Sendable {
    /// 400 `bad_request` — malformed JSON, a missing field or bad base64url.
    /// The associated value is the server's human-readable message, if any.
    case badRequest(message: String?)
    /// 401 `bad_auth` — missing or wrong credentials.
    case badAuth
    /// 401 `device_revoked` — stop syncing and show "removed from Lume Cloud".
    case deviceRevoked
    /// 403 `signup_closed` — the instance is invite-only and the invite is missing or wrong.
    case signupClosed
    /// 404 `account_deleted` — switch to local-only and keep the local data.
    case accountDeleted
    /// 404 `not_found` — unknown route, or an expired or unknown pairing code.
    case notFound
    /// 409 `pairing_already_sealed` — another device sealed this pairing first.
    case pairingAlreadySealed
    /// 410 `resync_required` — `since` is older than the tombstone horizon;
    /// do a full resync from `since=0` (§6.3).
    case resyncRequired
    /// 413 `record_too_large` — a record or the whole push is over the limits.
    case recordTooLarge
    /// 429 `rate_limited` — wait `retryAfter` seconds (from `Retry-After`) if given.
    case rateLimited(retryAfter: TimeInterval?)
    /// 507 `quota_exceeded` — over 10 MiB of ciphertext or 100,000 live records.
    case quotaExceeded
    /// Any other non-2xx response.
    case server(status: Int, code: String?)
    /// The request never got an HTTP response (offline, DNS, refused,
    /// timeout…). The `URLError` is stripped of its failing URL.
    case transport(URLError)
    /// The response didn't match the expected shape. The description names
    /// only the coding path, never response values.
    case decoding(String)
    /// The client has no `Credentials` but the route needs them.
    case missingCredentials
}

extension LumeCloudError {
    /// Maps a non-2xx response to a typed error. The `error` code wins; the
    /// status decides only when the body isn't the documented JSON (e.g. an
    /// edge proxy's 429). An unknown code on any status but 429 becomes
    /// `.server(status:code:)`.
    static func from(status: Int, body: Data, retryAfter: String?) -> LumeCloudError {
        let payload = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let code = payload?.error
        switch code {
        case LumeCloudErrorCode.badRequest: return .badRequest(message: payload?.message)
        case LumeCloudErrorCode.badAuth: return .badAuth
        case LumeCloudErrorCode.deviceRevoked: return .deviceRevoked
        case LumeCloudErrorCode.signupClosed: return .signupClosed
        case LumeCloudErrorCode.accountDeleted: return .accountDeleted
        case LumeCloudErrorCode.notFound: return .notFound
        case LumeCloudErrorCode.pairingAlreadySealed: return .pairingAlreadySealed
        case LumeCloudErrorCode.resyncRequired: return .resyncRequired
        case LumeCloudErrorCode.recordTooLarge: return .recordTooLarge
        case LumeCloudErrorCode.rateLimited: return .rateLimited(retryAfter: parseRetryAfter(retryAfter))
        case LumeCloudErrorCode.quotaExceeded: return .quotaExceeded
        default: break
        }
        switch status {
        case 400 where code == nil: return .badRequest(message: nil)
        case 401 where code == nil: return .badAuth
        case 404 where code == nil: return .notFound
        case 410 where code == nil: return .resyncRequired
        case 413 where code == nil: return .recordTooLarge
        case 429: return .rateLimited(retryAfter: parseRetryAfter(retryAfter))
        case 507 where code == nil: return .quotaExceeded
        default: return .server(status: status, code: code)
        }
    }

    /// `Retry-After` as delta-seconds, or as an HTTP-date relative to now.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// A `URLError` with the same code but no `userInfo`, so the failing URL
    /// (which can carry a poll token) never ends up in a description or log.
    static func sanitizedTransport(_ error: URLError) -> LumeCloudError {
        .transport(URLError(error.code))
    }

    /// A decoding failure described by its coding path only.
    static func decodingFailure(_ error: any Error) -> LumeCloudError {
        guard let error = error as? DecodingError else { return .decoding("unexpected response") }
        let (kind, context): (String, DecodingError.Context) = switch error {
        case let .typeMismatch(_, context): ("type mismatch", context)
        case let .valueNotFound(_, context): ("missing value", context)
        case let .keyNotFound(key, context): ("missing key \(key.stringValue)", context)
        case let .dataCorrupted(context): ("invalid data", context)
        @unknown default: ("unexpected response", DecodingError.Context(codingPath: [], debugDescription: ""))
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return .decoding(path.isEmpty ? kind : "\(kind) at \(path)")
    }
}

extension LumeCloudError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .badRequest(message):
            message ?? "Lume Cloud rejected the request."
        case .badAuth:
            "Lume Cloud didn't accept this device's credentials."
        case .deviceRevoked:
            "This device was removed from Lume Cloud."
        case .signupClosed:
            "This Lume Cloud server only accepts new accounts with an invite code."
        case .accountDeleted:
            "This Lume Cloud account no longer exists."
        case .notFound:
            "Not found. The pairing code may have expired."
        case .pairingAlreadySealed:
            "Another device already answered this pairing code."
        case .resyncRequired:
            "Lume Cloud needs a full resync."
        case .recordTooLarge:
            "An item is too large for Lume Cloud."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Too many requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "Too many requests. Try again later."
            }
        case .quotaExceeded:
            "This Lume Cloud account is full."
        case let .server(status, _):
            "Lume Cloud returned an error (HTTP \(status))."
        case let .transport(error):
            "Couldn't reach Lume Cloud: \(error.localizedDescription)"
        case .decoding:
            "Lume Cloud sent an unexpected response."
        case .missingCredentials:
            "This device isn't signed in to Lume Cloud."
        }
    }
}

extension LumeCloudError: Equatable {
    public static func == (lhs: LumeCloudError, rhs: LumeCloudError) -> Bool {
        switch (lhs, rhs) {
        case (.badAuth, .badAuth), (.deviceRevoked, .deviceRevoked), (.signupClosed, .signupClosed),
             (.accountDeleted, .accountDeleted), (.notFound, .notFound),
             (.pairingAlreadySealed, .pairingAlreadySealed), (.resyncRequired, .resyncRequired),
             (.recordTooLarge, .recordTooLarge), (.quotaExceeded, .quotaExceeded),
             (.missingCredentials, .missingCredentials):
            true
        case let (.badRequest(a), .badRequest(b)):
            a == b
        case let (.rateLimited(a), .rateLimited(b)):
            a == b
        case let (.server(a, b), .server(c, d)):
            a == c && b == d
        case let (.transport(a), .transport(b)):
            a.code == b.code
        case let (.decoding(a), .decoding(b)):
            a == b
        default:
            false
        }
    }
}
