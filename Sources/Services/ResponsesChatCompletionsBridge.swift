import Foundation

enum ResponsesChatCompletionsBridge {
    private enum MediaKind {
        case image
        case audio
        case video
    }

    private struct TextToolCall {
        let name: String
        let arguments: String
    }

    enum TranslationError: LocalizedError {
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

    static func makeChatCompletionsRequestData(
        from data: Data,
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool = false,
        usesMaxCompletionTokens: Bool = false,
        supportsParallelToolCalls: Bool = true,
        usesMiniMaxReasoning: Bool = false,
        usesDeepSeekReasoning: Bool = false
    ) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidRequest(L10n.tr("Responses 请求不是有效的 JSON。"))
        }

        return try makeChatCompletionsRequestData(
            from: request,
            fallbackModel: fallbackModel,
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters,
            usesMaxCompletionTokens: usesMaxCompletionTokens,
            supportsParallelToolCalls: supportsParallelToolCalls,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
    }

    static func makeChatCompletionsRequestData(
        from request: [String: Any],
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool = false,
        usesMaxCompletionTokens: Bool = false,
        supportsParallelToolCalls: Bool = true,
        usesMiniMaxReasoning: Bool = false,
        usesDeepSeekReasoning: Bool = false
    ) throws -> Data {
        let object = try makeChatCompletionsRequestObject(
            from: request,
            fallbackModel: fallbackModel,
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters,
            usesMaxCompletionTokens: usesMaxCompletionTokens,
            supportsParallelToolCalls: supportsParallelToolCalls,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponsesResponseData(
        from data: Data,
        fallbackModel: String,
        usesMiniMaxReasoning: Bool = false,
        usesDeepSeekReasoning: Bool = false
    ) throws -> Data {
        let object = try makeResponsesResponseObject(
            from: data,
            fallbackModel: fallbackModel,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponseStreamData(from response: [String: Any]) -> Data {
        let responseID = trimmedString(response["id"]) ?? UUID().uuidString
        let model = trimmedString(response["model"]) ?? ""
        let usage = response["usage"] as? [String: Any] ?? [:]
        let outputItems = (response["output"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        var events = [String]()

        appendStreamEvent(
            named: "response.created",
            payload: [
                "type": "response.created",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "model": model,
                    "status": "in_progress",
                    "output": [],
                ],
            ],
            to: &events
        )

        for (outputIndex, item) in outputItems.enumerated() {
            let itemType = trimmedString(item["type"]) ?? "message"
            switch itemType {
            case "reasoning":
                let itemID = trimmedString(item["id"]) ?? "rs_\(UUID().uuidString)"
                let summaryItems = (item["summary"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "reasoning",
                            "status": "in_progress",
                            "summary": [],
                            "content": NSNull(),
                        ],
                    ],
                    to: &events
                )

                var completedSummary = [[String: Any]]()
                for (summaryIndex, summaryItem) in summaryItems.enumerated() {
                    let summaryType = trimmedString(summaryItem["type"]) ?? "summary_text"
                    guard summaryType == "summary_text" else { continue }
                    let text = summaryItem["text"] as? String ?? ""
                    let addedPart: [String: Any] = [
                        "type": "summary_text",
                        "text": "",
                    ]
                    let completedPart: [String: Any] = [
                        "type": "summary_text",
                        "text": text,
                    ]

                    appendStreamEvent(
                        named: "response.reasoning_summary_part.added",
                        payload: [
                            "type": "response.reasoning_summary_part.added",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "part": addedPart,
                        ],
                        to: &events
                    )
                    if !text.isEmpty {
                        appendStreamEvent(
                            named: "response.reasoning_summary_text.delta",
                            payload: [
                                "type": "response.reasoning_summary_text.delta",
                                "response_id": responseID,
                                "output_index": outputIndex,
                                "item_id": itemID,
                                "summary_index": summaryIndex,
                                "delta": text,
                            ],
                            to: &events
                        )
                    }
                    appendStreamEvent(
                        named: "response.reasoning_summary_text.done",
                        payload: [
                            "type": "response.reasoning_summary_text.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "text": text,
                        ],
                        to: &events
                    )
                    appendStreamEvent(
                        named: "response.reasoning_summary_part.done",
                        payload: [
                            "type": "response.reasoning_summary_part.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "summary_index": summaryIndex,
                            "part": completedPart,
                        ],
                        to: &events
                    )
                    completedSummary.append(completedPart)
                }

                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "reasoning",
                            "status": "completed",
                            "summary": completedSummary,
                            "content": NSNull(),
                        ],
                    ],
                    to: &events
                )
            case "message":
                let itemID = trimmedString(item["id"]) ?? "msg_\(UUID().uuidString)"
                let role = normalizedRole(from: item["role"])
                let contentItems = (item["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "message",
                            "status": "in_progress",
                            "role": role,
                            "content": [],
                        ],
                    ],
                    to: &events
                )

                var completedContent = [[String: Any]]()
                for (contentIndex, contentItem) in contentItems.enumerated() {
                    let contentType = trimmedString(contentItem["type"]) ?? "output_text"
                    guard contentType == "output_text" || contentType == "text" else { continue }
                    let text = contentItem["text"] as? String ?? ""
                    let addedPart: [String: Any] = [
                        "type": "output_text",
                        "text": "",
                    ]
                    let completedPart: [String: Any] = [
                        "type": "output_text",
                        "text": text,
                    ]

                    appendStreamEvent(
                        named: "response.content_part.added",
                        payload: [
                            "type": "response.content_part.added",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "part": addedPart,
                        ],
                        to: &events
                    )
                    if !text.isEmpty {
                        appendStreamEvent(
                            named: "response.output_text.delta",
                            payload: [
                                "type": "response.output_text.delta",
                                "response_id": responseID,
                                "output_index": outputIndex,
                                "item_id": itemID,
                                "content_index": contentIndex,
                                "delta": text,
                            ],
                            to: &events
                        )
                    }
                    appendStreamEvent(
                        named: "response.output_text.done",
                        payload: [
                            "type": "response.output_text.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "text": text,
                        ],
                        to: &events
                    )
                    appendStreamEvent(
                        named: "response.content_part.done",
                        payload: [
                            "type": "response.content_part.done",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "content_index": contentIndex,
                            "part": completedPart,
                        ],
                        to: &events
                    )
                    completedContent.append(completedPart)
                }

                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "message",
                            "status": "completed",
                            "role": role,
                            "content": completedContent,
                        ],
                    ],
                    to: &events
                )
            case "function_call":
                let itemID = trimmedString(item["id"]) ?? "fc_\(UUID().uuidString)"
                let callID = trimmedString(item["call_id"]) ?? itemID
                let name = trimmedString(item["name"]) ?? "tool"
                let arguments = trimmedString(item["arguments"]) ?? "{}"

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call",
                            "status": "in_progress",
                            "call_id": callID,
                            "name": name,
                            "arguments": "",
                        ],
                    ],
                    to: &events
                )
                if !arguments.isEmpty {
                    appendStreamEvent(
                        named: "response.function_call_arguments.delta",
                        payload: [
                            "type": "response.function_call_arguments.delta",
                            "response_id": responseID,
                            "output_index": outputIndex,
                            "item_id": itemID,
                            "delta": arguments,
                        ],
                        to: &events
                    )
                }
                appendStreamEvent(
                    named: "response.function_call_arguments.done",
                    payload: [
                        "type": "response.function_call_arguments.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item_id": itemID,
                        "arguments": arguments,
                    ],
                    to: &events
                )
                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call",
                            "status": "completed",
                            "call_id": callID,
                            "name": name,
                            "arguments": arguments,
                        ],
                    ],
                    to: &events
                )
            case "function_call_output":
                let itemID = trimmedString(item["id"]) ?? "fco_\(UUID().uuidString)"
                let callID = trimmedString(item["call_id"]) ?? itemID
                let output = item["output"] ?? ""

                appendStreamEvent(
                    named: "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call_output",
                            "status": "in_progress",
                            "call_id": callID,
                            "output": "",
                        ],
                    ],
                    to: &events
                )
                appendStreamEvent(
                    named: "response.output_item.done",
                    payload: [
                        "type": "response.output_item.done",
                        "response_id": responseID,
                        "output_index": outputIndex,
                        "item": [
                            "id": itemID,
                            "type": "function_call_output",
                            "status": "completed",
                            "call_id": callID,
                            "output": output,
                        ],
                    ],
                    to: &events
                )
            default:
                continue
            }
        }

        appendStreamEvent(
            named: "response.completed",
            payload: [
                "type": "response.completed",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "model": model,
                    "output": outputItems,
                    "usage": usage,
                ],
            ],
            to: &events
        )

        events.append("data: [DONE]\n\n")
        return Data(events.joined().utf8)
    }

    static func makeStreamEventData(named eventName: String, payload: [String: Any]) -> Data {
        Data(streamEventString(named: eventName, payload: payload).utf8)
    }

    static func makeStreamDoneData() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    static func extractErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? L10n.tr("上游模型返回了未知错误。")
        }

        if let error = object["error"] as? [String: Any], let message = trimmedString(error["message"]) {
            return message
        }
        if let message = trimmedString(object["message"]) {
            return message
        }
        if let detail = trimmedString(object["detail"]) {
            return detail
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? L10n.tr("上游模型返回了未知错误。")
    }

    static func containsSupportedMedia(in request: [String: Any]) -> Bool {
        inputContainsSupportedMedia(request["input"])
    }

    static func makeMultimodalPrepassRequestData(
        from request: [String: Any],
        multimodalModel: String,
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool = false,
        usesMaxCompletionTokens: Bool = false,
        supportsParallelToolCalls: Bool = true,
        usesMiniMaxReasoning: Bool = false,
        usesDeepSeekReasoning: Bool = false
    ) throws -> Data {
        var prepassRequest = request
        prepassRequest["model"] = multimodalModel
        prepassRequest["instructions"] = multimodalPrepassInstructions
        prepassRequest["stream"] = false
        prepassRequest.removeValue(forKey: "tools")
        prepassRequest.removeValue(forKey: "tool_choice")
        prepassRequest.removeValue(forKey: "parallel_tool_calls")

        return try makeChatCompletionsRequestData(
            from: prepassRequest,
            fallbackModel: fallbackModel,
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters,
            usesMaxCompletionTokens: usesMaxCompletionTokens,
            supportsParallelToolCalls: supportsParallelToolCalls,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
    }

    static func makeTextOnlyRequestData(
        from request: [String: Any],
        attachmentSummary: String,
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool = false,
        usesMaxCompletionTokens: Bool = false,
        supportsParallelToolCalls: Bool = true,
        usesMiniMaxReasoning: Bool = false,
        usesDeepSeekReasoning: Bool = false
    ) throws -> Data {
        var textOnlyRequest = request
        textOnlyRequest["input"] = textOnlyInput(from: request["input"], attachmentSummary: attachmentSummary)
        return try makeChatCompletionsRequestData(
            from: textOnlyRequest,
            fallbackModel: fallbackModel,
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters,
            usesMaxCompletionTokens: usesMaxCompletionTokens,
            supportsParallelToolCalls: supportsParallelToolCalls,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
    }

    static func extractAssistantText(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [Any]
        else {
            return nil
        }

        for choiceValue in choices {
            guard
                let choice = choiceValue as? [String: Any],
                let message = choice["message"] as? [String: Any],
                let text = assistantContentText(from: message["content"])
            else {
                continue
            }
            return text
        }
        return nil
    }

    private static var multimodalPrepassInstructions: String {
        L10n.tr(
            "你是多模态附件解析模型。请只基于用户提供的图片、音频或视频附件和用户文本，输出供后续文本代码模型使用的事实摘要。保留与任务相关的文字、数字、界面、文件、错误和约束；不要调用工具，不要编写代码；不确定的内容标注“不确定”。"
        )
    }

    private static func inputContainsSupportedMedia(_ input: Any?) -> Bool {
        if let item = input as? [String: Any] {
            return messageContainsSupportedMedia(item)
        }
        guard let items = input as? [Any] else {
            return false
        }
        return items.contains { itemValue in
            guard let item = itemValue as? [String: Any] else { return false }
            return messageContainsSupportedMedia(item)
        }
    }

    private static func messageContainsSupportedMedia(_ item: [String: Any]) -> Bool {
        guard
            normalizedInputItemType(from: item) == "message",
            let content = item["content"] as? [Any]
        else {
            return false
        }
        return content.contains { contentValue in
            guard let contentItem = contentValue as? [String: Any] else {
                return false
            }
            return isSupportedMediaContentItem(contentItem)
        }
    }

    private static func textOnlyInput(from input: Any?, attachmentSummary: String) -> Any {
        if var item = input as? [String: Any] {
            if normalizedInputItemType(from: item) == "message" {
                item["content"] = textOnlyContent(from: item["content"])
            }
            return [item, attachmentSummaryMessage(attachmentSummary)]
        }
        guard let items = input as? [Any] else {
            return input ?? [attachmentSummaryMessage(attachmentSummary)]
        }

        var textOnlyItems = items.map { itemValue -> Any in
            guard var item = itemValue as? [String: Any] else {
                return itemValue
            }
            guard normalizedInputItemType(from: item) == "message" else {
                return item
            }
            item["content"] = textOnlyContent(from: item["content"])
            return item
        }
        textOnlyItems.append(attachmentSummaryMessage(attachmentSummary))
        return textOnlyItems
    }

    private static func textOnlyContent(from content: Any?) -> Any {
        if let text = content as? String {
            return text
        }
        guard let contentItems = content as? [Any] else {
            return ""
        }
        return contentItems.compactMap { contentValue -> Any? in
            guard let contentItem = contentValue as? [String: Any] else {
                return contentValue
            }
            return isSupportedMediaContentItem(contentItem) ? nil : contentItem
        }
    }

    // 主模型只接收文本摘要，避免 text-only 模型再次收到媒体 part。
    private static func attachmentSummaryMessage(_ summary: String) -> [String: Any] {
        [
            "type": "message",
            "role": "user",
            "content": [
                [
                    "type": "input_text",
                    "text": L10n.tr("以下是多模态模型对用户附件的解析结果：\n\n%@", summary),
                ],
            ],
        ]
    }

    private static func assistantContentText(from content: Any?) -> String? {
        if let text = trimmedString(content) {
            return text
        }
        guard let contentItems = content as? [Any] else {
            return nil
        }
        let textParts = contentItems.compactMap { contentValue -> String? in
            guard
                let contentItem = contentValue as? [String: Any],
                let type = trimmedString(contentItem["type"]),
                type == "text" || type == "output_text"
            else {
                return nil
            }
            return trimmedString(contentItem["text"])
        }
        let joined = textParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isSupportedMediaContentItem(_ item: [String: Any]) -> Bool {
        guard let type = trimmedString(item["type"]) else {
            return false
        }
        switch type {
        case "input_image", "image_url", "input_audio", "video_url":
            return true
        case "input_file":
            return fileDataMediaPart(from: item) != nil
        default:
            return false
        }
    }

    private static func makeChatCompletionsRequestObject(
        from request: [String: Any],
        fallbackModel: String,
        requiresNonEmptyToolParameters: Bool,
        usesMaxCompletionTokens: Bool,
        supportsParallelToolCalls: Bool,
        usesMiniMaxReasoning: Bool,
        usesDeepSeekReasoning: Bool
    ) throws -> [String: Any] {
        let model = trimmedString(request["model"]) ?? fallbackModel
        let instructions = trimmedString(request["instructions"])
        let messages = try translateMessages(
            from: request["input"],
            instructions: instructions,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
        let tools = translateTools(
            from: request["tools"],
            requiresNonEmptyToolParameters: requiresNonEmptyToolParameters
        )
        let toolChoice = translateToolChoice(from: request["tool_choice"])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let toolChoice {
            body["tool_choice"] = toolChoice
        }
        if let maxTokens = intValue(request["max_output_tokens"] ?? request["max_tokens"]) {
            body[usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }
        if supportsParallelToolCalls, let parallelToolCalls = request["parallel_tool_calls"] as? Bool {
            body["parallel_tool_calls"] = usesMiniMaxReasoning ? false : parallelToolCalls
        }
        if let temperature = doubleValue(request["temperature"]) {
            body["temperature"] = temperature
        }
        if let topP = doubleValue(request["top_p"]) {
            body["top_p"] = topP
        }
        if usesMiniMaxReasoning {
            body["reasoning_split"] = true
        }
        return body
    }

    private static func translateMessages(
        from input: Any?,
        instructions: String?,
        usesMiniMaxReasoning: Bool,
        usesDeepSeekReasoning: Bool
    ) throws -> [[String: Any]] {
        var messages = [[String: Any]]()
        if let instructions, !instructions.isEmpty {
            messages.append([
                "role": "system",
                "content": instructions,
            ])
        }

        if let text = input as? String, !text.isEmpty {
            messages.append([
                "role": "user",
                "content": text,
            ])
            return messages
        }

        guard let items = input as? [Any] else {
            return messages
        }

        var lastAssistantIndex: Int?
        var pendingReasoningDetails = [[String: Any]]()
        var pendingReasoningContents = [String]()

        for itemValue in items {
            guard
                let item = itemValue as? [String: Any],
                let type = normalizedInputItemType(from: item)
            else {
                continue
            }

            switch type {
            case "reasoning":
                if usesMiniMaxReasoning {
                    let reasoningDetails = reasoningDetails(from: item)
                    if !reasoningDetails.isEmpty {
                        if let index = lastAssistantIndex {
                            var message = messages[index]
                            mergeReasoningDetails(reasoningDetails, into: &message)
                            messages[index] = message
                        } else {
                            pendingReasoningDetails.append(contentsOf: reasoningDetails)
                        }
                    }
                }
                if usesDeepSeekReasoning {
                    let reasoningContents = reasoningHistoryTexts(from: item)
                    if !reasoningContents.isEmpty {
                        if let index = lastAssistantIndex {
                            var message = messages[index]
                            mergeReasoningContent(reasoningContents, into: &message)
                            messages[index] = message
                        } else {
                            pendingReasoningContents.append(contentsOf: reasoningContents)
                        }
                    }
                }
            case "message":
                let role = normalizedRole(from: item["role"])
                var message: [String: Any] = ["role": role]
                if let content = translateMessageContent(from: item["content"], role: role) {
                    message["content"] = content
                } else if role == "assistant" {
                    message["content"] = NSNull()
                } else {
                    message["content"] = ""
                }
                if usesDeepSeekReasoning, role == "assistant", let reasoningContent = trimmedString(item["reasoning_content"]) {
                    mergeReasoningContent([reasoningContent], into: &message)
                }
                if usesMiniMaxReasoning, role == "assistant", !pendingReasoningDetails.isEmpty {
                    mergeReasoningDetails(pendingReasoningDetails, into: &message)
                    pendingReasoningDetails.removeAll()
                }
                if usesDeepSeekReasoning, role == "assistant", !pendingReasoningContents.isEmpty {
                    mergeReasoningContent(pendingReasoningContents, into: &message)
                    pendingReasoningContents.removeAll()
                }
                messages.append(message)
                lastAssistantIndex = role == "assistant" ? messages.index(before: messages.endIndex) : nil
            case "function_call", "custom_tool_call":
                let toolCall = makeToolCall(from: item, type: type)
                if let index = lastAssistantIndex {
                    var message = messages[index]
                    if usesMiniMaxReasoning, !pendingReasoningDetails.isEmpty {
                        mergeReasoningDetails(pendingReasoningDetails, into: &message)
                        pendingReasoningDetails.removeAll()
                    }
                    if usesDeepSeekReasoning, !pendingReasoningContents.isEmpty {
                        mergeReasoningContent(pendingReasoningContents, into: &message)
                        pendingReasoningContents.removeAll()
                    }
                    var toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
                    toolCalls.append(toolCall)
                    message["tool_calls"] = toolCalls
                    if message["content"] == nil {
                        message["content"] = NSNull()
                    }
                    messages[index] = message
                } else {
                    var message: [String: Any] = [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [toolCall],
                    ]
                    if usesMiniMaxReasoning, !pendingReasoningDetails.isEmpty {
                        mergeReasoningDetails(pendingReasoningDetails, into: &message)
                        pendingReasoningDetails.removeAll()
                    }
                    if usesDeepSeekReasoning, !pendingReasoningContents.isEmpty {
                        mergeReasoningContent(pendingReasoningContents, into: &message)
                        pendingReasoningContents.removeAll()
                    }
                    messages.append(message)
                    lastAssistantIndex = messages.index(before: messages.endIndex)
                }
            case "function_call_output":
                messages.append([
                    "role": "tool",
                    "tool_call_id": trimmedString(item["call_id"]) ?? UUID().uuidString,
                    "content": toolOutputText(from: item["output"]),
                ])
                lastAssistantIndex = nil
            default:
                continue
            }
        }

        return usesMiniMaxReasoning ? normalizedMiniMaxMessages(messages) : messages
    }

    private static func reasoningDetails(from item: [String: Any]) -> [[String: Any]] {
        var details = [[String: Any]]()

        let summaryItems = (item["summary"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for summaryItem in summaryItems {
            guard let text = trimmedString(summaryItem["text"]) else { continue }
            details.append(["text": text])
        }
        if !details.isEmpty {
            return details
        }

        let contentItems = (item["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        for contentItem in contentItems {
            guard let text = trimmedString(contentItem["text"]) else { continue }
            details.append(["text": text])
        }
        if !details.isEmpty {
            return details
        }

        if let text = trimmedString(item["text"]) {
            details.append(["text": text])
        }
        return details
    }

    private static func mergeReasoningDetails(_ details: [[String: Any]], into message: inout [String: Any]) {
        guard !details.isEmpty else { return }
        let existingDetails = (message["reasoning_details"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        message["reasoning_details"] = existingDetails + details
    }

    private static func reasoningHistoryTexts(from item: [String: Any]) -> [String] {
        if let reasoningContent = trimmedString(item["reasoning_content"]) {
            return [reasoningContent]
        }
        return reasoningDetails(from: item).compactMap { detail in
            trimmedString(detail["text"])
        }
    }

    private static func normalizedInputItemType(from item: [String: Any]) -> String? {
        if let type = trimmedString(item["type"]) {
            return type
        }
        if item["role"] != nil || item["content"] != nil {
            return "message"
        }
        if item["call_id"] != nil && (item["name"] != nil || item["arguments"] != nil || item["input"] != nil) {
            return "function_call"
        }
        if item["tool_call_id"] != nil || (item["call_id"] != nil && item["output"] != nil) {
            return "function_call_output"
        }
        if item["summary"] != nil || item["text"] != nil {
            return "reasoning"
        }
        return nil
    }

    private static func mergeReasoningContent(_ contents: [String], into message: inout [String: Any]) {
        guard !contents.isEmpty else { return }
        var merged = [String]()
        if let existing = trimmedString(message["reasoning_content"]) {
            merged.append(existing)
        }
        merged.append(contentsOf: contents)
        let combined = merged.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return }
        message["reasoning_content"] = combined
    }

    private static func normalizedMiniMaxMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var normalized = [[String: Any]]()
        var index = 0

        while index < messages.count {
            let message = messages[index]
            let role = trimmedString(message["role"]) ?? ""
            let toolCalls = (message["tool_calls"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []

            guard role == "assistant", toolCalls.count > 1 else {
                normalized.append(message)
                index += 1
                continue
            }

            let toolCallIDs = Set(toolCalls.compactMap { trimmedString($0["id"]) })
            var toolOutputsByID = [String: [String: Any]]()
            var consumedToolOutputCount = 0
            var lookaheadIndex = index + 1

            while lookaheadIndex < messages.count {
                let candidate = messages[lookaheadIndex]
                guard trimmedString(candidate["role"]) == "tool" else {
                    break
                }
                let callID = trimmedString(candidate["tool_call_id"]) ?? ""
                guard toolCallIDs.contains(callID) else {
                    break
                }
                toolOutputsByID[callID] = candidate
                consumedToolOutputCount += 1
                lookaheadIndex += 1
            }

            for (toolCallIndex, toolCall) in toolCalls.enumerated() {
                var assistantMessage = message
                assistantMessage["tool_calls"] = [toolCall]
                if toolCallIndex > 0 {
                    assistantMessage["content"] = NSNull()
                    assistantMessage.removeValue(forKey: "reasoning_details")
                }
                normalized.append(assistantMessage)

                let callID = trimmedString(toolCall["id"]) ?? ""
                if let toolOutput = toolOutputsByID[callID] {
                    normalized.append(toolOutput)
                }
            }

            index += 1 + consumedToolOutputCount
        }

        return normalized
    }

    private static func normalizedRole(from value: Any?) -> String {
        switch trimmedString(value) {
        case "assistant":
            return "assistant"
        case "system":
            return "system"
        default:
            return "user"
        }
    }

    private static func translateMessageContent(from value: Any?, role: String) -> Any? {
        if let string = value as? String {
            return string
        }

        guard let content = value as? [Any] else {
            return nil
        }

        var textParts = [String]()
        var richParts = [[String: Any]]()
        var hasRichMedia = false

        for itemValue in content {
            guard let item = itemValue as? [String: Any], let type = trimmedString(item["type"]) else { continue }
            switch type {
            case "input_text", "output_text", "text":
                let text = item["text"] as? String ?? ""
                textParts.append(text)
                richParts.append([
                    "type": "text",
                    "text": text,
                ])
            case "input_image":
                guard let imageURL = mediaContentObject(from: item["image_url"], requiredKey: "url") else { continue }
                hasRichMedia = true
                richParts.append([
                    "type": "image_url",
                    "image_url": imageURL,
                ])
            case "image_url":
                guard let imageURL = mediaContentObject(from: item["image_url"], requiredKey: "url") else { continue }
                hasRichMedia = true
                richParts.append([
                    "type": "image_url",
                    "image_url": imageURL,
                ])
            case "input_audio":
                guard let inputAudio = mediaContentObject(from: item["input_audio"], requiredKey: "data") else { continue }
                hasRichMedia = true
                richParts.append([
                    "type": "input_audio",
                    "input_audio": inputAudio,
                ])
            case "video_url":
                guard let videoURL = mediaContentObject(from: item["video_url"], requiredKey: "url") else { continue }
                hasRichMedia = true
                richParts.append([
                    "type": "video_url",
                    "video_url": videoURL,
                ])
            case "input_file":
                guard let mediaPart = fileDataMediaPart(from: item) else { continue }
                hasRichMedia = true
                richParts.append(mediaPart)
            default:
                continue
            }
        }

        if hasRichMedia {
            return richParts
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n\n")
        }
        return role == "assistant" ? NSNull() : ""
    }

    // Normalizes Responses media parts into ChatCompletions media payload objects.
    private static func mediaContentObject(from value: Any?, requiredKey: String) -> [String: Any]? {
        if let string = trimmedString(value) {
            return [requiredKey: string]
        }
        guard
            var object = value as? [String: Any],
            let requiredValue = trimmedString(object[requiredKey])
        else {
            return nil
        }
        object[requiredKey] = requiredValue
        return object
    }

    private static func fileDataMediaPart(from item: [String: Any]) -> [String: Any]? {
        guard
            let fileData = mediaContentObject(from: item["file_data"], requiredKey: "url")?["url"] as? String,
            let mediaKind = mediaKind(fromFileData: fileData, item: item)
        else {
            return nil
        }

        switch mediaKind {
        case .image:
            return [
                "type": "image_url",
                "image_url": [
                    "url": fileData,
                ],
            ]
        case .audio:
            return [
                "type": "input_audio",
                "input_audio": [
                    "data": fileData,
                ],
            ]
        case .video:
            return [
                "type": "video_url",
                "video_url": [
                    "url": fileData,
                ],
            ]
        }
    }

    private static func mediaKind(fromFileData fileData: String, item: [String: Any]) -> MediaKind? {
        if let mediaType = dataURLMediaType(from: fileData) {
            return mediaKind(fromMediaType: mediaType)
        }
        if let mediaType = trimmedString(item["media_type"] ?? item["mime_type"] ?? item["content_type"]) {
            return mediaKind(fromMediaType: mediaType)
        }
        if let filename = trimmedString(item["filename"]) {
            return mediaKind(fromFilename: filename)
        }
        return nil
    }

    private static func dataURLMediaType(from value: String) -> String? {
        guard value.lowercased().hasPrefix("data:"),
              let commaIndex = value.firstIndex(of: ",")
        else {
            return nil
        }

        let metadataStart = value.index(value.startIndex, offsetBy: 5)
        let metadata = value[metadataStart..<commaIndex]
        let parts = metadata.split(separator: ";", omittingEmptySubsequences: true)
        return parts.first.map(String.init)
    }

    private static func mediaKind(fromMediaType mediaType: String) -> MediaKind? {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            return .image
        }
        if normalized.hasPrefix("audio/") {
            return .audio
        }
        if normalized.hasPrefix("video/") {
            return .video
        }
        return nil
    }

    private static func mediaKind(fromFilename filename: String) -> MediaKind? {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "apng", "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "webp":
            return .image
        case "aac", "flac", "m4a", "mp3", "ogg", "opus", "wav":
            return .audio
        case "avi", "m4v", "mov", "mp4", "mpeg", "mpg", "webm":
            return .video
        default:
            return nil
        }
    }

    private static func makeToolCall(from item: [String: Any], type: String) -> [String: Any] {
        let arguments: String
        if type == "custom_tool_call" {
            arguments = trimmedString(item["input"]) ?? "{}"
        } else if let stringArguments = item["arguments"] as? String {
            arguments = stringArguments
        } else {
            arguments = jsonString(from: item["arguments"] ?? [:]) ?? "{}"
        }

        return [
            "id": trimmedString(item["call_id"]) ?? UUID().uuidString,
            "type": "function",
            "function": [
                "name": trimmedString(item["name"]) ?? "tool",
                "arguments": arguments,
            ],
        ]
    }

    private static func translateTools(
        from value: Any?,
        requiresNonEmptyToolParameters: Bool
    ) -> [[String: Any]] {
        guard let tools = value as? [Any] else {
            return []
        }

        return tools.compactMap { toolValue in
            guard
                let tool = toolValue as? [String: Any],
                let name = trimmedString(tool["name"])
            else {
                return nil
            }

            var function: [String: Any] = ["name": name]
            if let description = trimmedString(tool["description"]) {
                function["description"] = description
            }
            if let parameters = normalizedToolParameters(
                from: tool["parameters"] ?? tool["input_schema"],
                requiresNonEmptyToolParameters: requiresNonEmptyToolParameters
            ) {
                function["parameters"] = parameters
            }

            return [
                "type": "function",
                "function": function,
            ]
        }
    }

    private static func normalizedToolParameters(
        from value: Any?,
        requiresNonEmptyToolParameters: Bool
    ) -> [String: Any]? {
        guard var parameters = value as? [String: Any] else {
            return requiresNonEmptyToolParameters ? compatibilityPlaceholderParameters() : nil
        }

        guard requiresNonEmptyToolParameters else {
            return parameters
        }

        guard trimmedString(parameters["type"]) == "object" else {
            return parameters
        }

        let properties = parameters["properties"] as? [String: Any] ?? [:]
        guard properties.isEmpty else {
            return parameters
        }

        parameters["properties"] = compatibilityPlaceholderParameters()["properties"]
        return parameters
    }

    private static func compatibilityPlaceholderParameters() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "_compat": [
                    "type": "boolean",
                    "description": "Compatibility placeholder.",
                ],
            ],
        ]
    }

    private static func translateToolChoice(from value: Any?) -> Any? {
        guard let value else {
            return nil
        }

        if let string = trimmedString(value) {
            switch string {
            case "auto", "required", "none":
                return string
            default:
                return nil
            }
        }

        guard
            let object = value as? [String: Any],
            let type = trimmedString(object["type"])
        else {
            return nil
        }

        switch type {
        case "function", "tool":
            guard let name = trimmedString(object["name"]) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": name,
                ],
            ]
        case "auto", "required", "none":
            return type
        default:
            return nil
        }
    }

    private static func toolOutputText(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let items as [Any]:
            let texts = items.compactMap { itemValue -> String? in
                guard
                    let item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "input_text" || type == "text"
                else {
                    return nil
                }
                return item["text"] as? String
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n\n")
            }
            return jsonString(from: items) ?? ""
        case nil:
            return ""
        default:
            return jsonString(from: value) ?? ""
        }
    }

    private static func makeResponsesResponseObject(
        from data: Data,
        fallbackModel: String,
        usesMiniMaxReasoning: Bool,
        usesDeepSeekReasoning: Bool
    ) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse(L10n.tr("上游 Chat Completions 返回了无效 JSON。"))
        }

        guard
            let choices = response["choices"] as? [Any],
            let choice = choices.first as? [String: Any],
            let message = choice["message"] as? [String: Any]
        else {
            throw TranslationError.invalidResponse(L10n.tr("上游 Chat Completions 缺少 choices。"))
        }

        let textToolExtraction = extractTextToolCalls(from: message["content"])
        var normalizedMessage = message
        if !textToolExtraction.toolCalls.isEmpty {
            normalizedMessage["content"] = textToolExtraction.content
        }

        var output = [[String: Any]]()
        let normalizedOutput = normalizedOutput(
            from: normalizedMessage,
            usesMiniMaxReasoning: usesMiniMaxReasoning,
            usesDeepSeekReasoning: usesDeepSeekReasoning
        )
        if let reasoningItem = normalizedOutput.reasoningItem {
            output.append(reasoningItem)
        }
        if !normalizedOutput.content.isEmpty {
            var messageOutput: [String: Any] = [
                "id": "msg_\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": normalizedOutput.content,
            ]
            if let reasoningContent = normalizedOutput.reasoningContent {
                messageOutput["reasoning_content"] = reasoningContent
            }
            output.append(messageOutput)
        }

        let toolCalls = message["tool_calls"] as? [Any] ?? []
        for toolCallValue in toolCalls {
            guard
                let toolCall = toolCallValue as? [String: Any],
                let function = toolCall["function"] as? [String: Any]
            else {
                continue
            }

            output.append([
                "id": trimmedString(toolCall["id"]) ?? "fc_\(UUID().uuidString)",
                "type": "function_call",
                "status": "completed",
                "call_id": trimmedString(toolCall["id"]) ?? UUID().uuidString,
                "name": trimmedString(function["name"]) ?? "tool",
                "arguments": trimmedString(function["arguments"]) ?? "{}",
            ])
        }
        for toolCall in textToolExtraction.toolCalls {
            let callID = "call_\(UUID().uuidString)"
            output.append([
                "id": "fc_\(UUID().uuidString)",
                "type": "function_call",
                "status": "completed",
                "call_id": callID,
                "name": toolCall.name,
                "arguments": toolCall.arguments,
            ])
        }

        if output.isEmpty {
            output.append([
                "id": "msg_\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "",
                ]],
            ])
        }

        let usage = response["usage"] as? [String: Any]
        let inputTokens = intValue(usage?["prompt_tokens"]) ?? intValue(usage?["input_tokens"]) ?? 0
        let outputTokens = intValue(usage?["completion_tokens"]) ?? intValue(usage?["output_tokens"]) ?? 0
        let totalTokens = intValue(usage?["total_tokens"]) ?? (inputTokens + outputTokens)

        return [
            "id": trimmedString(response["id"]) ?? UUID().uuidString,
            "object": "response",
            "model": trimmedString(response["model"]) ?? fallbackModel,
            "output": output,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "total_tokens": totalTokens,
            ],
        ]
    }

    // 兼容把工具调用降级成文本标签返回的 OpenAI-compatible 上游。
    private static func extractTextToolCalls(from content: Any?) -> (content: Any?, toolCalls: [TextToolCall]) {
        switch content {
        case let text as String:
            let extracted = extractTextToolCalls(fromText: text)
            return (extracted.text, extracted.toolCalls)
        case let items as [Any]:
            var rewrittenItems = [Any]()
            var toolCalls = [TextToolCall]()
            for itemValue in items {
                guard
                    var item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "text" || type == "output_text",
                    let text = item["text"] as? String
                else {
                    rewrittenItems.append(itemValue)
                    continue
                }

                let extracted = extractTextToolCalls(fromText: text)
                toolCalls.append(contentsOf: extracted.toolCalls)
                item["text"] = extracted.text
                rewrittenItems.append(item)
            }
            return (rewrittenItems, toolCalls)
        default:
            return (content, [])
        }
    }

    private static func extractTextToolCalls(fromText text: String) -> (text: String, toolCalls: [TextToolCall]) {
        guard text.contains("<tool_call>"), text.contains("</tool_call>") else {
            return (text, [])
        }
        guard
            let blockRegex = try? NSRegularExpression(
                pattern: #"<tool_call>\s*<function=([A-Za-z0-9_.-]+)>\s*(.*?)\s*</function>\s*</tool_call>"#,
                options: [.dotMatchesLineSeparators]
            ),
            let parameterRegex = try? NSRegularExpression(
                pattern: #"<parameter=([A-Za-z0-9_.-]+)>(.*?)</parameter>"#,
                options: [.dotMatchesLineSeparators]
            )
        else {
            return (text, [])
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = blockRegex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return (text, [])
        }

        var toolCalls = [TextToolCall]()
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let functionName = nsText.substring(with: match.range(at: 1))
            let parameterSource = nsText.substring(with: match.range(at: 2))
            let nsParameterSource = parameterSource as NSString
            let parameterMatches = parameterRegex.matches(
                in: parameterSource,
                options: [],
                range: NSRange(location: 0, length: nsParameterSource.length)
            )
            let parameters = parameterMatches.reduce(into: [String: Any]()) { result, parameterMatch in
                guard parameterMatch.numberOfRanges >= 3 else { return }
                let name = nsParameterSource.substring(with: parameterMatch.range(at: 1))
                let value = nsParameterSource.substring(with: parameterMatch.range(at: 2))
                result[name] = value
            }
            guard !parameters.isEmpty else { continue }
            toolCalls.append(
                TextToolCall(
                    name: functionName,
                    arguments: jsonString(from: parameters) ?? "{}"
                )
            )
        }

        guard !toolCalls.isEmpty else {
            return (text, [])
        }

        let strippedText = blockRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (strippedText, toolCalls)
    }

    private static func normalizedOutput(
        from message: [String: Any],
        usesMiniMaxReasoning: Bool,
        usesDeepSeekReasoning: Bool
    ) -> (reasoningItem: [String: Any]?, content: [[String: Any]], reasoningContent: String?) {
        let deepSeekReasoningContent = usesDeepSeekReasoning ? trimmedString(message["reasoning_content"]) : nil
        var reasoningSummaryTexts = usesMiniMaxReasoning ? reasoningTexts(from: message["reasoning_details"]) : []
        if reasoningSummaryTexts.isEmpty, usesDeepSeekReasoning {
            reasoningSummaryTexts = reasoningTexts(from: deepSeekReasoningContent)
        }
        let extraction = outputTextContent(
            from: message["content"],
            stripMiniMaxThinking: usesMiniMaxReasoning,
            collectMiniMaxThinking: usesMiniMaxReasoning && reasoningSummaryTexts.isEmpty
        )
        if reasoningSummaryTexts.isEmpty {
            reasoningSummaryTexts = extraction.reasoningTexts
        }

        let reasoningItem: [String: Any]?
        if (usesMiniMaxReasoning || usesDeepSeekReasoning), !reasoningSummaryTexts.isEmpty {
            reasoningItem = [
                "id": "rs_\(UUID().uuidString)",
                "type": "reasoning",
                "summary": reasoningSummaryTexts.map { text in
                    [
                        "type": "summary_text",
                        "text": text,
                    ]
                },
                "content": NSNull(),
            ]
        } else {
            reasoningItem = nil
        }

        let reasoningContentForHistory: String?
        if usesDeepSeekReasoning {
            if let deepSeekReasoningContent {
                reasoningContentForHistory = deepSeekReasoningContent
            } else {
                let merged = reasoningSummaryTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                reasoningContentForHistory = merged.isEmpty ? nil : merged
            }
        } else {
            reasoningContentForHistory = nil
        }

        return (reasoningItem, extraction.content, reasoningContentForHistory)
    }

    private static func reasoningTexts(from value: Any?) -> [String] {
        switch value {
        case let string as String:
            return trimmedString(string).map { [$0] } ?? []
        case let items as [Any]:
            return items.compactMap { itemValue in
                if let text = trimmedString(itemValue) {
                    return text
                }
                guard let item = itemValue as? [String: Any] else {
                    return nil
                }
                return trimmedString(item["text"])
            }
        default:
            return []
        }
    }

    private static func outputTextContent(
        from value: Any?,
        stripMiniMaxThinking: Bool = false,
        collectMiniMaxThinking: Bool = false
    ) -> (content: [[String: Any]], reasoningTexts: [String]) {
        switch value {
        case let string as String:
            let extracted = extractMiniMaxThinking(
                from: string,
                stripMiniMaxThinking: stripMiniMaxThinking,
                collectMiniMaxThinking: collectMiniMaxThinking
            )
            guard !extracted.content.isEmpty else {
                return ([], extracted.reasoningTexts)
            }
            return ([[
                "type": "output_text",
                "text": extracted.content,
            ]], extracted.reasoningTexts)
        case let items as [Any]:
            var reasoningTexts = [String]()
            let content = items.compactMap { itemValue -> [String: Any]? in
                guard
                    let item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "text" || type == "output_text",
                    let text = item["text"] as? String
                else {
                    return nil
                }
                let extracted = extractMiniMaxThinking(
                    from: text,
                    stripMiniMaxThinking: stripMiniMaxThinking,
                    collectMiniMaxThinking: collectMiniMaxThinking
                )
                reasoningTexts.append(contentsOf: extracted.reasoningTexts)
                guard !extracted.content.isEmpty else {
                    return nil
                }
                return [
                    "type": "output_text",
                    "text": extracted.content,
                ]
            }
            return (content, reasoningTexts)
        default:
            return ([], [])
        }
    }

    private static func extractMiniMaxThinking(
        from text: String,
        stripMiniMaxThinking: Bool,
        collectMiniMaxThinking: Bool
    ) -> (content: String, reasoningTexts: [String]) {
        guard stripMiniMaxThinking, !text.isEmpty else {
            return (text, [])
        }

        guard
            let regex = try? NSRegularExpression(
                pattern: "<think>(.*?)</think>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else {
            return (text, [])
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return (text, [])
        }

        let nsText = text as NSString
        let reasoningTexts = collectMiniMaxThinking ? matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            let thinkRange = match.range(at: 1)
            guard thinkRange.location != NSNotFound else { return nil }
            return trimmedString(nsText.substring(with: thinkRange))
        } : []

        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, reasoningTexts)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
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

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func jsonString(from value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func appendStreamEvent(named eventName: String, payload: [String: Any], to events: inout [String]) {
        events.append(streamEventString(named: eventName, payload: payload))
    }

    private static func streamEventString(named eventName: String, payload: [String: Any]) -> String {
        let payloadString = jsonString(from: payload) ?? "{}"
        return "event: \(eventName)\ndata: \(payloadString)\n\n"
    }
}
