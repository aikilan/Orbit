import Foundation
import XCTest
@testable import Orbit

final class ClaudeCLILauncherTests: XCTestCase {
    func testLaunchCLIUsesExecutableOverrideWhenProvided() throws {
        let fileManager = LauncherTestFileManager()
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileManager.mockHomeDirectory = homeURL

        var capturedLines: [String] = []
        let launcher = ClaudeCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )

        let rootURL = homeURL.appendingPathComponent("isolated-root", isDirectory: true)
        let workingDirectoryURL = homeURL.appendingPathComponent("workspace", isDirectory: true)
        let executableOverrideURL = homeURL.appendingPathComponent("patched-runtime/bin/claude", isDirectory: false)

        try launcher.launchCLI(
            context: ResolvedClaudeCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                rootURL: rootURL,
                configDirectoryURL: rootURL.appendingPathComponent(".claude", isDirectory: true),
                executableOverrideURL: executableOverrideURL,
                providerSnapshot: ResolvedClaudeProviderSnapshot(
                    source: .explicitProvider,
                    model: "claude-sonnet-4.5",
                    modelProvider: "openrouter",
                    baseURL: "https://proxy.example/v1",
                    apiKeyEnvName: "ANTHROPIC_API_KEY",
                    availableModels: ["deepseek-chat", "deepseek-reasoner"]
                ),
                environmentVariables: [
                    "ANTHROPIC_API_KEY": "sk-ant-test",
                    "ANTHROPIC_BASE_URL": "https://proxy.example/v1",
                ],
                arguments: ["--model", "claude-sonnet-4.5"]
            )
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env ANTHROPIC_API_KEY=\\\"sk-ant-test\\\" ANTHROPIC_BASE_URL=\\\"https://proxy.example/v1\\\" CLAUDE_CONFIG_DIR=\\\"\(rootURL.appendingPathComponent(".claude").path)\\\" HOME=\\\"\(rootURL.path)\\\" \\\"\(executableOverrideURL.path)\\\" \\\"--model\\\" \\\"claude-sonnet-4.5\\\"\"",
                "end tell",
            ]
        )

        let settingsURL = rootURL.appendingPathComponent(".claude/settings.json", isDirectory: false)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "claude-sonnet-4.5")
        XCTAssertEqual(object["availableModels"] as? [String], ["deepseek-chat", "deepseek-reasoner", "claude-sonnet-4.5"])
    }

    func testLaunchCLIUsesResolvedExecutableWhenOverrideIsNil() throws {
        let fileManager = LauncherTestFileManager()
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileManager.mockHomeDirectory = homeURL

        var capturedLines: [String] = []
        let launcher = ClaudeCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            },
            resolveClaudeExecutable: { _ in
                URL(fileURLWithPath: "/opt/claude/bin/claude", isDirectory: false)
            }
        )

        let rootURL = homeURL.appendingPathComponent("isolated-root", isDirectory: true)
        let workingDirectoryURL = homeURL.appendingPathComponent("workspace", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedClaudeCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                rootURL: rootURL,
                configDirectoryURL: rootURL.appendingPathComponent(".claude", isDirectory: true),
                executableOverrideURL: nil,
                providerSnapshot: ResolvedClaudeProviderSnapshot(
                    source: .inheritCodexEnvironment,
                    model: "gpt-5.4",
                    modelProvider: "openai",
                    baseURL: "http://127.0.0.1:18080",
                    apiKeyEnvName: "ANTHROPIC_API_KEY",
                    availableModels: ["gpt-5.4"]
                ),
                environmentVariables: [
                    "ANTHROPIC_API_KEY": "codex-oauth-bridge",
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:18080",
                ],
                arguments: ["--model", "gpt-5.4"]
            )
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env ANTHROPIC_API_KEY=\\\"codex-oauth-bridge\\\" ANTHROPIC_BASE_URL=\\\"http://127.0.0.1:18080\\\" CLAUDE_CONFIG_DIR=\\\"\(rootURL.appendingPathComponent(".claude").path)\\\" HOME=\\\"\(rootURL.path)\\\" \\\"/opt/claude/bin/claude\\\" \\\"--model\\\" \\\"gpt-5.4\\\"\"",
                "end tell",
            ]
        )

        let settingsURL = rootURL.appendingPathComponent(".claude/settings.json", isDirectory: false)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        XCTAssertEqual(object["availableModels"] as? [String], ["gpt-5.4"])
    }
}

private final class LauncherTestFileManager: FileManager {
    var mockHomeDirectory = FileManager.default.homeDirectoryForCurrentUser

    override var homeDirectoryForCurrentUser: URL {
        mockHomeDirectory
    }
}
