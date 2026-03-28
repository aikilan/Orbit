import Foundation

enum ResponsesChatCompletionsBridge {
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

    static func makeChatCompletionsRequestData(from data: Data, fallbackModel: String) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidRequest(L10n.tr("Responses 请求不是有效的 JSON。"))
        }

        let object = try makeChatCompletionsRequestObject(from: request, fallbackModel: fallbackModel)
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponsesResponseData(from data: Data, fallbackModel: String) throws -> Data {
        let object = try makeResponsesResponseObject(from: data, fallbackModel: fallbackModel)
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func makeResponseStreamData(from response: [String: Any]) -> Data {
        let eventObject: [String: Any] = [
            "type": "response.completed",
            "response": response,
        ]
        let payload = jsonString(from: eventObject) ?? "{}"
        return Data("event: response.completed\ndata: \(payload)\n\ndata: [DONE]\n\n".utf8)
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

    private static func makeChatCompletionsRequestObject(
        from request: [String: Any],
        fallbackModel: String
    ) throws -> [String: Any] {
        let model = trimmedString(request["model"]) ?? fallbackModel
        let instructions = trimmedString(request["instructions"])
        let messages = try translateMessages(from: request["input"], instructions: instructions)
        let tools = translateTools(from: request["tools"])
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
            body["max_tokens"] = maxTokens
        }
        if let parallelToolCalls = request["parallel_tool_calls"] as? Bool {
            body["parallel_tool_calls"] = parallelToolCalls
        }
        return body
    }

    private static func translateMessages(from input: Any?, instructions: String?) throws -> [[String: Any]] {
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

        for itemValue in items {
            guard let item = itemValue as? [String: Any], let type = trimmedString(item["type"]) else { continue }

            switch type {
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
                messages.append(message)
                lastAssistantIndex = role == "assistant" ? messages.index(before: messages.endIndex) : nil
            case "function_call", "custom_tool_call":
                let toolCall = makeToolCall(from: item, type: type)
                if let index = lastAssistantIndex {
                    var message = messages[index]
                    var toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
                    toolCalls.append(toolCall)
                    message["tool_calls"] = toolCalls
                    if message["content"] == nil {
                        message["content"] = NSNull()
                    }
                    messages[index] = message
                } else {
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [toolCall],
                    ])
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

        return messages
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
        var hasImage = false

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
                guard let imageURL = trimmedString(item["image_url"]) else { continue }
                hasImage = true
                richParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": imageURL,
                    ],
                ])
            default:
                continue
            }
        }

        if hasImage {
            return richParts
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n\n")
        }
        return role == "assistant" ? NSNull() : ""
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

    private static func translateTools(from value: Any?) -> [[String: Any]] {
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
            if let parameters = tool["parameters"] ?? tool["input_schema"] {
                function["parameters"] = parameters
            }

            return [
                "type": "function",
                "function": function,
            ]
        }
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

    private static func makeResponsesResponseObject(from data: Data, fallbackModel: String) throws -> [String: Any] {
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

        var output = [[String: Any]]()
        let content = outputTextContent(from: message["content"])
        if !content.isEmpty {
            output.append([
                "type": "message",
                "role": "assistant",
                "content": content,
            ])
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
                "type": "function_call",
                "call_id": trimmedString(toolCall["id"]) ?? UUID().uuidString,
                "name": trimmedString(function["name"]) ?? "tool",
                "arguments": trimmedString(function["arguments"]) ?? "{}",
            ])
        }

        if output.isEmpty {
            output.append([
                "type": "message",
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

    private static func outputTextContent(from value: Any?) -> [[String: Any]] {
        switch value {
        case let string as String:
            guard !string.isEmpty else { return [] }
            return [[
                "type": "output_text",
                "text": string,
            ]]
        case let items as [Any]:
            return items.compactMap { itemValue in
                guard
                    let item = itemValue as? [String: Any],
                    let type = trimmedString(item["type"]),
                    type == "text",
                    let text = item["text"] as? String
                else {
                    return nil
                }
                return [
                    "type": "output_text",
                    "text": text,
                ]
            }
        default:
            return []
        }
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
}
