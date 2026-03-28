import Foundation
import Network

func makeCodexResponsesBridgeRequestData(from data: Data, fallbackModel: String) throws -> Data {
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CodexOAuthClaudeBridgeServer.TranslationError.invalidRequest(L10n.tr("Claude 请求不是有效的 JSON。"))
    }

    let model = CodexOAuthClaudeBridgeServer.trimmedString(body["model"]) ?? fallbackModel
    let instructions = CodexOAuthClaudeBridgeServer.extractInstructions(from: body["system"])
    let input = try CodexOAuthClaudeBridgeServer.translateMessages(from: body["messages"])
    let tools = CodexOAuthClaudeBridgeServer.translateTools(from: body["tools"])

    let request: [String: Any] = [
        "model": model,
        "instructions": instructions.isEmpty ? L10n.tr("You are Claude Code.") : instructions,
        "input": input,
        "tools": tools,
        "tool_choice": CodexOAuthClaudeBridgeServer.translateToolChoice(from: body["tool_choice"]),
        "parallel_tool_calls": true,
        "store": false,
        "stream": true,
        "include": [],
    ]

    return try JSONSerialization.data(withJSONObject: request, options: [])
}

func extractCodexResponsesBridgeCompletedData(from data: Data) throws -> Data {
    if (try? JSONSerialization.jsonObject(with: data)) != nil {
        return data
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw CodexOAuthClaudeBridgeServer.TranslationError.invalidResponse(L10n.tr("上游 Responses 返回了无效 JSON。"))
    }

    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let blocks = normalized.components(separatedBy: "\n\n")
    var lastResponseObject: [String: Any]?

    for block in blocks {
        let lines = block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { continue }

        var eventName: String?
        var dataLines = [String]()
        for line in lines {
            if line.hasPrefix("event:") {
                eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        let payloadString = dataLines.joined(separator: "\n")
        guard !payloadString.isEmpty, payloadString != "[DONE]",
              let payloadData = payloadString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            continue
        }

        if let responseObject = object["response"] as? [String: Any] {
            lastResponseObject = responseObject
            if eventName == "response.completed" {
                return try JSONSerialization.data(withJSONObject: responseObject, options: [])
            }
        }
    }

    if let lastResponseObject {
        return try JSONSerialization.data(withJSONObject: lastResponseObject, options: [])
    }

    throw CodexOAuthClaudeBridgeServer.TranslationError.invalidResponse(L10n.tr("上游 Responses 返回了无效 JSON。"))
}

struct CodexOAuthClaudeBridgeUpstreamResponse: Sendable {
    let statusCode: Int
    let body: Data
}

private func defaultCodexOAuthClaudeBridgeUpstreamRequest(
    source: OpenAICompatibleClaudeBridgeSource,
    body: Data
) async throws -> CodexOAuthClaudeBridgeUpstreamResponse {
    switch source {
    case let .codexAuthPayload(payload):
        let url: URL
        let authorizationValue: String
        let accountID: String?

        switch payload.authMode {
        case .chatgpt:
            url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
            authorizationValue = "Bearer \(payload.tokens.accessToken)"
            accountID = payload.tokens.accountID
        case .openAIAPIKey:
            guard let apiKey = payload.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
                throw CodexOAuthClaudeBridgeManagerError.unsupportedAuthMode
            }
            url = URL(string: "https://api.openai.com/v1/responses")!
            authorizationValue = "Bearer \(apiKey)"
            accountID = nil
        case .claudeProfile, .anthropicAPIKey, .providerAPIKey:
            throw CodexOAuthClaudeBridgeManagerError.unsupportedAuthMode
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return CodexOAuthClaudeBridgeUpstreamResponse(statusCode: statusCode, body: data)
    case let .provider(baseURL, _, apiKey, supportsResponsesAPI):
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBaseURL.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexOAuthClaudeBridgeManagerError.unsupportedAuthMode
        }

        if supportsResponsesAPI {
            var request = URLRequest(url: URL(string: "\(trimmedBaseURL)/responses")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
            return CodexOAuthClaudeBridgeUpstreamResponse(statusCode: statusCode, body: data)
        }

        let requestObject = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let fallbackModel = CodexOAuthClaudeBridgeServer.trimmedString(requestObject?["model"]) ?? "gpt-5.4"
        let chatRequest = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: body,
            fallbackModel: fallbackModel
        )
        var request = URLRequest(url: URL(string: "\(trimmedBaseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = chatRequest
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        if !(200..<300).contains(statusCode) {
            return CodexOAuthClaudeBridgeUpstreamResponse(statusCode: statusCode, body: data)
        }
        let bridgedData = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: data,
            fallbackModel: fallbackModel
        )
        return CodexOAuthClaudeBridgeUpstreamResponse(statusCode: statusCode, body: bridgedData)
    }
}

enum CodexOAuthClaudeBridgeManagerError: LocalizedError, Equatable {
    case bridgeStartFailed
    case unsupportedAuthMode

    var errorDescription: String? {
        switch self {
        case .bridgeStartFailed:
            return L10n.tr("本地 Codex 凭据桥接启动失败。")
        case .unsupportedAuthMode:
            return L10n.tr("当前 Codex 账号凭据不支持桥接到 Claude Code。")
        }
    }
}

actor CodexOAuthClaudeBridgeManager {
    private let sendUpstreamRequest: @Sendable (OpenAICompatibleClaudeBridgeSource, Data) async throws -> CodexOAuthClaudeBridgeUpstreamResponse
    private var servers: [String: CodexOAuthClaudeBridgeServer] = [:]

    init(
        sendUpstreamRequest: @escaping @Sendable (OpenAICompatibleClaudeBridgeSource, Data) async throws -> CodexOAuthClaudeBridgeUpstreamResponse = defaultCodexOAuthClaudeBridgeUpstreamRequest
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String
    ) async throws -> PreparedCodexOAuthClaudeBridge {
        if case let .codexAuthPayload(payload) = source,
           payload.authMode != .chatgpt && payload.authMode != .openAIAPIKey
        {
            throw CodexOAuthClaudeBridgeManagerError.unsupportedAuthMode
        }

        let key = accountID.uuidString
        let server = servers[key] ?? CodexOAuthClaudeBridgeServer(sendUpstreamRequest: sendUpstreamRequest)
        server.update(source: source, defaultModel: model)
        let baseURL = try await server.startIfNeeded()
        servers[key] = server

        return PreparedCodexOAuthClaudeBridge(
            baseURL: baseURL,
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "codex-oauth-bridge"
        )
    }
}

extension CodexOAuthClaudeBridgeManager: CodexOAuthClaudeBridgeManaging {}

fileprivate final class CodexOAuthClaudeBridgeServer: @unchecked Sendable {
    private final class ResumeState: @unchecked Sendable {
        var didResume = false
    }

    private struct HTTPRequest {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data

        var path: String {
            URLComponents(string: "http://127.0.0.1\(target)")?.path ?? target
        }
    }

    private struct HTTPResponse {
        let statusCode: Int
        let contentType: String
        let body: Data
    }

    fileprivate enum TranslationError: LocalizedError {
        case invalidRequest(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case let .invalidRequest(message):
                return message
            case let .invalidResponse(message):
                return message
            }
        }
    }

    private let queue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.claude-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.claude-bridge.state")
    private let sendUpstreamRequest: @Sendable (OpenAICompatibleClaudeBridgeSource, Data) async throws -> CodexOAuthClaudeBridgeUpstreamResponse
    private var listener: NWListener?
    private var baseURL: String?
    private var source: OpenAICompatibleClaudeBridgeSource?
    private var defaultModel = "gpt-5.4"

    init(
        sendUpstreamRequest: @escaping @Sendable (OpenAICompatibleClaudeBridgeSource, Data) async throws -> CodexOAuthClaudeBridgeUpstreamResponse
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
    }

    func update(source: OpenAICompatibleClaudeBridgeSource, defaultModel: String) {
        stateQueue.sync {
            self.source = source
            if !defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.defaultModel = defaultModel
            }
        }
    }

    func startIfNeeded() async throws -> String {
        if let baseURL = stateQueue.sync(execute: { baseURL }) {
            return baseURL
        }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeState()
            let resumeQueue = DispatchQueue(label: "com.openai.CodexAccountSwitcher.claude-bridge.resume")

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
                        resumeOnce(.failure(CodexOAuthClaudeBridgeManagerError.bridgeStartFailed))
                        return
                    }

                    let baseURL = "http://127.0.0.1:\(port)"
                    self.stateQueue.sync {
                        self.baseURL = baseURL
                    }
                    resumeOnce(.success(baseURL))
                case .failed:
                    resumeOnce(.failure(CodexOAuthClaudeBridgeManagerError.bridgeStartFailed))
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

            if let request = self.parseRequest(from: nextBuffer) {
                Task { [weak self] in
                    guard let self else { return }
                    let response = await self.response(for: request)
                    self.send(response: response, through: connection)
                }
                return
            }

            if isComplete {
                self.send(
                    response: self.jsonResponse(
                        statusCode: 400,
                        body: self.errorPayload(type: "invalid_request_error", message: L10n.tr("Claude 请求格式无效。"))
                    ),
                    through: connection
                )
                return
            }

            self.receive(connection: connection, buffer: nextBuffer)
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

        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func response(for request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/messages"):
            return await messageResponse(for: request)
        case ("POST", "/v1/messages/count_tokens"):
            return countTokensResponse(for: request)
        case ("GET", "/v1/models"):
            return modelsResponse()
        case let ("GET", path) where path.hasPrefix("/v1/models/"):
            return modelResponse(id: String(path.dropFirst("/v1/models/".count)))
        default:
            return jsonResponse(
                statusCode: 404,
                body: errorPayload(type: "not_found_error", message: L10n.tr("不支持的 Claude 桥接路径。"))
            )
        }
    }

    private func messageResponse(for request: HTTPRequest) async -> HTTPResponse {
        do {
            let (source, defaultModel) = currentState()
            guard let source else {
                return jsonResponse(
                    statusCode: 502,
                    body: errorPayload(type: "api_error", message: L10n.tr("本地 Codex 凭据桥接启动失败。"))
                )
            }
            let upstreamBody = try Self.makeResponsesRequestData(from: request.body, fallbackModel: defaultModel)
            let upstreamResponse = try await sendUpstreamRequest(source, upstreamBody)

            if (200..<300).contains(upstreamResponse.statusCode) {
                let normalizedBody = try Self.extractCompletedResponsesData(from: upstreamResponse.body)
                if Self.requestWantsStreaming(request.body) {
                    let bridgedBody = try Self.makeAnthropicMessageStreamData(
                        from: normalizedBody,
                        fallbackModel: defaultModel
                    )
                    return eventStreamResponse(statusCode: 200, body: bridgedBody)
                }

                let bridgedBody = try Self.makeAnthropicMessageResponseData(
                    from: normalizedBody,
                    fallbackModel: defaultModel
                )
                return jsonResponse(statusCode: 200, body: bridgedBody)
            }

            return jsonResponse(
                statusCode: upstreamResponse.statusCode,
                body: errorPayload(
                    type: Self.errorType(for: upstreamResponse.statusCode),
                    message: Self.extractUpstreamErrorMessage(from: upstreamResponse.body)
                )
            )
        } catch let error as TranslationError {
            let statusCode: Int
            switch error {
            case .invalidRequest:
                statusCode = 400
            case .invalidResponse:
                statusCode = 502
            }
            return jsonResponse(
                statusCode: statusCode,
                body: errorPayload(type: "invalid_request_error", message: error.localizedDescription)
            )
        } catch {
            return jsonResponse(
                statusCode: 502,
                body: errorPayload(type: "api_error", message: error.localizedDescription)
            )
        }
    }

    private func countTokensResponse(for request: HTTPRequest) -> HTTPResponse {
        let estimated = max(1, request.body.count / 4)
        let payload = ["input_tokens": estimated]
        return jsonResponse(statusCode: 200, body: jsonData(payload))
    }

    private func modelsResponse() -> HTTPResponse {
        let model = currentState().defaultModel
        let payload: [String: Any] = [
            "data": [modelObject(for: model)],
            "has_more": false,
            "first_id": model,
            "last_id": model,
        ]
        return jsonResponse(statusCode: 200, body: jsonData(payload))
    }

    private func modelResponse(id: String) -> HTTPResponse {
        let model = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonResponse(statusCode: 200, body: jsonData(modelObject(for: model.isEmpty ? currentState().defaultModel : model)))
    }

    private func modelObject(for model: String) -> [String: Any] {
        [
            "id": model,
            "type": "model",
            "display_name": model,
        ]
    }

    private func currentState() -> (source: OpenAICompatibleClaudeBridgeSource?, defaultModel: String) {
        stateQueue.sync {
            (source, defaultModel)
        }
    }

    private func send(response: HTTPResponse, through connection: NWConnection) {
        let reason = Self.reasonPhrase(for: response.statusCode)
        let header = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        let data = Data(header.utf8) + response.body
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func jsonResponse(statusCode: Int, body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "application/json", body: body)
    }

    private func eventStreamResponse(statusCode: Int, body: Data) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "text/event-stream", body: body)
    }

    private func errorPayload(type: String, message: String) -> Data {
        jsonData([
            "type": "error",
            "error": [
                "type": type,
                "message": message,
            ],
        ])
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 403:
            return "Forbidden"
        case 404:
            return "Not Found"
        case 429:
            return "Too Many Requests"
        case 502:
            return "Bad Gateway"
        default:
            return "Error"
        }
    }

    private static func errorType(for statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return "authentication_error"
        case 429:
            return "rate_limit_error"
        default:
            return "invalid_request_error"
        }
    }

    private static func extractUpstreamErrorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? L10n.tr("上游模型返回了未知错误。")
        }

        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? L10n.tr("上游模型返回了未知错误。")
    }

    private static func makeResponsesRequestData(from data: Data, fallbackModel: String) throws -> Data {
        try makeCodexResponsesBridgeRequestData(from: data, fallbackModel: fallbackModel)
    }

    private static func extractCompletedResponsesData(from data: Data) throws -> Data {
        try extractCodexResponsesBridgeCompletedData(from: data)
    }

    private static func makeAnthropicMessageResponseData(from data: Data, fallbackModel: String) throws -> Data {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse(L10n.tr("上游 Responses 返回了无效 JSON。"))
        }

        let model = trimmedString(body["model"]) ?? fallbackModel
        let output = body["output"] as? [Any] ?? []
        var content = [[String: Any]]()
        var hasToolUse = false

        for itemValue in output {
            guard let item = itemValue as? [String: Any], let type = trimmedString(item["type"]) else { continue }
            switch type {
            case "message":
                let contentItems = item["content"] as? [Any] ?? []
                for contentItemValue in contentItems {
                    guard let contentItem = contentItemValue as? [String: Any], let contentType = trimmedString(contentItem["type"]) else { continue }
                    switch contentType {
                    case "output_text", "input_text":
                        if let text = contentItem["text"] as? String {
                            content.append([
                                "type": "text",
                                "text": text,
                            ])
                        }
                    default:
                        continue
                    }
                }
            case "function_call":
                let name = trimmedString(item["name"]) ?? "tool"
                let callID = trimmedString(item["call_id"]) ?? UUID().uuidString
                let input = parsedJSONObject(fromJSONString: item["arguments"]) ?? [:]
                content.append([
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": input,
                ])
                hasToolUse = true
            case "custom_tool_call":
                let name = trimmedString(item["name"]) ?? "tool"
                let callID = trimmedString(item["call_id"]) ?? UUID().uuidString
                let input = parsedJSONObject(fromJSONString: item["input"]) ?? [:]
                content.append([
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": input,
                ])
                hasToolUse = true
            default:
                continue
            }
        }

        if content.isEmpty {
            content.append([
                "type": "text",
                "text": "",
            ])
        }

        let usage = body["usage"] as? [String: Any]
        let response: [String: Any] = [
            "id": trimmedString(body["id"]) ?? "msg_\(UUID().uuidString)",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": hasToolUse ? "tool_use" : "end_turn",
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": intValue(usage?["input_tokens"]) ?? 0,
                "output_tokens": intValue(usage?["output_tokens"]) ?? 0,
            ],
        ]

        return try JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func makeAnthropicMessageStreamData(from data: Data, fallbackModel: String) throws -> Data {
        let messageData = try makeAnthropicMessageResponseData(from: data, fallbackModel: fallbackModel)
        guard let message = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            throw TranslationError.invalidResponse(L10n.tr("Claude 桥接流式响应格式无效。"))
        }

        let usage = message["usage"] as? [String: Any] ?? [:]
        let stopReason = message["stop_reason"] ?? NSNull()
        let stopSequence = message["stop_sequence"] ?? NSNull()
        let content = message["content"] as? [[String: Any]] ?? []
        let messageID = trimmedString(message["id"]) ?? "msg_\(UUID().uuidString)"
        let model = trimmedString(message["model"]) ?? fallbackModel

        var events = [String]()
        events.append(
            sseEvent(
                name: "message_start",
                payload: [
                    "type": "message_start",
                    "message": [
                        "id": messageID,
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [],
                        "stop_reason": NSNull(),
                        "stop_sequence": NSNull(),
                        "usage": [
                            "input_tokens": intValue(usage["input_tokens"]) ?? 0,
                            "output_tokens": 0,
                        ],
                    ],
                ]
            )
        )

        for (index, block) in content.enumerated() {
            guard let type = trimmedString(block["type"]) else { continue }

            switch type {
            case "text":
                let text = block["text"] as? String ?? ""
                events.append(
                    sseEvent(
                        name: "content_block_start",
                        payload: [
                            "type": "content_block_start",
                            "index": index,
                            "content_block": [
                                "type": "text",
                                "text": "",
                            ],
                        ]
                    )
                )
                events.append(
                    sseEvent(
                        name: "content_block_delta",
                        payload: [
                            "type": "content_block_delta",
                            "index": index,
                            "delta": [
                                "type": "text_delta",
                                "text": text,
                            ],
                        ]
                    )
                )
                events.append(
                    sseEvent(
                        name: "content_block_stop",
                        payload: [
                            "type": "content_block_stop",
                            "index": index,
                        ]
                    )
                )
            case "tool_use":
                let toolID = trimmedString(block["id"]) ?? UUID().uuidString
                let name = trimmedString(block["name"]) ?? "tool"
                let partialJSON = jsonString(from: block["input"] ?? [:]) ?? "{}"
                events.append(
                    sseEvent(
                        name: "content_block_start",
                        payload: [
                            "type": "content_block_start",
                            "index": index,
                            "content_block": [
                                "type": "tool_use",
                                "id": toolID,
                                "name": name,
                                "input": [:],
                            ],
                        ]
                    )
                )
                events.append(
                    sseEvent(
                        name: "content_block_delta",
                        payload: [
                            "type": "content_block_delta",
                            "index": index,
                            "delta": [
                                "type": "input_json_delta",
                                "partial_json": partialJSON,
                            ],
                        ]
                    )
                )
                events.append(
                    sseEvent(
                        name: "content_block_stop",
                        payload: [
                            "type": "content_block_stop",
                            "index": index,
                        ]
                    )
                )
            default:
                continue
            }
        }

        events.append(
            sseEvent(
                name: "message_delta",
                payload: [
                    "type": "message_delta",
                    "delta": [
                        "stop_reason": stopReason,
                        "stop_sequence": stopSequence,
                    ],
                    "usage": [
                        "output_tokens": intValue(usage["output_tokens"]) ?? 0,
                    ],
                ]
            )
        )
        events.append(
            sseEvent(
                name: "message_stop",
                payload: [
                    "type": "message_stop",
                ]
            )
        )

        return Data(events.joined(separator: "\n\n").appending("\n\n").utf8)
    }

    fileprivate static func extractInstructions(from value: Any?) -> String {
        if let string = trimmedString(value) {
            return string
        }

        guard let items = value as? [Any] else {
            return ""
        }

        return items.compactMap { item in
            guard
                let object = item as? [String: Any],
                trimmedString(object["type"]) == "text",
                let text = object["text"] as? String,
                !text.isEmpty
            else {
                return nil
            }
            return text
        }
        .joined(separator: "\n\n")
    }

    fileprivate static func translateMessages(from value: Any?) throws -> [Any] {
        guard let messages = value as? [Any] else {
            return []
        }

        var items = [[String: Any]]()

        for messageValue in messages {
            guard let message = messageValue as? [String: Any] else { continue }
            let role = trimmedString(message["role"]) ?? "user"

            if let stringContent = message["content"] as? String {
                if !stringContent.isEmpty {
                    items.append([
                        "type": "message",
                        "role": role,
                        "content": [[
                            "type": role == "assistant" ? "output_text" : "input_text",
                            "text": stringContent,
                        ]],
                    ])
                }
                continue
            }

            guard let blocks = message["content"] as? [Any] else { continue }
            var pendingContent = [[String: Any]]()

            func flushPendingContent() {
                guard !pendingContent.isEmpty else { return }
                items.append([
                    "type": "message",
                    "role": role,
                    "content": pendingContent,
                ])
                pendingContent.removeAll(keepingCapacity: true)
            }

            for blockValue in blocks {
                guard let block = blockValue as? [String: Any], let type = trimmedString(block["type"]) else { continue }
                switch type {
                case "text":
                    if let text = block["text"] as? String {
                        pendingContent.append([
                            "type": role == "assistant" ? "output_text" : "input_text",
                            "text": text,
                        ])
                    }
                case "image":
                    if let imageContent = inputImageContent(from: block) {
                        pendingContent.append(imageContent)
                    }
                case "tool_use":
                    flushPendingContent()
                    items.append(try functionCallInput(from: block))
                case "tool_result":
                    flushPendingContent()
                    items.append(try functionCallOutputInput(from: block))
                default:
                    continue
                }
            }

            flushPendingContent()
        }

        return items
    }

    private static func functionCallInput(from block: [String: Any]) throws -> [String: Any] {
        guard let name = trimmedString(block["name"]), let callID = trimmedString(block["id"]) else {
            throw TranslationError.invalidRequest(L10n.tr("Claude tool_use 缺少 name 或 id。"))
        }

        let input = block["input"] ?? [:]
        let arguments = jsonString(from: input) ?? "{}"
        return [
            "type": "function_call",
            "name": name,
            "arguments": arguments,
            "call_id": callID,
        ]
    }

    private static func functionCallOutputInput(from block: [String: Any]) throws -> [String: Any] {
        guard let callID = trimmedString(block["tool_use_id"]) else {
            throw TranslationError.invalidRequest(L10n.tr("Claude tool_result 缺少 tool_use_id。"))
        }

        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": toolResultOutput(from: block["content"]),
        ]
    }

    private static func toolResultOutput(from value: Any?) -> Any {
        switch value {
        case let string as String:
            return string
        case let blocks as [Any]:
            let items = blocks.compactMap(toolResultContentItem(from:))
            if items.isEmpty {
                return jsonString(from: blocks) ?? ""
            }
            if items.count == 1, items[0]["type"] as? String == "input_text", let text = items[0]["text"] as? String {
                return text
            }
            return items
        case nil:
            return ""
        default:
            return jsonString(from: value) ?? ""
        }
    }

    private static func toolResultContentItem(from value: Any) -> [String: Any]? {
        guard let block = value as? [String: Any], let type = trimmedString(block["type"]) else {
            return nil
        }

        switch type {
        case "text":
            guard let text = block["text"] as? String else { return nil }
            return [
                "type": "input_text",
                "text": text,
            ]
        case "image":
            return inputImageContent(from: block)
        default:
            return nil
        }
    }

    private static func inputImageContent(from block: [String: Any]) -> [String: Any]? {
        if let imageURL = trimmedString(block["image_url"]) {
            return [
                "type": "input_image",
                "image_url": imageURL,
            ]
        }

        guard
            let source = block["source"] as? [String: Any],
            trimmedString(source["type"]) == "base64",
            let mediaType = trimmedString(source["media_type"] ?? source["mime_type"]),
            let data = trimmedString(source["data"])
        else {
            return nil
        }

        return [
            "type": "input_image",
            "image_url": "data:\(mediaType);base64,\(data)",
        ]
    }

    fileprivate static func translateTools(from value: Any?) -> [Any] {
        guard let tools = value as? [Any] else {
            return []
        }

        return tools.compactMap { toolValue in
            guard let tool = toolValue as? [String: Any], let name = trimmedString(tool["name"]) else {
                return nil
            }

            var converted: [String: Any] = [
                "type": "function",
                "name": name,
            ]
            if let description = trimmedString(tool["description"]) {
                converted["description"] = description
            }
            if let schema = tool["input_schema"] {
                converted["parameters"] = schema
            }
            return converted
        }
    }

    fileprivate static func translateToolChoice(from value: Any?) -> Any {
        guard let toolChoice = value as? [String: Any], let type = trimmedString(toolChoice["type"]) else {
            return "auto"
        }

        switch type {
        case "tool":
            if let name = trimmedString(toolChoice["name"]) {
                return [
                    "type": "function",
                    "name": name,
                ]
            }
            return "auto"
        case "any":
            return "required"
        default:
            return "auto"
        }
    }

    private static func parsedJSONObject(fromJSONString value: Any?) -> Any? {
        guard let string = value as? String, let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func jsonString(from value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else {
            return value as? String
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func requestWantsStreaming(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stream = object["stream"] as? Bool
        else {
            return false
        }
        return stream
    }

    private static func sseEvent(name: String, payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "event: \(name)\ndata: \(data)"
    }

    fileprivate static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
