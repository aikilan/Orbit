import Foundation
import XCTest
@testable import Orbit

@MainActor
final class AppViewModelTests: XCTestCase {
    nonisolated(unsafe) private var originalLanguagePreference: AppLanguagePreference?

    override func setUp() {
        super.setUp()
        originalLanguagePreference = L10n.currentLanguagePreference
        L10n.setLanguagePreference(.simplifiedChinese)
    }

    override func tearDown() {
        if let originalLanguagePreference {
            L10n.setLanguagePreference(originalLanguagePreference)
        }
        originalLanguagePreference = nil
        super.tearDown()
    }

    func testSwitchToAccountUsesRefreshedPayloadWhenRefreshSucceeds() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let refreshedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_new")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(
                refreshResult: .success(
                    AuthLoginResult(
                        payload: refreshedPayload,
                        identity: AuthIdentity(
                            accountID: "acct_cached",
                            displayName: "Refreshed User",
                            email: "refresh@example.com",
                            planType: "plus"
                        )
                    )
                )
            ),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.switchToAccount(account)

        XCTAssertEqual(harness.authFileManager.activatedPayloads.last?.tokens.refreshToken, "refresh_new")
        XCTAssertEqual(try harness.credentialStore.load(for: accountID).tokens.refreshToken, "refresh_new")
        XCTAssertEqual(harness.model.activeAccount?.id, accountID)
    }

    func testSwitchToAccountFallsBackToCachedPayloadWhenRefreshFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.switchToAccount(account)

        XCTAssertEqual(harness.authFileManager.activatedPayloads.last?.tokens.refreshToken, "refresh_old")
        XCTAssertTrue(harness.model.database.switchLogs.contains { $0.message.contains(L10n.tr("已回退本地缓存凭据")) })
    }

    func testSwitchToAccountOffersRestartActionWhenHotReloadNeedsRestart() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .authError(.refreshTokenReused), isRunning: true)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.switchToAccount(account)

        XCTAssertEqual(harness.model.banner?.action, .restartCodex)
        XCTAssertTrue(harness.model.shouldOfferRestartCodex(for: account))
        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertEqual(
            harness.model.restartPromptMessage,
            L10n.tr("auth.json 已更新，但运行中的 Codex 仍持有旧授权并触发 refresh_token_reused，建议重启 Codex。")
        )
    }

    func testSwitchToAccountRestartRecommendedWithoutMainInstanceOmitsRestartAction() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .restartRecommended, isRunning: false)

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.switchToAccount(account)

        XCTAssertNil(harness.model.banner?.action)
        XCTAssertFalse(harness.model.shouldOfferRestartCodex(for: account))
        XCTAssertFalse(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertNil(harness.model.restartPromptMessage)
    }

    func testSwitchToCopilotMainAccountPromptsRestartAndSyncsRealCodexHome() async throws {
        let currentAccountID = UUID()
        let copilotAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .verified, isRunning: true)
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential),
            statusResult: .success(
                CopilotAccountStatus(
                    availableModels: ["gpt-4.1", "claude-opus-4.1"],
                    currentModel: "gpt-4.1",
                    quotaSnapshot: nil
                )
            )
        )
        resolver.desktopContextResult = .success(
            ResolvedCodexDesktopLaunchContext(
                accountID: copilotAccountID,
                codexHomeURL: URL(fileURLWithPath: "/tmp/unused"),
                authPayload: nil,
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-4.1", "claude-opus-4.1"]),
                configFileContents: """
                model = "gpt-4.1"
                model_reasoning_effort = "high"
                model_provider = "github-copilot"

                [model_providers.github-copilot]
                name = "GitHub Copilot"
                wire_api = "responses"
                env_key = "GITHUB_TOKEN"
                """,
                environmentVariables: ["GITHUB_TOKEN": "copilot_access_token"]
            )
        )

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: currentAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let configURL = harness.model.paths.codex.homeURL.appendingPathComponent("config.toml")
        let authFileURL = harness.model.paths.codex.homeURL.appendingPathComponent("auth.json")
        let modelCatalogURL = harness.model.paths.codex.homeURL.appendingPathComponent("orbit-main-model-catalog.json")
        try "theme = \"dark\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        try "legacy-auth".write(to: authFileURL, atomically: true, encoding: .utf8)

        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))
        await harness.model.switchToAccount(account)

        let configContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccountID)
        XCTAssertEqual(harness.model.banner?.action, .restartCodex)
        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertEqual(
            harness.model.restartPromptMessage,
            L10n.tr("Codex 主实例配置已切换到账号 %@，需要重启 Codex 才会加载新的模型目录与凭据。", account.displayName)
        )
        XCTAssertTrue(configContents.contains("theme = \"dark\""))
        XCTAssertTrue(configContents.contains("# orbit-managed:start main-codex"))
        XCTAssertTrue(configContents.contains("model_provider = \"github-copilot\""))
        XCTAssertTrue(configContents.contains("orbit-main-model-catalog.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelCatalogURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authFileURL.path))
    }

    func testSwitchToProviderMainAccountPromptsRestartImmediately() async throws {
        let currentAccountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .verified, isRunning: true)
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopContextResult = .success(
            ResolvedCodexDesktopLaunchContext(
                accountID: providerAccountID,
                codexHomeURL: URL(fileURLWithPath: "/tmp/unused"),
                authPayload: nil,
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["deepseek-chat"]),
                configFileContents: """
                model = "deepseek-chat"
                model_reasoning_effort = "medium"
                model_provider = "deepseek"

                [model_providers.deepseek]
                name = "DeepSeek"
                wire_api = "responses"
                base_url = "https://api.deepseek.com/v1"
                env_key = "DEEPSEEK_API_KEY"
                """,
                environmentVariables: ["DEEPSEEK_API_KEY": "sk-deepseek"]
            )
        )
        let providerAccount = makeProviderAccount(
            id: providerAccountID,
            platform: .codex,
            identifier: "provider_deepseek",
            displayName: "DeepSeek Work",
            email: "deepseek@example.com",
            rule: .openAICompatible,
            presetID: "deepseek",
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            envName: "DEEPSEEK_API_KEY",
            model: "deepseek-chat"
        )

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: currentAccountID,
            extraSeeds: [
                AccountSeed(account: providerAccount, payload: try makeProviderCredential("sk-deepseek"), snapshot: nil)
            ],
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == providerAccountID }))

        await harness.model.switchToAccount(account)

        XCTAssertEqual(harness.model.activeAccount?.id, providerAccountID)
        XCTAssertEqual(harness.model.banner?.action, .restartCodex)
        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertEqual(
            harness.model.restartPromptMessage,
            L10n.tr("Codex 主实例配置已切换到账号 %@，需要重启 Codex 才会加载新的模型目录与凭据。", account.displayName)
        )
    }

    func testRestartVisibilityUsesCachedRuntimeState() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .verified, isRunning: true)

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: accountID
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let callCountAfterPrepare = runtimeInspector.hasRunningMainApplicationCallCount

        XCTAssertTrue(harness.model.canQuickRestartCodex)
        XCTAssertTrue(harness.model.canOperateMainCodexInstance(for: account))
        XCTAssertTrue(harness.model.canOperateFocusedMainCodexInstance)
        XCTAssertFalse(harness.model.shouldOfferRestartCodex(for: account))
        XCTAssertEqual(harness.model.mainCodexInstanceActionTitle, L10n.tr("重启 Codex 主实例"))
        XCTAssertEqual(harness.model.mainCodexInstanceActionInProgressTitle, L10n.tr("正在重启主实例..."))
        XCTAssertEqual(runtimeInspector.hasRunningMainApplicationCallCount, callCountAfterPrepare)

        runtimeInspector.setIsRunning(false)
        await harness.model.performBannerAction(.restartCodex)

        XCTAssertFalse(harness.model.canQuickRestartCodex)
        XCTAssertEqual(harness.model.mainCodexInstanceActionTitle, L10n.tr("启动 Codex 主实例"))
        XCTAssertEqual(harness.model.mainCodexInstanceActionInProgressTitle, L10n.tr("正在启动主实例..."))
    }

    func testMainCodexInstanceActionRequiresActiveCodexAccount() async throws {
        let accountID = UUID()
        let inactiveAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_active", refreshToken: "refresh_active")
        let inactivePayload = makePayload(accountID: "acct_inactive", refreshToken: "refresh_inactive")

        let inactiveCodexAccount = ManagedAccount(
            id: inactiveAccountID,
            platform: .codex,
            codexAccountID: inactivePayload.accountIdentifier,
            displayName: "Inactive Codex",
            email: "inactive@example.com",
            authMode: inactivePayload.authMode,
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
        let activeClaudeAccount = makeProviderAccount(
            id: UUID(),
            platform: .claude,
            identifier: "claude_active",
            displayName: "Claude Active",
            email: "claude@example.com",
            rule: .claudeCompatible,
            presetID: "claude",
            providerDisplayName: "Claude",
            baseURL: "https://api.anthropic.com",
            envName: "ANTHROPIC_API_KEY",
            model: "claude-sonnet-4",
            isActive: true
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified, isRunning: true),
            activeAccountID: accountID,
            extraSeeds: [
                AccountSeed(
                    account: inactiveCodexAccount,
                    payload: .codex(inactivePayload),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()
        let activeCodexAccount: ManagedAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == accountID }))
        let loadedInactiveCodexAccount: ManagedAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == inactiveAccountID }))

        XCTAssertTrue(harness.model.canOperateMainCodexInstance(for: activeCodexAccount))
        XCTAssertFalse(harness.model.canOperateMainCodexInstance(for: loadedInactiveCodexAccount))
        XCTAssertFalse(harness.model.canOperateMainCodexInstance(for: activeClaudeAccount))
    }

    func testRestartActionKeepsSwitchStateStableAcrossAwaitBoundaries() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(
            result: .authError(.refreshTokenReused),
            isRunning: true,
            hasRunningMainApplicationDelay: .milliseconds(50),
            restartDelay: .milliseconds(50),
            runningStateAfterRestart: false
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: accountID
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.switchToAccount(account)

        XCTAssertEqual(harness.model.banner?.action, .restartCodex)
        XCTAssertEqual(harness.model.restartRecommendedAccountID, account.id)
        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertNotNil(harness.model.pendingRestartPromptMessage)

        let actionTask = Task { @MainActor in
            await harness.model.performBannerAction(.restartCodex)
        }

        for _ in 0..<20 {
            if harness.model.isRestartingCodex {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(harness.model.isRestartingCodex)
        XCTAssertEqual(harness.model.restartRecommendedAccountID, account.id)
        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertNotNil(harness.model.pendingRestartPromptMessage)
        XCTAssertEqual(harness.model.banner?.action, .restartCodex)

        await actionTask.value

        XCTAssertEqual(runtimeInspector.restartCallCount, 1)
        XCTAssertFalse(harness.model.isRestartingCodex)
        XCTAssertNil(harness.model.restartRecommendedAccountID)
        XCTAssertFalse(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertNil(harness.model.pendingRestartPromptMessage)
        XCTAssertFalse(harness.model.hasRunningMainCodexDesktop)
        XCTAssertEqual(harness.model.banner?.level, .info)
        XCTAssertNil(harness.model.banner?.action)
        XCTAssertEqual(
            harness.model.banner?.message,
            L10n.tr("已请求重启 Codex，新的授权信息会在应用恢复后重新加载。")
        )
    }

    func testRestartActionPassesLaunchEnvironmentForActiveCopilotMainAccount() async throws {
        let currentAccountID = UUID()
        let copilotAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .verified, isRunning: false)
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential),
            statusResult: .success(
                CopilotAccountStatus(
                    availableModels: ["gpt-4.1"],
                    currentModel: "gpt-4.1",
                    quotaSnapshot: nil
                )
            )
        )
        resolver.desktopContextResult = .success(
            ResolvedCodexDesktopLaunchContext(
                accountID: copilotAccountID,
                codexHomeURL: URL(fileURLWithPath: "/tmp/unused"),
                authPayload: nil,
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-4.1"]),
                configFileContents: """
                model = "gpt-4.1"
                model_reasoning_effort = "medium"
                model_provider = "github-copilot"
                """,
                environmentVariables: [
                    "GITHUB_TOKEN": "copilot_access_token",
                    "OPENAI_BASE_URL": "http://127.0.0.1:18081",
                ]
            )
        )

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        await harness.model.performBannerAction(.restartCodex)

        XCTAssertEqual(runtimeInspector.restartCallCount, 1)
        XCTAssertEqual(
            runtimeInspector.lastRestartLaunchEnvironment,
            [
                "GITHUB_TOKEN": "copilot_access_token",
                "OPENAI_BASE_URL": "http://127.0.0.1:18081",
            ]
        )
        XCTAssertEqual(
            harness.model.banner?.message,
            L10n.tr("已请求重启 Codex，主实例会按当前账号重新加载模型目录与凭据。")
        )
    }

    func testSwitchBackToChatGPTRemovesMainManagedBlock() async throws {
        let currentAccountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let runtimeInspector = MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopContextResult = .success(
            ResolvedCodexDesktopLaunchContext(
                accountID: providerAccountID,
                codexHomeURL: URL(fileURLWithPath: "/tmp/unused"),
                authPayload: nil,
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["deepseek-chat"]),
                configFileContents: """
                model = "deepseek-chat"
                model_reasoning_effort = "medium"
                model_provider = "deepseek"
                """,
                environmentVariables: ["DEEPSEEK_API_KEY": "sk-deepseek"]
            )
        )
        let providerAccount = makeProviderAccount(
            id: providerAccountID,
            platform: .codex,
            identifier: "provider_deepseek",
            displayName: "DeepSeek Work",
            email: "deepseek@example.com",
            rule: .openAICompatible,
            presetID: "deepseek",
            providerDisplayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            envName: "DEEPSEEK_API_KEY",
            model: "deepseek-chat"
        )

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: runtimeInspector,
            activeAccountID: currentAccountID,
            extraSeeds: [
                AccountSeed(account: providerAccount, payload: try makeProviderCredential("sk-deepseek"), snapshot: nil)
            ],
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let configURL = harness.model.paths.codex.homeURL.appendingPathComponent("config.toml")
        let modelCatalogURL = harness.model.paths.codex.homeURL.appendingPathComponent("orbit-main-model-catalog.json")
        try "theme = \"dark\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let provider = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == providerAccountID }))
        await harness.model.switchToAccount(provider)
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("# orbit-managed:start main-codex"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelCatalogURL.path))

        let chatgptAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == currentAccountID }))
        await harness.model.switchToAccount(chatgptAccount)

        let configContents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(configContents.contains("theme = \"dark\""))
        XCTAssertFalse(configContents.contains("# orbit-managed:start main-codex"))
        XCTAssertFalse(configContents.contains("orbit-main-model-catalog.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelCatalogURL.path))
    }

    func testRefreshAccountStatusFormatsQuotaAsRemainingPercent() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let refreshedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_new")
        let usageSnapshot = QuotaSnapshot(
            primary: RateLimitWindowSnapshot(usedPercent: 0, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_773_908_626)),
            secondary: RateLimitWindowSnapshot(usedPercent: 32, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_774_017_140)),
            credits: nil,
            planType: "team",
            capturedAt: Date(),
            source: .onlineUsageRefresh
        )
        let subscriptionDetails = SubscriptionDetails(
            allowed: true,
            limitReached: false
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(
                refreshResult: .success(
                    AuthLoginResult(
                        payload: refreshedPayload,
                        identity: AuthIdentity(
                            accountID: "acct_cached",
                            displayName: "Refreshed User",
                            email: "refresh@example.com",
                            planType: "team"
                        )
                    )
                ),
                usageResult: .success(
                    UsageRefreshResult(
                        snapshot: usageSnapshot,
                        email: "refresh@example.com",
                        planType: "team",
                        allowed: true,
                        limitReached: false,
                        subscriptionDetails: subscriptionDetails
                    )
                )
            ),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.refreshAccountStatus(account)

        let refreshedAccount = try XCTUnwrap(harness.model.accounts.first)
        let snapshot = try XCTUnwrap(harness.model.snapshot(for: accountID))
        XCTAssertEqual(snapshot.primary.remainingPercentText, "100%")
        XCTAssertEqual(try XCTUnwrap(snapshot.secondary).remainingPercentText, "68%")
        XCTAssertEqual(
            refreshedAccount.lastStatusMessage,
            L10n.tr("状态与额度已更新：剩余 %@。", L10n.tr("5h %@ / 7d %@", "100%", "68%"))
        )
        XCTAssertEqual(refreshedAccount.subscriptionDetails?.allowed, true)
        XCTAssertEqual(refreshedAccount.subscriptionDetails?.limitReached, false)
    }

    func testRefreshCopilotAccountStatusUsesLiveModelWhenStoredModelIsStale() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-5.3-codex",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential),
            statusResult: .success(
                CopilotAccountStatus(
                    availableModels: ["gpt-4.1", "gpt-4o"],
                    currentModel: "gpt-4.1",
                    quotaSnapshot: nil
                )
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-5.3-codex",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        await harness.model.refreshAccountStatus(account)

        let providerSnapshot = await copilotProvider.snapshot()
        let refreshedAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))
        XCTAssertEqual(providerSnapshot.resolveCallCount, 1)
        XCTAssertEqual(providerSnapshot.fetchStatusCallCount, 1)
        XCTAssertEqual(refreshedAccount.defaultModel, "gpt-4.1")
        XCTAssertEqual(refreshedAccount.lastStatusMessage, L10n.tr("GitHub Copilot 已验证：默认模型 %@。", "gpt-4.1"))
    }

    func testReconcileCurrentAuthStateAlignsActiveAccountWithAuthFile() async throws {
        let currentAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: currentAccountID
        )

        await harness.model.prepare()
        XCTAssertEqual(harness.model.activeAccount?.id, currentAccountID)

        harness.authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_actual",
            refreshToken: "refresh_actual",
            displayName: "Actual User",
            email: "actual@example.com",
            planType: "team"
        )

        await harness.model.reconcileCurrentAuthState()

        XCTAssertEqual(harness.model.activeAccount?.codexAccountID, "acct_actual")
        XCTAssertEqual(harness.model.selectedAccount?.codexAccountID, "acct_actual")
    }

    func testPrepareCallsAppSupportPathRepairerOnce() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let repairer = RecordingAppSupportPathRepairer()
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            appSupportPathRepairer: repairer,
            enableSessionLogger: true
        )

        await harness.model.prepare()
        await harness.model.prepare()

        XCTAssertEqual(repairer.repairCallCount, 1)
        XCTAssertEqual(repairer.lastAppSupportDirectoryURL, harness.model.paths.appSupportDirectoryURL)
        let log = try readSessionLog(from: harness)
        XCTAssertEqual(occurrenceCount(of: "database.load.begin", in: log), 1)
        XCTAssertEqual(occurrenceCount(of: "prepare.skip_already_loaded", in: log), 1)
    }

    func testPrepareContinuesWhenAppSupportPathRepairFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let repairer = RecordingAppSupportPathRepairer()
        repairer.result = .failure(MockError.unused)

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            appSupportPathRepairer: repairer,
            enableSessionLogger: true
        )

        await harness.model.prepare()

        XCTAssertEqual(repairer.repairCallCount, 1)
        XCTAssertEqual(harness.model.activeAccount?.id, accountID)
        XCTAssertTrue(
            harness.model.database.switchLogs.contains {
                $0.level == .warning && $0.message.contains("运行期目录路径修复失败")
            }
        )
        let log = try readSessionLog(from: harness)
        XCTAssertTrue(log.contains("app_support_repair.failure"))
        XCTAssertTrue(log.contains("prepare.complete"))
    }

    func testPrepareWritesSessionLogForSuccessfulInitialization() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            enableSessionLogger: true
        )

        await harness.model.prepare()

        let log = try readSessionLog(from: harness)
        XCTAssertTrue(log.contains("database.load.begin"))
        XCTAssertTrue(log.contains("database.load.end account_count=1"))
        XCTAssertTrue(log.contains("credentials.preload.begin"))
        XCTAssertTrue(log.contains("credentials.preload.end"))
        XCTAssertTrue(log.contains("app_support_repair.begin"))
        XCTAssertTrue(log.contains("app_support_repair.end updated=false"))
        XCTAssertTrue(log.contains("import_current_auth.begin"))
        XCTAssertTrue(log.contains("import_current_auth.end result=no_auth_file"))
        XCTAssertTrue(log.contains("quota_monitor.start"))
        XCTAssertTrue(log.contains("prepare.complete"))
    }

    func testPrepareWritesSessionLogWhenDatabaseLoadFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            enableSessionLogger: true
        )
        try "{invalid json}".write(to: harness.model.paths.databaseURL, atomically: true, encoding: .utf8)

        await harness.model.prepare()

        let log = try readSessionLog(from: harness)
        XCTAssertTrue(log.contains("database.load.failure"))
        XCTAssertTrue(log.contains("prepare.complete"))
    }

    func testPreparePassivelyImportsCurrentCodexAuthWhenClaudeIsActive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            appSupportOverride: appSupport
        )
        let databaseStore = AppDatabaseStore(databaseURL: paths.databaseURL)
        let credentialStore = InMemoryCredentialStore()
        let claudeAccountID = UUID()
        let claudeCredential = StoredCredential.claudeProfile(ClaudeProfileSnapshotRef(snapshotID: "snapshot_prepare"))
        try credentialStore.save(claudeCredential, for: claudeAccountID)

        let claudeAccount = ManagedAccount(
            id: claudeAccountID,
            platform: .claude,
            codexAccountID: claudeCredential.accountIdentifier,
            displayName: "Claude Profile",
            email: nil,
            authMode: .claudeProfile,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: true
        )
        try await databaseStore.save(
            AppDatabase(
                version: AppDatabase.currentVersion,
                accounts: [claudeAccount],
                quotaSnapshots: [:],
                switchLogs: [],
                activeAccountID: claudeAccountID
            )
        )

        let authFileManager = RecordingAuthFileManager()
        authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_imported",
            refreshToken: "refresh_imported",
            displayName: "Imported User",
            email: "imported@example.com",
            planType: "team"
        )
        let model = AppViewModel(
            paths: paths,
            databaseStore: databaseStore,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            jwtDecoder: JWTClaimsDecoder(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            quotaMonitor: NoopQuotaMonitor(),
            userNotifier: RecordingUserNotifier(),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await model.prepare()

        XCTAssertEqual(model.database.activeAccountID, claudeAccountID)
        XCTAssertEqual(model.database.accounts.count, 2)
        XCTAssertEqual(model.accounts.count, 2)
        let importedAccount = try XCTUnwrap(model.database.accounts.first(where: { $0.codexAccountID == "acct_imported" }))
        XCTAssertEqual(importedAccount.codexAccountID, "acct_imported")
        XCTAssertEqual(model.selectedAccountID, claudeAccountID)
        XCTAssertEqual(model.selectedAccount?.id, claudeAccountID)
        XCTAssertTrue(
            model.database.switchLogs.contains {
                $0.message == L10n.tr(
                    "检测到当前 ~/.codex/auth.json 正在使用账号 %@，已同步账号信息，但未切换当前账号。",
                    importedAccount.displayName
                )
            }
        )
    }

    func testPreparePassivelyImportsCurrentCodexAuthWhenCopilotIsActive() async throws {
        let currentAccountID = UUID()
        let copilotAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let authFileManager = RecordingAuthFileManager()
        authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_imported",
            refreshToken: "refresh_imported",
            displayName: "Imported User",
            email: "imported@example.com",
            planType: "team"
        )

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccountID)
        XCTAssertEqual(harness.model.selectedAccount?.id, copilotAccountID)
        XCTAssertTrue(harness.model.accounts.contains(where: { $0.codexAccountID == "acct_imported" }))
        XCTAssertTrue(
            harness.model.database.switchLogs.contains {
                $0.message == L10n.tr(
                    "检测到当前 ~/.codex/auth.json 正在使用账号 %@，已同步账号信息，但未切换当前账号。",
                    "Imported User"
                )
            }
        )
    }

    func testReconcileCurrentAuthStateKeepsSelectedCodexAccountWhenClaudeIsActive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: codexHome,
            claudeHomeOverride: claudeHome,
            appSupportOverride: appSupport
        )
        let databaseStore = AppDatabaseStore(databaseURL: paths.databaseURL)
        let credentialStore = InMemoryCredentialStore()
        let claudeAccountID = UUID()
        let selectedCodexAccountID = UUID()
        let selectedCodexPayload = makePayload(accountID: "acct_existing", refreshToken: "refresh_existing")
        let claudeCredential = StoredCredential.claudeProfile(ClaudeProfileSnapshotRef(snapshotID: "snapshot_reconcile"))
        try credentialStore.save(claudeCredential, for: claudeAccountID)
        try credentialStore.save(selectedCodexPayload, for: selectedCodexAccountID)

        let claudeAccount = ManagedAccount(
            id: claudeAccountID,
            platform: .claude,
            codexAccountID: claudeCredential.accountIdentifier,
            displayName: "Claude Profile",
            email: nil,
            authMode: .claudeProfile,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: true
        )
        let selectedCodexAccount = ManagedAccount(
            id: selectedCodexAccountID,
            codexAccountID: selectedCodexPayload.accountIdentifier,
            displayName: "Selected Codex",
            email: "selected@example.com",
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
        try await databaseStore.save(
            AppDatabase(
                version: AppDatabase.currentVersion,
                accounts: [claudeAccount, selectedCodexAccount],
                quotaSnapshots: [:],
                switchLogs: [],
                activeAccountID: claudeAccountID
            )
        )

        let authFileManager = RecordingAuthFileManager()
        let model = AppViewModel(
            paths: paths,
            databaseStore: databaseStore,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            jwtDecoder: JWTClaimsDecoder(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            quotaMonitor: NoopQuotaMonitor(),
            userNotifier: RecordingUserNotifier(),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await model.prepare()
        XCTAssertEqual(model.database.activeAccountID, claudeAccountID)
        XCTAssertEqual(model.selectedAccountID, claudeAccountID)

        model.selectedAccountID = selectedCodexAccountID

        authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_reconciled",
            refreshToken: "refresh_reconciled",
            displayName: "Reconciled User",
            email: "reconciled@example.com",
            planType: "pro"
        )

        await model.reconcileCurrentAuthState()

        XCTAssertEqual(model.database.activeAccountID, claudeAccountID)
        XCTAssertEqual(model.selectedAccountID, selectedCodexAccountID)
        XCTAssertEqual(model.selectedAccount?.codexAccountID, "acct_existing")
        XCTAssertTrue(model.accounts.contains(where: { $0.codexAccountID == "acct_reconciled" }))
        XCTAssertTrue(
            model.database.switchLogs.contains {
                $0.message == L10n.tr(
                    "检测到当前 ~/.codex/auth.json 正在使用账号 %@，已同步账号信息，但未切换当前账号。",
                    "Reconciled User"
                )
            }
        )
    }

    func testReconcileCurrentAuthStateKeepsCopilotAccountActive() async throws {
        let currentAccountID = UUID()
        let copilotAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let authFileManager = RecordingAuthFileManager()

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()
        let copilotAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        await harness.model.switchToAccount(copilotAccount)
        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccountID)

        authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_actual",
            refreshToken: "refresh_actual",
            displayName: "Actual User",
            email: "actual@example.com",
            planType: "team"
        )

        await harness.model.reconcileCurrentAuthState()

        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccountID)
        XCTAssertEqual(harness.model.selectedAccount?.id, copilotAccountID)
        XCTAssertTrue(harness.model.accounts.contains(where: { $0.codexAccountID == "acct_actual" }))
        XCTAssertTrue(
            harness.model.database.switchLogs.contains {
                $0.message == L10n.tr(
                    "检测到当前 ~/.codex/auth.json 正在使用账号 %@，已同步账号信息，但未切换当前账号。",
                    "Actual User"
                )
            }
        )
    }

    func testProgrammaticActivationSkipsAuthReconcile() async throws {
        let currentAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: currentAccountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: currentAccountID
        )

        await harness.model.prepare()
        harness.authFileManager.currentAuth = makeSignedLikePayload(
            accountID: "acct_actual",
            refreshToken: "refresh_actual",
            displayName: "Actual User",
            email: "actual@example.com",
            planType: "team"
        )

        harness.model.noteProgrammaticActivation(gracePeriod: 60)
        await harness.model.reconcileCurrentAuthStateForAppActivation()

        XCTAssertEqual(harness.model.activeAccount?.codexAccountID, "acct_cached")
    }

    func testDismissRestartPromptClearsMenuBarPromptState() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .authError(.refreshTokenReused), isRunning: true)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        await harness.model.switchToAccount(account)

        harness.model.dismissRestartPrompt()

        XCTAssertFalse(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertNil(harness.model.banner)
    }

    func testBannerAutoDismissesAfterDelay() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let cliLauncher = RecordingCodexCLILauncher()
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            cliLauncher: cliLauncher,
            bannerAutoDismissDuration: .milliseconds(50)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("auto-dismiss-cli"))
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))

        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(harness.model.banner)
    }

    func testRestartPromptMessageSurvivesUnrelatedBannerUpdates() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .authError(.refreshTokenReused), isRunning: true)
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        await harness.model.switchToAccount(account)

        harness.model.banner = BannerState(level: .info, message: "其他提示")

        XCTAssertTrue(harness.model.shouldPromptRestartAfterSwitch)
        XCTAssertEqual(
            harness.model.restartPromptMessage,
            L10n.tr("auth.json 已更新，但运行中的 Codex 仍持有旧授权并触发 refresh_token_reused，建议重启 Codex。")
        )
    }

    func testStartAPIKeyLoginCreatesAndActivatesAPIKeyAccount() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        harness.model.addAccountMode = .providerAPIKey
        harness.model.apiKeyInput = "sk-test-api-key"
        harness.model.apiKeyDisplayName = "API 测试账号"

        await harness.model.startAPIKeyLogin()

        XCTAssertEqual(harness.model.activeAccount?.authMode, .providerAPIKey)
        XCTAssertEqual(harness.model.activeAccount?.providerRule, .openAICompatible)
        XCTAssertEqual(harness.model.activeAccount?.providerPresetID, "openai")
        XCTAssertEqual(harness.model.activeAccount?.displayName, "API 测试账号")
        XCTAssertTrue(harness.authFileManager.activatedPayloads.isEmpty)
        XCTAssertEqual(try harness.credentialStore.load(for: try XCTUnwrap(harness.model.activeAccount?.id)).providerAPIKeyCredential?.apiKey, "sk-test-api-key")
    }

    func testStartAPIKeyLoginKeepsExistingAccountsWhenAddingDifferentKey() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        XCTAssertEqual(harness.model.accounts.count, 1)

        harness.model.addAccountMode = .providerAPIKey
        harness.model.apiKeyInput = "sk-test-api-key-2"
        harness.model.apiKeyDisplayName = "第二个账号"

        await harness.model.startAPIKeyLogin()

        let newCredential = try ProviderAPIKeyCredential(apiKey: "sk-test-api-key-2").validated()
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertTrue(harness.model.accounts.contains(where: { $0.codexAccountID == cachedPayload.accountIdentifier }))
        XCTAssertTrue(harness.model.accounts.contains(where: { $0.accountIdentifier == newCredential.accountIdentifier }))
        XCTAssertEqual(harness.model.activeAccount?.accountIdentifier, newCredential.accountIdentifier)
        XCTAssertEqual(harness.model.activeAccount?.displayName, "第二个账号")
    }

    func testStartAPIKeyLoginUpsertsExistingAPIKeyAccountInsteadOfDuplicating() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-same-key")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        XCTAssertEqual(harness.model.accounts.count, 1)

        harness.model.addAccountMode = .providerAPIKey
        harness.model.apiKeyInput = "sk-test-same-key"
        harness.model.apiKeyDisplayName = "重复登录"

        await harness.model.startAPIKeyLogin()

        let credential = try ProviderAPIKeyCredential(apiKey: "sk-test-same-key").validated()
        XCTAssertEqual(harness.model.accounts.count, 1)
        XCTAssertEqual(harness.model.activeAccount?.id, accountID)
        XCTAssertEqual(harness.model.activeAccount?.accountIdentifier, credential.accountIdentifier)
    }

    func testAccountsListCombinesPlatformsAndFocusedPlatformStateFollowsSelection() async throws {
        let accountID = UUID()
        let claudeAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            activeAccountID: accountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: claudeAccountID,
                        platform: .claude,
                        codexAccountID: "claude-profile",
                        displayName: "Claude Profile",
                        email: nil,
                        authMode: .claudeProfile,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .claudeProfile(ClaudeProfileSnapshotRef(snapshotID: "snapshot_focus")),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(harness.model.focusedPlatform, .codex)

        harness.model.selectedAccountID = claudeAccountID
        harness.model.prepareAddAccountSheet()

        XCTAssertEqual(harness.model.focusedPlatform, .claude)
        XCTAssertTrue(harness.model.canAddAccounts)
        XCTAssertEqual(harness.model.focusedPlatformHomeButtonTitle, L10n.tr("打开 ~/.claude"))
        XCTAssertEqual(harness.model.addAccountMode, .chatgptBrowser)
        XCTAssertEqual(harness.model.availableAddAccountModes, AddAccountMode.allCases)
        XCTAssertEqual(
            harness.model.focusedPlatformUnsupportedMessage,
            L10n.tr("Claude 当前支持本地 Profile 导入、Claude 兼容 API Key 管理和 Claude CLI 启动；不支持 claude.ai OAuth 切换。")
        )
    }

    func testPrepareAddAccountSheetDefaultsToChatGPTBrowserMode() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            activeAccountID: accountID
        )

        await harness.model.prepare()

        harness.model.selectedAccountID = nil
        harness.model.prepareAddAccountSheet()
        XCTAssertEqual(harness.model.addAccountMode, .chatgptBrowser)

        await harness.model.deleteAccount(accountID, clearCurrentAuth: false)

        harness.model.prepareAddAccountSheet()
        XCTAssertEqual(harness.model.addAccountMode, .chatgptBrowser)
    }

    func testStartCopilotLoginImportsLocalCredentialWithoutTerminal() async throws {
        let accountID = UUID()
        let terminalCommandLauncher = RecordingTerminalCommandLauncher()
        let copilotProvider = RecordingCopilotProvider(
            importResult: .success(
                CopilotCredential(
                    host: "https://github.com",
                    login: "aikilan",
                    accessToken: "copilot_access_token",
                    defaultModel: "gpt-4.1",
                    source: .localImport
                )
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            terminalCommandLauncher: terminalCommandLauncher,
            copilotProvider: copilotProvider
        )

        await harness.model.prepare()
        harness.model.prepareAddAccountSheet()
        harness.model.addAccountMode = .githubCopilot

        await harness.model.startCopilotLogin()

        let copilotAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.providerRule == .githubCopilot }))
        let snapshot = await copilotProvider.snapshot()

        XCTAssertEqual(snapshot.importCallCount, 1)
        XCTAssertEqual(snapshot.startDeviceLoginCallCount, 0)
        XCTAssertEqual(snapshot.completeDeviceLoginCallCount, 0)
        XCTAssertTrue(terminalCommandLauncher.launchedCommands.isEmpty)
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(copilotAccount.displayName, "GitHub Copilot • aikilan")
        XCTAssertEqual(copilotAccount.email, "https://github.com/aikilan")
        XCTAssertEqual(copilotAccount.defaultModel, "gpt-4.1")
        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccount.id)
        XCTAssertEqual(harness.model.selectedAccount?.id, copilotAccount.id)
        XCTAssertEqual(try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.login, "aikilan")
        XCTAssertEqual(
            try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.configDirectoryName,
            copilotAccount.id.uuidString
        )
        XCTAssertEqual(try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.accessToken, "copilot_access_token")
        XCTAssertEqual(try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.source, .localImport)
    }

    func testStartCopilotLoginFallsBackToBrowserAuthorizationWhenImportFails() async throws {
        let accountID = UUID()
        let terminalCommandLauncher = RecordingTerminalCommandLauncher()
        let challenge = CopilotDeviceLoginChallenge(
            host: "https://github.com",
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresInSeconds: 900,
            intervalSeconds: 1,
            defaultModel: nil
        )
        let copilotProvider = RecordingCopilotProvider(
            importResult: .failure(CopilotProviderError.upstream("404 page not found")),
            startDeviceLoginChallenge: challenge,
            completeDeviceLoginResult: .success(
                CopilotCredential(
                    host: "https://github.com",
                    login: "aikilan",
                    accessToken: "device_access_token",
                    defaultModel: nil,
                    source: .orbitOAuth
                )
            )
        )
        var openedURLs = [URL]()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            terminalCommandLauncher: terminalCommandLauncher,
            openExternalURL: { openedURLs.append($0) },
            copilotProvider: copilotProvider
        )

        await harness.model.prepare()
        harness.model.prepareAddAccountSheet()
        harness.model.addAccountMode = .githubCopilot

        await harness.model.startCopilotLogin()

        let copilotAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.providerRule == .githubCopilot }))
        let snapshot = await copilotProvider.snapshot()

        XCTAssertEqual(snapshot.importCallCount, 1)
        XCTAssertEqual(snapshot.startDeviceLoginCallCount, 1)
        XCTAssertEqual(snapshot.completeDeviceLoginCallCount, 1)
        XCTAssertEqual(snapshot.lastDeviceLoginHost, "https://github.com")
        XCTAssertEqual(snapshot.lastCompletedChallenge, challenge)
        XCTAssertEqual(openedURLs, [challenge.verificationURL])
        XCTAssertTrue(terminalCommandLauncher.launchedCommands.isEmpty)
        XCTAssertEqual(copilotAccount.displayName, "GitHub Copilot • aikilan")
        XCTAssertEqual(copilotAccount.email, "https://github.com/aikilan")
        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccount.id)
        XCTAssertEqual(harness.model.selectedAccount?.id, copilotAccount.id)
        XCTAssertEqual(try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.host, "https://github.com")
        XCTAssertEqual(
            try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.configDirectoryName,
            copilotAccount.id.uuidString
        )
        XCTAssertEqual(try harness.credentialStore.load(for: copilotAccount.id).copilotCredential?.source, .orbitOAuth)
    }

    func testReauthorizeChatGPTAccountUpdatesExistingCredentialAndActivatesAccount() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let refreshedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_new")
        let authFileManager = RecordingAuthFileManager()
        let oauthClient = MockOAuthClient(
            refreshResult: .failure(MockError.refreshFailed),
            browserLoginResult: .success(
                AuthLoginResult(
                    payload: refreshedPayload,
                    identity: AuthIdentity(
                        accountID: "acct_cached",
                        displayName: "Refreshed User",
                        email: "refresh@example.com",
                        planType: "plus"
                    )
                )
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        harness.model.openReauthorize(for: accountID)
        await harness.model.startBrowserLogin()
        harness.model.browserCallbackInput = "http://localhost:1455/auth/callback?code=test"
        await harness.model.submitBrowserCallback()

        let account = try XCTUnwrap(harness.model.database.account(id: accountID))
        XCTAssertEqual(harness.model.accounts.count, 1)
        XCTAssertEqual(account.displayName, "Cached User")
        XCTAssertEqual(account.email, "refresh@example.com")
        XCTAssertEqual(account.planType, "plus")
        XCTAssertEqual(harness.model.activeAccount?.id, accountID)
        XCTAssertEqual(harness.model.selectedAccount?.id, accountID)
        XCTAssertEqual(try harness.credentialStore.load(for: accountID).tokens.refreshToken, "refresh_new")
        XCTAssertEqual(authFileManager.activatedPayloads.last?.tokens.refreshToken, "refresh_new")
        XCTAssertFalse(harness.model.isReauthorizingAccount)
    }

    func testReauthorizeChatGPTAccountRejectsMismatchedAccount() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let otherPayload = makePayload(accountID: "acct_other", refreshToken: "refresh_other")
        let authFileManager = RecordingAuthFileManager()
        let oauthClient = MockOAuthClient(
            refreshResult: .failure(MockError.refreshFailed),
            browserLoginResult: .success(
                AuthLoginResult(
                    payload: otherPayload,
                    identity: AuthIdentity(
                        accountID: "acct_other",
                        displayName: "Other User",
                        email: "other@example.com",
                        planType: "team"
                    )
                )
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        harness.model.openReauthorize(for: accountID)
        await harness.model.startBrowserLogin()
        harness.model.browserCallbackInput = "http://localhost:1455/auth/callback?code=test"
        await harness.model.submitBrowserCallback()

        XCTAssertEqual(harness.model.accounts.count, 1)
        XCTAssertEqual(harness.model.activeAccount?.id, nil)
        XCTAssertEqual(try harness.credentialStore.load(for: accountID).tokens.refreshToken, "refresh_old")
        XCTAssertTrue(authFileManager.activatedPayloads.isEmpty)
        XCTAssertEqual(
            harness.model.addAccountError,
            L10n.tr("重新授权账号不匹配。请登录账号 %@。", "Cached User")
        )
        XCTAssertTrue(harness.model.isReauthorizingAccount)
    }

    func testReauthorizeCopilotAccountUpdatesCredentialAndKeepsManagedConfigDirectory() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let oldCredential = CopilotCredential(
            configDirectoryName: "managed-copilot-dir",
            host: "https://github.com",
            login: "aikilan",
            githubAccessToken: "github_old",
            accessToken: "copilot_old",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let newCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            githubAccessToken: "github_new",
            accessToken: "copilot_new",
            defaultModel: "gpt-4.1",
            source: .orbitOAuth
        )
        let copilotProvider = RecordingCopilotProvider(importResult: .success(newCredential))

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: oldCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: oldCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .copilot(oldCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider
        )

        await harness.model.prepare()
        harness.model.openReauthorize(for: copilotAccountID)
        await harness.model.startCopilotLogin()

        let storedCredential = try XCTUnwrap(try harness.credentialStore.load(for: copilotAccountID).copilotCredential)
        let account = try XCTUnwrap(harness.model.database.account(id: copilotAccountID))
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(account.displayName, "GitHub Copilot • aikilan")
        XCTAssertEqual(harness.model.activeAccount?.id, copilotAccountID)
        XCTAssertEqual(storedCredential.configDirectoryName, "managed-copilot-dir")
        XCTAssertEqual(storedCredential.githubAccessToken, "github_new")
        XCTAssertEqual(storedCredential.accessToken, "copilot_new")
        XCTAssertEqual(storedCredential.source, .orbitOAuth)
        XCTAssertFalse(harness.model.isReauthorizingAccount)
    }

    func testReauthorizeCopilotAccountRejectsMismatchedAccount() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let oldCredential = CopilotCredential(
            configDirectoryName: "managed-copilot-dir",
            host: "https://github.com",
            login: "aikilan",
            githubAccessToken: "github_old",
            accessToken: "copilot_old",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let otherCredential = CopilotCredential(
            host: "https://github.com",
            login: "other-user",
            githubAccessToken: "github_other",
            accessToken: "copilot_other",
            defaultModel: "gpt-4.1",
            source: .orbitOAuth
        )
        let challenge = CopilotDeviceLoginChallenge(
            host: "https://github.com",
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresInSeconds: 900,
            intervalSeconds: 1,
            defaultModel: "gpt-4.1"
        )
        let copilotProvider = RecordingCopilotProvider(
            importResult: .failure(CopilotProviderError.importUnavailable),
            startDeviceLoginChallenge: challenge,
            completeDeviceLoginResult: .success(otherCredential)
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: oldCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: oldCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .copilot(oldCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider
        )

        await harness.model.prepare()
        harness.model.openReauthorize(for: copilotAccountID)
        await harness.model.startCopilotLogin()

        let storedCredential = try XCTUnwrap(try harness.credentialStore.load(for: copilotAccountID).copilotCredential)
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(harness.model.activeAccount?.id, nil)
        XCTAssertEqual(storedCredential.configDirectoryName, "managed-copilot-dir")
        XCTAssertEqual(storedCredential.githubAccessToken, "github_old")
        XCTAssertEqual(storedCredential.accessToken, "copilot_old")
        XCTAssertEqual(
            harness.model.addAccountError,
            L10n.tr("重新授权账号不匹配。请登录账号 %@。", "GitHub Copilot • aikilan")
        )
        XCTAssertTrue(harness.model.isReauthorizingAccount)
    }

    func testProviderAPIKeyLoginDoesNotWriteCodexAuthForClaudeCompatibleAccount() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let authFileManager = RecordingAuthFileManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        harness.model.addAccountMode = .providerAPIKey
        harness.model.addAccountProviderRule = .claudeCompatible
        harness.model.applyProviderPreset(ProviderCatalog.preset(id: "anthropic"))
        harness.model.apiKeyInput = "sk-ant-test-claude"
        harness.model.apiKeyDisplayName = "Claude API"
        harness.model.addAccountDefaultModel = "claude-sonnet-4.5"

        await harness.model.startAPIKeyLogin()

        XCTAssertTrue(authFileManager.activatedPayloads.isEmpty)
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(harness.model.activeAccount?.platform, .claude)
        XCTAssertEqual(harness.model.activeAccount?.authMode, .providerAPIKey)
        XCTAssertEqual(harness.model.activeAccount?.providerRule, .claudeCompatible)
        XCTAssertEqual(harness.model.activeAccount?.providerPresetID, "anthropic")
        XCTAssertEqual(harness.model.activeAccount?.defaultCLITarget, .claude)
        XCTAssertEqual(harness.model.activeAccount?.displayName, "Claude API")
        XCTAssertEqual(harness.model.selectedAccount?.displayName, "Claude API")
        XCTAssertEqual(
            harness.model.banner?.message,
            L10n.tr("已切换到账号 %@。", "Claude API")
        )
    }

    func testOpenAICompatibleProviderLoginAllowsDeepSeekBaseURL() async throws {
        let accountID = UUID()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()
        harness.model.addAccountMode = .providerAPIKey
        harness.model.addAccountProviderRule = .openAICompatible
        harness.model.applyProviderPreset(ProviderCatalog.preset(id: ProviderCatalog.customPresetID))
        harness.model.addAccountProviderDisplayName = "DeepSeek"
        harness.model.addAccountProviderBaseURL = "https://api.deepseek.com/v1"
        harness.model.addAccountProviderAPIKeyEnvName = "DEEPSEEK_API_KEY"
        harness.model.addAccountDefaultModel = "deepseek-reasoner"
        harness.model.apiKeyInput = "sk-deepseek-test"

        await harness.model.startAPIKeyLogin()

        XCTAssertNil(harness.model.addAccountError)
        XCTAssertEqual(harness.model.accounts.count, 2)
        XCTAssertEqual(harness.model.activeAccount?.providerPresetID, ProviderCatalog.customPresetID)
        XCTAssertEqual(harness.model.activeAccount?.providerBaseURL, "https://api.deepseek.com/v1")
    }

    func testCanEditProviderAccountOnlyForProviderAPIKeyAccounts() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let customCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-editable").validated()
        let customAccountID = UUID()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: customAccountID,
                        platform: .codex,
                        identifier: customCredential.accountIdentifier,
                        displayName: "Custom Provider",
                        email: customCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "DeepSeek",
                        baseURL: "https://api.deepseek.com/v1",
                        envName: "DEEPSEEK_API_KEY",
                        model: "deepseek-chat"
                    ),
                    payload: .providerAPIKey(customCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        let builtInAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == accountID }))
        let customAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == customAccountID }))

        XCTAssertTrue(harness.model.canEditProviderAccount(builtInAccount))
        XCTAssertTrue(harness.model.canEditProviderAccount(customAccount))
    }

    func testOpenEditProviderPrefillsExistingValues() async throws {
        let accountID = UUID()
        let customAccountID = UUID()
        let customCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-prefill").validated()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: customAccountID,
                        platform: .codex,
                        identifier: customCredential.accountIdentifier,
                        displayName: "DeepSeek 生产",
                        email: customCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "DeepSeek",
                        baseURL: "https://api.deepseek.com/v1",
                        envName: "DEEPSEEK_API_KEY",
                        model: "deepseek-chat"
                    ),
                    payload: .providerAPIKey(customCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        harness.model.openEditProvider(for: customAccountID)

        XCTAssertTrue(harness.model.isEditingProviderAccount)
        XCTAssertEqual(harness.model.addAccountSheetTitle, L10n.tr("编辑供应商"))
        XCTAssertEqual(harness.model.addAccountActionButtonTitle, L10n.tr("保存修改"))
        XCTAssertEqual(harness.model.addAccountMode, .providerAPIKey)
        XCTAssertEqual(harness.model.addAccountProviderRule, .openAICompatible)
        XCTAssertEqual(harness.model.addAccountProviderPresetID, ProviderCatalog.customPresetID)
        XCTAssertEqual(harness.model.apiKeyDisplayName, "DeepSeek 生产")
        XCTAssertEqual(harness.model.addAccountProviderDisplayName, "DeepSeek")
        XCTAssertEqual(harness.model.addAccountProviderBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(harness.model.addAccountProviderAPIKeyEnvName, "DEEPSEEK_API_KEY")
        XCTAssertEqual(harness.model.addAccountDefaultModel, "deepseek-chat")
        XCTAssertEqual(
            harness.model.addAccountStatus,
            L10n.tr("修改当前供应商配置；API Key 留空表示继续使用当前凭据。")
        )
    }

    func testAvailableProviderPresetsHideCustomDuringCreateFlow() async throws {
        let harness = try await makeHarness(
            accountID: UUID(),
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false)
        )

        await harness.model.prepare()

        XCTAssertFalse(harness.model.availableProviderPresets.contains(where: { $0.id == ProviderCatalog.customPresetID }))

        harness.model.addAccountProviderRule = .claudeCompatible
        harness.model.applyProviderPreset(ProviderCatalog.preset(id: "anthropic"))

        XCTAssertFalse(harness.model.availableProviderPresets.contains(where: { $0.id == ProviderCatalog.customPresetID }))
    }

    func testAvailableProviderPresetsKeepCustomForEditingExistingCustomAccount() async throws {
        let accountID = UUID()
        let customAccountID = UUID()
        let customCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-existing").validated()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: customAccountID,
                        platform: .codex,
                        identifier: customCredential.accountIdentifier,
                        displayName: "Custom Existing",
                        email: customCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "Custom Existing",
                        baseURL: "https://api.deepseek.com/v1",
                        envName: "DEEPSEEK_API_KEY",
                        model: "deepseek-chat"
                    ),
                    payload: .providerAPIKey(customCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        harness.model.openEditProvider(for: customAccountID)

        XCTAssertTrue(harness.model.availableProviderPresets.contains(where: { $0.id == ProviderCatalog.customPresetID }))
    }

    func testEditProviderKeepsExistingAPIKeyWhenFieldIsEmpty() async throws {
        let accountID = UUID()
        let customAccountID = UUID()
        let customCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-keep-old").validated()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: customAccountID,
                        platform: .codex,
                        identifier: customCredential.accountIdentifier,
                        displayName: "Custom Old",
                        email: customCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "Old Provider",
                        baseURL: "https://old.example.com/v1",
                        envName: "OLD_API_KEY",
                        model: "old-model"
                    ),
                    payload: .providerAPIKey(customCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        harness.model.openEditProvider(for: customAccountID)
        harness.model.apiKeyDisplayName = "Custom Updated"
        harness.model.addAccountProviderDisplayName = "Updated Provider"
        harness.model.addAccountProviderBaseURL = "https://new.example.com/v1"
        harness.model.addAccountProviderAPIKeyEnvName = "UPDATED_API_KEY"
        harness.model.addAccountDefaultModel = "new-model"
        harness.model.apiKeyInput = ""

        await harness.model.startAPIKeyLogin()

        let updatedAccount = try XCTUnwrap(harness.model.database.account(id: customAccountID))
        XCTAssertEqual(updatedAccount.id, customAccountID)
        XCTAssertEqual(updatedAccount.accountIdentifier, customCredential.accountIdentifier)
        XCTAssertEqual(updatedAccount.displayName, "Custom Updated")
        XCTAssertEqual(updatedAccount.providerDisplayName, "Updated Provider")
        XCTAssertEqual(updatedAccount.providerBaseURL, "https://new.example.com/v1")
        XCTAssertEqual(updatedAccount.providerAPIKeyEnvName, "UPDATED_API_KEY")
        XCTAssertEqual(updatedAccount.defaultModel, "new-model")
        XCTAssertEqual(try harness.credentialStore.load(for: customAccountID).providerAPIKeyCredential?.apiKey, "sk-custom-keep-old")
        XCTAssertFalse(harness.model.isEditingProviderAccount)
    }

    func testEditProviderUpdatesCredentialAndIdentifierWhenAPIKeyChanges() async throws {
        let accountID = UUID()
        let customAccountID = UUID()
        let oldCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-old-key").validated()
        let newCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-new-key").validated()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: customAccountID,
                        platform: .codex,
                        identifier: oldCredential.accountIdentifier,
                        displayName: "Custom Old",
                        email: oldCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "Old Provider",
                        baseURL: "https://old.example.com/v1",
                        envName: "OLD_API_KEY",
                        model: "old-model"
                    ),
                    payload: .providerAPIKey(oldCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        harness.model.openEditProvider(for: customAccountID)
        harness.model.apiKeyDisplayName = "Custom New"
        harness.model.addAccountProviderDisplayName = "New Provider"
        harness.model.addAccountProviderBaseURL = "https://new.example.com/v1"
        harness.model.addAccountProviderAPIKeyEnvName = "NEW_API_KEY"
        harness.model.addAccountDefaultModel = "new-model"
        harness.model.apiKeyInput = "sk-custom-new-key"

        await harness.model.startAPIKeyLogin()

        let updatedAccount = try XCTUnwrap(harness.model.database.account(id: customAccountID))
        XCTAssertEqual(updatedAccount.id, customAccountID)
        XCTAssertEqual(updatedAccount.accountIdentifier, newCredential.accountIdentifier)
        XCTAssertEqual(updatedAccount.displayName, "Custom New")
        XCTAssertEqual(updatedAccount.email, newCredential.credentialSummary)
        XCTAssertEqual(try harness.credentialStore.load(for: customAccountID).providerAPIKeyCredential?.apiKey, "sk-custom-new-key")
    }

    func testEditProviderRejectsConflictingAPIKey() async throws {
        let accountID = UUID()
        let firstCustomAccountID = UUID()
        let secondCustomAccountID = UUID()
        let firstCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-first").validated()
        let secondCredential = try ProviderAPIKeyCredential(apiKey: "sk-custom-second").validated()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: firstCustomAccountID,
                        platform: .codex,
                        identifier: firstCredential.accountIdentifier,
                        displayName: "First Custom",
                        email: firstCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "First Provider",
                        baseURL: "https://first.example.com/v1",
                        envName: "FIRST_API_KEY",
                        model: "first-model"
                    ),
                    payload: .providerAPIKey(firstCredential),
                    snapshot: nil
                ),
                AccountSeed(
                    account: makeProviderAccount(
                        id: secondCustomAccountID,
                        platform: .codex,
                        identifier: secondCredential.accountIdentifier,
                        displayName: "Second Custom",
                        email: secondCredential.credentialSummary,
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "Second Provider",
                        baseURL: "https://second.example.com/v1",
                        envName: "SECOND_API_KEY",
                        model: "second-model"
                    ),
                    payload: .providerAPIKey(secondCredential),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()

        harness.model.openEditProvider(for: firstCustomAccountID)
        harness.model.apiKeyInput = "sk-custom-second"
        harness.model.addAccountDefaultModel = "updated-model"

        await harness.model.startAPIKeyLogin()

        let unchangedAccount = try XCTUnwrap(harness.model.database.account(id: firstCustomAccountID))
        XCTAssertEqual(unchangedAccount.accountIdentifier, firstCredential.accountIdentifier)
        XCTAssertEqual(try harness.credentialStore.load(for: firstCustomAccountID).providerAPIKeyCredential?.apiKey, "sk-custom-first")
        XCTAssertEqual(
            harness.model.addAccountError,
            L10n.tr("这个 API Key 已属于账号 %@，请使用其他 Key。", "Second Custom")
        )
        XCTAssertTrue(harness.model.isEditingProviderAccount)
    }

    func testClaudeCompatibleProviderAccountOpensCodexCLIThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingClaudeProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .claude,
                        identifier: "acct_claude_provider",
                        displayName: "Claude API",
                        email: "sk-...claude",
                        rule: .claudeCompatible,
                        presetID: "anthropic",
                        baseURL: "https://api.anthropic.com/v1",
                        envName: "ANTHROPIC_API_KEY",
                        model: "claude-sonnet-4.5"
                    ),
                    payload: try makeProviderCredential("sk-ant-test-claude"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            claudeProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("claude-provider-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "ANTHROPIC_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-ant-test-claude")
        XCTAssertEqual(bridgeSnapshot.lastModel, "claude-sonnet-4.5")
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"], "claude-provider-bridge")
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18081\"") == true)
        XCTAssertEqual(harness.model.cliLaunchHistory(for: account.id).first?.target, .codex)
    }

    func testOpenAICompatibleProviderAccountOpensClaudeCodeThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_openai_provider",
                        displayName: "OpenAI",
                        email: "sk-...openai",
                        rule: .openAICompatible,
                        presetID: "openai",
                        baseURL: "https://api.openai.com/v1",
                        envName: "OPENAI_API_KEY",
                        model: "gpt-5.4"
                    ),
                    payload: try makeProviderCredential("sk-openai-test"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("openai-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://api.openai.com/v1",
                apiKeyEnvName: "OPENAI_API_KEY",
                apiKey: "sk-openai-test",
                supportsResponsesAPI: true
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "gpt-5.4")
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertNil(claudeCLILauncher.lastContext?.executableOverrideURL)
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot,
            ResolvedClaudeProviderSnapshot(
                source: .inheritCodexEnvironment,
                model: "gpt-5.4",
                modelProvider: "openai",
                baseURL: "http://127.0.0.1:18080",
                apiKeyEnvName: "ANTHROPIC_API_KEY",
                availableModels: ["gpt-5.4"]
            )
        )
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_BASE_URL"], "http://127.0.0.1:18080")
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_API_KEY"], "codex-oauth-bridge")
    }

    func testDeepSeekProviderAccountOpensClaudeCodeThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_deepseek_provider",
                        displayName: "DeepSeek",
                        email: "sk-...deepseek",
                        rule: .openAICompatible,
                        presetID: "deepseek",
                        baseURL: "https://api.deepseek.com/v1",
                        envName: "DEEPSEEK_API_KEY",
                        model: "deepseek-chat"
                    ),
                    payload: try makeProviderCredential("sk-deepseek-test"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("deepseek-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://api.deepseek.com/v1",
                apiKeyEnvName: "DEEPSEEK_API_KEY",
                apiKey: "sk-deepseek-test",
                supportsResponsesAPI: false
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "deepseek-chat")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["deepseek-chat"])
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.availableModels, ["deepseek-chat"])
    }

    func testMoonshotProviderAccountOpensClaudeCodeThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_moonshot_provider",
                        displayName: "Moonshot",
                        email: "sk-...moonshot",
                        rule: .openAICompatible,
                        presetID: "moonshot",
                        baseURL: "https://api.moonshot.cn/v1",
                        envName: "MOONSHOT_API_KEY",
                        model: "kimi-k2-0711-preview"
                    ),
                    payload: try makeProviderCredential("sk-moonshot-test"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("moonshot-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://api.moonshot.cn/v1",
                apiKeyEnvName: "MOONSHOT_API_KEY",
                apiKey: "sk-moonshot-test",
                supportsResponsesAPI: false
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "kimi-k2-0711-preview")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["kimi-k2-0711-preview"])
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertNil(claudeCLILauncher.lastContext?.executableOverrideURL)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.availableModels, ["kimi-k2-0711-preview"])
    }

    func testMiniMaxOpenAICompatibleProviderAccountOpensClaudeCodeThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_minimax_provider",
                        displayName: "MiniMax",
                        email: "sk-...minimax",
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "MiniMax",
                        baseURL: "https://api.minimax.io/v1",
                        envName: "MINIMAX_API_KEY",
                        model: "MiniMax-M2.7"
                    ),
                    payload: try makeProviderCredential("sk-minimax-openai"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("minimax-openai-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://api.minimax.io/v1",
                apiKeyEnvName: "MINIMAX_API_KEY",
                apiKey: "sk-minimax-openai",
                supportsResponsesAPI: false
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "MiniMax-M2.7")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["MiniMax-M2.7"])
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertNil(claudeCLILauncher.lastContext?.executableOverrideURL)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.availableModels, ["MiniMax-M2.7"])
    }

    func testZAIProviderAccountOpensClaudeCodeThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_zai_provider",
                        displayName: "Z.AI",
                        email: "sk-...zai",
                        rule: .openAICompatible,
                        presetID: "zai",
                        baseURL: "https://api.z.ai/api/coding/paas/v4",
                        envName: "ZAI_API_KEY",
                        model: "glm-5"
                    ),
                    payload: try makeProviderCredential("sk-zai-test"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("zai-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                apiKeyEnvName: "ZAI_API_KEY",
                apiKey: "sk-zai-test",
                supportsResponsesAPI: false
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "glm-5")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["glm-5"])
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.availableModels, ["glm-5"])
    }

    func testMiniMaxClaudeCompatibleProviderAccountOpensClaudeCodeWithAnthropicAuthToken() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .claude,
                        identifier: "acct_minimax_claude",
                        displayName: "MiniMax Claude",
                        email: "sk-...minimax",
                        rule: .claudeCompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "MiniMax",
                        baseURL: "https://api.minimax.io/anthropic/v1",
                        envName: "MINIMAX_API_KEY",
                        model: "MiniMax-M2.7"
                    ),
                    payload: try makeProviderCredential("sk-minimax-claude"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("minimax-claude-direct")
        )

        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertNil(claudeCLILauncher.lastContext?.executableOverrideURL)
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot,
            ResolvedClaudeProviderSnapshot(
                source: .explicitProvider,
                model: "MiniMax-M2.7",
                modelProvider: nil,
                baseURL: "https://api.minimax.io/anthropic",
                apiKeyEnvName: "MINIMAX_API_KEY",
                availableModels: ["MiniMax-M2.7"]
            )
        )
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_BASE_URL"], "https://api.minimax.io/anthropic")
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_AUTH_TOKEN"], "sk-minimax-claude")
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["MINIMAX_API_KEY"], "sk-minimax-claude")
        XCTAssertNil(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_API_KEY"])
        XCTAssertEqual(harness.model.defaultCLITarget(for: account), .claude)
    }

    func testClaudeCompatibleProviderAccountOpensClaudeCodeDirectly() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .claude,
                        identifier: "acct_claude_direct",
                        displayName: "Claude Direct",
                        email: "sk-...direct",
                        rule: .claudeCompatible,
                        presetID: "anthropic",
                        baseURL: "https://api.anthropic.com/v1",
                        envName: "ANTHROPIC_API_KEY",
                        model: "claude-sonnet-4.5"
                    ),
                    payload: try makeProviderCredential("sk-ant-direct"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("claude-direct"))

        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertNil(claudeCLILauncher.lastContext?.executableOverrideURL)
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot,
            ResolvedClaudeProviderSnapshot(
                source: .explicitProvider,
                model: "claude-sonnet-4.5",
                modelProvider: nil,
                baseURL: "https://api.anthropic.com/v1",
                apiKeyEnvName: "ANTHROPIC_API_KEY",
                availableModels: ["claude-sonnet-4.5"]
            )
        )
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_BASE_URL"], "https://api.anthropic.com/v1")
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_API_KEY"], "sk-ant-direct")
        XCTAssertEqual(harness.model.defaultCLITarget(for: account), .claude)
    }

    func testChatGPTAccountOpensClaudeCodeUsingCodexOAuthBridge() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let authFileManager = RecordingAuthFileManager()
        authFileManager.currentAuth = cachedPayload
        let claudeCLILauncher = RecordingClaudeCLILauncher()
        let patchedRuntimeManager = RecordingClaudePatchedRuntimeManager()
        patchedRuntimeManager.executableOverrideURL = patchedRuntimeManager.runtimeURL
        let bridgeManager = RecordingCodexOAuthClaudeBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: patchedRuntimeManager,
            codexOAuthClaudeBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.openCLI(
            for: account,
            target: .claude,
            workingDirectoryURL: makeWorkingDirectoryURL("chatgpt-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, accountID)
        XCTAssertEqual(bridgeSnapshot.lastSource, .codexAuthPayload(cachedPayload))
        XCTAssertEqual(bridgeSnapshot.lastModel, "gpt-5.4")
        XCTAssertEqual(
            bridgeSnapshot.lastAvailableModels,
            [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.2",
                "gpt-5.1-codex-mini",
            ]
        )
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertEqual(claudeCLILauncher.lastContext?.executableOverrideURL, patchedRuntimeManager.runtimeURL)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.source, .inheritCodexEnvironment)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.model, "gpt-5.4")
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot?.availableModels,
            [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.2",
                "gpt-5.1-codex-mini",
            ]
        )
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_BASE_URL"], "http://127.0.0.1:18080")
        XCTAssertEqual(claudeCLILauncher.lastContext?.environmentVariables["ANTHROPIC_API_KEY"], "codex-oauth-bridge")
    }

    func testCLILaunchHistoryStoresOnlyPathAndTarget() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let claudeCLILauncher = RecordingClaudeCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .claude,
                        identifier: "acct_history_provider",
                        displayName: "Claude History",
                        email: "sk-...history",
                        rule: .claudeCompatible,
                        presetID: "anthropic",
                        baseURL: "https://api.anthropic.com/v1",
                        envName: "ANTHROPIC_API_KEY",
                        model: "claude-sonnet-4.5"
                    ),
                    payload: try makeProviderCredential("sk-ant-history"),
                    snapshot: nil
                )
            ],
            claudeCLILauncher: claudeCLILauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))
        let workingDirectoryURL = makeWorkingDirectoryURL("cli-history")

        await harness.model.openCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        let record = try XCTUnwrap(harness.model.cliLaunchHistory(for: account.id).first)
        XCTAssertEqual(record.path, workingDirectoryURL.path)
        XCTAssertEqual(record.target, .claude)
    }

    func testCLILaunchHistoryKeepsSamePathForDifferentTargets() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let codexCLILauncher = RecordingCodexCLILauncher()
        let claudeCLILauncher = RecordingClaudeCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: codexCLILauncher,
            claudeCLILauncher: claudeCLILauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("shared-cli-history")

        await harness.model.openCLI(for: account, target: .codex, workingDirectoryURL: workingDirectoryURL)
        await harness.model.openCLI(for: account, target: .claude, workingDirectoryURL: workingDirectoryURL)

        let history = harness.model.cliLaunchHistory(for: account.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.path), [workingDirectoryURL.path, workingDirectoryURL.path])
        XCTAssertEqual(history.map(\.target), [.claude, .codex])
    }

    func testClaudeProfileAccountCannotOpenCodexCLI() async throws {
        let accountID = UUID()
        let claudeAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: claudeAccountID,
                        platform: .claude,
                        codexAccountID: "claude-profile",
                        displayName: "Claude Profile",
                        email: nil,
                        authMode: .claudeProfile,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .claudeProfile(ClaudeProfileSnapshotRef(snapshotID: "snapshot_codex_blocked")),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: claudeAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("claude-profile-codex"))

        XCTAssertEqual(codexCLILauncher.launchCallCount, 0)
        XCTAssertEqual(
            harness.model.banner?.message,
            L10n.tr(
                "打开 %@ 失败：%@",
                CLIEnvironmentTarget.codex.displayName,
                CLIEnvironmentResolverError.codexCLINotSupported.localizedDescription
            )
        )
    }

    func testDeepSeekProviderAccountOpensCodexCLIThroughChatCompletionsBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingOpenAICompatibleProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_deepseek_provider",
                        displayName: "DeepSeek",
                        email: "sk-...deepseek",
                        rule: .openAICompatible,
                        presetID: "deepseek",
                        baseURL: "https://api.deepseek.com/v1",
                        envName: "DEEPSEEK_API_KEY",
                        model: "deepseek-reasoner"
                    ),
                    payload: try makeProviderCredential("sk-deepseek-test"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            openAICompatibleProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("deepseek-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "DEEPSEEK_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-deepseek-test")
        XCTAssertEqual(bridgeSnapshot.lastModel, "deepseek-reasoner")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["deepseek-reasoner"])
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"],
            "openai-compatible-provider-bridge"
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18082\"") == true)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["deepseek-reasoner"])
        )
    }

    func testCopilotAccountOpensCodexCLIUsingLiveModelCatalog() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-5.3-codex",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential),
            statusResult: .success(
                CopilotAccountStatus(
                    availableModels: ["gpt-4.1", "gpt-4o"],
                    currentModel: "gpt-4.1",
                    quotaSnapshot: nil
                )
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-5.3-codex",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider,
            cliLauncher: codexCLILauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("copilot-codex-live-models"))

        let providerSnapshot = await copilotProvider.snapshot()
        let refreshedAccount = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))
        XCTAssertEqual(providerSnapshot.resolveCallCount, 1)
        XCTAssertEqual(providerSnapshot.fetchStatusCallCount, 1)
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-4.1", "gpt-4o"])
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("model = \"gpt-4.1\"") == true)
        XCTAssertEqual(refreshedAccount.defaultModel, "gpt-4.1")
    }

    func testMoonshotProviderAccountOpensCodexCLIThroughChatCompletionsBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingOpenAICompatibleProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_moonshot_provider",
                        displayName: "Moonshot",
                        email: "sk-...moonshot",
                        rule: .openAICompatible,
                        presetID: "moonshot",
                        baseURL: "https://api.moonshot.cn/v1",
                        envName: "MOONSHOT_API_KEY",
                        model: "kimi-k2-0711-preview"
                    ),
                    payload: try makeProviderCredential("sk-moonshot-test"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            openAICompatibleProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("moonshot-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.moonshot.cn/v1")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "MOONSHOT_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-moonshot-test")
        XCTAssertEqual(bridgeSnapshot.lastModel, "kimi-k2-0711-preview")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["kimi-k2-0711-preview"])
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"],
            "openai-compatible-provider-bridge"
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18082\"") == true)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["kimi-k2-0711-preview"])
        )
    }

    func testMiniMaxOpenAICompatibleProviderAccountOpensCodexCLIThroughChatCompletionsBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingOpenAICompatibleProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_minimax_provider",
                        displayName: "MiniMax",
                        email: "sk-...minimax",
                        rule: .openAICompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "MiniMax",
                        baseURL: "https://api.minimaxi.com/v1",
                        envName: "MINIMAX_API_KEY",
                        model: "MiniMax-M2.7"
                    ),
                    payload: try makeProviderCredential("sk-minimax-openai"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            openAICompatibleProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("minimax-openai-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.minimaxi.com/v1")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "MINIMAX_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-minimax-openai")
        XCTAssertEqual(bridgeSnapshot.lastModel, "MiniMax-M2.7")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["MiniMax-M2.7"])
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"],
            "openai-compatible-provider-bridge"
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18082\"") == true)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(
                availableModels: ["MiniMax-M2.7"],
                supportsParallelToolCalls: false
            )
        )
    }

    func testMiniMaxClaudeCompatibleProviderAccountOpensCodexCLIThroughBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingClaudeProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .claude,
                        identifier: "acct_minimax_claude",
                        displayName: "MiniMax Claude",
                        email: "sk-...minimax",
                        rule: .claudeCompatible,
                        presetID: ProviderCatalog.customPresetID,
                        providerDisplayName: "MiniMax",
                        baseURL: "https://api.minimax.io/anthropic/v1",
                        envName: "MINIMAX_API_KEY",
                        model: "MiniMax-M2.7"
                    ),
                    payload: try makeProviderCredential("sk-minimax-claude"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            claudeProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("minimax-claude-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.minimax.io/anthropic/v1")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "MINIMAX_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-minimax-claude")
        XCTAssertEqual(bridgeSnapshot.lastModel, "MiniMax-M2.7")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["MiniMax-M2.7"])
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"],
            "claude-provider-bridge"
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18081\"") == true)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["MiniMax-M2.7"])
        )
    }

    func testZAIProviderAccountOpensCodexCLIThroughChatCompletionsBridge() async throws {
        let accountID = UUID()
        let providerAccountID = UUID()
        let codexCLILauncher = RecordingCodexCLILauncher()
        let bridgeManager = RecordingOpenAICompatibleProviderCodexBridgeManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            extraSeeds: [
                AccountSeed(
                    account: makeProviderAccount(
                        id: providerAccountID,
                        platform: .codex,
                        identifier: "acct_zai_provider",
                        displayName: "Z.AI",
                        email: "sk-...zai",
                        rule: .openAICompatible,
                        presetID: "zai",
                        baseURL: "https://api.z.ai/api/coding/paas/v4",
                        envName: "ZAI_API_KEY",
                        model: "glm-5"
                    ),
                    payload: try makeProviderCredential("sk-zai-test"),
                    snapshot: nil
                )
            ],
            cliLauncher: codexCLILauncher,
            openAICompatibleProviderCodexBridgeManager: bridgeManager
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.database.account(id: providerAccountID))

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: makeWorkingDirectoryURL("zai-codex"))

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(bridgeSnapshot.lastBaseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(bridgeSnapshot.lastAPIKeyEnvName, "ZAI_API_KEY")
        XCTAssertEqual(bridgeSnapshot.lastAPIKey, "sk-zai-test")
        XCTAssertEqual(bridgeSnapshot.lastModel, "glm-5")
        XCTAssertEqual(bridgeSnapshot.lastAvailableModels, ["glm-5"])
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["glm-5"])
        )
    }

    func testRefreshAllAccountStatusesRefreshesUnifiedQueue() async throws {
        let accountID = UUID()
        let claudeAccountID = UUID()
        let apiKeyPayload = try makeAPIKeyPayload("sk-test-unified-refresh")

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: apiKeyPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: claudeAccountID,
                        platform: .claude,
                        codexAccountID: "claude-profile-refresh",
                        displayName: "Claude Profile",
                        email: nil,
                        authMode: .claudeProfile,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .claudeProfile(ClaudeProfileSnapshotRef(snapshotID: "snapshot_refresh_all")),
                    snapshot: nil
                )
            ]
        )

        await harness.model.prepare()
        await harness.model.refreshAllAccountStatuses()

        let codexAccount = try XCTUnwrap(harness.model.database.account(id: accountID))
        let claudeAccount = try XCTUnwrap(harness.model.database.account(id: claudeAccountID))
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已完成 %d 个账号的状态与额度更新。", 2))
        XCTAssertNotNil(codexAccount.lastStatusCheckAt)
        XCTAssertNotNil(claudeAccount.lastStatusCheckAt)
        XCTAssertEqual(codexAccount.lastStatusLevel, .info)
        XCTAssertEqual(claudeAccount.lastStatusLevel, .info)
    }

    func testLowQuotaRecommendationNotifiesAndSupportsQuickSwitch() async throws {
        let activeAccountID = UUID()
        let candidateAccountID = UUID()
        let activePayload = makePayload(accountID: "acct_active", refreshToken: "refresh_active")
        let candidatePayload = makePayload(accountID: "acct_candidate", refreshToken: "refresh_candidate")
        let quotaMonitor = ControllableQuotaMonitor()
        let notifier = RecordingUserNotifier()
        let candidateSnapshot = QuotaSnapshot(
            primary: RateLimitWindowSnapshot(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
            secondary: RateLimitWindowSnapshot(usedPercent: 22, windowMinutes: 10080, resetsAt: nil),
            credits: nil,
            planType: "plus",
            capturedAt: Date(),
            source: .onlineUsageRefresh
        )

        let harness = try await makeHarness(
            accountID: activeAccountID,
            cachedPayload: activePayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .noRunningClient, isRunning: false),
            activeAccountID: activeAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: candidateAccountID,
                        codexAccountID: candidatePayload.accountIdentifier,
                        displayName: "Candidate User",
                        email: "candidate@example.com",
                        authMode: candidatePayload.authMode,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: candidateSnapshot.capturedAt,
                        lastRefreshAt: Date(),
                        planType: "plus",
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: false
                    ),
                    payload: .codex(candidatePayload),
                    snapshot: candidateSnapshot
                )
            ],
            quotaMonitor: quotaMonitor,
            userNotifier: notifier
        )

        await harness.model.prepare()

        let lowSnapshot = QuotaSnapshot(
            primary: RateLimitWindowSnapshot(usedPercent: 91, windowMinutes: 300, resetsAt: nil),
            secondary: RateLimitWindowSnapshot(usedPercent: 35, windowMinutes: 10080, resetsAt: nil),
            credits: nil,
            planType: "plus",
            capturedAt: Date(),
            source: .sessionTokenCount
        )

        quotaMonitor.emitSnapshot(accountID: activeAccountID, snapshot: lowSnapshot)
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.model.lowQuotaSwitchRecommendation?.recommendedAccountID, candidateAccountID)
        XCTAssertEqual(harness.model.lowQuotaSwitchRecommendation?.recommendedAccountName, "Candidate User")
        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.identifier, "\(activeAccountID.uuidString)|\(candidateAccountID.uuidString)")
        XCTAssertTrue(notifications.first?.body.contains("Candidate User") == true)

        await harness.model.switchToRecommendedLowQuotaAccount()

        XCTAssertEqual(harness.model.activeAccount?.id, candidateAccountID)
        XCTAssertNil(harness.model.lowQuotaSwitchRecommendation)
    }

    func testLaunchIsolatedCodexBlocksActiveChatGPTAccount() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let launcher = RecordingCodexInstanceLauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            instanceLauncher: launcher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        XCTAssertTrue(account.isActive)
        XCTAssertFalse(harness.model.canLaunchIsolatedCodex(for: account))

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 0)
        XCTAssertNil(launcher.lastPayload)
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("当前活跃的 ChatGPT 账号不能直接启动独立实例，避免触发 refresh_token_reused。"))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
    }

    func testLaunchIsolatedCodexSupportsActiveProviderAccount() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-5.4",
                availableModels: ["gpt-5.4", "gpt-4.1"]
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        XCTAssertTrue(account.isActive)
        XCTAssertTrue(harness.model.canLaunchIsolatedCodex(for: account))

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 0)
        XCTAssertEqual(
            harness.model.isolatedCodexModelSelection,
            IsolatedCodexModelSelectionState(
                accountID: account.id,
                accountDisplayName: account.displayName,
                availableModels: ["gpt-5.4", "gpt-4.1"],
                availableReasoningEfforts: ["low", "medium", "high", "xhigh"],
                selectedModel: "gpt-5.4",
                selectedReasoningEffort: "medium"
            )
        )
        harness.model.updateIsolatedCodexModelSelection("gpt-4.1")
        harness.model.updateIsolatedCodexModelSelectionReasoningEffort("high")

        await harness.model.confirmIsolatedCodexModelSelection()

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertNil(launcher.lastPayload)
        XCTAssertEqual(launcher.lastContext?.environmentVariables["OPENAI_API_KEY"], "sk-test-old")
        XCTAssertEqual(launcher.lastContext?.modelCatalogSnapshot, ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-4.1"]))
        XCTAssertEqual(harness.model.accounts.first?.defaultModel, "gpt-4.1")
        XCTAssertEqual(harness.model.accounts.first?.defaultModelReasoningEffort, "high")
        XCTAssertTrue(launcher.lastContext?.configFileContents?.contains("model_reasoning_effort = \"high\"") == true)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
    }

    func testLaunchIsolatedCodexSupportsGitHubCopilotAccount() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-4.1",
                availableModels: ["gpt-4.1", "claude-opus-4.1"]
            )
        )
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential)
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotProvider: copilotProvider,
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        XCTAssertTrue(account.isActive)
        XCTAssertTrue(harness.model.canLaunchIsolatedCodex(for: account))

        await harness.model.launchIsolatedCodex(for: account)

        let providerSnapshot = await copilotProvider.snapshot()
        XCTAssertEqual(providerSnapshot.resolveCallCount, 1)
        XCTAssertEqual(launcher.launchCallCount, 0)
        XCTAssertEqual(
            harness.model.isolatedCodexModelSelection,
            IsolatedCodexModelSelectionState(
                accountID: copilotAccountID,
                accountDisplayName: "GitHub Copilot • aikilan",
                availableModels: ["gpt-4.1", "claude-opus-4.1"],
                availableReasoningEfforts: ["low", "medium", "high", "xhigh"],
                selectedModel: "gpt-4.1",
                selectedReasoningEffort: "medium"
            )
        )
        harness.model.updateIsolatedCodexModelSelection("claude-opus-4.1")
        harness.model.updateIsolatedCodexModelSelectionReasoningEffort("xhigh")

        await harness.model.confirmIsolatedCodexModelSelection()

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertNil(launcher.lastPayload)
        XCTAssertEqual(launcher.lastContext?.accountID, copilotAccountID)
        XCTAssertEqual(
            launcher.lastContext?.modelCatalogSnapshot,
            ResolvedCodexModelCatalogSnapshot(availableModels: ["claude-opus-4.1"])
        )
        XCTAssertEqual(
            harness.model.accounts.first(where: { $0.id == copilotAccountID })?.defaultModel,
            "claude-opus-4.1"
        )
        XCTAssertEqual(
            harness.model.accounts.first(where: { $0.id == copilotAccountID })?.defaultModelReasoningEffort,
            "xhigh"
        )
        XCTAssertTrue(launcher.lastContext?.configFileContents?.contains("model_reasoning_effort = \"xhigh\"") == true)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
    }

    func testConfirmCopilotCLIInstallAutomaticallyRetriesCopilotIsolatedLaunch() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-4.1",
                availableModels: ["gpt-4.1"]
            )
        )
        resolver.desktopContextResults = [
            .failure(CopilotACPClientError.cliUnavailable),
        ]
        let installer = RecordingCopilotCLIInstaller()
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential)
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotCLIInstaller: installer,
            copilotProvider: copilotProvider,
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        await harness.model.launchIsolatedCodex(for: account)
        XCTAssertNotNil(harness.model.isolatedCodexModelSelection)

        await harness.model.confirmIsolatedCodexModelSelection()
        XCTAssertNotNil(harness.model.copilotCLIInstallPrompt)
        XCTAssertEqual(launcher.launchCallCount, 0)

        await harness.model.confirmCopilotCLIInstall()

        let installCallCount = await installer.snapshot()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertNil(harness.model.copilotCLIInstallPrompt)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
    }

    func testConfirmCopilotCLIInstallShowsErrorWhenAutomaticInstallFails() async throws {
        let accountID = UUID()
        let copilotAccountID = UUID()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-4.1",
                availableModels: ["gpt-4.1"]
            )
        )
        resolver.desktopContextResults = [
            .failure(CopilotACPClientError.cliUnavailable),
        ]
        let installer = RecordingCopilotCLIInstaller(result: .failure(MockError.cliLaunchFailed))
        let copilotCredential = CopilotCredential(
            host: "https://github.com",
            login: "aikilan",
            accessToken: "copilot_access_token",
            defaultModel: "gpt-4.1",
            source: .localImport
        )
        let copilotProvider = RecordingCopilotProvider(
            resolveCredentialResult: .success(copilotCredential)
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: makePayload(accountID: "acct_cached", refreshToken: "refresh_old"),
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: copilotAccountID,
            extraSeeds: [
                AccountSeed(
                    account: ManagedAccount(
                        id: copilotAccountID,
                        platform: .codex,
                        accountIdentifier: copilotCredential.accountIdentifier,
                        displayName: "GitHub Copilot • aikilan",
                        email: copilotCredential.credentialSummary,
                        authKind: .githubCopilot,
                        providerRule: .githubCopilot,
                        providerPresetID: nil,
                        providerDisplayName: "GitHub Copilot",
                        providerBaseURL: nil,
                        providerAPIKeyEnvName: nil,
                        defaultModel: "gpt-4.1",
                        defaultCLITarget: .codex,
                        createdAt: Date(),
                        lastUsedAt: nil,
                        lastQuotaSnapshotAt: nil,
                        lastRefreshAt: nil,
                        planType: nil,
                        subscriptionDetails: nil,
                        lastStatusCheckAt: nil,
                        lastStatusMessage: nil,
                        lastStatusLevel: nil,
                        isActive: true
                    ),
                    payload: .copilot(copilotCredential),
                    snapshot: nil
                )
            ],
            copilotCLIInstaller: installer,
            copilotProvider: copilotProvider,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first(where: { $0.id == copilotAccountID }))

        await harness.model.launchIsolatedCodex(for: account)
        await harness.model.confirmIsolatedCodexModelSelection()
        XCTAssertNotNil(harness.model.copilotCLIInstallPrompt)

        await harness.model.confirmCopilotCLIInstall()

        let installCallCount = await installer.snapshot()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertNil(harness.model.copilotCLIInstallPrompt)
        XCTAssertEqual(
            harness.model.banner?.message,
            L10n.tr("GitHub Copilot CLI 自动安装失败：%@", MockError.cliLaunchFailed.localizedDescription)
        )
        XCTAssertNotNil(harness.model.isolatedCodexModelSelection)
    }

    func testCancelIsolatedCodexModelSelectionDoesNotLaunchOrPersistModel() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-5.4",
                availableModels: ["gpt-5.4", "gpt-4.1"]
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.launchIsolatedCodex(for: account)
        harness.model.updateIsolatedCodexModelSelection("gpt-4.1")
        harness.model.updateIsolatedCodexModelSelectionReasoningEffort("high")
        harness.model.cancelIsolatedCodexModelSelection()

        XCTAssertEqual(launcher.launchCallCount, 0)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertEqual(harness.model.accounts.first?.defaultModel, "gpt-5.4")
        XCTAssertNil(harness.model.accounts.first?.defaultModelReasoningEffort)
    }

    func testLaunchIsolatedCodexShowsModelSelectionFailure() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .failure(MockError.cliLaunchFailed)

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 0)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertEqual(harness.model.isolatedCodexModelSelectionError, "cli launch failed")
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("加载启动模型失败：%@", "cli launch failed"))
    }

    func testConfirmIsolatedCodexModelSelectionLaunchesSingleModelAccount() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        resolver.desktopModelSelectionResult = .success(
            ResolvedCodexDesktopModelSelection(
                selectedModel: "gpt-5.4",
                availableModels: ["gpt-5.4"]
            )
        )

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.launchIsolatedCodex(for: account)
        await harness.model.confirmIsolatedCodexModelSelection()

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertNil(harness.model.isolatedCodexModelSelection)
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
    }

    func testStartProviderDesktopLaunchValidatesRequiredFields() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified)
        )

        await harness.model.prepare()
        harness.model.prepareProviderDesktopLaunch()
        harness.model.desktopLaunchDefaultModel = "deepseek-chat"

        let missingKey = await harness.model.startProviderDesktopLaunch()
        XCTAssertFalse(missingKey)
        XCTAssertEqual(harness.model.desktopLaunchError, L10n.tr("请输入 API Key。"))

        harness.model.desktopLaunchAPIKeyInput = "sk-test"
        harness.model.desktopLaunchDefaultModel = ""

        let missingModel = await harness.model.startProviderDesktopLaunch()
        XCTAssertFalse(missingModel)
        XCTAssertEqual(harness.model.desktopLaunchError, L10n.tr("请输入默认模型。"))
    }

    func testStartProviderDesktopLaunchSavesAccountAndLaunchesDesktopContext() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let launcher = RecordingCodexInstanceLauncher()
        let resolver = RecordingDesktopCLIEnvironmentResolver()
        let authFileManager = RecordingAuthFileManager()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: authFileManager,
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher,
            cliEnvironmentResolver: resolver
        )

        await harness.model.prepare()
        harness.model.prepareProviderDesktopLaunch()
        harness.model.desktopLaunchPresetID = "deepseek"
        harness.model.applyDesktopLaunchPreset(ProviderCatalog.preset(id: "deepseek"))
        harness.model.desktopLaunchDisplayName = "DeepSeek Work"
        harness.model.desktopLaunchDefaultModel = "deepseek-chat"
        harness.model.desktopLaunchAPIKeyInput = "sk-deepseek"

        let didLaunch = await harness.model.startProviderDesktopLaunch()

        XCTAssertTrue(didLaunch)
        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertNil(launcher.lastPayload)
        XCTAssertEqual(launcher.lastContext?.environmentVariables["DEEPSEEK_API_KEY"], "sk-deepseek")
        XCTAssertTrue(launcher.lastContext?.configFileContents?.contains("model = \"deepseek-chat\"") == true)
        XCTAssertTrue(launcher.lastContext?.configFileContents?.contains("model_reasoning_effort = \"medium\"") == true)
        XCTAssertEqual(launcher.lastContext?.modelCatalogSnapshot, ResolvedCodexModelCatalogSnapshot(availableModels: ["deepseek-chat"]))
        XCTAssertTrue(authFileManager.activatedPayloads.isEmpty)

        let savedAccount = try XCTUnwrap(
            harness.model.accounts.first(where: {
                $0.providerRule == .openAICompatible && $0.providerPresetID == "deepseek"
            })
        )
        XCTAssertEqual(savedAccount.displayName, "DeepSeek Work")
        XCTAssertEqual(savedAccount.defaultModel, "deepseek-chat")
        XCTAssertEqual(savedAccount.providerBaseURL, ProviderCatalog.preset(id: "deepseek")?.baseURL)
        XCTAssertEqual(savedAccount.providerAPIKeyEnvName, ProviderCatalog.preset(id: "deepseek")?.apiKeyEnvName)
        XCTAssertEqual(harness.model.activeAccount?.id, savedAccount.id)
        XCTAssertEqual(harness.model.selectedAccount?.id, savedAccount.id)
        XCTAssertEqual(try harness.credentialStore.load(for: savedAccount.id).providerAPIKeyCredential?.apiKey, "sk-deepseek")
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已保存账号 %@，并启动独立 Codex 实例。", "DeepSeek Work"))
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: savedAccount.id))

        launcher.simulateTermination(for: savedAccount.id)
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(harness.model.hasLaunchedIsolatedInstance(for: savedAccount.id))
    }

    func testLaunchIsolatedCodexRefreshesChatGPTPayloadBeforeLaunching() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let refreshedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_new")
        let launcher = RecordingCodexInstanceLauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(
                refreshResult: .success(
                    AuthLoginResult(
                        payload: refreshedPayload,
                        identity: AuthIdentity(
                            accountID: "acct_cached",
                            displayName: "Refreshed User",
                            email: "refresh@example.com",
                            planType: "plus"
                        )
                    )
                )
            ),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        XCTAssertFalse(account.isActive)
        XCTAssertTrue(harness.model.canLaunchIsolatedCodex(for: account))

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertEqual(launcher.lastAccountID, accountID)
        XCTAssertEqual(launcher.lastPayload, refreshedPayload)
        XCTAssertEqual(launcher.lastAppSupportDirectoryURL, harness.model.paths.appSupportDirectoryURL)
        XCTAssertEqual(try harness.credentialStore.load(for: accountID), refreshedPayload)
        XCTAssertTrue(harness.model.database.switchLogs.contains { $0.message.contains(L10n.tr("独立实例启动前已在线刷新账号")) })
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 启动独立 Codex 实例。", account.displayName))
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.canLaunchIsolatedCodex(for: account))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
    }

    func testLaunchIsolatedCodexFallsBackToLocalPayloadWhenRefreshFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let launcher = RecordingCodexInstanceLauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        XCTAssertTrue(harness.model.canLaunchIsolatedCodex(for: account))

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertEqual(launcher.lastPayload, cachedPayload)
        XCTAssertTrue(
            harness.model.database.switchLogs.contains {
                $0.message.contains(L10n.tr("独立实例启动前在线刷新账号 %@ 失败", "Cached User"))
            }
        )
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 启动独立 Codex 实例。", account.displayName))
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.canLaunchIsolatedCodex(for: account))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
    }

    func testLaunchIsolatedCodexBlocksRepeatedLaunchAfterSuccess() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let launcher = RecordingCodexInstanceLauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.launchIsolatedCodex(for: account)
        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("账号 %@ 的独立实例已在当前会话中启动。", account.displayName))
        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.canLaunchIsolatedCodex(for: account))
    }

    func testLaunchIsolatedCodexClearsLaunchStateWhenInstanceTerminates() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let launcher = RecordingCodexInstanceLauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            instanceLauncher: launcher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)

        await harness.model.launchIsolatedCodex(for: account)

        XCTAssertTrue(harness.model.hasLaunchedIsolatedInstance(for: account.id))

        launcher.simulateTermination(for: account.id)
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertTrue(harness.model.canLaunchIsolatedCodex(for: account))
    }

    func testOpenCodexCLIUsesGlobalAuthForActiveAccountWithoutRefresh() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let oauthClient = MockOAuthClient(refreshResult: .failure(MockError.refreshFailed))
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .verified),
            activeAccountID: accountID,
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("global-cli")

        XCTAssertTrue(account.isActive)

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        XCTAssertEqual(oauthClient.refreshCallCount, 0)
        XCTAssertEqual(cliLauncher.launchCallCount, 1)
        XCTAssertEqual(cliLauncher.lastContext?.mode, .globalCurrentAuth)
        XCTAssertEqual(cliLauncher.lastContext?.workingDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [workingDirectoryURL.path])
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
        XCTAssertFalse(harness.model.isLaunchingCLI(for: account.id))
    }

    func testOpenCodexCLIRefreshesChatGPTPayloadBeforeLaunchingIsolatedCLI() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let refreshedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_new")
        let oauthClient = MockOAuthClient(
            refreshResult: .success(
                AuthLoginResult(
                    payload: refreshedPayload,
                    identity: AuthIdentity(
                        accountID: "acct_cached",
                        displayName: "Refreshed User",
                        email: "refresh@example.com",
                        planType: "plus"
                    )
                )
            )
        )
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("refreshed-cli")

        XCTAssertFalse(account.isActive)

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        XCTAssertEqual(oauthClient.refreshCallCount, 1)
        XCTAssertEqual(cliLauncher.launchCallCount, 1)
        XCTAssertEqual(cliLauncher.lastContext?.mode, .isolated)
        XCTAssertEqual(cliLauncher.lastContext?.authPayload, refreshedPayload)
        XCTAssertEqual(cliLauncher.lastContext?.workingDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(try harness.credentialStore.load(for: accountID), refreshedPayload)
        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [workingDirectoryURL.path])
        XCTAssertTrue(harness.model.database.switchLogs.contains { $0.message.contains(L10n.tr("打开 CLI 前已在线刷新账号")) })
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
        XCTAssertFalse(harness.model.isLaunchingCLI(for: account.id))
    }

    func testOpenCodexCLIFallsBackToLocalPayloadWhenRefreshFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let oauthClient = MockOAuthClient(refreshResult: .failure(MockError.refreshFailed))
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("fallback-cli")

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        XCTAssertEqual(oauthClient.refreshCallCount, 1)
        XCTAssertEqual(cliLauncher.launchCallCount, 1)
        XCTAssertEqual(cliLauncher.lastContext?.mode, .isolated)
        XCTAssertEqual(cliLauncher.lastContext?.authPayload, cachedPayload)
        XCTAssertEqual(cliLauncher.lastContext?.workingDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [workingDirectoryURL.path])
        XCTAssertTrue(
            harness.model.database.switchLogs.contains {
                $0.message.contains(L10n.tr("打开 CLI 前在线刷新账号 %@ 失败", "Cached User"))
            }
        )
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
        XCTAssertFalse(harness.model.isLaunchingCLI(for: account.id))
    }

    func testOpenCodexCLIOpensIsolatedCLIForAPIKeyAccount() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let oauthClient = MockOAuthClient(refreshResult: .failure(MockError.refreshFailed))
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: oauthClient,
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("apikey-cli")

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        XCTAssertEqual(oauthClient.refreshCallCount, 0)
        XCTAssertEqual(cliLauncher.launchCallCount, 1)
        XCTAssertEqual(cliLauncher.lastContext?.mode, .isolated)
        XCTAssertNil(cliLauncher.lastContext?.authPayload)
        XCTAssertNil(cliLauncher.lastContext?.modelCatalogSnapshot)
        XCTAssertTrue(cliLauncher.lastContext?.configFileContents?.contains("base_url = \"https://api.openai.com/v1\"") == true)
        XCTAssertEqual(cliLauncher.lastContext?.environmentVariables["OPENAI_API_KEY"], "sk-test-old")
        XCTAssertEqual(cliLauncher.lastContext?.workingDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [workingDirectoryURL.path])
        XCTAssertEqual(harness.model.banner?.message, L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
        XCTAssertFalse(harness.model.isLaunchingCLI(for: account.id))
    }

    func testOpenCodexCLIClearsLaunchingStateAndShowsErrorWhenLaunchFails() async throws {
        let accountID = UUID()
        let cachedPayload = makePayload(accountID: "acct_cached", refreshToken: "refresh_old")
        let cliLauncher = RecordingCodexCLILauncher()
        cliLauncher.error = MockError.cliLaunchFailed

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let workingDirectoryURL = makeWorkingDirectoryURL("failed-cli")

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: workingDirectoryURL)

        XCTAssertEqual(harness.model.banner?.message, L10n.tr("打开 Codex CLI 失败：%@", "cli launch failed"))
        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [])
        XCTAssertFalse(harness.model.isLaunchingCLI(for: account.id))
    }

    func testOpenCodexCLIRemembersDirectoriesMostRecentFirstWithoutDuplicates() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let firstDirectoryURL = makeWorkingDirectoryURL("first-cli")
        let secondDirectoryURL = makeWorkingDirectoryURL("second-cli")

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: firstDirectoryURL)
        await harness.model.openCodexCLI(for: account, workingDirectoryURL: secondDirectoryURL)
        await harness.model.openCodexCLI(for: account, workingDirectoryURL: firstDirectoryURL)

        XCTAssertEqual(
            harness.model.cliWorkingDirectories(for: account.id),
            [firstDirectoryURL.path, secondDirectoryURL.path]
        )
    }

    func testDeleteCLILaunchRecordRemovesSelectedDirectory() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
        let cliLauncher = RecordingCodexCLILauncher()

        let harness = try await makeHarness(
            accountID: accountID,
            cachedPayload: cachedPayload,
            authFileManager: RecordingAuthFileManager(),
            oauthClient: MockOAuthClient(refreshResult: .failure(MockError.refreshFailed)),
            runtimeInspector: MockRuntimeInspector(result: .verified),
            cliLauncher: cliLauncher
        )

        await harness.model.prepare()
        let account = try XCTUnwrap(harness.model.accounts.first)
        let firstDirectoryURL = makeWorkingDirectoryURL("first-cli")
        let secondDirectoryURL = makeWorkingDirectoryURL("second-cli")

        await harness.model.openCodexCLI(for: account, workingDirectoryURL: firstDirectoryURL)
        await harness.model.openCodexCLI(for: account, workingDirectoryURL: secondDirectoryURL)

        let record = try XCTUnwrap(
            harness.model.cliLaunchHistory(for: account.id).first(where: { $0.path == secondDirectoryURL.path })
        )

        harness.model.deleteCLILaunchRecord(record.id, for: account.id)

        XCTAssertEqual(harness.model.cliWorkingDirectories(for: account.id), [firstDirectoryURL.path])
    }

    private func makeHarness(
        accountID: UUID,
        cachedPayload: CodexAuthPayload,
        authFileManager: RecordingAuthFileManager,
        oauthClient: MockOAuthClient,
        runtimeInspector: MockRuntimeInspector,
        activeAccountID: UUID? = nil,
        extraSeeds: [AccountSeed] = [],
        terminalCommandLauncher: any TerminalCommandLaunching = RecordingTerminalCommandLauncher(),
        copilotCLIInstaller: any CopilotCLIInstalling = RecordingCopilotCLIInstaller(),
        openExternalURL: @escaping (URL) -> Void = { _ in },
        copilotProvider: any CopilotProviderServing = NoopCopilotProvider(),
        copilotStatusRefresher: (any CopilotStatusRefreshing)? = nil,
        copilotManagedConfigManager: (any CopilotManagedConfigManaging)? = NoopCopilotManagedConfigManager(),
        quotaMonitor: any QuotaMonitoring = NoopQuotaMonitor(),
        userNotifier: any UserNotifying = RecordingUserNotifier(),
        instanceLauncher: any CodexInstanceLaunching = RecordingCodexInstanceLauncher(),
        cliEnvironmentResolver: any CLIEnvironmentResolving = CLIEnvironmentResolver(),
        cliLauncher: any CodexCLILaunching = RecordingCodexCLILauncher(),
        claudeCLILauncher: any ClaudeCLILaunching = RecordingClaudeCLILauncher(),
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging = RecordingClaudePatchedRuntimeManager(),
        appSupportPathRepairer: any AppSupportPathRepairing = NoopAppSupportPathRepairer(),
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging = RecordingCodexOAuthClaudeBridgeManager(),
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging = RecordingOpenAICompatibleProviderCodexBridgeManager(),
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging = RecordingClaudeProviderCodexBridgeManager(),
        bannerAutoDismissDuration: Duration = .seconds(10),
        enableSessionLogger: Bool = false
    ) async throws -> AppViewModelHarness {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let paths = try AppPaths(fileManager: fileManager, codexHomeOverride: codexHome, appSupportOverride: appSupport)
        let databaseStore = AppDatabaseStore(databaseURL: paths.databaseURL)
        let credentialStore = InMemoryCredentialStore()
        let sessionLogger = enableSessionLogger ? try AppSessionLogger(appSupportDirectoryURL: appSupport) : nil

        let isPrimaryAccountActive = activeAccountID == accountID
        let account: ManagedAccount
        if cachedPayload.authMode == .apiKey {
            let credential = try ProviderAPIKeyCredential(apiKey: cachedPayload.openAIAPIKey ?? "").validated()
            try credentialStore.save(.providerAPIKey(credential), for: accountID)
            account = ManagedAccount(
                id: accountID,
                platform: .codex,
                accountIdentifier: credential.accountIdentifier,
                displayName: "Cached User",
                email: credential.credentialSummary,
                authKind: .providerAPIKey,
                providerRule: .openAICompatible,
                providerPresetID: "openai",
                providerDisplayName: "OpenAI",
                providerBaseURL: "https://api.openai.com/v1",
                providerAPIKeyEnvName: "OPENAI_API_KEY",
                defaultModel: "gpt-5.4",
                defaultCLITarget: .codex,
                createdAt: Date(),
                lastUsedAt: nil,
                lastQuotaSnapshotAt: nil,
                lastRefreshAt: nil,
                planType: nil,
                subscriptionDetails: nil,
                lastStatusCheckAt: nil,
                lastStatusMessage: nil,
                lastStatusLevel: nil,
                isActive: isPrimaryAccountActive
            )
        } else {
            try credentialStore.save(cachedPayload, for: accountID)
            account = ManagedAccount(
                id: accountID,
                platform: .codex,
                codexAccountID: cachedPayload.accountIdentifier,
                displayName: "Cached User",
                email: "cached@example.com",
                authMode: cachedPayload.authMode,
                createdAt: Date(),
                lastUsedAt: nil,
                lastQuotaSnapshotAt: nil,
                lastRefreshAt: nil,
                planType: nil,
                lastStatusCheckAt: nil,
                lastStatusMessage: nil,
                lastStatusLevel: nil,
                isActive: isPrimaryAccountActive
            )
        }
        let normalizedSeeds = extraSeeds.map { seed in
            var account = seed.account
            account.isActive = activeAccountID == seed.account.id
            return AccountSeed(account: account, payload: seed.payload, snapshot: seed.snapshot)
        }
        for seed in normalizedSeeds {
            try credentialStore.save(seed.payload, for: seed.account.id)
        }
        try await databaseStore.save(AppDatabase(
            version: AppDatabase.currentVersion,
            accounts: [account] + normalizedSeeds.map(\.account),
            quotaSnapshots: Dictionary(uniqueKeysWithValues: normalizedSeeds.compactMap { seed in
                guard let snapshot = seed.snapshot else { return nil }
                return (seed.account.id.uuidString, snapshot)
            }),
            switchLogs: [],
            activeAccountID: activeAccountID
        ))

        let model = AppViewModel(
            paths: paths,
            sessionLogger: sessionLogger,
            databaseStore: databaseStore,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            jwtDecoder: JWTClaimsDecoder(),
            oauthClient: oauthClient,
            terminalCommandLauncher: terminalCommandLauncher,
            copilotCLIInstaller: copilotCLIInstaller,
            openExternalURL: openExternalURL,
            quotaMonitor: quotaMonitor,
            userNotifier: userNotifier,
            runtimeInspector: runtimeInspector,
            instanceLauncher: instanceLauncher,
            cliEnvironmentResolver: cliEnvironmentResolver,
            cliLauncher: cliLauncher,
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: claudePatchedRuntimeManager,
            appSupportPathRepairer: appSupportPathRepairer,
            codexOAuthClaudeBridgeManager: codexOAuthClaudeBridgeManager,
            copilotProvider: copilotProvider,
            copilotStatusRefresher: copilotStatusRefresher ?? CopilotStatusRefresher(provider: copilotProvider),
            copilotManagedConfigManager: copilotManagedConfigManager,
            openAICompatibleProviderCodexBridgeManager: openAICompatibleProviderCodexBridgeManager,
            claudeProviderCodexBridgeManager: claudeProviderCodexBridgeManager,
            bannerAutoDismissDuration: bannerAutoDismissDuration
        )

        return AppViewModelHarness(
            model: model,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            quotaMonitor: quotaMonitor,
            userNotifier: userNotifier,
            sessionLogger: sessionLogger
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

    private func makeAPIKeyPayload(_ apiKey: String) throws -> CodexAuthPayload {
        try CodexAuthPayload(authMode: .apiKey, openAIAPIKey: apiKey).validated()
    }

    private func makeProviderCredential(_ apiKey: String) throws -> StoredCredential {
        .providerAPIKey(try ProviderAPIKeyCredential(apiKey: apiKey).validated())
    }

    private func makeProviderAccount(
        id: UUID,
        platform: PlatformKind,
        identifier: String,
        displayName: String,
        email: String,
        rule: ProviderRule,
        presetID: String,
        providerDisplayName: String? = nil,
        baseURL: String,
        envName: String,
        model: String,
        defaultTarget: CLIEnvironmentTarget? = nil,
        isActive: Bool = false
    ) -> ManagedAccount {
        ManagedAccount(
            id: id,
            platform: platform,
            accountIdentifier: identifier,
            displayName: displayName,
            email: email,
            authKind: .providerAPIKey,
            providerRule: rule,
            providerPresetID: presetID,
            providerDisplayName: providerDisplayName,
            providerBaseURL: baseURL,
            providerAPIKeyEnvName: envName,
            defaultModel: model,
            defaultCLITarget: defaultTarget,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            subscriptionDetails: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: isActive
        )
    }

    private func makeWorkingDirectoryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func readSessionLog(from harness: AppViewModelHarness) throws -> String {
        let logger = try XCTUnwrap(harness.sessionLogger)
        return try String(contentsOf: logger.latestLogURL, encoding: .utf8)
    }

    private func occurrenceCount(of substring: String, in text: String) -> Int {
        text.components(separatedBy: substring).count - 1
    }

    private func makeSignedLikePayload(
        accountID: String,
        refreshToken: String,
        displayName: String,
        email: String,
        planType: String
    ) -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: Self.makeUnsignedJWT(claims: [
                    "name": displayName,
                    "email": email,
                    "https://api.openai.com/auth": [
                        "chatgpt_account_id": accountID,
                        "chatgpt_plan_type": planType,
                    ],
                ]),
                accessToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": [
                        "chatgpt_account_id": accountID,
                    ],
                ]),
                refreshToken: refreshToken,
                accountID: accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }

    private static func makeUnsignedJWT(claims: [String: Any]) -> String {
        func encode(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        return "\(encode(["alg": "none"]))" + "." + encode(claims) + ".signature"
    }
}

private struct AccountSeed {
    let account: ManagedAccount
    let payload: StoredCredential
    let snapshot: QuotaSnapshot?
}

private struct AppViewModelHarness {
    let model: AppViewModel
    let credentialStore: InMemoryCredentialStore
    let authFileManager: RecordingAuthFileManager
    let quotaMonitor: any QuotaMonitoring
    let userNotifier: any UserNotifying
    let sessionLogger: AppSessionLogger?
}

private final class RecordingAuthFileManager: AuthFileManaging {
    private(set) var activatedPayloads: [CodexAuthPayload] = []
    var currentAuth: CodexAuthPayload?

    func readCurrentAuth() throws -> CodexAuthPayload? {
        currentAuth
    }

    func activate(_ payload: CodexAuthPayload) throws {
        try activatePreservingFileIdentity(payload)
    }

    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws {
        currentAuth = payload
        activatedPayloads.append(payload)
    }

    func clearAuthFile() throws {
        currentAuth = nil
    }
}

private final class RecordingTerminalCommandLauncher: @unchecked Sendable, TerminalCommandLaunching {
    private(set) var launchedCommands: [String] = []

    func launch(command: String) throws {
        launchedCommands.append(command)
    }
}

private actor RecordingCopilotCLIInstallerSnapshot {
    var installCallCount = 0

    func recordInstall() {
        installCallCount += 1
    }

    func snapshot() -> Int {
        installCallCount
    }
}

private final class RecordingCopilotCLIInstaller: CopilotCLIInstalling {
    private let result: Result<Void, Error>
    private let snapshotStore = RecordingCopilotCLIInstallerSnapshot()

    init(result: Result<Void, Error> = .success(())) {
        self.result = result
    }

    func installCLI() async throws {
        await snapshotStore.recordInstall()
        try result.get()
    }

    func snapshot() async -> Int {
        await snapshotStore.snapshot()
    }
}

private final class MockOAuthClient: @unchecked Sendable, OAuthClienting {
    let refreshResult: Result<AuthLoginResult, Error>
    let usageResult: Result<UsageRefreshResult, Error>
    let browserLoginResult: Result<AuthLoginResult, Error>
    private(set) var refreshCallCount = 0
    private(set) var beginBrowserLoginCallCount = 0
    private(set) var completeBrowserLoginCallCount = 0
    private(set) var manualCompleteBrowserLoginCallCount = 0

    init(
        refreshResult: Result<AuthLoginResult, Error>,
        usageResult: Result<UsageRefreshResult, Error> = .failure(MockError.unused),
        browserLoginResult: Result<AuthLoginResult, Error> = .failure(MockError.unused)
    ) {
        self.refreshResult = refreshResult
        self.usageResult = usageResult
        self.browserLoginResult = browserLoginResult
    }

    func beginBrowserLogin(openURL: @escaping @Sendable (URL) -> Bool) async throws -> BrowserOAuthSession {
        beginBrowserLoginCallCount += 1
        let callbackURL = URL(string: "http://localhost:1455/auth/callback")!
        let authorizeURL = URL(string: "https://auth.example.test/oauth")!
        _ = openURL(authorizeURL)
        return BrowserOAuthSession(
            state: "mock-state",
            codeVerifier: "mock-code-verifier",
            callbackURL: callbackURL,
            authorizeURL: authorizeURL,
            callbackServer: nil,
            serverErrorDescription: "mock callback unavailable"
        )
    }

    func completeBrowserLogin(session: BrowserOAuthSession) async throws -> AuthLoginResult {
        completeBrowserLoginCallCount += 1
        return try browserLoginResult.get()
    }

    func completeBrowserLogin(session: BrowserOAuthSession, pastedInput: String) async throws -> AuthLoginResult {
        manualCompleteBrowserLoginCallCount += 1
        return try browserLoginResult.get()
    }

    func startDeviceCodeLogin() async throws -> DeviceCodeChallenge {
        throw MockError.unused
    }

    func pollDeviceCodeLogin(challenge: DeviceCodeChallenge) async throws -> AuthLoginResult {
        throw MockError.unused
    }

    func refreshAuth(using payload: CodexAuthPayload) async throws -> AuthLoginResult {
        refreshCallCount += 1
        return try refreshResult.get()
    }

    func fetchUsageSnapshot(using payload: CodexAuthPayload) async throws -> UsageRefreshResult {
        try usageResult.get()
    }
}

private final class NoopQuotaMonitor: QuotaMonitoring {
    func bootstrapSnapshot() -> QuotaSnapshot? { nil }
    func start(
        onSnapshot: @escaping (UUID, QuotaSnapshot) -> Void,
        onSignal: @escaping (UUID, Date) -> Void
    ) {}
    func setActiveAccountID(_ accountID: UUID?) {}
    func stop() {}
}

private final class ControllableQuotaMonitor: QuotaMonitoring {
    private var snapshotHandler: ((UUID, QuotaSnapshot) -> Void)?
    private var signalHandler: ((UUID, Date) -> Void)?

    func bootstrapSnapshot() -> QuotaSnapshot? { nil }

    func start(
        onSnapshot: @escaping (UUID, QuotaSnapshot) -> Void,
        onSignal: @escaping (UUID, Date) -> Void
    ) {
        snapshotHandler = onSnapshot
        signalHandler = onSignal
    }

    func setActiveAccountID(_ accountID: UUID?) {}
    func stop() {}

    func emitSnapshot(accountID: UUID, snapshot: QuotaSnapshot) {
        snapshotHandler?(accountID, snapshot)
    }
}

actor RecordingUserNotifier: UserNotifying {
    struct NotificationRecord: Equatable {
        let identifier: String
        let title: String
        let body: String
    }

    private(set) var notifications: [NotificationRecord] = []

    func notifyLowQuotaRecommendation(
        identifier: String,
        title: String,
        body: String
    ) async {
        notifications.append(NotificationRecord(identifier: identifier, title: title, body: body))
    }
}

@MainActor
private final class MockRuntimeInspector: @unchecked Sendable, CodexRuntimeInspecting {
    let result: SwitchVerificationResult
    private(set) var hasRunningMainApplicationCallCount = 0
    private var isRunning: Bool
    private(set) var restartCallCount = 0
    private(set) var lastRestartLaunchEnvironment: [String: String]?
    private let hasRunningMainApplicationDelay: Duration?
    private let restartDelay: Duration?
    private let runningStateAfterRestart: Bool?

    init(
        result: SwitchVerificationResult,
        isRunning: Bool = true,
        hasRunningMainApplicationDelay: Duration? = nil,
        restartDelay: Duration? = nil,
        runningStateAfterRestart: Bool? = nil
    ) {
        self.result = result
        self.isRunning = isRunning
        self.hasRunningMainApplicationDelay = hasRunningMainApplicationDelay
        self.restartDelay = restartDelay
        self.runningStateAfterRestart = runningStateAfterRestart
    }

    func setIsRunning(_ isRunning: Bool) {
        self.isRunning = isRunning
    }

    func hasRunningMainApplication() async -> Bool {
        hasRunningMainApplicationCallCount += 1
        if let hasRunningMainApplicationDelay {
            try? await Task.sleep(for: hasRunningMainApplicationDelay)
        }
        return isRunning
    }

    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval) async -> SwitchVerificationResult {
        result
    }

    func restartCodex(launchEnvironment: [String: String]) async throws {
        restartCallCount += 1
        lastRestartLaunchEnvironment = launchEnvironment
        if let restartDelay {
            try? await Task.sleep(for: restartDelay)
        }
        if let runningStateAfterRestart {
            isRunning = runningStateAfterRestart
        }
    }
}

private actor RecordingCopilotProvider: CopilotProviderServing {
    struct Snapshot: Equatable {
        let importCallCount: Int
        let lastImportHost: String?
        let resolveCallCount: Int
        let lastResolvedCredential: CopilotCredential?
        let fetchStatusCallCount: Int
        let lastStatusCredential: CopilotCredential?
        let startDeviceLoginCallCount: Int
        let lastDeviceLoginHost: String?
        let completeDeviceLoginCallCount: Int
        let lastCompletedChallenge: CopilotDeviceLoginChallenge?
    }

    private let importResult: Result<CopilotCredential, Error>
    private let resolveCredentialResult: Result<CopilotCredential, Error>?
    private let startDeviceLoginChallenge: CopilotDeviceLoginChallenge?
    private let completeDeviceLoginResult: Result<CopilotCredential, Error>
    private let statusResult: Result<CopilotAccountStatus, Error>
    private let sendChatCompletionsResult: Result<(Int, Data), Error>

    private var importCallCount = 0
    private var lastImportHost: String?
    private var resolveCallCount = 0
    private var lastResolvedCredential: CopilotCredential?
    private var fetchStatusCallCount = 0
    private var lastStatusCredential: CopilotCredential?
    private var startDeviceLoginCallCount = 0
    private var lastDeviceLoginHost: String?
    private var completeDeviceLoginCallCount = 0
    private var lastCompletedChallenge: CopilotDeviceLoginChallenge?

    init(
        importResult: Result<CopilotCredential, Error> = .failure(MockError.unused),
        resolveCredentialResult: Result<CopilotCredential, Error>? = nil,
        startDeviceLoginChallenge: CopilotDeviceLoginChallenge? = nil,
        completeDeviceLoginResult: Result<CopilotCredential, Error> = .failure(MockError.unused),
        statusResult: Result<CopilotAccountStatus, Error> = .success(
            CopilotAccountStatus(availableModels: [], currentModel: nil, quotaSnapshot: nil)
        ),
        sendChatCompletionsResult: Result<(Int, Data), Error> = .failure(MockError.unused)
    ) {
        self.importResult = importResult
        self.resolveCredentialResult = resolveCredentialResult
        self.startDeviceLoginChallenge = startDeviceLoginChallenge
        self.completeDeviceLoginResult = completeDeviceLoginResult
        self.statusResult = statusResult
        self.sendChatCompletionsResult = sendChatCompletionsResult
    }

    func importCredential(host: String, defaultModel: String?) async throws -> CopilotCredential {
        importCallCount += 1
        lastImportHost = host
        return try importResult.get()
    }

    func resolveCredential(_ credential: CopilotCredential) async throws -> CopilotCredential {
        resolveCallCount += 1
        lastResolvedCredential = credential
        if let resolveCredentialResult {
            return try resolveCredentialResult.get()
        }
        return credential
    }

    func startDeviceLogin(host: String, defaultModel: String?) async throws -> CopilotDeviceLoginChallenge {
        startDeviceLoginCallCount += 1
        lastDeviceLoginHost = host
        guard let startDeviceLoginChallenge else {
            throw MockError.unused
        }
        return startDeviceLoginChallenge
    }

    func completeDeviceLogin(_ challenge: CopilotDeviceLoginChallenge) async throws -> CopilotCredential {
        completeDeviceLoginCallCount += 1
        lastCompletedChallenge = challenge
        return try completeDeviceLoginResult.get()
    }

    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus {
        fetchStatusCallCount += 1
        lastStatusCredential = credential
        return try statusResult.get()
    }

    func sendChatCompletions(using credential: CopilotCredential, body: Data) async throws -> (statusCode: Int, data: Data) {
        let result = try sendChatCompletionsResult.get()
        return (statusCode: result.0, data: result.1)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            importCallCount: importCallCount,
            lastImportHost: lastImportHost,
            resolveCallCount: resolveCallCount,
            lastResolvedCredential: lastResolvedCredential,
            fetchStatusCallCount: fetchStatusCallCount,
            lastStatusCredential: lastStatusCredential,
            startDeviceLoginCallCount: startDeviceLoginCallCount,
            lastDeviceLoginHost: lastDeviceLoginHost,
            completeDeviceLoginCallCount: completeDeviceLoginCallCount,
            lastCompletedChallenge: lastCompletedChallenge
        )
    }
}

private final class RecordingDesktopCLIEnvironmentResolver: @unchecked Sendable, CLIEnvironmentResolving {
    var desktopModelSelectionResults: [Result<ResolvedCodexDesktopModelSelection, Error>] = []
    var desktopModelSelectionResult: Result<ResolvedCodexDesktopModelSelection, Error>?
    var desktopContextResults: [Result<ResolvedCodexDesktopLaunchContext, Error>] = []
    var desktopContextResult: Result<ResolvedCodexDesktopLaunchContext, Error>?

    func resolveCodexDesktopModelSelection(
        for account: ManagedAccount,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        copilotCredential: CopilotCredential?,
        copilotStatus: CopilotAccountStatus?
    ) async throws -> ResolvedCodexDesktopModelSelection {
        if !desktopModelSelectionResults.isEmpty {
            return try desktopModelSelectionResults.removeFirst().get()
        }
        if let desktopModelSelectionResult {
            return try desktopModelSelectionResult.get()
        }
        return ResolvedCodexDesktopModelSelection(
            selectedModel: account.resolvedDefaultModel,
            availableModels: [account.resolvedDefaultModel]
        )
    }

    func resolveCodexContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        authPayload: CodexAuthPayload?,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        copilotCredential: CopilotCredential?,
        copilotStatus: CopilotAccountStatus?,
        copilotResponsesBridgeManager: any CopilotResponsesBridgeManaging,
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging,
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging
    ) async throws -> ResolvedCodexCLILaunchContext {
        throw MockError.unused
    }

    func resolveCodexDesktopContext(
        for account: ManagedAccount,
        appPaths: AppPaths,
        authPayload: CodexAuthPayload?,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        copilotCredential: CopilotCredential?,
        copilotStatus: CopilotAccountStatus?,
        copilotResponsesBridgeManager: any CopilotResponsesBridgeManaging,
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging,
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging
    ) async throws -> ResolvedCodexDesktopLaunchContext {
        if !desktopContextResults.isEmpty {
            return try desktopContextResults.removeFirst().get()
        }
        if let desktopContextResult {
            return try desktopContextResult.get()
        }

        var environmentVariables: [String: String] = [:]
        if let providerAPIKeyCredential, !account.resolvedProviderAPIKeyEnvName.isEmpty {
            environmentVariables[account.resolvedProviderAPIKeyEnvName] = providerAPIKeyCredential.apiKey
        }
        if let copilotCredential, let accessToken = copilotCredential.accessToken ?? copilotCredential.githubAccessToken {
            environmentVariables["GITHUB_TOKEN"] = accessToken
        }

        return ResolvedCodexDesktopLaunchContext(
            accountID: account.id,
            codexHomeURL: appPaths.appSupportDirectoryURL
                .appendingPathComponent("isolated-codex-instances", isDirectory: true)
                .appendingPathComponent(account.id.uuidString, isDirectory: true)
                .appendingPathComponent("codex-home", isDirectory: true),
            authPayload: authPayload,
            modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: [account.resolvedDefaultModel]),
            configFileContents: """
            model = "\(account.resolvedDefaultModel)"
            model_reasoning_effort = "\(account.resolvedDefaultModelReasoningEffort)"
            """,
            environmentVariables: environmentVariables
        )
    }

    func resolveClaudeContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        codexAuthPayload: CodexAuthPayload?,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging,
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging,
        copilotStatus: CopilotAccountStatus?,
        copilotResponsesBridgeManager: any CopilotResponsesBridgeManaging,
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging
    ) async throws -> ResolvedClaudeCLILaunchContext {
        throw MockError.unused
    }
}

private final class RecordingCodexInstanceLauncher: CodexInstanceLaunching {
    var launchCallCount = 0
    var lastAccountID: UUID?
    var lastPayload: CodexAuthPayload?
    var lastContext: ResolvedCodexDesktopLaunchContext?
    var lastAppSupportDirectoryURL: URL?
    private var terminationHandlers: [UUID: @Sendable () -> Void] = [:]

    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths {
        launchCallCount += 1
        lastAccountID = account.id
        lastPayload = payload
        lastAppSupportDirectoryURL = appSupportDirectoryURL
        terminationHandlers[account.id] = onTermination
        return IsolatedCodexLaunchPaths(
            rootDirectoryURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString),
            codexHomeURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString).appendingPathComponent("codex-home"),
            userDataURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString).appendingPathComponent("user-data")
        )
    }

    func launchIsolatedInstance(
        context: ResolvedCodexDesktopLaunchContext,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths {
        launchCallCount += 1
        lastAccountID = context.accountID
        lastPayload = context.authPayload
        lastContext = context
        terminationHandlers[context.accountID] = onTermination
        let rootDirectoryURL = context.codexHomeURL.deletingLastPathComponent()
        return IsolatedCodexLaunchPaths(
            rootDirectoryURL: rootDirectoryURL,
            codexHomeURL: context.codexHomeURL,
            userDataURL: rootDirectoryURL.appendingPathComponent("user-data")
        )
    }

    func simulateTermination(for accountID: UUID) {
        let handler = terminationHandlers.removeValue(forKey: accountID)
        handler?()
    }
}

private final class RecordingCodexCLILauncher: CodexCLILaunching {
    var launchCallCount = 0
    var lastContext: ResolvedCodexCLILaunchContext?
    var error: Error?

    func launchCLI(context: ResolvedCodexCLILaunchContext) throws {
        if let error {
            throw error
        }
        launchCallCount += 1
        lastContext = context
    }
}

private final class RecordingClaudeCLILauncher: ClaudeCLILaunching {
    var launchCallCount = 0
    var lastContext: ResolvedClaudeCLILaunchContext?
    var error: Error?

    func launchCLI(context: ResolvedClaudeCLILaunchContext) throws {
        if let error {
            throw error
        }
        launchCallCount += 1
        lastContext = context
    }
}

private final class RecordingClaudePatchedRuntimeManager: @unchecked Sendable, ClaudePatchedRuntimeManaging {
    var resolveCallCount = 0
    var lastModel: String?
    var executableOverrideURL: URL?
    var runtimeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("claude", isDirectory: false)

    func resolveExecutableOverride(model: String, appSupportDirectoryURL: URL) throws -> URL? {
        resolveCallCount += 1
        lastModel = model
        return executableOverrideURL
    }
}

private final class RecordingAppSupportPathRepairer: @unchecked Sendable, AppSupportPathRepairing {
    var repairCallCount = 0
    var lastAppSupportDirectoryURL: URL?
    var result: Result<Bool, Error> = .success(false)

    func repairLegacyAbsolutePaths(in appSupportDirectoryURL: URL) throws -> Bool {
        repairCallCount += 1
        lastAppSupportDirectoryURL = appSupportDirectoryURL
        return try result.get()
    }
}

private actor RecordingCodexOAuthClaudeBridgeManager: CodexOAuthClaudeBridgeManaging {
    struct Snapshot: Equatable {
        let prepareCallCount: Int
        let lastAccountID: UUID?
        let lastSource: OpenAICompatibleClaudeBridgeSource?
        let lastModel: String?
        let lastAvailableModels: [String]?
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastSource: OpenAICompatibleClaudeBridgeSource?
    private var lastModel: String?
    private var lastAvailableModels: [String]?

    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedCodexOAuthClaudeBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastSource = source
        lastModel = model
        lastAvailableModels = availableModels
        return PreparedCodexOAuthClaudeBridge(
            baseURL: "http://127.0.0.1:18080",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "codex-oauth-bridge"
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCallCount: prepareCallCount,
            lastAccountID: lastAccountID,
            lastSource: lastSource,
            lastModel: lastModel,
            lastAvailableModels: lastAvailableModels
        )
    }
}

private actor RecordingOpenAICompatibleProviderCodexBridgeManager: OpenAICompatibleProviderCodexBridgeManaging {
    struct Snapshot: Equatable {
        let prepareCallCount: Int
        let lastAccountID: UUID?
        let lastBaseURL: String?
        let lastAPIKeyEnvName: String?
        let lastAPIKey: String?
        let lastModel: String?
        let lastAvailableModels: [String]?
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastBaseURL: String?
    private var lastAPIKeyEnvName: String?
    private var lastAPIKey: String?
    private var lastModel: String?
    private var lastAvailableModels: [String]?

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastBaseURL = baseURL
        lastAPIKeyEnvName = apiKeyEnvName
        lastAPIKey = apiKey
        lastModel = model
        lastAvailableModels = availableModels
        return PreparedOpenAICompatibleProviderCodexBridge(
            baseURL: "http://127.0.0.1:18082",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "openai-compatible-provider-bridge"
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCallCount: prepareCallCount,
            lastAccountID: lastAccountID,
            lastBaseURL: lastBaseURL,
            lastAPIKeyEnvName: lastAPIKeyEnvName,
            lastAPIKey: lastAPIKey,
            lastModel: lastModel,
            lastAvailableModels: lastAvailableModels
        )
    }
}

private actor RecordingClaudeProviderCodexBridgeManager: ClaudeProviderCodexBridgeManaging {
    struct Snapshot: Equatable {
        let prepareCallCount: Int
        let lastAccountID: UUID?
        let lastBaseURL: String?
        let lastAPIKeyEnvName: String?
        let lastAPIKey: String?
        let lastModel: String?
        let lastAvailableModels: [String]?
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastBaseURL: String?
    private var lastAPIKeyEnvName: String?
    private var lastAPIKey: String?
    private var lastModel: String?
    private var lastAvailableModels: [String]?

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedClaudeProviderCodexBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastBaseURL = baseURL
        lastAPIKeyEnvName = apiKeyEnvName
        lastAPIKey = apiKey
        lastModel = model
        lastAvailableModels = availableModels
        return PreparedClaudeProviderCodexBridge(
            baseURL: "http://127.0.0.1:18081",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "claude-provider-bridge"
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCallCount: prepareCallCount,
            lastAccountID: lastAccountID,
            lastBaseURL: lastBaseURL,
            lastAPIKeyEnvName: lastAPIKeyEnvName,
            lastAPIKey: lastAPIKey,
            lastModel: lastModel,
            lastAvailableModels: lastAvailableModels
        )
    }
}

private struct NoopCopilotManagedConfigManager: CopilotManagedConfigManaging {
    func bootstrap(
        accountID: UUID,
        credential: CopilotCredential,
        model: String?,
        reasoningEffort: String
    ) async throws -> ManagedCopilotConfigBootstrapResult {
        let updatedCredential = try CopilotCredential(
            configDirectoryName: credential.configDirectoryName ?? accountID.uuidString,
            host: credential.host,
            login: credential.login,
            githubAccessToken: credential.githubAccessToken,
            accessToken: credential.accessToken,
            defaultModel: model ?? credential.defaultModel,
            source: credential.source
        ).validated()
        return ManagedCopilotConfigBootstrapResult(
            credential: updatedCredential,
            configDirectoryURL: CopilotCLIConfiguration.defaultConfigDirectoryURL()
        )
    }
}

private enum MockError: LocalizedError {
    case refreshFailed
    case cliLaunchFailed
    case unused

    var errorDescription: String? {
        switch self {
        case .refreshFailed:
            return "refresh failed"
        case .cliLaunchFailed:
            return "cli launch failed"
        case .unused:
            return "unused"
        }
    }
}
