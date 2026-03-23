import Foundation

protocol AuthFileManaging {
    func readCurrentAuth() throws -> CodexAuthPayload?
    func activate(_ payload: CodexAuthPayload) throws
    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws
    func clearAuthFile() throws
}

protocol AccountCredentialStore {
    func preload() throws
    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws
    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> CodexAuthPayload
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
