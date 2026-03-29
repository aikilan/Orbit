import Foundation
import Network

struct BrowserAuthorizationCallback: Sendable {
    let code: String
    let state: String
}

final class LoopbackCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openai.Orbit.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<BrowserAuthorizationCallback, Error>?
    private var pendingResult: Result<BrowserAuthorizationCallback, Error>?

    private let host: String
    private let port: UInt16
    private let callbackPath: String

    init(host: String = "localhost", port: UInt16 = 1455, callbackPath: String = "/auth/callback") {
        self.host = host
        self.port = port
        self.callbackPath = callbackPath
    }

    func start() async throws -> URL {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthClientError.callbackServerFailed
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        let resolvedPort = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: OAuthClientError.callbackServerFailed)
                    }
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: self.queue)
        }

        return URL(string: "http://\(host):\(resolvedPort)\(callbackPath)")!
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> BrowserAuthorizationCallback {
        defer { stop() }

        return try await withThrowingTaskGroup(of: BrowserAuthorizationCallback.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserAuthorizationCallback, Error>) in
                    guard let self else {
                        continuation.resume(throwing: OAuthClientError.callbackServerFailed)
                        return
                    }

                    self.lock.lock()
                    if let pendingResult = self.pendingResult {
                        self.pendingResult = nil
                        self.lock.unlock()
                        continuation.resume(with: pendingResult)
                    } else {
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OAuthClientError.loginTimedOut
            }

            guard let result = try await group.next() else {
                throw OAuthClientError.loginTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            defer {
                connection.cancel()
            }

            if let error {
                self.finish(with: .failure(error))
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.sendResponse(connection: connection, statusCode: 400, body: "Invalid request.")
                self.finish(with: .failure(OAuthClientError.invalidCallback))
                return
            }

            let callbackResult = self.parseCallback(from: request)
            switch callbackResult {
            case let .success(callback):
                self.sendResponse(
                    connection: connection,
                    statusCode: 200,
                    body: "<html><body><h2>Login completed.</h2><p>You can close this tab and return to Orbit.</p></body></html>"
                )
                self.finish(with: .success(callback))
            case let .failure(error):
                self.sendResponse(
                    connection: connection,
                    statusCode: 400,
                    body: "<html><body><h2>Login failed.</h2><p>\(error.localizedDescription)</p></body></html>"
                )
                self.finish(with: .failure(error))
            }
        }
    }

    private func parseCallback(from request: String) -> Result<BrowserAuthorizationCallback, Error> {
        guard let requestLine = request.split(separator: "\r\n").first else {
            return .failure(OAuthClientError.invalidCallback)
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return .failure(OAuthClientError.invalidCallback)
        }

        let rawPath = String(components[1])
        guard let urlComponents = URLComponents(string: "http://\(host)\(rawPath)") else {
            return .failure(OAuthClientError.invalidCallback)
        }

        guard urlComponents.path == callbackPath else {
            return .failure(OAuthClientError.invalidCallback)
        }

        let queryItems = Dictionary(uniqueKeysWithValues: (urlComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = queryItems["error"], !error.isEmpty {
            return .failure(OAuthClientError.oauthRejected(error))
        }

        guard let code = queryItems["code"], !code.isEmpty, let state = queryItems["state"], !state.isEmpty else {
            return .failure(OAuthClientError.invalidCallback)
        }

        return .success(BrowserAuthorizationCallback(code: code, state: state))
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let response = """
        HTTP/1.1 \(statusCode) OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func finish(with result: Result<BrowserAuthorizationCallback, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
