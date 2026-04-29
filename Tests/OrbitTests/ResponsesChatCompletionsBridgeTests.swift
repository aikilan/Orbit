import Foundation
import XCTest
@testable import Orbit

final class ResponsesChatCompletionsBridgeTests: XCTestCase {
    func testCopilotACPStreamEventParserEmitsDeltasForCumulativeUpdates() throws {
        var parser = CopilotACPStreamEventParser()

        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先")),
            [.reasoningDelta("先")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先检查")),
            [.reasoningDelta("检查")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "thought", content: "先检查")),
            []
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "message", content: "完成")),
            [.messageDelta("完成")]
        )
        XCTAssertEqual(
            parser.consume(data: try acpUpdate(sessionUpdate: "message", content: "完成。")),
            [.messageDelta("。")]
        )

        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call_1",
                    "title": "Shell",
                    "rawInput": ["command": "pwd"],
                ])
            ),
            [
                .toolCall(
                    CopilotACPToolCall(
                        callID: "call_1",
                        name: "Shell",
                        arguments: #"{"command":"pwd"}"#,
                        outputText: nil
                    )
                ),
            ]
        )
        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call_1",
                    "rawOutput": "/tmp",
                ])
            ),
            [.toolCallOutput(callID: "call_1", output: "/tmp")]
        )
        XCTAssertEqual(
            parser.consume(
                data: try acpUpdate([
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call_1",
                    "rawOutput": "/tmp/project",
                ])
            ),
            [.toolCallOutput(callID: "call_1", output: "/project")]
        )
    }

    func testCopilotResponsesStreamEncoderEmitsLiveEvents() throws {
        var encoder = CopilotResponsesStreamEncoder(responseID: "resp_test", model: "gpt-4.1")
        var data = Data()

        data.append(encoder.startData())
        data.append(encoder.encode(event: .reasoningDelta("先检查。")))
        data.append(
            encoder.encode(
                event: .toolCall(
                    CopilotACPToolCall(
                        callID: "call_1",
                        name: "Shell",
                        arguments: #"{"command":"pwd"}"#,
                        outputText: nil
                    )
                )
            )
        )
        data.append(encoder.encode(event: .toolCallOutput(callID: "call_1", output: "/tmp/project")))
        data.append(encoder.encode(event: .messageDelta("完成。")))
        data.append(encoder.completeData())

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("event: response.created"))
        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""type":"function_call_output""#))
        XCTAssertTrue(text.contains("event: response.output_text.delta"))
        XCTAssertTrue(text.contains("event: response.completed"))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testMakeResponseStreamDataIncludesFunctionCallOutputItems() throws {
        let response: [String: Any] = [
            "id": "resp_copilot",
            "object": "response",
            "model": "gpt-5.3-codex",
            "output": [
                [
                    "id": "rs_1",
                    "type": "reasoning",
                    "summary": [[
                        "type": "summary_text",
                        "text": "先检查工作目录。",
                    ]],
                ],
                [
                    "id": "fc_1",
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "Print working directory",
                    "arguments": #"{"command":"pwd"}"#,
                ],
                [
                    "id": "fco_1",
                    "type": "function_call_output",
                    "call_id": "call_1",
                    "output": "/tmp/project",
                ],
                [
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "content": [[
                        "type": "output_text",
                        "text": "目录是 /tmp/project。",
                    ]],
                ],
            ],
            "usage": [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0,
            ],
        ]

        let data = ResponsesChatCompletionsBridge.makeResponseStreamData(from: response)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("event: response.reasoning_summary_text.done"))
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""type":"function_call_output""#))
        XCTAssertTrue(text.contains(#""call_id":"call_1""#))
        XCTAssertTrue(text.contains(#""output":"\/tmp\/project""#))
        XCTAssertTrue(text.contains("event: response.completed"))
    }

    func testMakeResponsesResponseDataExtractsTextToolCallBlocks() throws {
        let patch = """
        *** Begin Patch
        *** Update File: src/modules/bd-ai-import-questions/components/actions-bar/index.module.less
        @@
        -.wrapper {
        -}
        +.wrapper {
        +    width: 100%;
        +}
        *** End Patch
        """
        let upstreamResponse: [String: Any] = [
            "id": "chatcmpl_text_tool",
            "model": "custom-openai-compatible",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": """
                        样式文件是空的，需要补上。
                        <tool_call>
                        <function=apply_patch>
                        <parameter=patch>\(patch)</parameter>
                        </function>
                        </tool_call>
                        """,
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 1,
                "completion_tokens": 1,
                "total_tokens": 2,
            ],
        ]

        let upstreamData = try JSONSerialization.data(withJSONObject: upstreamResponse)
        let responseData = try ResponsesChatCompletionsBridge.makeResponsesResponseData(
            from: upstreamData,
            fallbackModel: "custom-openai-compatible"
        )
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        let message = try XCTUnwrap(output.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let toolCall = try XCTUnwrap(output.last)
        let arguments = try XCTUnwrap(toolCall["arguments"] as? String)
        let argumentObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])

        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(message["type"] as? String, "message")
        XCTAssertEqual(content.first?["text"] as? String, "样式文件是空的，需要补上。")
        XCTAssertEqual(toolCall["type"] as? String, "function_call")
        XCTAssertEqual(toolCall["name"] as? String, "apply_patch")
        XCTAssertEqual(argumentObject["patch"] as? String, patch)

        let streamText = try XCTUnwrap(
            String(data: ResponsesChatCompletionsBridge.makeResponseStreamData(from: response), encoding: .utf8)
        )
        XCTAssertTrue(streamText.contains("event: response.function_call_arguments.done"))
        XCTAssertTrue(streamText.contains("apply_patch"))
        XCTAssertFalse(streamText.contains("<tool_call>"))
    }

    func testMakeChatCompletionsRequestDataForwardsSupportedMediaParts() throws {
        let request: [String: Any] = [
            "model": "mimo-v2.5",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "看一下附件",
                        ],
                        [
                            "type": "input_image",
                            "image_url": "data:image/png;base64,aaa",
                        ],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": "https://example.test/audio.mp3",
                            ],
                        ],
                        [
                            "type": "video_url",
                            "video_url": [
                                "url": "https://example.test/video.mp4",
                                "media_resolution": "low",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        let data = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: requestData,
            fallbackModel: "mimo-v2.5"
        )
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        let inputAudio = try XCTUnwrap(content[2]["input_audio"] as? [String: Any])
        let videoURL = try XCTUnwrap(content[3]["video_url"] as? [String: Any])

        XCTAssertEqual(content.count, 4)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "看一下附件")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,aaa")
        XCTAssertEqual(content[2]["type"] as? String, "input_audio")
        XCTAssertEqual(inputAudio["data"] as? String, "https://example.test/audio.mp3")
        XCTAssertEqual(content[3]["type"] as? String, "video_url")
        XCTAssertEqual(videoURL["url"] as? String, "https://example.test/video.mp4")
        XCTAssertEqual(videoURL["media_resolution"] as? String, "low")
    }

    func testMakeChatCompletionsRequestDataDoesNotForwardUnsupportedInputFileParts() throws {
        let request: [String: Any] = [
            "model": "mimo-v2.5-pro",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "请参考附件",
                        ],
                        [
                            "type": "input_file",
                            "file_id": "file_123",
                        ],
                    ],
                ],
            ],
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        let data = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: requestData,
            fallbackModel: "mimo-v2.5-pro"
        )
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        let bodyText = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(content, "请参考附件")
        XCTAssertFalse(bodyText.contains("input_file"))
        XCTAssertFalse(bodyText.contains("file_123"))
    }

    func testMakeChatCompletionsRequestDataConvertsInputFileFileDataMediaParts() throws {
        let request: [String: Any] = [
            "model": "mimo-v2.5",
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
                        [
                            "type": "input_file",
                            "filename": "voice.wav",
                            "file_data": "data:audio/wav;base64,bbb",
                        ],
                        [
                            "type": "input_file",
                            "filename": "demo.mp4",
                            "file_data": "data:video/mp4;base64,ccc",
                        ],
                    ],
                ],
            ],
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        let data = try ResponsesChatCompletionsBridge.makeChatCompletionsRequestData(
            from: requestData,
            fallbackModel: "mimo-v2.5"
        )
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        let inputAudio = try XCTUnwrap(content[2]["input_audio"] as? [String: Any])
        let videoURL = try XCTUnwrap(content[3]["video_url"] as? [String: Any])

        XCTAssertEqual(content.count, 4)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,aaa")
        XCTAssertEqual(content[2]["type"] as? String, "input_audio")
        XCTAssertEqual(inputAudio["data"] as? String, "data:audio/wav;base64,bbb")
        XCTAssertEqual(content[3]["type"] as? String, "video_url")
        XCTAssertEqual(videoURL["url"] as? String, "data:video/mp4;base64,ccc")
    }

    private func acpUpdate(sessionUpdate: String, content: String) throws -> Data {
        try acpUpdate([
            "sessionUpdate": sessionUpdate,
            "content": content,
        ])
    }

    private func acpUpdate(_ update: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "update": update,
                ],
            ],
            options: []
        )
    }
}
