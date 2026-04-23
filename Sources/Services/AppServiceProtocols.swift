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

protocol TerminalCommandLaunching: Sendable {
    func launch(command: String) throws
}

protocol CopilotCLIInstalling: Sendable {
    func installCLI() async throws
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
    func resolveExecutableOverride(
        model: String,
        appSupportDirectoryURL: URL
    ) throws -> URL?
}

protocol AppSupportPathRepairing: Sendable {
    func repairLegacyAbsolutePaths(in appSupportDirectoryURL: URL) throws -> Bool
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
        model: String,
        availableModels: [String]
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

struct CopilotAccountStatus: Equatable, Sendable {
    let availableModels: [String]
    let currentModel: String?
    let quotaSnapshot: CopilotQuotaSnapshot?
}

struct CopilotDeviceLoginChallenge: Equatable, Sendable {
    let host: String
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresInSeconds: Int
    let intervalSeconds: Int
    let defaultModel: String?
}

protocol CopilotProviderServing: Sendable {
    func importCredential(
        host: String,
        defaultModel: String?
    ) async throws -> CopilotCredential

    func resolveCredential(_ credential: CopilotCredential) async throws -> CopilotCredential

    func startDeviceLogin(
        host: String,
        defaultModel: String?
    ) async throws -> CopilotDeviceLoginChallenge

    func completeDeviceLogin(_ challenge: CopilotDeviceLoginChallenge) async throws -> CopilotCredential

    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus

    func sendChatCompletions(
        using credential: CopilotCredential,
        body: Data
    ) async throws -> (statusCode: Int, data: Data)
}

protocol CopilotStatusRefreshing: Sendable {
    func fetchStatus(using credential: CopilotCredential) async throws -> CopilotAccountStatus
}

protocol CopilotSessionQueueImporting: Sendable {
    func sessions(for workspaceURL: URL) throws -> [CopilotSessionCandidate]
    func importSession(_ candidate: CopilotSessionCandidate) throws -> CopilotSessionQueueItem
}

struct MaterializedCodexThread: Equatable, Sendable {
    let id: String
    let path: String?
}

struct ResolvedCodexLocalThreadMaterializationContext: Equatable, Sendable {
    let accountID: UUID
    let workingDirectoryURL: URL
    let codexHomeURL: URL?
    let authPayload: CodexAuthPayload?
    let modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    let configFileContents: String?
    let environmentVariables: [String: String]
}

protocol CodexLocalThreadMaterializing: Sendable {
    func materializeCopilotSessionQueueItem(
        _ item: CopilotSessionQueueItem,
        context: ResolvedCodexLocalThreadMaterializationContext,
        developerInstructions: String
    ) async throws -> MaterializedCodexThread
}

struct PreparedCopilotResponsesBridge: Equatable, Sendable {
    let baseURL: String
    let apiKeyEnvName: String
    let apiKey: String
}

struct ManagedCopilotConfigBootstrapResult: Equatable, Sendable {
    let credential: CopilotCredential
    let configDirectoryURL: URL
}

struct ResolvedCodexDesktopModelSelection: Equatable, Sendable {
    let selectedModel: String
    let availableModels: [String]
}

protocol CopilotResponsesBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        credential: CopilotCredential,
        model: String,
        availableModels: [String],
        workingDirectoryURL: URL,
        configDirectoryURL: URL,
        reasoningEffort: String
    ) async throws -> PreparedCopilotResponsesBridge
}

protocol CopilotManagedConfigManaging: Sendable {
    func bootstrap(
        accountID: UUID,
        credential: CopilotCredential,
        model: String?,
        reasoningEffort: String
    ) async throws -> ManagedCopilotConfigBootstrapResult
}

protocol ClaudeProviderCodexBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
    ) async throws -> PreparedClaudeProviderCodexBridge
}

protocol OpenAICompatibleProviderCodexBridgeManaging: Sendable {
    func prepareBridge(
        accountID: UUID,
        baseURL: String,
        apiKeyEnvName: String,
        apiKey: String,
        model: String,
        availableModels: [String]
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
    func hasRunningMainApplication() async -> Bool
    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval) async -> SwitchVerificationResult
    func restartCodex(launchEnvironment: [String: String]) async throws
}

protocol CLIEnvironmentResolving: Sendable {
    func resolveCodexDesktopModelSelection(
        for account: ManagedAccount,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        copilotCredential: CopilotCredential?,
        copilotStatus: CopilotAccountStatus?
    ) async throws -> ResolvedCodexDesktopModelSelection

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
    ) async throws -> ResolvedCodexCLILaunchContext

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
    ) async throws -> ResolvedCodexDesktopLaunchContext

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
        appSupportDirectoryURL: URL,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths

    func launchIsolatedInstance(
        context: ResolvedCodexDesktopLaunchContext,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths

    func launchIsolatedInstance(
        context: ResolvedCodexDesktopLaunchContext,
        deeplinkURL: URL?,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths
}

extension CodexInstanceLaunching {
    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL
    ) throws -> IsolatedCodexLaunchPaths {
        try launchIsolatedInstance(
            for: account,
            payload: payload,
            appSupportDirectoryURL: appSupportDirectoryURL,
            onTermination: {}
        )
    }

    func launchIsolatedInstance(
        context: ResolvedCodexDesktopLaunchContext
    ) throws -> IsolatedCodexLaunchPaths {
        try launchIsolatedInstance(context: context, onTermination: {})
    }

    func launchIsolatedInstance(
        context: ResolvedCodexDesktopLaunchContext,
        deeplinkURL: URL?,
        onTermination: @escaping @Sendable () -> Void
    ) throws -> IsolatedCodexLaunchPaths {
        try launchIsolatedInstance(context: context, onTermination: onTermination)
    }
}

protocol CodexCLILaunching {
    func launchCLI(context: ResolvedCodexCLILaunchContext) throws
    func launchCLI(
        context: ResolvedCodexCLILaunchContext,
        initialPrompt: String?,
        additionalDirectoryURL: URL?
    ) throws
}

extension CodexCLILaunching {
    func launchCLI(
        context: ResolvedCodexCLILaunchContext,
        initialPrompt: String?,
        additionalDirectoryURL: URL?
    ) throws {
        var arguments = context.arguments
        if let additionalDirectoryURL {
            arguments.append(contentsOf: ["--add-dir", additionalDirectoryURL.standardizedFileURL.path])
        }
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            arguments.append(prompt)
        }
        try launchCLI(context: ResolvedCodexCLILaunchContext(
            accountID: context.accountID,
            workingDirectoryURL: context.workingDirectoryURL,
            mode: context.mode,
            codexHomeURL: context.codexHomeURL,
            authPayload: context.authPayload,
            modelCatalogSnapshot: context.modelCatalogSnapshot,
            configFileContents: context.configFileContents,
            environmentVariables: context.environmentVariables,
            arguments: arguments
        ))
    }
}

protocol ClaudeCLILaunching {
    func launchCLI(context: ResolvedClaudeCLILaunchContext) throws
}
