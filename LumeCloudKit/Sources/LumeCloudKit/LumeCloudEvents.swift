import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension LumeCloudClient {
    /// Opens `GET /v1/socket` (PROTOCOL.md §4.6) and yields the account's
    /// feed `seq` every time it advances. Pull `/changes` when one arrives.
    ///
    /// - Sends the text `ping` every 30 s; `pong` replies are swallowed.
    /// - Finishes when the server closes normally, and throws
    ///   `LumeCloudError` for anything else (a failed upgrade maps by HTTP
    ///   status, so a 401 reads as `.badAuth` and a 404 as `.notFound` —
    ///   pull `/changes` for the precise code).
    /// - Never reconnects on its own. The socket is only a hint: keep pulling
    ///   on launch and foreground, and pick your own reconnect policy.
    ///
    /// Cancelling the consuming task (or dropping the stream) closes the socket.
    public func events() -> AsyncThrowingStream<Int, Error> {
        let request: URLRequest
        do {
            request = try makeSocketRequest()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let task = session.webSocketTask(with: request)
        let pingInterval = pingInterval

        return AsyncThrowingStream { continuation in
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        if let seq = Self.seq(from: message) {
                            continuation.yield(seq)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || [.normalClosure, .goingAway].contains(task.closeCode) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.socketError(error, task: task))
                    }
                }
            }
            let pinger = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: pingInterval)
                        try await task.send(.string("ping"))
                    } catch {
                        // The receiver sees the same failure and finishes the stream.
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                pinger.cancel()
                task.cancel(with: .normalClosure, reason: nil)
            }
            task.resume()
        }
    }

    /// The upgrade request: `ws(s)://…/v1/socket` with the auth headers.
    func makeSocketRequest() throws -> URLRequest {
        var request = try makeRequest(.get, "v1/socket", auth: .full)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        if var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            switch components.scheme?.lowercased() {
            case "https": components.scheme = "wss"
            case "http": components.scheme = "ws"
            default: break
            }
            request.url = components.url
        }
        return request
    }

    /// The `seq` of a `{"type":"seq","seq":N}` message; `nil` for anything
    /// else (`pong`, unknown message types).
    static func seq(from message: URLSessionWebSocketTask.Message) -> Int? {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(bytes): data = bytes
        @unknown default: return nil
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value["type"]?.stringValue ?? "seq" == "seq"
        else { return nil }
        return value["seq"]?.intValue
    }

    /// Maps a socket failure (anything but a normal close) to `LumeCloudError`.
    static func socketError(_ error: any Error, task: URLSessionWebSocketTask) -> LumeCloudError {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return LumeCloudError.from(
                status: http.statusCode,
                body: Data(),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        if let urlError = error as? URLError {
            return LumeCloudError.sanitizedTransport(urlError)
        }
        // POSIX errors and abnormal close codes: the connection is gone.
        return LumeCloudError.transport(URLError(.networkConnectionLost))
    }
}
