import Foundation
import XCTest
@testable import Orbit

final class CodexCLILauncherTests: XCTestCase {
    func testLaunchCLIGlobalModeRunsPlainCodexCommand() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let workingDirectoryURL = rootURL.appendingPathComponent("workspace", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedCodexCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                mode: .globalCurrentAuth,
                codexHomeURL: nil,
                authPayload: nil,
                modelCatalogSnapshot: nil,
                configFileContents: nil,
                environmentVariables: [:],
                arguments: []
            )
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIIsolatedModeWritesAuthAndRunsWithIsolatedCodexHome() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let payload = makePayload(accountID: "acct_cli", refreshToken: "refresh_cli")
        let workingDirectoryURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedCodexCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: payload,
                modelCatalogSnapshot: nil,
                configFileContents: "model = \"gpt-5.4\"\n",
                environmentVariables: ["OPENROUTER_API_KEY": "sk-or-test"],
                arguments: []
            )
        )

        let savedPayload = try XCTUnwrap(
            try AuthFileManager(authFileURL: codexHomeURL.appendingPathComponent("auth.json")).readCurrentAuth()
        )
        XCTAssertEqual(savedPayload, payload)
        XCTAssertEqual(
            try String(contentsOf: codexHomeURL.appendingPathComponent("config.toml")),
            "model = \"gpt-5.4\"\n"
        )
        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env CODEX_HOME=\\\"\(codexHomeURL.path)\\\" OPENROUTER_API_KEY=\\\"sk-or-test\\\" codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIIsolatedModeWritesManagedModelCatalogAndConfigEntry() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let workingDirectoryURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent("codex-home", isDirectory: true)

        try launcher.launchCLI(
            context: ResolvedCodexCLILaunchContext(
                accountID: UUID(),
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: nil,
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(
                    availableModels: ["deepseek-chat", "deepseek-reasoner", "deepseek-chat"]
                ),
                configFileContents: """
                model = "deepseek-chat"
                model_provider = "deepseek"

                [model_providers.deepseek]
                name = "DeepSeek"
                base_url = "http://127.0.0.1:18082"
                env_key = "OPENAI_API_KEY"
                wire_api = "responses"
                """,
                environmentVariables: ["OPENAI_API_KEY": "sk-deepseek-test"],
                arguments: []
            )
        )

        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        let catalogURL = codexHomeURL.appendingPathComponent("model-catalog.json")
        let configContents = try String(contentsOf: configURL)
        let expectedConfigContents = """
        model = "deepseek-chat"
        model_provider = "deepseek"
        model_catalog_json = "\(catalogURL.path)"

        [model_providers.deepseek]
        name = "DeepSeek"
        base_url = "http://127.0.0.1:18082"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
        """
        XCTAssertEqual(configContents, expectedConfigContents)
        let modelCatalogIndex = try XCTUnwrap(configContents.range(of: "model_catalog_json")?.lowerBound)
        let providerTableIndex = try XCTUnwrap(configContents.range(of: "[model_providers.deepseek]")?.lowerBound)
        XCTAssertLessThan(modelCatalogIndex, providerTableIndex)

        let catalogData = try Data(contentsOf: catalogURL)
        let catalogObject = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let models = try XCTUnwrap(catalogObject["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.compactMap { $0["slug"] as? String }, ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertEqual(models.compactMap { $0["display_name"] as? String }, ["deepseek-chat", "deepseek-reasoner"])

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"cd \\\"\(workingDirectoryURL.path)\\\" && env CODEX_HOME=\\\"\(codexHomeURL.path)\\\" OPENAI_API_KEY=\\\"sk-deepseek-test\\\" codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIPropagatesAppleScriptFailure() {
        let fileManager = FileManager.default
        let appSupport = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { _ in
                throw TestError.appleScriptFailed
            }
        )

        XCTAssertThrowsError(
            try launcher.launchCLI(
                context: ResolvedCodexCLILaunchContext(
                    accountID: UUID(),
                    workingDirectoryURL: appSupport,
                    mode: .globalCurrentAuth,
                    codexHomeURL: nil,
                    authPayload: nil,
                    modelCatalogSnapshot: nil,
                    configFileContents: nil,
                    environmentVariables: [:],
                    arguments: []
                )
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .appleScriptFailed)
        }
    }

    private func makePayload(accountID: String, refreshToken: String) -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id_\(accountID)",
                accessToken: "access_\(accountID)",
                refreshToken: refreshToken,
                accountID: accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }
}

private enum TestError: Error, Equatable {
    case appleScriptFailed
}
