import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import LumeCloudKit
import Testing

/// Captured request + canned response, keyed by a per-test host so suites can
/// run in parallel against one `URLProtocol` class.
final class StubRegistry: @unchecked Sendable {
    struct Captured: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data?

        var json: JSONValue? {
            body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }

        var bodyString: String? {
            body.flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }

    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    typealias Handler = @Sendable (Captured) -> Response

    static let shared = StubRegistry()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var captured: [String: [Captured]] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    func handle(host: String, request: Captured) -> Response? {
        lock.withLock {
            captured[host, default: []].append(request)
            return handlers[host]
        }.map { $0(request) }
    }

    func requests(host: String) -> [Captured] {
        lock.withLock { captured[host] ?? [] }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            body = Self.read(stream)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value
        }
        let captured = StubRegistry.Captured(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        guard let stub = StubRegistry.shared.handle(host: url.host ?? "", request: captured) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url]))
            return
        }
        var headers = ["Content-Type": "application/json"]
        headers.merge(stub.headers) { _, new in new }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("LumeCloudClient")
struct ClientTests {
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    static let deviceID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let credentials = LumeCloudClient.Credentials(accountId: "acct123", authToken: "tok-SECRET", deviceID: deviceID)

    private func makeClient(
        credentials: LumeCloudClient.Credentials? = ClientTests.credentials,
        handler: @escaping StubRegistry.Handler
    ) -> LumeCloudClient {
        StubRegistry.shared.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LumeCloudClient(
            baseURL: URL(string: "https://\(host)")!,
            session: URLSession(configuration: configuration),
            credentials: credentials
        )
    }

    private func lastRequest() throws -> StubRegistry.Captured {
        try #require(StubRegistry.shared.requests(host: host).last)
    }

    private static func ok(_ json: String, status: Int = 200) -> StubRegistry.Response {
        StubRegistry.Response(status: status, body: Data(json.utf8))
    }

    private static func error(_ status: Int, _ code: String, headers: [String: String] = [:]) -> StubRegistry.Response {
        StubRegistry.Response(status: status, body: Data(#"{"error":"\#(code)","message":"m"}"#.utf8), headers: headers)
    }

    private func expectFullAuth(_ request: StubRegistry.Captured) {
        #expect(request.headers["Authorization"] == "Bearer acct123.tok-SECRET")
        #expect(request.headers["X-Lume-Device"] == "11111111-2222-4333-8444-555555555555")
    }

    private func expectNoAuth(_ request: StubRegistry.Captured) {
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Lume-Device"] == nil)
    }

    // MARK: Accounts

    @Test func createAccount() async throws {
        let keys = try LumeCloudKeys(rootKey: Data(0 ..< 32))
        let client = makeClient { _ in Self.ok(#"{"accountId":"cbm-snbxbUtTCAM8n_puuA","createdAt":1760000000000}"#, status: 201) }
        let created = try await client.createAccount(keys: keys, invite: "inv")
        #expect(created == AccountCreated(accountId: keys.accountId, createdAt: 1_760_000_000_000))
        let request = try lastRequest()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/accounts")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.json == [
            "authVerifier": .string(keys.authVerifier), "accountId": "cbm-snbxbUtTCAM8n_puuA", "invite": "inv",
        ])
        expectNoAuth(request)
    }

    @Test func createAccountOmitsMissingInvite() async throws {
        let keys = try LumeCloudKeys(rootKey: Data(0 ..< 32))
        let client = makeClient(credentials: nil) { _ in Self.ok(#"{"accountId":"a","createdAt":1}"#, status: 201) }
        _ = try await client.createAccount(keys: keys)
        #expect(try lastRequest().json == ["authVerifier": .string(keys.authVerifier), "accountId": .string(keys.accountId)])
    }

    @available(*, deprecated)
    @Test func deprecatedCreateAccountLetsTheServerPickTheID() async throws {
        let client = makeClient(credentials: nil) { _ in Self.ok(#"{"accountId":"a","createdAt":1}"#, status: 201) }
        _ = try await client.createAccount(authVerifier: "verifier")
        #expect(try lastRequest().json == ["authVerifier": "verifier"])
    }

    @Test func duplicateAccountIsTyped() async {
        let client = makeClient(credentials: nil) { _ in Self.error(409, "account_exists") }
        await #expect(throws: LumeCloudError.accountExists) {
            try await client.createAccount(keys: LumeCloudKeys.generate())
        }
    }

    @Test func account() async throws {
        let client = makeClient { _ in
            Self.ok(#"{"accountId":"a","createdAt":1,"usedBytes":1234,"recordCount":56,"nextSeq":789,"futureKey":true}"#)
        }
        let info = try await client.account()
        #expect(info == AccountInfo(accountId: "a", createdAt: 1, usedBytes: 1234, recordCount: 56, nextSeq: 789))
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/v1/accounts/me")
        #expect(request.body == nil)
        expectFullAuth(request)
    }

    @Test func deleteAccount() async throws {
        let client = makeClient { _ in StubRegistry.Response(status: 204, body: Data()) }
        try await client.deleteAccount()
        let request = try lastRequest()
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/accounts/me")
        expectFullAuth(request)
    }

    // MARK: Devices

    @Test func registerDevice() async throws {
        let client = makeClient { _ in
            Self.ok(#"{"id":"11111111-2222-4333-8444-555555555555","name":"Living Room","platform":"tvos","createdAt":1,"lastSeen":2,"revoked":false}"#)
        }
        let device = try await client.registerDevice(id: Self.deviceID, name: "Living Room", platform: .tvOS)
        #expect(device == Device(id: Self.deviceID, name: "Living Room", platform: .tvOS, createdAt: 1, lastSeen: 2, revoked: false))
        let request = try lastRequest()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/devices")
        #expect(request.json == ["id": "11111111-2222-4333-8444-555555555555", "name": "Living Room", "platform": "tvos"])
        #expect(request.headers["Authorization"] == "Bearer acct123.tok-SECRET")
        #expect(request.headers["X-Lume-Device"] == nil)
    }

    @Test func devicesKeepUnknownPlatforms() async throws {
        let client = makeClient { _ in
            Self.ok(#"{"devices":[{"id":"11111111-2222-4333-8444-555555555555","name":"TV","platform":"webos","createdAt":1,"lastSeen":2,"revoked":true}]}"#)
        }
        let devices = try await client.devices()
        #expect(devices.count == 1)
        #expect(devices[0].platform.rawValue == "webos")
        #expect(devices[0].revoked)
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/v1/devices")
        expectFullAuth(request)
    }

    @Test func revokeDevice() async throws {
        let client = makeClient { _ in StubRegistry.Response(status: 204, body: Data()) }
        let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        try await client.revokeDevice(id: id)
        let request = try lastRequest()
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/devices/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
        expectFullAuth(request)
    }

    // MARK: Changes & push

    @Test func changes() async throws {
        let client = makeClient { _ in
            Self.ok(#"{"records":[{"rid":"r1","version":3,"seq":41,"deleted":false,"ciphertext":"AQ","updatedAt":5},{"rid":"r2","version":2,"seq":42,"deleted":true,"ciphertext":null,"updatedAt":6}],"nextSeq":42,"hasMore":false}"#)
        }
        let page = try await client.changes(since: 40, limit: 1000)
        #expect(page.records == [
            RemoteRecord(rid: "r1", version: 3, seq: 41, deleted: false, ciphertext: "AQ", updatedAt: 5),
            RemoteRecord(rid: "r2", version: 2, seq: 42, deleted: true, ciphertext: nil, updatedAt: 6),
        ])
        #expect(page.nextSeq == 42)
        #expect(!page.hasMore)
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/v1/changes")
        #expect(request.query == ["since": "40", "limit": "1000"])
        expectFullAuth(request)
    }

    @Test func changesWithoutLimitUsesServerDefault() async throws {
        let client = makeClient { _ in Self.ok(#"{"records":[],"nextSeq":0,"hasMore":false}"#) }
        _ = try await client.changes(since: 0)
        #expect(try lastRequest().query == ["since": "0"])
    }

    @Test func allChangesFollowsHasMore() async throws {
        let client = makeClient { request in
            switch request.query["since"] {
            case "0": Self.ok(#"{"records":[{"rid":"a","version":1,"seq":1,"deleted":false,"ciphertext":"AQ","updatedAt":1}],"nextSeq":1,"hasMore":true}"#)
            case "1": Self.ok(#"{"records":[{"rid":"b","version":1,"seq":2,"deleted":false,"ciphertext":"AQ","updatedAt":1}],"nextSeq":2,"hasMore":true}"#)
            default: Self.ok(#"{"records":[],"nextSeq":2,"hasMore":false}"#)
            }
        }
        let page = try await client.allChanges(since: 0, limit: 1)
        #expect(page.records.map(\.rid) == ["a", "b"])
        #expect(page.nextSeq == 2)
        #expect(!page.hasMore)
        #expect(StubRegistry.shared.requests(host: host).map { $0.query["since"] } == ["0", "1", "2"])
    }

    @Test func allChangesStopsWhenTheCursorDoesNotAdvance() async throws {
        let client = makeClient { _ in Self.ok(#"{"records":[],"nextSeq":5,"hasMore":true}"#) }
        let page = try await client.allChanges(since: 5)
        #expect(page.nextSeq == 5)
        #expect(StubRegistry.shared.requests(host: host).count == 1)
    }

    @Test func push() async throws {
        let client = makeClient { _ in
            Self.ok(#"{"results":[{"rid":"r1","status":"ok","version":4,"seq":43},{"rid":"r2","status":"conflict","current":{"rid":"r2","version":7,"seq":12,"deleted":false,"ciphertext":"AQID","updatedAt":9}}],"nextSeq":44}"#)
        }
        let response = try await client.push([
            .upsert(rid: "r1", baseVersion: 3, ciphertext: "AQ"),
            .delete(rid: "r2", baseVersion: 6),
        ])
        #expect(response.results == [
            .ok(rid: "r1", version: 4, seq: 43),
            .conflict(rid: "r2", current: RemoteRecord(rid: "r2", version: 7, seq: 12, deleted: false, ciphertext: "AQID", updatedAt: 9)),
        ])
        #expect(response.results.map(\.rid) == ["r1", "r2"])
        #expect(response.nextSeq == 44)
        let request = try lastRequest()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/push")
        // A delete sends an explicit `"ciphertext":null`.
        #expect(request.bodyString == #"{"records":[{"baseVersion":3,"ciphertext":"AQ","deleted":false,"rid":"r1"},{"baseVersion":6,"ciphertext":null,"deleted":true,"rid":"r2"}]}"#)
        expectFullAuth(request)
    }

    @Test func unknownPushStatusIsADecodingError() async {
        let client = makeClient { _ in Self.ok(#"{"results":[{"rid":"r1","status":"maybe"}],"nextSeq":1}"#) }
        await #expect(throws: LumeCloudError.decoding("invalid data at results.0.status")) {
            try await client.push([.upsert(rid: "r1", baseVersion: 0, ciphertext: "AQ")])
        }
    }

    // MARK: Pairing

    @Test func startPairingIsUnauthenticated() async throws {
        let client = makeClient { _ in Self.ok(#"{"code":"483920","pollToken":"POLL-SECRET","expiresAt":99}"#, status: 201) }
        let ticket = try await client.startPairing(publicKey: "pk", deviceName: "Living Room", platform: .tvOS)
        #expect(ticket == PairingTicket(code: "483920", pollToken: "POLL-SECRET", expiresAt: 99))
        #expect(!"\(ticket)".contains("POLL-SECRET"))
        let request = try lastRequest()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/pairings")
        #expect(request.json == ["publicKey": "pk", "deviceName": "Living Room", "platform": "tvos"])
        expectNoAuth(request)
    }

    @Test func pairingRequest() async throws {
        let client = makeClient { _ in Self.ok(#"{"publicKey":"pk","deviceName":"Living Room","platform":"tvos","expiresAt":99}"#) }
        let pending = try await client.pairingRequest(code: "483920")
        #expect(pending == PairingRequest(publicKey: "pk", deviceName: "Living Room", platform: .tvOS, expiresAt: 99))
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/v1/pairings/483920")
        expectFullAuth(request)
    }

    @Test func sealPairing() async throws {
        let client = makeClient { _ in StubRegistry.Response(status: 204, body: Data()) }
        try await client.sealPairing(code: "483920", sealed: SealedGrant(enc: "e", ciphertext: "c"))
        let request = try lastRequest()
        #expect(request.method == "POST")
        #expect(request.path == "/v1/pairings/483920/seal")
        #expect(request.json == ["enc": "e", "ciphertext": "c"])
        expectFullAuth(request)
    }

    @Test func pairingResult() async throws {
        let client = makeClient { request in
            request.query["pollToken"] == "first"
                ? Self.ok(#"{"status":"pending"}"#)
                : Self.ok(#"{"status":"sealed","enc":"e","ciphertext":"c"}"#)
        }
        #expect(try await client.pairingResult(code: "483920", pollToken: "first") == .pending)
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/v1/pairings/483920/result")
        #expect(request.query == ["pollToken": "first"])
        expectNoAuth(request)
        #expect(try await client.pairingResult(code: "483920", pollToken: "x") == .sealed(SealedGrant(enc: "e", ciphertext: "c")))
    }

    // MARK: Health

    @Test func health() async throws {
        let client = makeClient(credentials: nil) { _ in Self.ok(#"{"ok":true,"version":"0.1.0"}"#) }
        #expect(try await client.health() == HealthStatus(ok: true, version: "0.1.0"))
        let request = try lastRequest()
        #expect(request.method == "GET")
        #expect(request.path == "/healthz")
        expectNoAuth(request)
    }

    // MARK: Base URL & credentials

    @Test func baseURLWithAPathPrefixIsKept() {
        let client = LumeCloudClient(baseURL: URL(string: "https://example.com/lume/")!, credentials: nil)
        #expect(client.url("v1/changes", query: [URLQueryItem(name: "since", value: "0")]).absoluteString
            == "https://example.com/lume/v1/changes?since=0")
        #expect(client.url("healthz").absoluteString == "https://example.com/lume/healthz")
    }

    @Test func authenticatedCallWithoutCredentialsFailsLocally() async {
        let client = makeClient(credentials: nil) { _ in Self.ok("{}") }
        await #expect(throws: LumeCloudError.missingCredentials) { try await client.account() }
        #expect(StubRegistry.shared.requests(host: host).isEmpty)
    }

    @Test func withCredentialsSwapsTheIdentity() async throws {
        let client = makeClient(credentials: nil) { _ in Self.ok(#"{"devices":[]}"#) }
        _ = try await client.withCredentials(Self.credentials).devices()
        expectFullAuth(try lastRequest())
    }

    @Test func credentialsFromKeys() throws {
        let keys = try LumeCloudKeys(rootKey: Data(0 ..< 32))
        let credentials = LumeCloudClient.Credentials(accountId: "a", keys: keys, deviceID: Self.deviceID)
        #expect(credentials.authorizationHeader == "Bearer a.Wvn4bW0A86n6O6NDhVbKaher7xdHMctYYtNfr-KGkTY")
        let derived = LumeCloudClient.Credentials(keys: keys, deviceID: Self.deviceID)
        #expect(derived.accountId == "cbm-snbxbUtTCAM8n_puuA")
        #expect(derived.authorizationHeader == "Bearer cbm-snbxbUtTCAM8n_puuA.Wvn4bW0A86n6O6NDhVbKaher7xdHMctYYtNfr-KGkTY")
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in ["\(credentials)", String(reflecting: credentials), dumped] {
            #expect(!text.contains(keys.authToken))
        }
    }

    @Test func socketRequest() throws {
        let client = LumeCloudClient(baseURL: URL(string: "https://cloud.example")!, credentials: Self.credentials)
        let request = try client.makeSocketRequest()
        #expect(request.url?.absoluteString == "wss://cloud.example/v1/socket")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acct123.tok-SECRET")
        #expect(request.value(forHTTPHeaderField: "X-Lume-Device") == "11111111-2222-4333-8444-555555555555")
        let local = LumeCloudClient(baseURL: URL(string: "http://localhost:8787")!, credentials: Self.credentials)
        #expect(try local.makeSocketRequest().url?.absoluteString == "ws://localhost:8787/v1/socket")
    }

    @Test func socketMessages() {
        #expect(LumeCloudClient.seq(from: .string(#"{"type":"seq","seq":44}"#)) == 44)
        #expect(LumeCloudClient.seq(from: .data(Data(#"{"seq":7}"#.utf8))) == 7)
        #expect(LumeCloudClient.seq(from: .string("pong")) == nil)
        #expect(LumeCloudClient.seq(from: .string(#"{"type":"other","seq":1}"#)) == nil)
        #expect(LumeCloudClient.seq(from: .string(#"{"type":"seq"}"#)) == nil)
    }

    @Test func eventsWithoutCredentialsThrows() async {
        let client = LumeCloudClient(baseURL: URL(string: "https://cloud.example")!, credentials: nil)
        await #expect(throws: LumeCloudError.missingCredentials) {
            for try await _ in client.events() {}
        }
    }

    // MARK: Error mapping

    @Test(arguments: [
        (400, "bad_request", LumeCloudError.badRequest(message: "m")),
        (401, "bad_auth", .badAuth),
        (401, "device_revoked", .deviceRevoked),
        (403, "signup_closed", .signupClosed),
        (404, "account_deleted", .accountDeleted),
        (404, "not_found", .notFound),
        (409, "account_exists", .accountExists),
        (409, "pairing_already_sealed", .pairingAlreadySealed),
        (410, "resync_required", .resyncRequired),
        (413, "record_too_large", .recordTooLarge),
        (429, "rate_limited", .rateLimited(retryAfter: nil)),
        (507, "quota_exceeded", .quotaExceeded),
        (500, "internal", .server(status: 500, code: "internal")),
        (418, "teapot", .server(status: 418, code: "teapot")),
    ])
    func errorCodesMapToTypedCases(status: Int, code: String, expected: LumeCloudError) async {
        let client = makeClient { _ in Self.error(status, code) }
        await #expect(throws: expected) { try await client.account() }
    }

    @Test func retryAfterIsParsed() async {
        let client = makeClient { _ in Self.error(429, "rate_limited", headers: ["Retry-After": "17"]) }
        await #expect(throws: LumeCloudError.rateLimited(retryAfter: 17)) { try await client.changes(since: 0) }
    }

    @Test func retryAfterAsHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let later = "Thu, 09 Oct 2025 08:54:20 GMT" // now + 60 s
        #expect(LumeCloudError.parseRetryAfter(later, now: now) == 60)
        #expect(LumeCloudError.parseRetryAfter("garbage", now: now) == nil)
        #expect(LumeCloudError.parseRetryAfter(nil, now: now) == nil)
    }

    @Test func bodilessErrorsMapByStatus() async {
        for (status, expected) in [
            (429, LumeCloudError.rateLimited(retryAfter: 3)), (401, .badAuth), (404, .notFound),
            (410, .resyncRequired), (413, .recordTooLarge), (507, .quotaExceeded), (400, .badRequest(message: nil)),
            (502, .server(status: 502, code: nil)),
        ] {
            let client = makeClient { _ in StubRegistry.Response(status: status, body: Data("<html>".utf8), headers: ["Retry-After": "3"]) }
            await #expect(throws: expected) { try await client.account() }
        }
    }

    @Test func transportErrorsAreStrippedOfTheURL() async throws {
        // No handler registered for this host: the stub fails with a URLError
        // whose userInfo carries the (secret-bearing) URL.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = LumeCloudClient(
            baseURL: URL(string: "https://unregistered-\(UUID().uuidString).test")!,
            session: URLSession(configuration: configuration),
            credentials: nil
        )
        do {
            _ = try await client.pairingResult(code: "123456", pollToken: "POLL-SECRET")
            Issue.record("expected a transport error")
        } catch let error as LumeCloudError {
            guard case let .transport(urlError) = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(urlError.code == .cannotConnectToHost)
            #expect(urlError.failingURL == nil)
            #expect(!String(describing: error).contains("POLL-SECRET"))
            #expect(!(error.errorDescription ?? "").contains("POLL-SECRET"))
        }
    }

    @Test func malformedSuccessBodyIsADecodingError() async {
        let client = makeClient { _ in Self.ok(#"{"accountId":"a"}"#) }
        await #expect(throws: LumeCloudError.decoding("missing key createdAt")) { try await client.account() }
    }

    @Test func errorDescriptionsNeverContainCredentials() {
        let errors: [LumeCloudError] = [
            .badRequest(message: nil), .badAuth, .deviceRevoked, .signupClosed, .accountDeleted, .notFound,
            .accountExists, .pairingAlreadySealed, .resyncRequired, .recordTooLarge, .rateLimited(retryAfter: 2.2), .quotaExceeded,
            .server(status: 500, code: nil), .transport(URLError(.timedOut)), .decoding("x"), .missingCredentials,
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
            #expect(!description.contains("tok-SECRET"))
        }
        #expect(LumeCloudError.rateLimited(retryAfter: 2.2).errorDescription == "Too many requests. Try again in 3 seconds.")
    }
}
