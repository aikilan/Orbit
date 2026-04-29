import Foundation
import XCTest
@testable import Orbit

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
            availableModels: ["deepseek-chat"],
            modelSettings: [ProviderModelSettings(model: "deepseek-chat", temperature: 0.7, topP: 0.8)]
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
        XCTAssertEqual(upstreamRequestObject["temperature"] as? Double, 0.7)
        XCTAssertEqual(upstreamRequestObject["top_p"] as? Double, 0.8)
        XCTAssertEqual(upstreamMessages.first?["role"] as? String, "system")
        XCTAssertEqual(upstreamMessages.dropFirst().first?["content"] as? String, "列出当前目录")
        XCTAssertEqual(output.first?["type"] as? String, "message")
        XCTAssertEqual(output.last?["type"] as? String, "function_call")
    }

    func testDeepSeekBridgePreservesReasoningContentAcrossTurns() async throws {
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
            "id": "chatcmpl_deepseek_reasoning",
            "model": "deepseek-reasoner",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_content": "先检查最近一次工具输出。",
                        "content": "建议先运行测试。",
                    ],
                    "finish_reason": "stop",
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
            model: "deepseek-reasoner",
            availableModels: ["deepseek-reasoner"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-reasoner",
            "stream": false,
            "input": [
                [
                    "type": "reasoning",
                    "summary": [
                        [
                            "type": "summary_text",
                            "text": "先检查最近一次工具输出。",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "我先看一下上一轮结果。",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "下一步怎么做？",
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
        let output = try XCTUnwrap(responseObject["output"] as? [[String: Any]])
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let upstreamMessages = try XCTUnwrap(upstreamRequestObject["messages"] as? [[String: Any]])
        let assistantMessage = try XCTUnwrap(upstreamMessages.first(where: { ($0["role"] as? String) == "assistant" }))
        let reasoningOutput = try XCTUnwrap(output.first(where: { ($0["type"] as? String) == "reasoning" }))
        let reasoningSummary = try XCTUnwrap(reasoningOutput["summary"] as? [[String: Any]])
        let assistantOutput = try XCTUnwrap(output.first(where: { ($0["type"] as? String) == "message" }))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(assistantMessage["reasoning_content"] as? String, "先检查最近一次工具输出。")
        XCTAssertEqual(reasoningSummary.first?["text"] as? String, "先检查最近一次工具输出。")
        XCTAssertEqual(assistantOutput["reasoning_content"] as? String, "先检查最近一次工具输出。")
        XCTAssertEqual(output.dropFirst().first?["type"] as? String, "message")
    }

    func testDeepSeekBridgePreservesAssistantReasoningContentWithoutTypeField() async throws {
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
            "id": "chatcmpl_deepseek_reasoning_no_type",
            "model": "deepseek-reasoner",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_content": "我会先复用上一轮推理。",
                        "content": "继续执行。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 8,
                "completion_tokens": 4,
                "total_tokens": 12,
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
            model: "deepseek-reasoner",
            availableModels: ["deepseek-reasoner"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-reasoner",
            "stream": false,
            "input": [
                [
                    "role": "assistant",
                    "reasoning_content": "先检查上一次工具输出，再继续。",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "上一轮结果已经拿到。",
                        ],
                    ],
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "继续下一步。",
                        ],
                    ],
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let upstreamMessages = try XCTUnwrap(upstreamRequestObject["messages"] as? [[String: Any]])
        let firstAssistant = try XCTUnwrap(upstreamMessages.first)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(firstAssistant["role"] as? String, "assistant")
        XCTAssertEqual(firstAssistant["reasoning_content"] as? String, "先检查上一次工具输出，再继续。")
    }

    func testMiMoBridgeUsesMaxCompletionTokensAndPreservesReasoningContent() async throws {
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
            "id": "chatcmpl_mimo_reasoning",
            "model": "mimo-v2.5-pro",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_content": "先复用上一轮工具调用推理。",
                        "content": "继续处理。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 8,
                "completion_tokens": 4,
                "total_tokens": 12,
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
            baseURL: "https://api.xiaomimimo.com/v1",
            apiKeyEnvName: "MIMO_API_KEY",
            apiKey: "sk-mimo-test",
            model: "mimo-v2.5-pro",
            availableModels: ["mimo-v2.5-pro"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "stream": false,
            "max_output_tokens": 1024,
            "parallel_tool_calls": true,
            "input": [
                [
                    "type": "reasoning",
                    "summary": [
                        [
                            "type": "summary_text",
                            "text": "上一轮已经判断需要调用工具。",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "我会继续执行。",
                        ],
                    ],
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "继续。",
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
        let output = try XCTUnwrap(responseObject["output"] as? [[String: Any]])
        let recordedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(recordedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let upstreamMessages = try XCTUnwrap(upstreamRequestObject["messages"] as? [[String: Any]])
        let assistantMessage = try XCTUnwrap(upstreamMessages.first(where: { ($0["role"] as? String) == "assistant" }))
        let assistantOutput = try XCTUnwrap(output.first(where: { ($0["type"] as? String) == "message" }))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(upstreamRequestObject["model"] as? String, "mimo-v2.5-pro")
        XCTAssertEqual(upstreamRequestObject["max_completion_tokens"] as? Int, 1024)
        XCTAssertNil(upstreamRequestObject["max_tokens"])
        XCTAssertNil(upstreamRequestObject["parallel_tool_calls"])
        XCTAssertEqual(assistantMessage["reasoning_content"] as? String, "上一轮已经判断需要调用工具。")
        XCTAssertEqual(assistantOutput["reasoning_content"] as? String, "先复用上一轮工具调用推理。")
    }

    func testBridgeRunsAssociatedMultimodalModelBeforeMainModelWhenRequestContainsMedia() async throws {
        actor Recorder {
            private(set) var requestBodies = [Data]()

            func store(_ data: Data) -> Int {
                requestBodies.append(data)
                return requestBodies.count
            }

            func bodies() -> [Data] {
                requestBodies
            }
        }

        let recorder = Recorder()
        let prepassResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_prepass",
            "model": "mimo-v2.5",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "附件显示样式文件为空，需要补上 wrapper 布局样式。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 20,
                "completion_tokens": 8,
                "total_tokens": 28,
            ],
        ])
        let mainResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_main",
            "model": "mimo-v2.5-pro",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "我会补上样式。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 30,
                "completion_tokens": 6,
                "total_tokens": 36,
            ],
        ])

        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, body in
                let index = await recorder.store(body)
                return index == 1 ? (200, prepassResponse) : (200, mainResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.xiaomimimo.com/v1",
            apiKeyEnvName: "MIMO_API_KEY",
            apiKey: "sk-mimo-test",
            model: "mimo-v2.5-pro",
            availableModels: ["mimo-v2.5-pro"],
            modelSettings: [
                ProviderModelSettings(model: "mimo-v2.5-pro", temperature: 0.7, topP: 0.8, multimodalModel: "mimo-v2.5"),
                ProviderModelSettings(model: "mimo-v2.5", temperature: 0.4, topP: 0.9),
            ]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "mimo-v2.5-pro",
            "stream": true,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "根据附件修改样式",
                        ],
                        [
                            "type": "input_file",
                            "filename": "mockup.png",
                            "file_data": "data:image/png;base64,aaa",
                        ],
                    ],
                ],
            ],
            "tools": [
                [
                    "type": "function",
                    "name": "apply_patch",
                    "description": "apply a patch",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "patch": ["type": "string"],
                        ],
                    ],
                ],
            ],
            "tool_choice": "auto",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let requestBodies = await recorder.bodies()
        let prepassBody = try XCTUnwrap(requestBodies.first)
        let mainBody = try XCTUnwrap(requestBodies.last)
        let prepassObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepassBody) as? [String: Any])
        let mainObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: mainBody) as? [String: Any])
        let prepassMessages = try XCTUnwrap(prepassObject["messages"] as? [[String: Any]])
        let prepassContent = try XCTUnwrap(prepassMessages.last?["content"] as? [[String: Any]])
        let mainMessages = try XCTUnwrap(mainObject["messages"] as? [[String: Any]])
        let mainBodyText = try XCTUnwrap(String(data: mainBody, encoding: .utf8))
        let responseText = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertEqual(prepassObject["model"] as? String, "mimo-v2.5")
        XCTAssertEqual(prepassObject["temperature"] as? Double, 0.4)
        XCTAssertEqual(prepassObject["top_p"] as? Double, 0.9)
        XCTAssertNil(prepassObject["tools"])
        XCTAssertNil(prepassObject["tool_choice"])
        XCTAssertEqual(prepassContent[1]["type"] as? String, "image_url")
        XCTAssertEqual(mainObject["model"] as? String, "mimo-v2.5-pro")
        XCTAssertEqual(mainObject["temperature"] as? Double, 0.7)
        XCTAssertEqual(mainObject["top_p"] as? Double, 0.8)
        XCTAssertNotNil(mainObject["tools"])
        XCTAssertEqual(mainObject["tool_choice"] as? String, "auto")
        XCTAssertTrue(mainMessages.contains { ($0["content"] as? String)?.contains("以下是多模态模型对用户附件的解析结果") == true })
        XCTAssertTrue(mainMessages.contains { ($0["content"] as? String)?.contains("附件显示样式文件为空") == true })
        XCTAssertFalse(mainBodyText.contains("image_url"))
        XCTAssertFalse(mainBodyText.contains("file_data"))
        XCTAssertFalse(mainBodyText.contains("input_audio"))
        XCTAssertFalse(mainBodyText.contains("video_url"))
        XCTAssertTrue(responseText.contains("event: response.completed"))
        XCTAssertTrue(responseText.contains("data: [DONE]"))
    }

    @MainActor
    func testDebugStoreRecordsMultimodalPrepassEvents() async throws {
        actor Recorder {
            private var count = 0

            func next() -> Int {
                count += 1
                return count
            }
        }

        let recorder = Recorder()
        let debugStore = ProviderBridgeDebugStore()
        let prepassResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_prepass_debug",
            "model": "mimo-v2.5",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "附件显示顶部筛选栏和重复题按钮。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
        ])
        let mainResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_main_debug",
            "model": "mimo-v2.5-pro",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "继续实现。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
        ])
        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                let index = await recorder.next()
                return index == 1 ? (200, prepassResponse) : (200, mainResponse)
            },
            debugStore: debugStore
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.xiaomimimo.com/v1",
            apiKeyEnvName: "MIMO_API_KEY",
            apiKey: "sk-mimo-test",
            model: "mimo-v2.5-pro",
            availableModels: ["mimo-v2.5-pro"],
            modelSettings: [
                ProviderModelSettings(model: "mimo-v2.5-pro", multimodalModel: "mimo-v2.5"),
            ]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "stream": false,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "分析附件",
                        ],
                        [
                            "type": "input_file",
                            "filename": "mockup.png",
                            "file_data": "data:image/png;base64,aaa",
                        ],
                    ],
                ],
            ],
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let debugRequest = try XCTUnwrap(debugStore.requests.first)
        let eventTitles = debugStore.events.map(\.title)
        let prepassRequestEvent = try XCTUnwrap(debugStore.events.first { $0.title == L10n.tr("多模态预处理请求") })
        let mainRequestEvent = try XCTUnwrap(debugStore.events.first { $0.title == L10n.tr("主模型请求") })

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(debugRequest.model, "mimo-v2.5-pro")
        XCTAssertTrue(debugRequest.hasMedia)
        XCTAssertEqual(debugRequest.multimodalModel, "mimo-v2.5")
        XCTAssertEqual(debugRequest.status, .completed)
        XCTAssertTrue(eventTitles.contains(L10n.tr("Bridge 分析")))
        XCTAssertTrue(eventTitles.contains(L10n.tr("模型归一化")))
        XCTAssertTrue(eventTitles.contains(L10n.tr("多模态预处理响应")))
        XCTAssertTrue(eventTitles.contains(L10n.tr("多模态摘要")))
        XCTAssertTrue(eventTitles.contains(L10n.tr("主模型响应")))
        XCTAssertTrue(prepassRequestEvent.payloadPreview?.contains("<redacted 3 chars>") == true)
        XCTAssertTrue(mainRequestEvent.detail.contains("text-only"))
        XCTAssertFalse(mainRequestEvent.payloadPreview?.contains("file_data") == true)
    }

    func testBridgeReturnsPrepassErrorWithoutCallingMainModel() async throws {
        actor Recorder {
            private(set) var requestBodies = [Data]()

            func store(_ data: Data) {
                requestBodies.append(data)
            }

            func count() -> Int {
                requestBodies.count
            }
        }

        let recorder = Recorder()
        let prepassError = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "unsupported image",
            ],
        ])
        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, body in
                await recorder.store(body)
                return (400, prepassError)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.xiaomimimo.com/v1",
            apiKeyEnvName: "MIMO_API_KEY",
            apiKey: "sk-mimo-test",
            model: "mimo-v2.5-pro",
            availableModels: ["mimo-v2.5-pro"],
            modelSettings: [
                ProviderModelSettings(model: "mimo-v2.5-pro", multimodalModel: "mimo-v2.5"),
            ]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "mimo-v2.5-pro",
            "stream": false,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "看附件",
                        ],
                        [
                            "type": "input_image",
                            "image_url": "data:image/png;base64,aaa",
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
        let error = try XCTUnwrap(responseObject["error"] as? [String: Any])
        let requestCount = await recorder.count()

        XCTAssertEqual(httpResponse.statusCode, 400)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(error["message"] as? String, "unsupported image")
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

    func testBridgeRetriesTransient529BeforeReturningSuccess() async throws {
        actor AttemptCounter {
            private var count = 0

            func next() -> Int {
                count += 1
                return count
            }

            func value() -> Int {
                count
            }
        }

        let attempts = AttemptCounter()
        let overloadResponse = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "The server cluster is currently under high load.",
                "type": "api_error",
            ],
        ])
        let successResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_retry_test",
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "恢复成功。",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 4,
                "total_tokens": 14,
            ],
        ])

        let manager = OpenAICompatibleProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                let attempt = await attempts.next()
                return attempt < 3 ? (529, overloadResponse) : (200, successResponse)
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.minimax.io/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "stream": false,
            "input": "说一句话",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let responseObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(responseObject["output"] as? [[String: Any]])
        let content = try XCTUnwrap(output.first?["content"] as? [[String: Any]])
        let totalAttempts = await attempts.value()

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(totalAttempts, 3)
        XCTAssertEqual(content.first?["text"] as? String, "恢复成功。")
    }

    func testMiniMaxBridgeFillsEmptyToolParametersBeforeForwarding() async throws {
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
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "done",
                    ],
                    "finish_reason": "stop",
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
            baseURL: "https://api.minimax.io/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "stream": false,
            "parallel_tool_calls": true,
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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        _ = try await session.data(for: request)

        let capturedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(capturedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])
        let tools = try XCTUnwrap(upstreamRequestObject["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertEqual(Array(properties.keys), ["_compat"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(upstreamRequestObject["reasoning_split"] as? Bool, true)
        XCTAssertEqual(upstreamRequestObject["parallel_tool_calls"] as? Bool, false)
    }

    func testMiniMaxBridgeSeparatesReasoningFromVisibleOutput() async throws {
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
            "id": "chatcmpl_minimax_reasoning",
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_details": [
                            [
                                "text": "先检查模块边界。",
                            ],
                        ],
                        "content": "这是最终答案。",
                    ],
                    "finish_reason": "stop",
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
            baseURL: "https://api.minimax.io/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
            "stream": false,
            "input": "分析一下这个项目",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let responseObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(responseObject["output"] as? [[String: Any]])
        let summary = try XCTUnwrap(output.first?["summary"] as? [[String: Any]])
        let content = try XCTUnwrap(output.dropFirst().first?["content"] as? [[String: Any]])
        let capturedBody = await recorder.body()
        let upstreamBody = try XCTUnwrap(capturedBody)
        let upstreamRequestObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(upstreamRequestObject["reasoning_split"] as? Bool, true)
        XCTAssertEqual(output.first?["type"] as? String, "reasoning")
        XCTAssertEqual(summary.first?["text"] as? String, "先检查模块边界。")
        XCTAssertEqual(output.dropFirst().first?["type"] as? String, "message")
        XCTAssertEqual(content.first?["text"] as? String, "这是最终答案。")
    }

    func testMiniMaxBridgeStreamsReasoningBeforeVisibleAnswer() async throws {
        let upstreamResponse = try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl_minimax_stream",
            "model": "MiniMax-M2.7",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "reasoning_details": [
                            [
                                "text": "先整理上下文。",
                            ],
                        ],
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
            baseURL: "https://api.minimax.io/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            apiKey: "sk-minimax-test",
            model: "MiniMax-M2.7",
            availableModels: ["MiniMax-M2.7"]
        )

        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/responses")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "MiniMax-M2.7",
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
        XCTAssertTrue(text.contains("event: response.reasoning_summary_part.added"))
        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.done"))
        XCTAssertTrue(text.contains("\"type\":\"reasoning\""))
        XCTAssertTrue(text.contains("event: response.output_text.delta"))
        XCTAssertTrue(text.contains("\"text\":\"嗨。\""))
        XCTAssertTrue(text.contains("event: response.completed"))
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
