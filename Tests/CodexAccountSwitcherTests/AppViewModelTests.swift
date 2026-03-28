import Foundation
import XCTest
@testable import CodexAccountSwitcher

@MainActor
final class AppViewModelTests: XCTestCase {
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
        XCTAssertEqual(snapshot.secondary.remainingPercentText, "68%")
        XCTAssertEqual(
            refreshedAccount.lastStatusMessage,
            L10n.tr("状态与额度已更新：剩余 %@。", L10n.tr("5h %@ / 7d %@", "100%", "68%"))
        )
        XCTAssertEqual(refreshedAccount.subscriptionDetails?.allowed, true)
        XCTAssertEqual(refreshedAccount.subscriptionDetails?.limitReached, false)
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
                        identifier: "acct_openrouter_provider",
                        displayName: "OpenRouter",
                        email: "sk-...router",
                        rule: .openAICompatible,
                        presetID: "openrouter",
                        baseURL: "https://openrouter.ai/api/v1",
                        envName: "OPENROUTER_API_KEY",
                        model: "openrouter/anthropic/claude-sonnet-4.5"
                    ),
                    payload: try makeProviderCredential("sk-or-test"),
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
            workingDirectoryURL: makeWorkingDirectoryURL("openrouter-claude")
        )

        let bridgeSnapshot = await bridgeManager.snapshot()
        XCTAssertEqual(bridgeSnapshot.prepareCallCount, 1)
        XCTAssertEqual(bridgeSnapshot.lastAccountID, providerAccountID)
        XCTAssertEqual(
            bridgeSnapshot.lastSource,
            .provider(
                baseURL: "https://openrouter.ai/api/v1",
                apiKeyEnvName: "OPENROUTER_API_KEY",
                apiKey: "sk-or-test",
                supportsResponsesAPI: true
            )
        )
        XCTAssertEqual(bridgeSnapshot.lastModel, "openrouter/anthropic/claude-sonnet-4.5")
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertEqual(claudeCLILauncher.lastContext?.patchedExecutableURL, patchedRuntimeManager.runtimeURL)
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot,
            ResolvedClaudeProviderSnapshot(
                source: .inheritCodexEnvironment,
                model: "openrouter/anthropic/claude-sonnet-4.5",
                modelProvider: "openrouter",
                baseURL: "http://127.0.0.1:18080",
                apiKeyEnvName: "ANTHROPIC_API_KEY"
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
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
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
        XCTAssertEqual(claudeCLILauncher.lastContext?.patchedExecutableURL, patchedRuntimeManager.runtimeURL)
        XCTAssertEqual(
            claudeCLILauncher.lastContext?.providerSnapshot,
            ResolvedClaudeProviderSnapshot(
                source: .explicitProvider,
                model: "claude-sonnet-4.5",
                modelProvider: nil,
                baseURL: "https://api.anthropic.com/v1",
                apiKeyEnvName: "ANTHROPIC_API_KEY"
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
        XCTAssertEqual(claudeCLILauncher.launchCallCount, 1)
        XCTAssertEqual(claudeCLILauncher.lastContext?.patchedExecutableURL, patchedRuntimeManager.runtimeURL)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.source, .inheritCodexEnvironment)
        XCTAssertEqual(claudeCLILauncher.lastContext?.providerSnapshot?.model, "gpt-5.4")
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
        XCTAssertEqual(codexCLILauncher.launchCallCount, 1)
        XCTAssertEqual(
            codexCLILauncher.lastContext?.environmentVariables["OPENAI_API_KEY"],
            "openai-compatible-provider-bridge"
        )
        XCTAssertTrue(codexCLILauncher.lastContext?.configFileContents?.contains("base_url = \"http://127.0.0.1:18082\"") == true)
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

    func testLaunchIsolatedCodexDoesNotSupportActiveProviderAccount() async throws {
        let accountID = UUID()
        let cachedPayload = try makeAPIKeyPayload("sk-test-old")
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
        XCTAssertFalse(harness.model.hasLaunchedIsolatedInstance(for: account.id))
        XCTAssertFalse(harness.model.isLaunchingIsolatedInstance(for: account.id))
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
        quotaMonitor: any QuotaMonitoring = NoopQuotaMonitor(),
        userNotifier: any UserNotifying = RecordingUserNotifier(),
        instanceLauncher: any CodexInstanceLaunching = RecordingCodexInstanceLauncher(),
        cliLauncher: any CodexCLILaunching = RecordingCodexCLILauncher(),
        claudeCLILauncher: any ClaudeCLILaunching = RecordingClaudeCLILauncher(),
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging = RecordingClaudePatchedRuntimeManager(),
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging = RecordingCodexOAuthClaudeBridgeManager(),
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging = RecordingOpenAICompatibleProviderCodexBridgeManager(),
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging = RecordingClaudeProviderCodexBridgeManager(),
        bannerAutoDismissDuration: Duration = .seconds(10)
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
            databaseStore: databaseStore,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            jwtDecoder: JWTClaimsDecoder(),
            oauthClient: oauthClient,
            quotaMonitor: quotaMonitor,
            userNotifier: userNotifier,
            runtimeInspector: runtimeInspector,
            instanceLauncher: instanceLauncher,
            cliLauncher: cliLauncher,
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: claudePatchedRuntimeManager,
            codexOAuthClaudeBridgeManager: codexOAuthClaudeBridgeManager,
            openAICompatibleProviderCodexBridgeManager: openAICompatibleProviderCodexBridgeManager,
            claudeProviderCodexBridgeManager: claudeProviderCodexBridgeManager,
            bannerAutoDismissDuration: bannerAutoDismissDuration
        )

        return AppViewModelHarness(
            model: model,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            quotaMonitor: quotaMonitor,
            userNotifier: userNotifier
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
            providerDisplayName: nil,
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

private final class MockOAuthClient: @unchecked Sendable, OAuthClienting {
    let refreshResult: Result<AuthLoginResult, Error>
    let usageResult: Result<UsageRefreshResult, Error>
    private(set) var refreshCallCount = 0

    init(
        refreshResult: Result<AuthLoginResult, Error>,
        usageResult: Result<UsageRefreshResult, Error> = .failure(MockError.unused)
    ) {
        self.refreshResult = refreshResult
        self.usageResult = usageResult
    }

    func beginBrowserLogin(openURL: @escaping @Sendable (URL) -> Bool) async throws -> BrowserOAuthSession {
        throw MockError.unused
    }

    func completeBrowserLogin(session: BrowserOAuthSession) async throws -> AuthLoginResult {
        throw MockError.unused
    }

    func completeBrowserLogin(session: BrowserOAuthSession, pastedInput: String) async throws -> AuthLoginResult {
        throw MockError.unused
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

private final class MockRuntimeInspector: @unchecked Sendable, CodexRuntimeInspecting {
    let result: SwitchVerificationResult
    let isRunning: Bool
    private(set) var restartCallCount = 0

    init(result: SwitchVerificationResult, isRunning: Bool = true) {
        self.result = result
        self.isRunning = isRunning
    }

    func isCodexDesktopRunning() -> Bool {
        isRunning
    }

    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval) async -> SwitchVerificationResult {
        result
    }

    func restartCodex() async throws {
        restartCallCount += 1
    }
}

private final class RecordingCodexInstanceLauncher: CodexInstanceLaunching {
    var launchCallCount = 0
    var lastAccountID: UUID?
    var lastPayload: CodexAuthPayload?
    var lastAppSupportDirectoryURL: URL?

    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL
    ) throws -> IsolatedCodexLaunchPaths {
        launchCallCount += 1
        lastAccountID = account.id
        lastPayload = payload
        lastAppSupportDirectoryURL = appSupportDirectoryURL
        return IsolatedCodexLaunchPaths(
            rootDirectoryURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString),
            codexHomeURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString).appendingPathComponent("codex-home"),
            userDataURL: appSupportDirectoryURL.appendingPathComponent("isolated-codex-instances").appendingPathComponent(account.id.uuidString).appendingPathComponent("user-data")
        )
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
    var prepareCallCount = 0
    var lastModel: String?
    var runtimeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("claude", isDirectory: false)

    func preparePatchedRuntime(model: String, appSupportDirectoryURL: URL) throws -> URL {
        prepareCallCount += 1
        lastModel = model
        return runtimeURL
    }
}

private actor RecordingCodexOAuthClaudeBridgeManager: CodexOAuthClaudeBridgeManaging {
    struct Snapshot: Equatable {
        let prepareCallCount: Int
        let lastAccountID: UUID?
        let lastSource: OpenAICompatibleClaudeBridgeSource?
        let lastModel: String?
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastSource: OpenAICompatibleClaudeBridgeSource?
    private var lastModel: String?

    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String
    ) async throws -> PreparedCodexOAuthClaudeBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastSource = source
        lastModel = model
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
            lastModel: lastModel
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
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastBaseURL: String?
    private var lastAPIKeyEnvName: String?
    private var lastAPIKey: String?
    private var lastModel: String?

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastBaseURL = baseURL
        lastAPIKeyEnvName = apiKeyEnvName
        lastAPIKey = apiKey
        lastModel = model
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
            lastModel: lastModel
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
    }

    private var prepareCallCount = 0
    private var lastAccountID: UUID?
    private var lastBaseURL: String?
    private var lastAPIKeyEnvName: String?
    private var lastAPIKey: String?
    private var lastModel: String?

    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String
    ) async throws -> PreparedClaudeProviderCodexBridge {
        prepareCallCount += 1
        lastAccountID = accountID
        lastBaseURL = baseURL
        lastAPIKeyEnvName = apiKeyEnvName
        lastAPIKey = apiKey
        lastModel = model
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
            lastModel: lastModel
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
