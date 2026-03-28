import Foundation

protocol AuthFileManaging {
    func readCurrentAuth() throws -> CodexAuthPayload?
    func activate(_ payload: CodexAuthPayload) throws
    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws
    func clearAuthFile() throws
}

protocol AccountCredentialStore {
    func preload() throws
    func save(_ credential: StoredCredential, for accountID: UUID) throws
    func load(for accountID: UUID) throws -> StoredCredential
    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> StoredCredential
    func delete(for accountID: UUID) throws
}

protocol OAuthClienting: Sendable {
    func beginBrowserLogin(openURL: @escaping @Sendable (URL) -> Bool) async throws -> BrowserOAuthSession
    func completeBrowserLogin(session: BrowserOAuthSession) async throws -> AuthLoginResult
    func completeBrowserLogin(session: BrowserOAuthSession, pastedInput: String) async throws -> AuthLoginResult
    func startDeviceCodeLogin() async throws -> DeviceCodeChallenge
    func pollDeviceCodeLogin(challenge: DeviceCodeChallenge) async throws -> AuthLoginResult
    func refreshAuth(using payload: CodexAuthPayload) async throws -> AuthLoginResult
    func fetchUsageSnapshot(using payload: CodexAuthPayload) async throws -> UsageRefreshResult
}

protocol ClaudeProfileManaging: Sendable {
    func currentProfileExists() -> Bool
    func importCurrentProfile() throws -> ClaudeProfileSnapshotRef
    func activateProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws
    func deleteProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws
    func prepareIsolatedProfileRoot(for accountID: UUID, snapshotRef: ClaudeProfileSnapshotRef) throws -> URL
    func prepareIsolatedAPIKeyRoot(for accountID: UUID) throws -> URL
}

protocol ClaudeAPIClienting: Sendable {
    func probeStatus(using credential: AnthropicAPIKeyCredential) async throws -> ClaudeRateLimitSnapshot
}

protocol ClaudePatchedRuntimeManaging: Sendable {
    func preparePatchedRuntime(
        model: String,
        appSupportDirectoryURL: URL
    ) throws -> URL
}

enum OpenAICompatibleClaudeBridgeSource: Equatable, Sendable {
    case codexAuthPayload(CodexAuthPayload)
    case provider(baseURL: String, apiKeyEnvName: String, apiKey: String, supportsResponsesAPI: Bool)
}

struct PreparedCodexOAuthClaudeBridge: Equatable, Sendable {
    let baseURL: String
    let apiKeyEnvName: String
    let apiKey: String
}

protocol CodexOAuthClaudeBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        source: OpenAICompatibleClaudeBridgeSource,
        model: String
    ) async throws -> PreparedCodexOAuthClaudeBridge
}

struct PreparedClaudeProviderCodexBridge: Equatable, Sendable {
    let baseURL: String
    let apiKeyEnvName: String
    let apiKey: String
}

struct PreparedOpenAICompatibleProviderCodexBridge: Equatable, Sendable {
    let baseURL: String
    let apiKeyEnvName: String
    let apiKey: String
}

protocol ClaudeProviderCodexBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String
    ) async throws -> PreparedClaudeProviderCodexBridge
}

protocol OpenAICompatibleProviderCodexBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String
    ) async throws -> PreparedOpenAICompatibleProviderCodexBridge
}

protocol QuotaMonitoring: AnyObject {
    func bootstrapSnapshot() -> QuotaSnapshot?
    func start(
        onSnapshot: @escaping (UUID, QuotaSnapshot) -> Void,
        onSignal: @escaping (UUID, Date) -> Void
    )
    func setActiveAccountID(_ accountID: UUID?)
    func stop()
}

protocol UserNotifying: Sendable {
    func notifyLowQuotaRecommendation(
        identifier: String,
        title: String,
        body: String
    ) async
}

protocol CodexRuntimeInspecting: Sendable {
    func isCodexDesktopRunning() -> Bool
    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval) async -> SwitchVerificationResult
    func restartCodex() async throws
}

protocol CLIEnvironmentResolving: Sendable {
    func resolveCodexContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        authPayload: CodexAuthPayload?,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging,
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging
    ) async throws -> ResolvedCodexCLILaunchContext

    func resolveClaudeContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        codexAuthPayload: CodexAuthPayload?,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging,
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging,
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging
    ) async throws -> ResolvedClaudeCLILaunchContext
}

struct IsolatedCodexLaunchPaths: Equatable, Sendable {
    let rootDirectoryURL: URL
    let codexHomeURL: URL
    let userDataURL: URL
}

protocol CodexInstanceLaunching {
    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL
    ) throws -> IsolatedCodexLaunchPaths
}

protocol CodexCLILaunching {
    func launchCLI(context: ResolvedCodexCLILaunchContext) throws
}

protocol ClaudeCLILaunching {
    func launchCLI(context: ResolvedClaudeCLILaunchContext) throws
}
