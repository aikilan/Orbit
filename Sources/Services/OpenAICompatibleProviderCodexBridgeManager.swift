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
    private let debugStore: ProviderBridgeDebugStore?
    private var servers: [String: OpenAICompatibleProviderCodexBridgeServer] = [:]

    init(debugStore: ProviderBridgeDebugStore? = nil) {
        self.sendUpstreamRequest = Self.sendUpstreamRequest
        self.debugStore = debugStore
    }

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, Data) async throws -> (Int, Data),
        debugStore: ProviderBridgeDebugStore? = nil
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
        self.debugStore = debugStore
    }

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings] = []
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedAPIKey.isEmpty, !trimmedModel.isEmpty else {
            throw OpenAICompatibleProviderCodexBridgeManagerError.invalidProvider
        }

        let server = servers[accountID.uuidString]
            ?? OpenAICompatibleProviderCodexBridgeServer(sendUpstreamRequest: sendUpstreamRequest, debugStore: debugStore)
        server.update(
            baseURL: trimmedBaseURL,
            apiKeyEnvName: apiKeyEnvName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            model: trimmedModel,
            availableModels: availableModels,
            modelSettings: modelSettings
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

    private struct State {
        let baseURL: String
        let bridgeBaseURL: String
        let apiKeyEnvName: String
        let apiKey: String
        let defaultModel: String
        let availableModels: [String]
        let modelSettings: [ProviderModelSettings]
    }

    private let queue = DispatchQueue(label: "com.openai.Orbit.openai-compatible-provider-bridge")
    private let stateQueue = DispatchQueue(label: "com.openai.Orbit.openai-compatible-provider-bridge.state")
    private let sendUpstreamRequest: @Sendable (String, String, Data) async throws -> (Int, Data)
    private let debugStore: ProviderBridgeDebugStore?
    private let overloadRetryDelaysNanos: [UInt64] = [200_000_000, 500_000_000]

    private var listener: NWListener?
    private var localBaseURL: String?
    private var upstreamBaseURL = ""
    private var apiKeyEnvName = "OPENAI_API_KEY"
    private var apiKey = ""
    private var defaultModel = "gpt-5.4"
    private var availableModels = ["gpt-5.4"]
    private var modelSettings = [ProviderModelSettings(model: "gpt-5.4")]

    init(
        sendUpstreamRequest: @escaping @Sendable (String, String, Data) async throws -> (Int, Data),
        debugStore: ProviderBridgeDebugStore?
    ) {
        self.sendUpstreamRequest = sendUpstreamRequest
        self.debugStore = debugStore
    }

    func update(
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String],
        modelSettings: [ProviderModelSettings]
    ) {
        stateQueue.sync {
            self.upstreamBaseURL = baseURL
            self.apiKeyEnvName = apiKeyEnvName.isEmpty ? "OPENAI_API_KEY" : apiKeyEnvName
            self.apiKey = apiKey
            self.defaultModel = model
            self.availableModels = normalizedAvailableModels(availableModels, fallbackModel: model)
            self.modelSettings = ProviderModelSettings.normalized(modelSettings, fallbackModel: model)
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
            let resumeQueue = DispatchQueue(label: "com.openai.Orbit.openai-compatible-provider-bridge.resume")

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
        let requestID = UUID()
        var didStartDebugRequest = false

        do {
            let state = currentState()
            var requestObject = try requestJSONObject(from: request.body)
            let wantsStream = (requestObject["stream"] as? Bool) ?? false
            let requestedModel = trimmedString(requestObject["model"])
            let effectiveModel = resolvedProviderModel(requestedModel, state: state)
            requestObject["model"] = effectiveModel
            let usesMiniMaxReasoning = isMiniMaxAPIHost(state.baseURL)
            let usesMiMoCompatibility = isMiMoAPIHost(state.baseURL)
            let usesReasoningContent = isDeepSeekAPIHost(state.baseURL) || usesMiMoCompatibility
            let hasMedia = ResponsesChatCompletionsBridge.containsSupportedMedia(in: requestObject)
            let multimodalModel = ProviderModelSettings.parameters(
                for: effectiveModel,
                in: state.modelSettings,
                fallbackModel: state.defaultModel
            )?.normalizedMultimodalModel
            let upstreamRequest: Data

            await recordDebugRequestStarted(
                id: requestID,
                state: state,
                path: request.path,
                model: effectiveModel,
                stream: wantsStream,
                hasMedia: hasMedia,
                multimodalModel: multimodalModel,
                payloadPreview: Self.payloadPreview(from: request.body)
            )
            didStartDebugRequest = true
            await appendDebugEvent(
                requestID: requestID,
                title: L10n.tr("Bridge 分析"),
                detail: debugAnalysisDetail(hasMedia: hasMedia, multimodalModel: multimodalModel),
                payloadPreview: nil
            )
            if let requestedModel, requestedModel != effectiveModel {
                await appendDebugEvent(
                    requestID: requestID,
                    title: L10n.tr("模型归一化"),
                    detail: "\(requestedModel) -> \(effectiveModel)",
                    payloadPreview: nil
                )
            }

            // 有附件且配置了关联模型时，先把附件解析成文本，再交给主模型执行工具调用。
            if let multimodalModel, hasMedia {
                let prepassRequest = try ResponsesChatCompletionsBridge.makeMultimodalPrepassRequestData(
                    from: requestObject,
                    multimodalModel: multimodalModel,
                    fallbackModel: multimodalModel,
                    requiresNonEmptyToolParameters: usesMiniMaxReasoning,
                    usesMaxCompletionTokens: usesMiMoCompatibility,
                    supportsParallelToolCalls: !usesMiMoCompatibility,
                    usesMiniMaxReasoning: usesMiniMaxReasoning,
                    usesDeepSeekReasoning: usesReasoningContent
                )
                let parameterizedPrepassRequest = try ProviderModelSettings.applyParameters(
                    toJSONData: prepassRequest,
                    requestedModel: multimodalModel,
                    settings: state.modelSettings,
                    fallbackModel: state.defaultModel
                )
                await appendDebugEvent(
                    requestID: requestID,
                    title: L10n.tr("多模态预处理请求"),
                    detail: "model=\(multimodalModel)",
                    payloadPreview: Self.payloadPreview(from: parameterizedPrepassRequest)
                )
                let (prepassStatusCode, prepassData) = try await sendUpstreamRequestHandlingOverload(
                    baseURL: state.baseURL,
                    apiKey: state.apiKey,
                    body: parameterizedPrepassRequest
                )
                await appendDebugEvent(
                    requestID: requestID,
                    title: L10n.tr("多模态预处理响应"),
                    detail: "HTTP \(prepassStatusCode)",
                    payloadPreview: Self.payloadPreview(from: prepassData)
                )

                guard (200..<300).contains(prepassStatusCode) else {
                    let message = ResponsesChatCompletionsBridge.extractErrorMessage(from: prepassData)
                    await recordDebugRequestFinished(
                        id: requestID,
                        status: .failed,
                        httpStatus: prepassStatusCode,
                        errorMessage: message
                    )
                    return jsonResponse(statusCode: prepassStatusCode, body: errorPayload(message: message))
                }
                guard let attachmentSummary = ResponsesChatCompletionsBridge.extractAssistantText(from: prepassData) else {
                    throw ResponsesChatCompletionsBridge.TranslationError.invalidResponse(L10n.tr("多模态模型未返回可转交给主模型的文本摘要。"))
                }
                await appendDebugEvent(
                    requestID: requestID,
                    title: L10n.tr("多模态摘要"),
                    detail: L10n.tr("%d 字符", attachmentSummary.count),
                    payloadPreview: attachmentSummary
                )

                upstreamRequest = try ResponsesChatCompletionsBridge.makeTextOnlyRequestData(
                    from: requestObject,
                    attachmentSummary: attachmentSummary,
                    fallbackModel: state.defaultModel,
                    requiresNonEmptyToolParameters: usesMiniMaxReasoning,
                    usesMaxCompletionTokens: usesMiMoCompatibility,
                    supportsParallelToolCalls: !usesMiMoCompatibility,
                    usesMiniMaxReasoning: usesMiniMaxReasoning,
                    usesDeepSeekReasoning: usesReasoningContent
                )
            } else {
                upstreamRequest = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
                    from: requestObject,
                    fallbackModel: state.defaultModel,
                    requiresNonEmptyToolParameters: usesMiniMaxReasoning,
                    usesMaxCompletionTokens: usesMiMoCompatibility,
                    supportsParallelToolCalls: !usesMiMoCompatibility,
                    usesMiniMaxReasoning: usesMiniMaxReasoning,
                    usesDeepSeekReasoning: usesReasoningContent
                )
            }
            let parameterizedUpstreamRequest = try ProviderModelSettings.applyParameters(
                toJSONData: upstreamRequest,
                requestedModel: effectiveModel,
                settings: state.modelSettings,
                fallbackModel: state.defaultModel
            )
            await appendDebugEvent(
                requestID: requestID,
                title: L10n.tr("主模型请求"),
                detail: hasMedia && multimodalModel != nil ? "model=\(effectiveModel) text-only" : "model=\(effectiveModel)",
                payloadPreview: Self.payloadPreview(from: parameterizedUpstreamRequest)
            )
            let (statusCode, data) = try await sendUpstreamRequestHandlingOverload(
                baseURL: state.baseURL,
                apiKey: state.apiKey,
                body: parameterizedUpstreamRequest
            )
            await appendDebugEvent(
                requestID: requestID,
                title: L10n.tr("主模型响应"),
                detail: "HTTP \(statusCode)",
                payloadPreview: Self.payloadPreview(from: data)
            )

            guard (200..<300).contains(statusCode) else {
                let message = ResponsesChatCompletionsBridge.extractErrorMessage(from: data)
                await recordDebugRequestFinished(
                    id: requestID,
                    status: .failed,
                    httpStatus: statusCode,
                    errorMessage: message
                )
                return jsonResponse(statusCode: statusCode, body: errorPayload(message: message))
            }

            let responseData = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
                from: data,
                fallbackModel: state.defaultModel,
                usesMiniMaxReasoning: usesMiniMaxReasoning,
                usesDeepSeekReasoning: usesReasoningContent
            )
            guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw ResponsesChatCompletionsBridge.TranslationError.invalidResponse(L10n.tr("本地桥接响应格式无效。"))
            }

            await recordDebugRequestFinished(id: requestID, status: .completed, httpStatus: 200, errorMessage: nil)
            if wantsStream {
                return HTTPResponse(
                    statusCode: 200,
                    contentType: "text/event-stream",
                    body: ResponsesChatCompletionsBridge.makeResponseStreamData(from: responseObject)
                )
            }

            return jsonResponse(statusCode: 200, body: responseData)
        } catch {
            if didStartDebugRequest {
                await recordDebugRequestFinished(
                    id: requestID,
                    status: .failed,
                    httpStatus: 502,
                    errorMessage: error.localizedDescription
                )
            }
            return jsonResponse(statusCode: 502, body: errorPayload(message: error.localizedDescription))
        }
    }

    private func requestJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICompatibleProviderCodexBridgeManagerError.invalidProvider
        }
        return object
    }

    private func currentState() -> State {
        stateQueue.sync {
            State(
                baseURL: upstreamBaseURL,
                bridgeBaseURL: localBaseURL ?? "",
                apiKeyEnvName: apiKeyEnvName,
                apiKey: apiKey,
                defaultModel: defaultModel,
                availableModels: availableModels,
                modelSettings: modelSettings
            )
        }
    }

    private func recordDebugRequestStarted(
        id: UUID,
        state: State,
        path: String,
        model: String,
        stream: Bool,
        hasMedia: Bool,
        multimodalModel: String?,
        payloadPreview: String?
    ) async {
        guard let debugStore else { return }
        await MainActor.run {
            debugStore.recordRequestStarted(
                id: id,
                bridgeBaseURL: state.bridgeBaseURL,
                upstreamBaseURL: state.baseURL,
                path: path,
                model: model,
                stream: stream,
                hasMedia: hasMedia,
                multimodalModel: multimodalModel,
                payloadPreview: payloadPreview
            )
        }
    }

    private func recordDebugRequestFinished(
        id: UUID,
        status: ProviderBridgeDebugRequestStatus,
        httpStatus: Int?,
        errorMessage: String?
    ) async {
        guard let debugStore else { return }
        await MainActor.run {
            debugStore.recordRequestFinished(
                id: id,
                status: status,
                httpStatus: httpStatus,
                errorMessage: errorMessage
            )
        }
    }

    private func appendDebugEvent(
        requestID: UUID,
        title: String,
        detail: String,
        payloadPreview: String?
    ) async {
        guard let debugStore else { return }
        await MainActor.run {
            debugStore.appendEvent(
                requestID: requestID,
                title: title,
                detail: detail,
                payloadPreview: payloadPreview
            )
        }
    }

    private func sendUpstreamRequestHandlingOverload(
        baseURL: String,
        apiKey: String,
        body: Data
    ) async throws -> (Int, Data) {
        var response = try await sendUpstreamRequest(baseURL, apiKey, body)
        for delay in overloadRetryDelaysNanos where response.0 == 529 {
            try await Task.sleep(nanoseconds: delay)
            response = try await sendUpstreamRequest(baseURL, apiKey, body)
        }
        return response.0 == 529 ? (429, response.1) : response
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

    private func debugAnalysisDetail(hasMedia: Bool, multimodalModel: String?) -> String {
        let mediaText = hasMedia ? L10n.tr("已检测媒体") : L10n.tr("未检测媒体")
        let multimodalText = multimodalModel.map { L10n.tr("关联多模态模型：%@", $0) } ?? L10n.tr("未配置关联多模态模型")
        return "\(mediaText), \(multimodalText)"
    }

    private func resolvedProviderModel(_ requestedModel: String?, state: State) -> String {
        let trimmedRequestedModel = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedRequestedModel.isEmpty else {
            return state.defaultModel
        }

        var knownModels = Set(state.availableModels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for setting in state.modelSettings {
            knownModels.insert(setting.model.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        knownModels.remove("")

        // Provider bridge 是协议边界，不能把 Codex 内置 gpt-* 模型名透传给自定义上游。
        return knownModels.contains(trimmedRequestedModel) ? trimmedRequestedModel : state.defaultModel
    }

    private static func payloadPreview(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let redactedObject = redactedPayload(object, key: nil)
            if JSONSerialization.isValidJSONObject(redactedObject),
               let previewData = try? JSONSerialization.data(withJSONObject: redactedObject, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: previewData, encoding: .utf8)
            {
                return truncatedPayloadPreview(text)
            }
        }

        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return truncatedPayloadPreview(text)
    }

    private static func redactedPayload(_ value: Any, key: String?) -> Any {
        if let dictionary = value as? [String: Any] {
            var redacted = [String: Any]()
            for (childKey, childValue) in dictionary {
                redacted[childKey] = redactedPayload(childValue, key: childKey)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redactedPayload($0, key: key) }
        }
        if let string = value as? String {
            return redactedString(string, key: key)
        }
        return value
    }

    // 调试预览保留媒体类型和长度，隐藏 base64 正文，避免大附件撑爆时间线。
    private static func redactedString(_ string: String, key: String?) -> String {
        if string.hasPrefix("data:") {
            return redactedDataURL(string)
        }

        switch key?.lowercased() {
        case "file_data", "data":
            return "<redacted \(string.count) chars>"
        default:
            return string
        }
    }

    private static func redactedDataURL(_ string: String) -> String {
        guard let commaIndex = string.firstIndex(of: ",") else {
            return "<redacted data URL \(string.count) chars>"
        }
        let header = string[..<commaIndex]
        let payloadStart = string.index(after: commaIndex)
        let payloadLength = string.distance(from: payloadStart, to: string.endIndex)
        return "\(header),<redacted \(payloadLength) chars>"
    }

    private static func truncatedPayloadPreview(_ text: String) -> String {
        if text.count <= ProviderBridgeDebugStore.payloadPreviewLimit {
            return text
        }
        return String(text.prefix(ProviderBridgeDebugStore.payloadPreviewLimit)) + "\n... truncated ..."
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

    private func isDeepSeekAPIHost(_ baseURL: String) -> Bool {
        let trimmedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBaseURL.isEmpty else {
            return false
        }

        let rawURL = URL(string: trimmedBaseURL)
            ?? URL(string: "https://\(trimmedBaseURL)")
        return rawURL?.host?.lowercased() == "api.deepseek.com"
    }

    private func trimmedString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
