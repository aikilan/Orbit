import Foundation
import XCTest
@testable import Orbit

final class PlatformFoundationTests: XCTestCase {
    func testOpenAICompatiblePresetListIncludesDeepSeek() {
        XCTAssertTrue(
            ProviderCatalog.presets(for: .openAICompatible).contains(where: { $0.id == "deepseek" })
        )
        XCTAssertFalse(
            ProviderCatalog.presets(for: .openAICompatible).contains(where: { $0.id == "openrouter" })
        )
    }

    func testOpenAICompatiblePresetListIncludesMoonshot() {
        XCTAssertTrue(
            ProviderCatalog.presets(for: .openAICompatible).contains(where: { $0.id == "moonshot" })
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: "moonshot",
                baseURL: "https://api.moonshot.cn/v1"
            )
        )
    }

    func testMiniMaxPresetListsIncludeDomesticAndOverseas() {
        let openAIPresetIDs = Set(ProviderCatalog.presets(for: .openAICompatible).map(\.id))
        let claudePresetIDs = Set(ProviderCatalog.presets(for: .claudeCompatible).map(\.id))

        XCTAssertTrue(openAIPresetIDs.contains("minimax"))
        XCTAssertTrue(openAIPresetIDs.contains("minimax_cn"))
        XCTAssertTrue(claudePresetIDs.contains("minimax_claude"))
        XCTAssertTrue(claudePresetIDs.contains("minimax_claude_cn"))
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

    func testSupportsResponsesAPIDetectsMoonshotAsChatCompletionsOnly() {
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: ProviderCatalog.customPresetID,
                baseURL: "https://api.moonshot.cn/v1"
            )
        )
    }

    func testSupportsResponsesAPIDetectsMiniMaxAsChatCompletionsOnly() {
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: "minimax",
                baseURL: "https://api.minimax.io/v1"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: "minimax_cn",
                baseURL: "https://api.minimaxi.com/v1"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: ProviderCatalog.customPresetID,
                baseURL: "https://api.minimax.io/v1"
            )
        )
        XCTAssertFalse(
            ProviderCatalog.supportsResponsesAPI(
                presetID: ProviderCatalog.customPresetID,
                baseURL: "https://api.minimaxi.com/v1"
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

    func testAppPathsMigratesLLMSupportDirectoryWhenOrbitDirectoryMissing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let legacySupport = root.appendingPathComponent("LLMAccountSwitcher", isDirectory: true)
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

        XCTAssertEqual(paths.appSupportDirectoryURL.lastPathComponent, "Orbit")
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacySupport.path))
    }

    func testAppPathsMigratesCodexSupportDirectoryWhenNewerLegacyDirectoryIsAbsent() throws {
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

        XCTAssertEqual(paths.appSupportDirectoryURL.lastPathComponent, "Orbit")
        XCTAssertTrue(fileManager.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacySupport.path))
    }

    func testAppPathsPrefersOrbitSupportDirectoryWhenItExists() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let codexLegacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let llmLegacySupport = root.appendingPathComponent("LLMAccountSwitcher", isDirectory: true)
        let orbitSupport = root.appendingPathComponent("Orbit", isDirectory: true)
        let newDatabase = orbitSupport.appendingPathComponent("accounts.json")
        let codexLegacyDatabase = codexLegacySupport.appendingPathComponent("accounts.json")
        let llmLegacyDatabase = llmLegacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexLegacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: llmLegacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: orbitSupport, withIntermediateDirectories: true)
        try Data("codex-legacy".utf8).write(to: codexLegacyDatabase)
        try Data("llm-legacy".utf8).write(to: llmLegacyDatabase)
        try Data("new".utf8).write(to: newDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL, orbitSupport)
        XCTAssertEqual(try String(contentsOf: newDatabase), "new")
        XCTAssertEqual(try String(contentsOf: codexLegacyDatabase), "codex-legacy")
        XCTAssertEqual(try String(contentsOf: llmLegacyDatabase), "llm-legacy")
    }

    func testAppPathsPrefersLLMSupportDirectoryWhenBothLegacyDirectoriesExist() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let codexLegacySupport = root.appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let llmLegacySupport = root.appendingPathComponent("LLMAccountSwitcher", isDirectory: true)
        let codexLegacyDatabase = codexLegacySupport.appendingPathComponent("accounts.json")
        let llmLegacyDatabase = llmLegacySupport.appendingPathComponent("accounts.json")

        defer {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexLegacySupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: llmLegacySupport, withIntermediateDirectories: true)
        try Data("codex-legacy".utf8).write(to: codexLegacyDatabase)
        try Data("llm-legacy".utf8).write(to: llmLegacyDatabase)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            applicationSupportRootOverride: root
        )

        XCTAssertEqual(paths.appSupportDirectoryURL.lastPathComponent, "Orbit")
        XCTAssertEqual(try String(contentsOf: paths.databaseURL), "llm-legacy")
        XCTAssertTrue(fileManager.fileExists(atPath: codexLegacyDatabase.path))
        XCTAssertFalse(fileManager.fileExists(atPath: llmLegacySupport.path))
    }
}
