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
            model: "deepseek-chat"
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
}
