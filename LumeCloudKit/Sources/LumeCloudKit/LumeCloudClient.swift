import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Async client for a Lume Cloud server (PROTOCOL.md §4).
///
/// Stateless and `Sendable`: create one per server and account, and share it
/// freely from any actor. The client never retries — not on `429`, not on a
/// transport error, never a `POST` or `DELETE`. Retry policy, backoff and
/// conflict rounds are the caller's job. The auth token only ever travels in
/// the `Authorization` header and never appears in an error.
public final class LumeCloudClient: Sendable {
    /// What an authenticated request carries (§2.2).
    public struct Credentials: Sendable, Hashable {
        public var accountId: String
        /// `base64url(authKey)` — `LumeCloudKeys.authToken`.
        public var authToken: String
        public var deviceID: UUID

        public init(accountId: String, authToken: String, deviceID: UUID) {
            self.accountId = accountId
            self.authToken = authToken
            self.deviceID = deviceID
        }

        public init(accountId: String, keys: LumeCloudKeys, deviceID: UUID) {
            self.init(accountId: accountId, authToken: keys.authToken, deviceID: deviceID)
        }

        /// Credentials for the account derived from `keys` (`keys.accountId`).
        /// This is all a device restoring from a recovery key needs.
        public init(keys: LumeCloudKeys, deviceID: UUID) {
            self.init(accountId: keys.accountId, keys: keys, deviceID: deviceID)
        }

        /// `Bearer <accountId>.<authToken>`.
        var authorizationHeader: String { "Bearer \(accountId).\(authToken)" }
    }

    public let baseURL: URL
    public let session: URLSession
    public let credentials: Credentials?
    /// Interval between `ping`s on the events socket (30 s per §4.6).
    let pingInterval: Duration

    public convenience init(baseURL: URL, session: URLSession = .shared, credentials: Credentials?) {
        self.init(baseURL: baseURL, session: session, credentials: credentials, pingInterval: .seconds(30))
    }

    init(baseURL: URL, session: URLSession, credentials: Credentials?, pingInterval: Duration) {
        self.baseURL = baseURL
        self.session = session
        self.credentials = credentials
        self.pingInterval = pingInterval
    }

    /// A copy of this client with other credentials, e.g. right after
    /// `createAccount` or a finished pairing.
    public func withCredentials(_ credentials: Credentials?) -> LumeCloudClient {
        LumeCloudClient(baseURL: baseURL, session: session, credentials: credentials, pingInterval: pingInterval)
    }

    // MARK: - Accounts (§4.1)

    /// `POST /v1/accounts` (unauthenticated) for the account derived from
    /// `keys`: sends `keys.authVerifier` and `keys.accountId`, so the returned
    /// `accountId` equals `keys.accountId`.
    ///
    /// Throws `.accountExists` when that account already exists (sign in to
    /// it instead). Pass `invite` only for an invite-only instance; a missing
    /// or wrong one throws `.signupClosed`.
    public func createAccount(keys: LumeCloudKeys, invite: String? = nil) async throws -> AccountCreated {
        let body = CreateAccountBody(authVerifier: keys.authVerifier, accountId: keys.accountId, invite: invite)
        return try await send(.post, "v1/accounts", body: body, auth: .none)
    }

    /// `POST /v1/accounts` without an `accountId`: the server picks a random
    /// one, which a recovery key can't restore.
    @available(*, deprecated, message: "Use createAccount(keys:invite:), whose account id is derived from the root key.")
    public func createAccount(authVerifier: String, invite: String? = nil) async throws -> AccountCreated {
        try await send(.post, "v1/accounts", body: CreateAccountBody(authVerifier: authVerifier, invite: invite), auth: .none)
    }

    /// `GET /v1/accounts/me`.
    public func account() async throws -> AccountInfo {
        try await send(.get, "v1/accounts/me")
    }

    /// `DELETE /v1/accounts/me`. Every later call throws `.accountDeleted`.
    public func deleteAccount() async throws {
        try await sendWithoutContent(.delete, "v1/accounts/me")
    }

    // MARK: - Devices (§4.2)

    /// `POST /v1/devices` — registers or updates a device; idempotent by `id`.
    /// Sends the `Authorization` header only: the id travels in the body.
    public func registerDevice(id: UUID, name: String, platform: LumeCloudPlatform) async throws -> Device {
        let body = RegisterDeviceBody(id: id.uuidString, name: name, platform: platform)
        return try await send(.post, "v1/devices", body: body, auth: .accountOnly)
    }

    /// `GET /v1/devices`.
    public func devices() async throws -> [Device] {
        let list: DeviceList = try await send(.get, "v1/devices")
        return list.devices
    }

    /// `DELETE /v1/devices/{id}` — marks the device revoked (it then gets
    /// `.deviceRevoked`). It still knows the root key; see §4.2.
    public func revokeDevice(id: UUID) async throws {
        try await sendWithoutContent(.delete, "v1/devices/\(id.uuidString)")
    }

    // MARK: - Change feed (§4.3)

    /// `GET /v1/changes?since=&limit=`. `since: 0` returns the live set
    /// without tombstones; a stale `since` throws `.resyncRequired`. A `nil`
    /// limit uses the server default (500); the server accepts 1…1000.
    public func changes(since: Int, limit: Int? = nil) async throws -> ChangesPage {
        var query = [URLQueryItem(name: "since", value: String(since))]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await send(.get, "v1/changes", query: query)
    }

    /// Follows `changes(since:limit:)` until `hasMore` is false and returns
    /// every record in feed order, with the final `nextSeq` and
    /// `hasMore == false`. A record that changed mid-walk can show up twice;
    /// the later entry is the current one.
    public func allChanges(since: Int, limit: Int? = nil) async throws -> ChangesPage {
        var records: [RemoteRecord] = []
        var cursor = since
        while true {
            let page = try await changes(since: cursor, limit: limit)
            records += page.records
            // Guard against a server that claims more without advancing.
            guard page.hasMore, page.nextSeq > cursor else {
                return ChangesPage(records: records, nextSeq: page.nextSeq, hasMore: false)
            }
            cursor = page.nextSeq
        }
    }

    // MARK: - Push (§4.4)

    /// `POST /v1/push` — at most 500 records and 4 MiB. Conflicts come back
    /// per record; `.recordTooLarge` / `.quotaExceeded` reject the whole push.
    public func push(_ records: [PushRecord]) async throws -> PushResponse {
        try await send(.post, "v1/push", body: PushBody(records: records))
    }

    // MARK: - Pairing (§4.5)

    /// `POST /v1/pairings` (unauthenticated) — the new device's step 1.
    public func startPairing(publicKey: String, deviceName: String, platform: LumeCloudPlatform) async throws -> PairingTicket {
        let body = StartPairingBody(publicKey: publicKey, deviceName: deviceName, platform: platform)
        return try await send(.post, "v1/pairings", body: body, auth: .none)
    }

    /// `GET /v1/pairings/{code}` — the joined device looks up a code.
    /// Throws `.notFound` for an expired or unknown code.
    public func pairingRequest(code: String) async throws -> PairingRequest {
        try await send(.get, "v1/pairings/\(code)")
    }

    /// `POST /v1/pairings/{code}/seal` — first writer wins; a second seal
    /// throws `.pairingAlreadySealed`.
    public func sealPairing(code: String, sealed: SealedGrant) async throws {
        try await sendWithoutContent(.post, "v1/pairings/\(code)/seal", body: sealed)
    }

    /// `GET /v1/pairings/{code}/result?pollToken=` (unauthenticated) — the new
    /// device polls this every 2 s. The server forgets the pairing after the
    /// first `sealed` answer.
    public func pairingResult(code: String, pollToken: String) async throws -> PairingPollResult {
        try await send(
            .get,
            "v1/pairings/\(code)/result",
            query: [URLQueryItem(name: "pollToken", value: pollToken)],
            auth: .none
        )
    }

    // MARK: - Health (§4.7)

    /// `GET /healthz` (no `/v1` prefix, unauthenticated).
    @discardableResult
    public func health() async throws -> HealthStatus {
        try await send(.get, "healthz", auth: .none)
    }

    // MARK: - Request building

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    enum Auth {
        /// No credentials at all.
        case none
        /// `Authorization` only (`POST /v1/devices`).
        case accountOnly
        /// `Authorization` and `X-Lume-Device`.
        case full
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.append(path: String(component), directoryHint: .notDirectory)
        }
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        return url
    }

    func makeRequest(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        auth: Auth
    ) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method.rawValue
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth != .none {
            guard let credentials else { throw LumeCloudError.missingCredentials }
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            if auth == .full {
                request.setValue(credentials.deviceID.uuidString, forHTTPHeaderField: LumeCloudAPI.deviceHeader)
            }
        }
        return request
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw LumeCloudError.badRequest(message: "The request couldn't be encoded.")
        }
    }

    // MARK: - Transport

    private func send<Response: Decodable>(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = String?.none,
        auth: Auth = .full
    ) async throws -> Response {
        let data = try await perform(method, path, query: query, body: body, auth: auth)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LumeCloudError.decodingFailure(error)
        }
    }

    private func sendWithoutContent(
        _ method: Method,
        _ path: String,
        body: (some Encodable)? = String?.none,
        auth: Auth = .full
    ) async throws {
        _ = try await perform(method, path, query: [], body: body, auth: auth)
    }

    private func perform(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem],
        body: (some Encodable)?,
        auth: Auth
    ) async throws -> Data {
        var bodyData: Data?
        if let body {
            bodyData = try Self.encode(body)
        }
        let request = try makeRequest(method, path, query: query, body: bodyData, auth: auth)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LumeCloudError.sanitizedTransport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LumeCloudError.decoding("not an HTTP response")
        }
        guard !(200 ..< 300).contains(http.statusCode) else { return data }
        throw LumeCloudError.from(
            status: http.statusCode,
            body: data,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        )
    }
}

extension LumeCloudClient.Credentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Credentials(accountId: \(accountId), deviceID: \(deviceID.uuidString), authToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accountId": accountId, "deviceID": deviceID], displayStyle: .struct)
    }
}
