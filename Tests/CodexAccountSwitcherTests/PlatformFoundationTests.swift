import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class PlatformFoundationTests: XCTestCase {
    func testOpenAICompatiblePresetListIncludesDeepSeek() {
        XCTAssertTrue(
            ProviderCatalog.presets(for: .openAICompatible).contains(where: { $0.id == "deepseek" })
        )
    }

    func testOpenAICompatiblePresetListIncludesZhipuDomesticAndOverseas() {
        let presetIDs = Set(ProviderCatalog.presets(for: .openAICompatible).map(\.id))

        XCTAssertTrue(presetIDs.contains("zai"))
        XCTAssertTrue(presetIDs.contains("bigmodel"))
    }

    func testSupportsResponsesAPIDetectsZhipuAndZAIAsChatCompletionsOnly() {
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: "zai",
                baseURL: "https://api.z.ai/api/coding/paas/v4"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: "bigmodel",
                baseURL: "https://open.bigmodel.cn/api/coding/paas/v4"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: ProviderCatalog.customPresetID,
                baseURL: "https://open.bigmodel.cn/api/coding/paas/v4"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: ProviderCatalog.customPresetID,
                baseURL: "https://api.z.ai/api/coding/paas/v4"
            )
        )
    }

    func testLegacyDatabaseDecodesAccountsAsCodexAndBumpsVersion() throws {
        let accountID = UUID()
        let json = """
        {
          "version": 2,
          "accounts": [
            {
              "id": "\(accountID.uuidString)",
              "codexAccountID": "acct_legacy",
              "displayName": "Legacy User",
              "email": "legacy@example.com",
              "authMode": "chatgpt",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "switchLogs": [],
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))

        XCTAssertEqual(database.version, AppDatabase.currentVersion)
        XCTAssertEqual(database.accounts.count, 1)
        XCTAssertEqual(database.accounts.first?.platform, .codex)
    }

    func testLegacyCLIWorkingDirectoriesMigrateToLaunchHistory() throws {
        let accountID = UUID()
        let path = "/tmp/workspace"
        let json = """
        {
          "version": 4,
          "accounts": [
            {
              "id": "\(accountID.uuidString)",
              "platform": "codex",
              "accountIdentifier": "acct_legacy",
              "displayName": "Legacy User",
              "email": "legacy@example.com",
              "authKind": "chatgpt",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "claudeRateLimitSnapshots": {},
          "switchLogs": [],
          "cliWorkingDirectoriesByAccountID": {
            "\(accountID.uuidString)": ["\(path)"]
          },
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))
        let history = database.cliLaunchHistory(for: accountID)

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.path, path)
        XCTAssertEqual(history.first?.target, .codex)
        XCTAssertEqual(database.defaultCLITarget(for: try XCTUnwrap(database.account(id: accountID))), .codex)
    }

    func testLegacyDefaultEnvironmentMigratesToDefaultTarget() throws {
        let accountID = UUID()
        let json = """
        {
          "version": 5,
          "accounts": [
            {
              "id": "\(accountID.uuidString)",
              "platform": "claude",
              "accountIdentifier": "acct_legacy_claude",
              "displayName": "Legacy Claude",
              "email": null,
              "authKind": "claude_profile",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "claudeRateLimitSnapshots": {},
          "switchLogs": [],
          "cliEnvironmentProfiles": [
            {
              "id": "legacy-claude-env",
              "displayName": "Legacy Claude",
              "target": "claude",
              "isBuiltIn": false,
              "claude": {
                "model": "claude-sonnet-4.5",
                "providerBaseURL": "https://proxy.example/v1",
                "apiKeyEnvName": "ANTHROPIC_API_KEY",
                "apiKey": "sk-ant-test",
                "contextLimit": 200000,
                "useAccountCredentials": false
              }
            }
          ],
          "defaultCLIEnvironmentIDByAccountID": {},
          "cliLaunchHistoryByAccountID": {},
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))
        let account = try XCTUnwrap(database.account(id: accountID))

        XCTAssertEqual(database.version, AppDatabase.currentVersion)
        XCTAssertEqual(database.defaultCLITarget(for: account), .claude)
    }

    func testLegacyAPIKeyAccountsMigrateToProviderAccounts() throws {
        let openAIAccountID = UUID()
        let anthropicAccountID = UUID()
        let json = """
        {
          "version": 7,
          "accounts": [
            {
              "id": "\(openAIAccountID.uuidString)",
              "platform": "codex",
              "accountIdentifier": "acct_openai",
              "displayName": "OpenAI Legacy",
              "email": "sk-...openai",
              "authKind": "api_key",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            },
            {
              "id": "\(anthropicAccountID.uuidString)",
              "platform": "claude",
              "accountIdentifier": "acct_anthropic",
              "displayName": "Anthropic Legacy",
              "email": "sk-...anthropic",
              "authKind": "anthropic_api_key",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "claudeRateLimitSnapshots": {},
          "switchLogs": [],
          "cliLaunchHistoryByAccountID": {},
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))
        let openAIAccount = try XCTUnwrap(database.account(id: openAIAccountID))
        let anthropicAccount = try XCTUnwrap(database.account(id: anthropicAccountID))

        XCTAssertEqual(openAIAccount.authKind, .providerAPIKey)
        XCTAssertEqual(openAIAccount.providerRule, .openAICompatible)
        XCTAssertEqual(openAIAccount.providerPresetID, "openai")
        XCTAssertEqual(openAIAccount.defaultModel, "gpt-5.4")
        XCTAssertEqual(openAIAccount.defaultCLITarget, .codex)

        XCTAssertEqual(anthropicAccount.authKind, .providerAPIKey)
        XCTAssertEqual(anthropicAccount.providerRule, .claudeCompatible)
        XCTAssertEqual(anthropicAccount.providerPresetID, "anthropic")
        XCTAssertEqual(anthropicAccount.defaultModel, "claude-sonnet-4.5")
        XCTAssertEqual(anthropicAccount.defaultCLITarget, .claude)
    }

    func testLegacyDefaultCodexEnvironmentMigratesToCodexTarget() throws {
        let accountID = UUID()
        let json = """
        {
          "version": 6,
          "accounts": [
            {
              "id": "\(accountID.uuidString)",
              "platform": "codex",
              "accountIdentifier": "acct_legacy",
              "displayName": "Legacy User",
              "email": "legacy@example.com",
              "authKind": "chatgpt",
              "createdAt": "2026-03-25T10:00:00Z",
              "isActive": false
            }
          ],
          "quotaSnapshots": {},
          "claudeRateLimitSnapshots": {},
          "switchLogs": [],
          "cliEnvironmentProfiles": [
            {
              "id": "custom-codex",
              "displayName": "Custom Codex",
              "target": "codex",
              "isBuiltIn": false,
              "codex": {
                "model": "openrouter/anthropic/claude-sonnet-4.5",
                "modelProvider": "openrouter",
                "useAccountCredentials": false,
                "customProvider": {
                  "identifier": "openrouter",
                  "displayName": "OpenRouter",
                  "baseURL": "https://openrouter.ai/api/v1",
                  "envKey": "OPENROUTER_API_KEY",
                  "apiKey": "sk-or-test",
                  "wireAPI": "responses"
                }
              }
            }
          ],
          "defaultCLIEnvironmentIDByAccountID": {
            "\(accountID.uuidString)": "custom-codex"
          },
          "cliLaunchHistoryByAccountID": {},
          "activeAccountID": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let database = try decoder.decode(AppDatabase.self, from: Data(json.utf8))
        let account = try XCTUnwrap(database.account(id: accountID))

        XCTAssertEqual(database.version, AppDatabase.currentVersion)
        XCTAssertEqual(database.defaultCLITarget(for: account), .codex)
    }

    func testAppPathsMigratesLegacySupportDirectoryWhenNewDirectoryMissing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let legacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let legacyDatabase = legacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL.lastPathComponent, "LLMAccountSwitcher")
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacySupport.path))
    }

    func testAppPathsPrefersNewSupportDirectoryWhenBothDirectoriesExist() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let legacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let newSupport = root.appendingPathComponent("LLMAccountSwitcher", isDirectory: true)
        let newDatabase = newSupport.appendingPathComponent("accounts.json")
        let legacyDatabase = legacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newSupport, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDatabase)
        try Data("new".utf8).write(to: newDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL, newSupport)
        XCTAssertEqual(try String(contentsOf: newDatabase), "new")
        XCTAssertEqual(try String(contentsOf: legacyDatabase), "legacy")
    }
}
