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
}
