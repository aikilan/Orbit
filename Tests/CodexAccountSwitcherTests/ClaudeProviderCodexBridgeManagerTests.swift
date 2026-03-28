import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class ClaudeProviderCodexBridgeManagerTests: XCTestCase {
    func testMakeClaudeProviderUpstreamRequestUsesXAPIKeyForStandardAnthropicProvider() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-test",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMakeClaudeProviderUpstreamRequestUsesAuthorizationForMiniMaxAnthropicProvider() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.minimax.io/anthropic",
            apiKey: "sk-minimax-test",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.minimax.io/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-minimax-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMakeClaudeProviderUpstreamRequestNormalizesMiniMaxAnthropicV1BaseURL() throws {
        let request = makeClaudeProviderUpstreamRequest(
            baseURL: "https://api.minimaxi.com/anthropic/v1",
            apiKey: "sk-minimax-cn",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.minimaxi.com/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-minimax-cn")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testModelsEndpointReturnsAvailableModelsAndAppendsDefaultModel() async throws {
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: ["claude-opus-4.1", "claude-sonnet-4"]
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/v1/models")))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["claude-opus-4.1", "claude-sonnet-4", "claude-sonnet-4.5"])
    }

    func testModelsEndpointFallsBackToSingleDefaultModel() async throws {
        let manager = ClaudeProviderCodexBridgeManager(
            sendUpstreamRequest: { _, _, _ in
                XCTFail("不应该触发上游请求")
                return (200, Data("{}".utf8))
            }
        )

        let bridge = try await manager.prepareBridge(
            accountID: UUID(),
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4.5",
            availableModels: []
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "\(bridge.baseURL)/models")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["claude-sonnet-4.5"])
    }
}
