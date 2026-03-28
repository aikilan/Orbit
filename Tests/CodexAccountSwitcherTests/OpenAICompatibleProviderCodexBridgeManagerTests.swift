import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class OpenAICompatibleProviderCodexBridgeManagerTests: XCTestCase {
    func testBridgeTranslatesResponsesRequestAndChatCompletionsResponse() async throws {
        actor Recorder {
            var lastRequestBody: Data?

            func store(_ data: Data) {
                lastRequestBody = data
            }

            func body() -> Data? {
                lastRequestBody
            }
        }

        let recorder = Recorder()
        let upstreamResponse = try JSONSerialization.data(withJSONObject: [
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

        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, body in
                await recorder.store(body)
                return (200, upstreamResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnvName: "DEEPSEEK_API_KEY",
            apiKey: "sk-deepseek-test",
            model: "deepseek-chat",
            availableModels: ["deepseek-chat"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "instructions": "You are Codex.",
            "stream": false,
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
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let responseObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let upstreamMessages = try XCTUnwrap(upstreamRequestObject["messages"] as? [[String: Any]])
        let output = try XCTUnwrap(responseObject["output"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(upstreamRequestObject["model"] as? String, "deepseek-chat")
        XCTAssertEqual(upstreamMessages.first?["role"] as? String, "system")
        XCTAssertEqual(upstreamMessages.dropFirst().first?["content"] as? String, "列出当前目录")
        XCTAssertEqual(output.first?["type"] as? String, "message")
        XCTAssertEqual(output.last?["type"] as? String, "function_call")
    }

    func testBridgeStreamsCodexCompatibleResponsesEvents() async throws {
        let upstreamResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_stream_test",
            "model": "deepseek-chat",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "嗨。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 9,
                "completion_tokens": 2,
                "total_tokens": 11,
            ],
        ])

        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                (200, upstreamResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnvName: "DEEPSEEK_API_KEY",
            apiKey: "sk-deepseek-test",
            model: "deepseek-chat",
            availableModels: ["deepseek-chat"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-chat",
            "stream": true,
            "input": "用一句中文说 hi",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertTrue(text.contains("event: response.created"))
        XCTAssertTrue(text.contains("event: response.output_item.done"))
        XCTAssertTrue(text.contains("event: response.output_text.delta"))
        XCTAssertTrue(text.contains("\"text\":\"嗨。\""))
        XCTAssertTrue(text.contains("event: response.completed"))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testModelsEndpointReturnsAvailableModelsAndAppendsDefaultModel() async throws {
        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnvName: "DEEPSEEK_API_KEY",
            apiKey: "sk-deepseek-test",
            model: "deepseek-coder",
            availableModels: ["deepseek-chat", "deepseek-reasoner"]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["deepseek-chat", "deepseek-reasoner", "deepseek-coder"])
    }

    func testModelsEndpointFallsBackToSingleDefaultModel() async throws {
        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnvName: "DEEPSEEK_API_KEY",
            apiKey: "sk-deepseek-test",
            model: "deepseek-chat",
            availableModels: []
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/models")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["deepseek-chat"])
    }
}
