import Foundation
import Network

enum OpenAICompatibleProviderCodexBridgeManagerError: LocalizedError, Equatable {
    case bridgeStartFailed
    case invalidProvider

    var errorDescription: String? {
        switch self {
        case .bridgeStartFailed:
            return L10n.tr("OpenAI 兼容 Provider 到 Codex 的本地桥接启动失败。")
        case .invalidProvider:
            return L10n.tr("OpenAI 兼容 Provider 配置不完整。")
        }
    }
}

actor OpenAICompatibleProviderCodexBridgeManager {
    private let sendUpstreamRequest: @Sendable (String, String, Data) async throws -> (Int, Data)
    private var servers: [String: OpenAICompatibleProviderCodexBridgeServer] = [:]

    init() {
        self.sendUpstreamRequest = Self.sendUpstreamRequest
    }

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, Data) async throws -> (Int, Data)
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedAPIKey.isEmpty, !trimmedModel.isEmpty else {
            throw OpenAICompatibleProviderCodexBridgeManagerError.invalidProvider
        }

        let server = servers[accountID.uuidString]
            ?? OpenAICompatibleProviderCodexBridgeServer(sendUpstreamRequest: sendUpstreamRequest)
        server.update(
            baseURL: trimmedBaseURL,
            apiKeyEnvName: apiKeyEnvName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            model: trimmedModel,
            availableModels: availableModels
        )
        let localBaseURL = try await server.startIfNeeded()
        servers[accountID.uuidString] = server

        return PreparedOpenAICompatibleProviderCodexBridge(
            baseURL: localBaseURL,
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "openai-compatible-provider-bridge"
        )
    }

    private static func sendUpstreamRequest(baseURL: String, apiKey: String, body: Data) async throws -> (Int, Data) {
        let normalizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let url = URL(string: "\(normalizedBaseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return (statusCode, data)
    }
}

extension OpenAICompatibleProviderCodexBridgeManager: OpenAICompatibleProviderCodexBridgeManaging {}

private final class OpenAICompatibleProviderCodexBridgeServer: @unchecked Sendable {
    private final class ResumeState: @unchecked Sendable {
        var didResume = false
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private struct HTTPResponse {
        let statusCode: Int
        let contentType: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.openai-compatible-provider-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.openai-compatible-provider-bridge.state")
    private let sendUpstreamRequest: @Sendable (String, String, Data) async throws -> (Int, Data)

    private var listener: NWListener?
    private var localBaseURL: String?
    private var upstreamBaseURL = ""
    private var apiKeyEnvName = "OPENAI_API_KEY"
    private var apiKey = ""
    private var defaultModel = "gpt-5.4"
    private var availableModels = ["gpt-5.4"]

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, Data) async throws -> (Int, Data)
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func update(baseURL: String, apiKeyEnvName: String, apiKey: String, model: String, availableModels: [String]) {
        stateQueue.sync {
            self.upstreamBaseURL = baseURL
            self.apiKeyEnvName = apiKeyEnvName.isEmpty ? "OPENAI_API_KEY" : apiKeyEnvName
            self.apiKey = apiKey
            self.defaultModel = model
            self.availableModels = normalizedAvailableModels(availableModels, fallbackModel: model)
        }
    }

    func startIfNeeded() async throws -> String {
        if let localBaseURL = stateQueue.sync(execute: { self.localBaseURL }) {
            return localBaseURL
        }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeState()
            let resumeQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.openai-compatible-provider-bridge.resume")

            let resumeOnce: @Sendable (Result<String, Error>) -> Void = { result in
                resumeQueue.sync {
                    guard !resumeState.didResume else { return }
                    resumeState.didResume = true
                    switch result {
                    case let .success(baseURL):
                        continuation.resume(returning: baseURL)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        resumeOnce(.failure(OpenAICompatibleProviderCodexBridgeManagerError.bridgeStartFailed))
                        return
                    }
                    let localBaseURL = "http://127.0.0.1:\(port)"
                    self.stateQueue.sync {
                        self.localBaseURL = localBaseURL
                    }
                    resumeOnce(.success(localBaseURL))
                case .failed:
                    resumeOnce(.failure(OpenAICompatibleProviderCodexBridgeManagerError.bridgeStartFailed))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = parseRequest(from: nextBuffer) {
                Task { [weak self] in
                    guard let self else { return }
                    let response = await self.response(for: request)
                    self.send(response: response, through: connection)
                }
                return
            }

            if isComplete {
                send(
                    response: jsonResponse(
                        statusCode: 400,
                        body: errorPayload(message: L10n.tr("Codex 请求格式无效。"))
                    ),
                    through: connection
                )
                return
            }

            receive(connection: connection, buffer: nextBuffer)
        }
    }

    private func parseRequest(from buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            return nil
        }

        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers = [String: String]()
        for line in headerLines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else {
            return nil
        }

        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func response(for request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/responses"), ("POST", "/v1/responses"):
            return await responsesResponse(for: request)
        case ("GET", "/models"), ("GET", "/v1/models"):
            return jsonResponse(statusCode: 200, body: jsonData(["data": modelObjects()]))
        default:
            return jsonResponse(statusCode: 404, body: errorPayload(message: L10n.tr("不支持的 Codex Provider 路径。")))
        }
    }

    private func responsesResponse(for request: HTTPRequest) async -> HTTPResponse {
        do {
            let state = currentState()
            let requestObject = try requestJSONObject(from: request.body)
            let wantsStream = (requestObject["stream"] as? Bool) ?? false
            let upstreamRequest = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
                from: request.body,
                fallbackModel: state.defaultModel
            )
            let (statusCode, data) = try await sendUpstreamRequest(state.baseURL, state.apiKey, upstreamRequest)

            guard (200..<300).contains(statusCode) else {
                return jsonResponse(
                    statusCode: statusCode,
                    body: errorPayload(message: ResponsesChatCompletionsBridge.extractErrorMessage(from: data))
                )
            }

            let responseData = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
                from: data,
                fallbackModel: state.defaultModel
            )
            guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw ResponsesChatCompletionsBridge.TranslationError.invalidResponse(L10n.tr("本地桥接响应格式无效。"))
            }

            if wantsStream {
                return HTTPResponse(
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: ResponsesChatCompletionsBridge.makeResponseStreamData(from: responseObject)
                )
            }

            return jsonResponse(statusCode: 200, body: responseData)
        } catch {
            return jsonResponse(statusCode: 502, body: errorPayload(message: error.localizedDescription))
        }
    }

    private func requestJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICompatibleProviderCodexBridgeManagerError.invalidProvider
        }
        return object
    }

    private func currentState() -> (baseURL: String, apiKeyEnvName: String, apiKey: String, defaultModel: String, availableModels: [String]) {
        stateQueue.sync {
            (upstreamBaseURL, apiKeyEnvName, apiKey, defaultModel, availableModels)
        }
    }

    private func send(response: HTTPResponse, through connection: NWConnection) {
        let header = [
            "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func jsonResponse(statusCode: Int, body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "application/json", body: body)
    }

    private func errorPayload(message: String) -> Data {
        jsonData([
            "error": [
                "message": message,
                "type": "api_error",
            ],
        ])
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }

    private func modelObjects() -> [[String: Any]] {
        let state = currentState()
        let models = state.availableModels.isEmpty ? [state.defaultModel] : state.availableModels
        return models.map(modelObject(for:))
    }

    private func modelObject(for model: String) -> [String: Any] {
        return [
            "id": model,
            "object": "model",
            "owned_by": "openai-compatible-provider",
        ]
    }

    private func normalizedAvailableModels(_ availableModels: [String], fallbackModel: String) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in availableModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        let trimmedFallback = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty, seen.insert(trimmedFallback).inserted {
            normalized.append(trimmedFallback)
        }

        return normalized
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        case 429:
            return "Too Many Requests"
        default:
            return "Error"
        }
    }
}
