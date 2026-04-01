import XCTest
@testable import Orbit

extension ManagedAuthKind {
    static var apiKey: ManagedAuthKind { .openAIAPIKey }
}

extension ManagedAccount {
    init(
        id: UUID,
        platform: PlatformKind = .codex,
        codexAccountID: String,
        displayName: String,
        email: String?,
        authMode: ManagedAuthKind,
        createdAt: Date,
        lastUsedAt: Date?,
        lastQuotaSnapshotAt: Date?,
        lastRefreshAt: Date?,
        planType: String?,
        subscriptionDetails: SubscriptionDetails? = nil,
        lastStatusCheckAt: Date?,
        lastStatusMessage: String?,
        lastStatusLevel: SwitchLogLevel?,
        isActive: Bool
    ) {
        self.init(
            id: id,
            platform: platform,
            accountIdentifier: codexAccountID,
            displayName: displayName,
            email: email,
            authKind: authMode,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            lastQuotaSnapshotAt: lastQuotaSnapshotAt,
            lastRefreshAt: lastRefreshAt,
            planType: planType,
            subscriptionDetails: subscriptionDetails,
            lastStatusCheckAt: lastStatusCheckAt,
            lastStatusMessage: lastStatusMessage,
            lastStatusLevel: lastStatusLevel,
            isActive: isActive
        )
    }

    var codexAccountID: String { accountIdentifier }
    var authMode: ManagedAuthKind { authKind }
}

extension StoredCredential {
    var tokens: CodexTokenBundle {
        guard let payload = codexPayload else {
            fatalError("Expected codex credential in test")
        }
        return payload.tokens
    }

    var authMode: ManagedAuthKind {
        guard let payload = codexPayload else {
            fatalError("Expected codex credential in test")
        }
        return payload.authMode
    }

    var openAIAPIKey: String? {
        codexPayload?.openAIAPIKey
    }

    var lastRefresh: String? {
        codexPayload?.lastRefresh
    }
}

extension InMemoryCredentialStore {
    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws {
        try save(.codex(payload), for: accountID)
    }
}

extension CachedCredentialStore {
    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws {
        try save(.codex(payload), for: accountID)
    }
}

func XCTAssertEqual(
    _ expression1: @autoclosure () throws -> StoredCredential,
    _ expression2: @autoclosure () throws -> CodexAuthPayload,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(try? expression1().codexPayload, try? expression2(), file: file, line: line)
}

func XCTAssertEqual(
    _ expression1: @autoclosure () throws -> CodexAuthPayload,
    _ expression2: @autoclosure () throws -> StoredCredential,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(try? expression1(), try? expression2().codexPayload, file: file, line: line)
}

extension AppDatabase {
    init(
        version: Int,
        accounts: [ManagedAccount],
        quotaSnapshots: [String: QuotaSnapshot],
        switchLogs: [SwitchLogEntry],
        cliWorkingDirectoriesByAccountID: [String: [String]] = [:],
        activeAccountID: UUID? = nil
    ) {
        let launchHistory = Dictionary(uniqueKeysWithValues: accounts.map { account in
            let records = (cliWorkingDirectoriesByAccountID[account.id.uuidString] ?? []).map {
                CLILaunchRecord(path: $0, target: account.defaultCLITarget)
            }
            return (account.id.uuidString, records)
        })
        self.init(
            version: version,
            accounts: accounts,
            quotaSnapshots: quotaSnapshots,
            claudeRateLimitSnapshots: [:],
            switchLogs: switchLogs,
            cliLaunchHistoryByAccountID: launchHistory,
            activeAccountID: activeAccountID
        )
    }
}

private struct NoopClaudeProfileManager: ClaudeProfileManaging {
    func currentProfileExists() -> Bool { false }
    func importCurrentProfile() throws -> ClaudeProfileSnapshotRef { throw NSError(domain: "test", code: 1) }
    func activateProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {}
    func deleteProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {}
    func prepareIsolatedProfileRoot(for accountID: UUID, snapshotRef: ClaudeProfileSnapshotRef) throws -> URL {
        FileManager.default.temporaryDirectory
    }
    func prepareIsolatedAPIKeyRoot(for accountID: UUID) throws -> URL {
        FileManager.default.temporaryDirectory
    }
}

private struct NoopClaudeAPIClient: ClaudeAPIClienting {
    func probeStatus(using credential: AnthropicAPIKeyCredential) async throws -> ClaudeRateLimitSnapshot {
        throw NSError(domain: "test", code: 1)
    }
}

private struct NoopClaudeCLILauncher: ClaudeCLILaunching {
    func launchCLI(context: ResolvedClaudeCLILaunchContext) throws {}
}

private struct NoopClaudePatchedRuntimeManager: ClaudePatchedRuntimeManaging {
    func resolveExecutableOverride(model: String, appSupportDirectoryURL: URL) throws -> URL? {
        nil
    }
}

struct NoopAppSupportPathRepairer: AppSupportPathRepairing {
    func repairLegacyAbsolutePaths(in appSupportDirectoryURL: URL) throws -> Bool {
        false
    }
}

private struct NoopCodexOAuthClaudeBridgeManager: CodexOAuthClaudeBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedCodexOAuthClaudeBridge {
        PreparedCodexOAuthClaudeBridge(
            baseURL: "http://127.0.0.1:18080",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            apiKey: "codex-oauth-bridge"
        )
    }
}

private struct NoopOpenAICompatibleProviderCodexBridgeManager: OpenAICompatibleProviderCodexBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge {
        PreparedOpenAICompatibleProviderCodexBridge(
            baseURL: "http://127.0.0.1:18082",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "openai-compatible-provider-bridge"
        )
    }
}

private struct NoopClaudeProviderCodexBridgeManager: ClaudeProviderCodexBridgeManaging {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedClaudeProviderCodexBridge {
        PreparedClaudeProviderCodexBridge(
            baseURL: "http://127.0.0.1:18081",
            apiKeyEnvName: "OPENAI_API_KEY",
            apiKey: "claude-provider-bridge"
        )
    }
}

extension AppViewModel {
    convenience init(
        paths: AppPaths,
        sessionLogger: AppSessionLogger? = nil,
        databaseStore: AppDatabaseStore,
        credentialStore: any AccountCredentialStore,
        authFileManager: any AuthFileManaging,
        jwtDecoder: JWTClaimsDecoder,
        oauthClient: any OAuthClienting,
        quotaMonitor: any QuotaMonitoring,
        userNotifier: any UserNotifying,
        runtimeInspector: any CodexRuntimeInspecting,
        instanceLauncher: any CodexInstanceLaunching = CodexInstanceLauncher(),
        cliEnvironmentResolver: any CLIEnvironmentResolving = CLIEnvironmentResolver(),
        cliLauncher: any CodexCLILaunching = CodexCLILauncher(),
        claudeCLILauncher: any ClaudeCLILaunching = NoopClaudeCLILauncher(),
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging = NoopClaudePatchedRuntimeManager(),
        appSupportPathRepairer: any AppSupportPathRepairing = NoopAppSupportPathRepairer(),
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging = NoopCodexOAuthClaudeBridgeManager(),
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging = NoopOpenAICompatibleProviderCodexBridgeManager(),
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging = NoopClaudeProviderCodexBridgeManager(),
        bannerAutoDismissDuration: Duration = .seconds(10)
    ) {
        self.init(
            paths: paths,
            sessionLogger: sessionLogger,
            databaseStore: databaseStore,
            credentialStore: credentialStore,
            authFileManager: authFileManager,
            jwtDecoder: jwtDecoder,
            oauthClient: oauthClient,
            claudeProfileManager: NoopClaudeProfileManager(),
            claudeAPIClient: NoopClaudeAPIClient(),
            quotaMonitor: quotaMonitor,
            userNotifier: userNotifier,
            runtimeInspector: runtimeInspector,
            instanceLauncher: instanceLauncher,
            cliEnvironmentResolver: cliEnvironmentResolver,
            codexCLILauncher: cliLauncher,
            claudeCLILauncher: claudeCLILauncher,
            claudePatchedRuntimeManager: claudePatchedRuntimeManager,
            appSupportPathRepairer: appSupportPathRepairer,
            codexOAuthClaudeBridgeManager: codexOAuthClaudeBridgeManager,
            openAICompatibleProviderCodexBridgeManager: openAICompatibleProviderCodexBridgeManager,
            claudeProviderCodexBridgeManager: claudeProviderCodexBridgeManager,
            bannerAutoDismissDuration: bannerAutoDismissDuration
        )
    }
}
