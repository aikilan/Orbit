import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class CodexCLILauncherTests: XCTestCase {
    func testLaunchCLIGlobalModeRunsPlainCodexCommand() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )

        try launcher.launchCLI(
            for: makeAccount(),
            mode: .globalCurrentAuth,
            appSupportDirectoryURL: appSupport
        )

        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"codex\"",
                "end tell",
            ]
        )
    }

    func testLaunchCLIIsolatedModeWritesAuthAndRunsWithIsolatedCodexHome() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        var capturedLines: [String] = []
        let launcher = CodexCLILauncher(
            fileManager: fileManager,
            runAppleScript: { lines in
                capturedLines = lines
            }
        )
        let account = makeAccount()
        let payload = makePayload(accountID: "acct_cli", refreshToken: "refresh_cli")
        let codexHomeURL = appSupport
            .appendingPathComponent("isolated-codex-instances", isDirectory: true)
            .appendingPathComponent(account.id.uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)

        try launcher.launchCLI(
            for: account,
            mode: .isolatedAccount(payload: payload),
            appSupportDirectoryURL: appSupport
        )

        let savedPayload = try XCTUnwrap(
            try AuthFileManager(authFileURL: codexHomeURL.appendingPathComponent("auth.json")).readCurrentAuth()
        )
        XCTAssertEqual(savedPayload, payload)
        XCTAssertEqual(
            capturedLines,
            [
                "tell application \"Terminal\"",
                "activate",
                "do script \"env CODEX_HOME=\\\"\(codexHomeURL.path)\\\" codex\"",
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
                for: makeAccount(),
                mode: .globalCurrentAuth,
                appSupportDirectoryURL: appSupport
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .appleScriptFailed)
        }
    }

    private func makeAccount() -> ManagedAccount {
        ManagedAccount(
            id: UUID(),
            codexAccountID: "acct_cli",
            displayName: "CLI User",
            email: "cli@example.com",
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
