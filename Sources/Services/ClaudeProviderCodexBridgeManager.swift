import Foundation
import Network

func makeClaudeProviderUpstreamRequest(baseURL: String, apiKey: String, body: Data) -> URLRequest {
    let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestURL: URL

    if let minimaxBaseURL = normalizedMiniMaxAnthropicBaseURL(trimmedBaseURL, includeVersion: true) {
        requestURL = URL(string: "\(minimaxBaseURL)/messages")!
    } else {
        let normalizedBaseURL = trimmedBaseURL.hasSuffix("/") ? String(trimmedBaseURL.dropLast()) : trimmedBaseURL
        requestURL = URL(string: "\(normalizedBaseURL)/messages")!
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    if normalizedMiniMaxAnthropicBaseURL(trimmedBaseURL, includeVersion: false) != nil {
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
    } else {
        request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-api-key")
    }

    return request
}

enum ClaudeProviderCodexBridgeManagerError: LocalizedError, Equatable {
    case bridgeStartFailed
    case invalidProvider

    var errorDescription: String? {
        switch self {
        case .bridgeStartFailed:
            return L10n.tr("Claude Provider 到 Codex 的本地桥接启动失败。")
        case .invalidProvider:
            return L10n.tr("Claude Provider 配置不完整。")
        }
    }
}

actor ClaudeProviderCodexBridgeManager {
    private let sendUpstreamRequest: @Sendable (String, String, Data) async throws -> (Int, Data)
    private var servers: [String: ClaudeProviderCodexBridgeServer] = [:]

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
    ) async throws -> PreparedClaudeProviderCodexBridge {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedAPIKey.isEmpty, !trimmedModel.isEmpty else {
            throw ClaudeProviderCodexBridgeManagerError.invalidProvider
        }

        let server = servers[accountID.uuidString]
            ?? ClaudeProviderCodexBridgeServer(sendUpstreamRequest: sendUpstreamRequest)
        server.update(
            baseURL: trimmedBaseURL,
            apiKeyEnvName: apiKeyEnvName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            model: trimmedModel,
            availableModels: availableModels
        )
        let localBaseURL = try await server.startIfNeeded()
        servers[accountID.uuidString] = server

        return PreparedClaudeProviderCodexBridge(
            baseURL: localBaseURL,
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "claude-provider-bridge"
        )
    }

    private static func sendUpstreamRequest(baseURL: String, apiKey: String, body: Data) async throws -> (Int, Data) {
        let request = makeClaudeProviderUpstreamRequest(baseURL: baseURL, apiKey: apiKey, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return (statusCode, data)
    }
}

extension ClaudeProviderCodexBridgeManager: ClaudeProviderCodexBridgeManaging {}

private final class ClaudeProviderCodexBridgeServer: @unchecked Sendable {
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

    private let queue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.codex-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.codex-bridge.state")
    private let sendUpstreamRequest: @Sendable (String, String, Data) async throws -> (Int, Data)

    private var listener: NWListener?
    private var localBaseURL: String?
    private var upstreamBaseURL = ""
    private var apiKeyEnvName = "ANTHROPIC_API_KEY"
    private var apiKey = ""
    private var defaultModel = "claude-sonnet-4.5"
    private var availableModels = ["claude-sonnet-4.5"]

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, Data) async throws -> (Int, Data)
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func update(baseURL: String, apiKeyEnvName: String, apiKey: String, model: String, availableModels: [String]) {
        stateQueue.sync {
            self.upstreamBaseURL = baseURL
            self.apiKeyEnvName = apiKeyEnvName.isEmpty ? "ANTHROPIC_API_KEY" : apiKeyEnvName
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
            let resumeQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.codex-bridge.resume")

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
                        resumeOnce(.failure(ClaudeProviderCodexBridgeManagerError.bridgeStartFailed))
                        return
                    }
                    let localBaseURL = "http://127.0.0.1:\(port)"
                    self.stateQueue.sync {
                        self.localBaseURL = localBaseURL
                    }
                    resumeOnce(.success(localBaseURL))
                case .failed:
                    resumeOnce(.failure(ClaudeProviderCodexBridgeManagerError.bridgeStartFailed))
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
            let upstreamRequest = try Self.makeClaudeRequest(from: requestObject, fallbackModel: state.defaultModel)
            let (statusCode, data) = try await sendUpstreamRequest(state.baseURL, state.apiKey, upstreamRequest)

            guard (200..<300).contains(statusCode) else {
                return jsonResponse(statusCode: statusCode, body: errorPayload(message: extractErrorMessage(from: data)))
            }

            let responseObject = try Self.makeResponsesResponse(from: data, fallbackModel: state.defaultModel)
            if wantsStream {
                let body = Self.makeResponseStreamData(from: responseObject)
                return HTTPResponse(statusCode: 200, contentType: "text/event-stream", body: body)
            }
            return jsonResponse(statusCode: 200, body: jsonData(responseObject))
        } catch {
            return jsonResponse(statusCode: 502, body: errorPayload(message: error.localizedDescription))
        }
    }

    private func requestJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeProviderCodexBridgeManagerError.invalidProvider
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
            "owned_by": "claude-compatible",
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

    private func extractErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? L10n.tr("上游模型返回了未知错误。")
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let type = object["type"] as? String, type == "error", let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? L10n.tr("上游模型返回了未知错误。")
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

    private static func makeClaudeRequest(from request: [String: Any], fallbackModel: String) throws -> Data {
        let model = (request["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (request["model"] as? String ?? fallbackModel)
            : fallbackModel
        let instructions = (request["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let messages = translateMessages(from: request["input"])
        let tools = translateTools(from: request["tools"])
        let toolChoice = translateToolChoice(from: request["tool_choice"])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 8192,
        ]
        if let instructions, !instructions.isEmpty {
            body["system"] = instructions
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let toolChoice {
            body["tool_choice"] = toolChoice
        }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private static func translateMessages(from input: Any?) -> [[String: Any]] {
        if let text = input as? String, !text.isEmpty {
            return [[
                "role": "user",
                "content": [["type": "text", "text": text]],
            ]]
        }

        guard let items = input as? [Any] else {
            return []
        }

        var messages = [[String: Any]]()
        var pendingToolResults = [[String: Any]]()

        for itemValue in items {
            guard let item = itemValue as? [String: Any] else { continue }
            let type = (item["type"] as? String) ?? ""

            switch type {
            case "message":
                if !pendingToolResults.isEmpty {
                    messages.append([
                        "role": "user",
                        "content": pendingToolResults,
                    ])
                    pendingToolResults.removeAll()
                }
                let role = (item["role"] as? String) ?? "user"
                let content = translateMessageContent(from: item["content"])
                messages.append([
                    "role": role == "assistant" ? "assistant" : "user",
                    "content": content.isEmpty ? [["type": "text", "text": ""]] : content,
                ])
            case "function_call_output":
                let outputText = (item["output"] as? String) ?? "{}"
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": (item["call_id"] as? String) ?? UUID().uuidString,
                    "content": outputText,
                ])
            default:
                continue
            }
        }

        if !pendingToolResults.isEmpty {
            messages.append([
                "role": "user",
                "content": pendingToolResults,
            ])
        }

        return messages
    }

    private static func translateMessageContent(from content: Any?) -> [[String: Any]] {
        if let text = content as? String {
            return [["type": "text", "text": text]]
        }
        guard let contentItems = content as? [Any] else {
            return []
        }

        var translated = [[String: Any]]()
        for contentValue in contentItems {
            guard let contentItem = contentValue as? [String: Any] else { continue }
            switch contentItem["type"] as? String {
            case "input_text", "output_text", "text":
                translated.append([
                    "type": "text",
                    "text": (contentItem["text"] as? String) ?? "",
                ])
            case "function_call":
                translated.append([
                    "type": "tool_use",
                    "id": (contentItem["call_id"] as? String) ?? UUID().uuidString,
                    "name": (contentItem["name"] as? String) ?? "tool",
                    "input": parsedJSONObject(from: contentItem["arguments"]) ?? [:],
                ])
            default:
                continue
            }
        }
        return translated
    }

    private static func translateTools(from value: Any?) -> [[String: Any]] {
        guard let tools = value as? [Any] else { return [] }
        return tools.compactMap { toolValue in
            guard let tool = toolValue as? [String: Any] else { return nil }
            let name = (tool["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            let schema = (tool["parameters"] as? [String: Any]) ?? (tool["input_schema"] as? [String: Any]) ?? [:]
            return [
                "name": name,
                "description": (tool["description"] as? String) ?? "",
                "input_schema": schema,
            ]
        }
    }

    private static func translateToolChoice(from value: Any?) -> [String: Any]? {
        guard let value else { return nil }
        if let stringValue = value as? String {
            switch stringValue {
            case "auto":
                return ["type": "auto"]
            case "required":
                return ["type": "any"]
            default:
                return nil
            }
        }
        guard let object = value as? [String: Any], let type = object["type"] as? String else {
            return nil
        }
        if type == "function", let name = object["name"] as? String {
            return ["type": "tool", "name": name]
        }
        return nil
    }

    private static func makeResponsesResponse(from data: Data, fallbackModel: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeProviderCodexBridgeManagerError.invalidProvider
        }

        let contentBlocks = object["content"] as? [Any] ?? []
        var output = [[String: Any]]()
        var messageContent = [[String: Any]]()

        for blockValue in contentBlocks {
            guard let block = blockValue as? [String: Any], let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                messageContent.append([
                    "type": "output_text",
                    "text": (block["text"] as? String) ?? "",
                ])
            case "tool_use":
                if !messageContent.isEmpty {
                    output.append([
                        "type": "message",
                        "role": "assistant",
                        "content": messageContent,
                    ])
                    messageContent.removeAll()
                }
                output.append([
                    "type": "function_call",
                    "call_id": (block["id"] as? String) ?? UUID().uuidString,
                    "name": (block["name"] as? String) ?? "tool",
                    "arguments": jsonString(from: block["input"] ?? [:]) ?? "{}",
                ])
            default:
                continue
            }
        }

        if !messageContent.isEmpty {
            output.append([
                "type": "message",
                "role": "assistant",
                "content": messageContent,
            ])
        }

        let usage = object["usage"] as? [String: Any]
        return [
            "id": object["id"] as? String ?? UUID().uuidString,
            "object": "response",
            "model": object["model"] as? String ?? fallbackModel,
            "output": output,
            "usage": [
                "input_tokens": usage?["input_tokens"] as? Int ?? 0,
                "output_tokens": usage?["output_tokens"] as? Int ?? 0,
                "total_tokens": (usage?["input_tokens"] as? Int ?? 0) + (usage?["output_tokens"] as? Int ?? 0),
            ],
        ]
    }

    private static func makeResponseStreamData(from response: [String: Any]) -> Data {
        let eventObject: [String: Any] = [
            "type": "response.completed",
            "response": response,
        ]
        let payload = jsonString(from: eventObject) ?? "{}"
        return Data("event: response.completed\ndata: \(payload)\n\ndata: [DONE]\n\n".utf8)
    }

    private static func parsedJSONObject(from value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let text = value as? String, let data = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonString(from value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
