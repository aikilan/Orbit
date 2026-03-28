import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class CodexOAuthClaudeBridgeManagerTests: XCTestCase {
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
            model: "gpt-5.4"
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
}
