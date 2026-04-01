import Foundation
import XCTest
@testable import Orbit

final class CodexInstanceLauncherTests: XCTestCase {
    func testLaunchIsolatedInstanceWritesAuthFileAndStartsCodexWithIsolatedDirectories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let appURL = root.appendingPathComponent("Codex.app", isDirectory: true)
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: false)

        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        var capturedExecutableURL: URL?
        var capturedArguments: [String] = []
        var capturedEnvironment: [String: String] = [:]

        let launcher = CodexInstanceLauncher(
            fileManager: fileManager,
            resolveAppURL: { appURL },
            runProcess: { executableURL, arguments, environment in
                capturedExecutableURL = executableURL
                capturedArguments = arguments
                capturedEnvironment = environment
            }
        )

        let account = ManagedAccount(
            id: UUID(),
            codexAccountID: "acct_launch",
            displayName: "Launch User",
            email: "launch@example.com",
            authMode: .chatgpt,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
        let payload = CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id_launch",
                accessToken: "access_launch",
                refreshToken: "refresh_launch",
                accountID: "acct_launch"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )

        let paths = try launcher.launchIsolatedInstance(
            for: account,
            payload: payload,
            appSupportDirectoryURL: appSupport
        )

        XCTAssertEqual(capturedExecutableURL, executableURL)
        XCTAssertEqual(capturedArguments, ["--user-data-dir=\(paths.userDataURL.path)"])
        XCTAssertEqual(capturedEnvironment["CODEX_HOME"], paths.codexHomeURL.path)

        let savedPayload = try XCTUnwrap(try AuthFileManager(
            authFileURL: paths.codexHomeURL.appendingPathComponent("auth.json")
        ).readCurrentAuth())
        XCTAssertEqual(savedPayload, payload)
    }

    func testLaunchIsolatedInstanceThrowsWhenCodexAppMissing() {
        let launcher = CodexInstanceLauncher(resolveAppURL: { nil })
        let account = ManagedAccount(
            id: UUID(),
            codexAccountID: "acct_missing",
            displayName: "Missing App",
            email: nil,
            authMode: .apiKey,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: false
        )
        let payload = CodexAuthPayload(authMode: .apiKey, openAIAPIKey: "sk-test-missing")
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(
            try launcher.launchIsolatedInstance(for: account, payload: payload, appSupportDirectoryURL: appSupport)
        ) { error in
            XCTAssertEqual(error as? CodexInstanceLauncherError, .applicationNotFound)
        }
    }

    func testLaunchIsolatedInstanceWritesManagedProviderFilesAndEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Codex.app", isDirectory: true)
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: false)
        let codexHomeURL = root
            .appendingPathComponent("isolated-codex-instances", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)

        try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        var capturedArguments: [String] = []
        var capturedEnvironment: [String: String] = [:]

        let launcher = CodexInstanceLauncher(
            fileManager: fileManager,
            resolveAppURL: { appURL },
            runProcess: { _, arguments, environment in
                capturedArguments = arguments
                capturedEnvironment = environment
            }
        )

        let context = ResolvedCodexDesktopLaunchContext(
            accountID: UUID(),
            codexHomeURL: codexHomeURL,
            authPayload: nil,
            modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["deepseek-chat", "deepseek-reasoner"]),
            configFileContents: """
            model = "deepseek-chat"
            model_provider = "deepseek"

            [model_providers.deepseek]
            name = "DeepSeek"
            base_url = "http://127.0.0.1:18082"
            env_key = "OPENAI_API_KEY"
            wire_api = "responses"
            """,
            environmentVariables: ["OPENAI_API_KEY": "provider-key"]
        )

        let paths = try launcher.launchIsolatedInstance(context: context)

        XCTAssertEqual(capturedArguments, ["--user-data-dir=\(paths.userDataURL.path)"])
        XCTAssertEqual(capturedEnvironment["CODEX_HOME"], codexHomeURL.path)
        XCTAssertEqual(capturedEnvironment["OPENAI_API_KEY"], "provider-key")
        XCTAssertFalse(fileManager.fileExists(atPath: codexHomeURL.appendingPathComponent("auth.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: codexHomeURL.appendingPathComponent("config.toml").path))
        XCTAssertTrue(fileManager.fileExists(atPath: codexHomeURL.appendingPathComponent("model-catalog.json").path))

        let configContents = try String(contentsOf: codexHomeURL.appendingPathComponent("config.toml"), encoding: .utf8)
        let catalogContents = try String(contentsOf: codexHomeURL.appendingPathComponent("model-catalog.json"), encoding: .utf8)
        XCTAssertTrue(configContents.contains("model_provider = \"deepseek\""))
        XCTAssertTrue(configContents.contains("model_catalog_json = "))
        XCTAssertTrue(catalogContents.contains("\"slug\" : \"deepseek-chat\""))
        XCTAssertTrue(catalogContents.contains("\"slug\" : \"deepseek-reasoner\""))
    }
}
