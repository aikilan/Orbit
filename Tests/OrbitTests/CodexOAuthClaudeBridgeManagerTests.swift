import Foundation
import XCTest
@testable import Orbit

final class CodexOAuthClaudeBridgeManagerTests: XCTestCase {
    func testResponsesChatCompletionsBridgeConvertsResponsesRequestToChatCompletions() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "instructions": "You are Codex.",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "列出当前目录",
                        ],
                    ],
                ],
                [
                    "type": "function_call",
                    "call_id": "call_ls",
                    "name": "exec",
                    "arguments": "{\"cmd\":\"ls\"}",
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_ls",
                    "output": "README.md",
                ],
            ],
            "tools": [
                [
                    "type": "function",
                    "name": "exec",
                    "description": "run shell command",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "cmd": ["type": "string"],
                        ],
                    ],
                ],
            ],
            "tool_choice": [
                "type": "function",
                "name": "exec",
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "deepseek-chat"
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let toolChoice = try XCTUnwrap(object["tool_choice"] as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "列出当前目录")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual((messages[2]["tool_calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["content"] as? String, "README.md")
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "exec")
        XCTAssertEqual(toolChoice["type"] as? String, "function")
    }

    func testResponsesChatCompletionsBridgeConvertsChatCompletionsResponseToResponses() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_test",
            "model": "deepseek-chat",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "done",
                        "tool_calls": [
                            [
                                "id": "call_ls",
                                "type": "function",
                                "function": [
                                    "name": "exec",
                                    "arguments": "{\"cmd\":\"ls\"}",
                                ],
                            ],
                        ],
                    ],
                    "finish_reason": "tool_calls",
                ],
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15,
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: response,
            fallbackModel: "deepseek-chat"
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])

        XCTAssertEqual(object["id"] as? String, "chatcmpl_test")
        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(output.first?["type"] as? String, "message")
        XCTAssertEqual((output.first?["content"] as? [[String: Any]])?.first?["text"] as? String, "done")
        XCTAssertEqual(output.last?["type"] as? String, "function_call")
        XCTAssertEqual(output.last?["name"] as? String, "exec")
        XCTAssertEqual((object["usage"] as? [String: Any])?["total_tokens"] as? Int, 15)
    }

    func testResponsesChatCompletionsBridgeFillsEmptyToolParametersForMiniMaxCompatibility() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "input": "关闭页面",
            "tools": [
                [
                    "type": "function",
                    "name": "browser_close",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ])

        let bridged = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: request,
            fallbackModel: "MiniMax-M2.7",
            requiresNonEmptyToolParameters: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertEqual(Array(properties.keys), ["_compat"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
    }

    func testResponsesBridgeRequestUsesStreamingAndListInput() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "max_tokens": 256,
            "system": "You are Claude Code.",
            "messages": [
                [
                    "role": "user",
                    "content": "分析一下这个项目",
                ],
            ],
        ])

        let bridged = try makeCodexResponsesBridgeRequestData(from: request, fallbackModel: "gpt-5.4")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bridged) as? [String: Any])

        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        XCTAssertEqual(object["instructions"] as? String, "You are Claude Code.")
        XCTAssertEqual((object["input"] as? [Any])?.isEmpty, false)
        XCTAssertNil(object["max_output_tokens"])
    }

    func testExtractCompletedResponsesBridgeDataReturnsFinalResponseObject() throws {
        let sseBody = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_test","status":"in_progress"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-5.4","output":[{"id":"msg_test","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"hello from codex"}]}],"usage":{"input_tokens":12,"output_tokens":7}}}

        """

        let extracted = try extractCodexResponsesBridgeCompletedData(from: Data(sseBody.utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: extracted) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "resp_test")
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let content = try XCTUnwrap(output.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello from codex")
    }

    func testBridgeReturnsAnthropicSSEForStreamingClaudeRequests() async throws {
        let upstreamSSE = """
        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-5.4","output":[{"id":"msg_test","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"hello from codex"}]}],"usage":{"input_tokens":12,"output_tokens":7}}}

        """

        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data(upstreamSSE.utf8)
                )
            }
        )
        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .codexAuthPayload(CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: "sk-test")),
            model: "gpt-5.4",
            availableModels: ["gpt-5.4"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("codex-oauth-bridge", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "stream": true,
            "messages": [
                [
                    "role": "user",
                    "content": "分析一下这个项目",
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertTrue(text.contains("event: message_start"))
        XCTAssertTrue(text.contains("event: content_block_start"))
        XCTAssertTrue(text.contains("event: message_stop"))
    }

    func testModelsEndpointReturnsAvailableModelsForProviderBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .provider(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnvName: "OPENAI_API_KEY",
                apiKey: "sk-openai-test",
                supportsResponsesAPI: true
            ),
            model: "gpt-5.4",
            availableModels: ["gpt-4.1", "gpt-4o"]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-4.1", "gpt-4o", "gpt-5.4"])
    }

    func testModelsEndpointFallsBackToSingleDefaultModelForProviderBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .provider(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnvName: "OPENAI_API_KEY",
                apiKey: "sk-openai-test",
                supportsResponsesAPI: true
            ),
            model: "gpt-5.4",
            availableModels: []
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-5.4"])
    }

    func testModelsEndpointReturnsAvailableModelsForCodexOAuthBridge() async throws {
        let manager = CodexOAuthClaudeBridgeManager(
            sendUpstreamRequest: { _, _ in
                XCTFail("不应该触发上游请求")
                return CodexOAuthClaudeBridgeUpstreamResponse(
                    statusCode: 200,
                    body: Data("{}".utf8)
                )
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            source: .codexAuthPayload(CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: "sk-test")),
            model: "gpt-5.4",
            availableModels: [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
            ]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["gpt-5.3-codex", "gpt-5.4", "gpt-5.2-codex"])
    }
}
