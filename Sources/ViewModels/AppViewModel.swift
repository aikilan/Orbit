import AppKit
import Combine
import Foundation

enum BannerAction: Equatable {
    case restartCodex

    var title: String {
        switch self {
        case .restartCodex:
            return L10n.tr("重启 Codex")
        }
    }
}

struct BannerState: Equatable {
    let level: SwitchLogLevel
    let message: String
    let action: BannerAction?

    init(level: SwitchLogLevel, message: String, action: BannerAction? = nil) {
        self.level = level
        self.message = message
        self.action = action
    }
}

struct LowQuotaSwitchRecommendation: Equatable, Sendable {
    let activeAccountID: UUID
    let activeAccountName: String
    let activeSummary: String
    let recommendedAccountID: UUID
    let recommendedAccountName: String
    let recommendedSummary: String

    var promptTitle: String {
        L10n.tr("当前账号 5 小时额度偏低")
    }

    var promptMessage: String {
        L10n.tr("%@ 当前剩余 %@，建议切换到 %@（%@）。", activeAccountName, activeSummary, recommendedAccountName, recommendedSummary)
    }

    var switchButtonTitle: String {
        L10n.tr("切换到 %@", recommendedAccountName)
    }

    var notificationTitle: String {
        L10n.tr("Codex 额度提醒")
    }

    var notificationBody: String {
        L10n.tr("%@ 的 5 小时额度接近 10%%，可切换到 %@（%@）。", activeAccountName, recommendedAccountName, recommendedSummary)
    }

    var recommendationKey: String {
        "\(activeAccountID.uuidString)|\(recommendedAccountID.uuidString)"
    }
}

enum AddAccountMode: String, CaseIterable, Identifiable {
    case browser
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser:
            return L10n.tr("浏览器登录")
        case .apiKey:
            return L10n.tr("API Key")
        }
    }
}

private enum AccountStatusRefreshOutcome {
    case success
    case partial
    case failure
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var database: AppDatabase = .empty
    @Published var selectedAccountID: UUID?
    @Published private(set) var languagePreference = L10n.currentLanguagePreference
    @Published var addAccountMode: AddAccountMode = .browser
    @Published var addAccountStatus = L10n.tr("选择浏览器登录或 API Key 接入方式。")
    @Published var addAccountError: String?
    @Published var isAuthenticating = false
    @Published var browserAuthorizeURL: URL?
    @Published var browserCallbackInput = ""
    @Published var apiKeyInput = ""
    @Published var apiKeyDisplayName = ""
    @Published var banner: BannerState?
    @Published var pendingDeleteAccountID: UUID?
    @Published private(set) var refreshingAccountIDs: Set<UUID> = []
    @Published private(set) var isRefreshingAllStatuses = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var verifyingSwitchAccountID: UUID?
    @Published private(set) var restartRecommendedAccountID: UUID?
    @Published private(set) var isRestartingCodex = false
    @Published private(set) var shouldPromptRestartAfterSwitch = false
    @Published private(set) var pendingRestartPromptMessage: String?
    @Published private(set) var lowQuotaSwitchRecommendation: LowQuotaSwitchRecommendation?
    @Published private(set) var launchingIsolatedInstanceAccountID: UUID?
    @Published private(set) var launchedIsolatedInstanceAccountIDs: Set<UUID> = []
    @Published private(set) var launchingCLIAccountID: UUID?

    let paths: AppPaths

    private let databaseStore: AppDatabaseStore
    private let credentialStore: any AccountCredentialStore
    private let authFileManager: any AuthFileManaging
    private let jwtDecoder: JWTClaimsDecoder
    private let oauthClient: any OAuthClienting
    private let quotaMonitor: any QuotaMonitoring
    private let userNotifier: any UserNotifying
    private let runtimeInspector: any CodexRuntimeInspecting
    private let instanceLauncher: any CodexInstanceLaunching
    private let cliLauncher: any CodexCLILaunching
    private let bannerAutoDismissDuration: Duration
    private var browserSession: BrowserOAuthSession?
    private var browserWaitTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isReconcilingCurrentAuth = false
    private var suppressActivationReconcileUntil: Date?
    private var dismissedLowQuotaRecommendationKey: String?
    private var notifiedLowQuotaRecommendationKey: String?

    init(
        paths: AppPaths,
        databaseStore: AppDatabaseStore,
        credentialStore: any AccountCredentialStore,
        authFileManager: any AuthFileManaging,
        jwtDecoder: JWTClaimsDecoder,
        oauthClient: any OAuthClienting,
        quotaMonitor: any QuotaMonitoring,
        userNotifier: any UserNotifying,
        runtimeInspector: any CodexRuntimeInspecting,
        instanceLauncher: any CodexInstanceLaunching = CodexInstanceLauncher(),
        cliLauncher: any CodexCLILaunching = CodexCLILauncher(),
        bannerAutoDismissDuration: Duration = .seconds(10)
    ) {
        self.paths = paths
        self.databaseStore = databaseStore
        self.credentialStore = credentialStore
        self.authFileManager = authFileManager
        self.jwtDecoder = jwtDecoder
        self.oauthClient = oauthClient
        self.quotaMonitor = quotaMonitor
        self.userNotifier = userNotifier
        self.runtimeInspector = runtimeInspector
        self.instanceLauncher = instanceLauncher
        self.cliLauncher = cliLauncher
        self.bannerAutoDismissDuration = bannerAutoDismissDuration
    }

    static func live() -> AppViewModel {
        do {
            let paths = try AppPaths()
            let dbStore = AppDatabaseStore(databaseURL: paths.databaseURL)
            let credentialStore = CachedCredentialStore(
                persistentStore: PlaintextCredentialCacheStore(cacheFileURL: paths.credentialCacheURL)
            )
            let authFileManager = AuthFileManager(authFileURL: paths.authFileURL)
            let jwtDecoder = JWTClaimsDecoder()
            let oauthClient = OAuthClient()
            let logReader = SQLiteLogReader(databaseURL: paths.stateDatabaseURL)
            let quotaMonitor = QuotaMonitor(
                sessionScanner: SessionQuotaScanner(sessionsDirectoryURL: paths.sessionsDirectoryURL),
                logReader: logReader
            )
            let userNotifier = UserNotificationManager()
            let runtimeInspector = CodexRuntimeInspector(logReader: logReader)
            return AppViewModel(
                paths: paths,
                databaseStore: dbStore,
                credentialStore: credentialStore,
                authFileManager: authFileManager,
                jwtDecoder: jwtDecoder,
                oauthClient: oauthClient,
                quotaMonitor: quotaMonitor,
                userNotifier: userNotifier,
                runtimeInspector: runtimeInspector,
                cliLauncher: CodexCLILauncher()
            )
        } catch {
            fatalError("Failed to build AppViewModel: \(error.localizedDescription)")
        }
    }

    var accounts: [ManagedAccount] {
        database.accounts
    }

    var activeAccount: ManagedAccount? {
        database.account(id: database.activeAccountID)
    }

    var selectedAccount: ManagedAccount? {
        database.account(id: selectedAccountID) ?? activeAccount
    }

    var pendingDeleteAccount: ManagedAccount? {
        database.account(id: pendingDeleteAccountID)
    }

    func isRefreshingStatus(for accountID: UUID) -> Bool {
        refreshingAccountIDs.contains(accountID)
    }

    func isSwitchingAccount(_ accountID: UUID) -> Bool {
        switchingAccountID == accountID
    }

    func isVerifyingSwitch(for accountID: UUID) -> Bool {
        verifyingSwitchAccountID == accountID
    }

    func isLaunchingIsolatedInstance(for accountID: UUID) -> Bool {
        launchingIsolatedInstanceAccountID == accountID
    }

    func hasLaunchedIsolatedInstance(for accountID: UUID) -> Bool {
        launchedIsolatedInstanceAccountIDs.contains(accountID)
    }

    func isLaunchingCLI(for accountID: UUID) -> Bool {
        launchingCLIAccountID == accountID
    }

    func canLaunchIsolatedCodex(for account: ManagedAccount) -> Bool {
        !(account.isActive && account.authMode == .chatgpt) && !hasLaunchedIsolatedInstance(for: account.id)
    }

    var isSwitchInProgress: Bool {
        switchingAccountID != nil || verifyingSwitchAccountID != nil
    }

    func snapshot(for accountID: UUID) -> QuotaSnapshot? {
        database.snapshot(for: accountID)
    }

    func cliWorkingDirectories(for accountID: UUID) -> [String] {
        database.cliWorkingDirectories(for: accountID)
    }

    func shouldOfferRestartCodex(for account: ManagedAccount) -> Bool {
        restartRecommendedAccountID == account.id && runtimeInspector.isCodexDesktopRunning()
    }

    var canQuickRestartCodex: Bool {
        runtimeInspector.isCodexDesktopRunning()
    }

    var restartPromptMessage: String? {
        guard shouldPromptRestartAfterSwitch else { return nil }
        return pendingRestartPromptMessage
    }

    func updateLanguagePreference(_ preference: AppLanguagePreference) {
        guard languagePreference != preference else { return }
        L10n.setLanguagePreference(preference)
        languagePreference = preference

        if browserSession == nil, !isAuthenticating, addAccountError == nil {
            addAccountStatus = L10n.tr("选择浏览器登录或 API Key 接入方式。")
        }

        (NSApp.delegate as? AppDelegate)?.refreshLocalization()
    }

    func prepare() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            database = try await databaseStore.load()
            selectedAccountID = database.activeAccountID ?? database.accounts.first?.id
        } catch {
            pushBanner(level: .error, message: L10n.tr("本地数据库读取失败：%@", error.localizedDescription))
        }

        do {
            try credentialStore.preload()
        } catch {
            database.appendLog(level: .warning, message: L10n.tr("本地凭据缓存读取失败，将在需要时回退迁移：%@", error.localizedDescription))
        }

        await importCurrentAuthIfNeeded()
        startQuotaMonitor()
        evaluateLowQuotaSwitchRecommendation()
    }

    func importCurrentAuthIfNeeded() async {
        do {
            guard let payload = try authFileManager.readCurrentAuth() else { return }
            let identity = try resolveIdentity(from: payload)
            let account = upsertAccount(identity: identity, payload: payload, makeActive: true)
            try credentialStore.save(payload, for: account.id)

            if database.snapshot(for: account.id) == nil, let snapshot = quotaMonitor.bootstrapSnapshot() {
                database.updateSnapshot(snapshot, for: account.id)
                evaluateLowQuotaSwitchRecommendation()
            }

            setActiveAccount(account.id)
            selectedAccountID = selectedAccountID ?? account.id
            database.appendLog(level: .info, message: L10n.tr("已导入当前 ~/.codex/auth.json 对应的账号。"))
            try await persistDatabase()
        } catch {
            pushBanner(level: .warning, message: L10n.tr("当前 auth.json 无法导入：%@", error.localizedDescription))
        }
    }

    func reconcileCurrentAuthState() async {
        guard hasLoaded, !isReconcilingCurrentAuth else { return }
        isReconcilingCurrentAuth = true
        defer { isReconcilingCurrentAuth = false }

        do {
            guard let payload = try authFileManager.readCurrentAuth() else {
                guard let previousActiveID = database.activeAccountID else { return }
                setActiveAccount(nil)
                if selectedAccountID == previousActiveID {
                    selectedAccountID = database.accounts.first?.id
                }
                database.appendLog(level: .info, message: L10n.tr("检测到当前 ~/.codex/auth.json 已清空，已同步当前账号状态。"))
                try await persistDatabase()
                return
            }

            let identity = try resolveIdentity(from: payload)
            let previousActiveID = database.activeAccountID
            let existingAccountID = database.accounts.first(where: { $0.codexAccountID == identity.accountID })?.id
            let account = upsertAccount(identity: identity, payload: payload, makeActive: true)
            try credentialStore.save(payload, for: account.id)

            if database.snapshot(for: account.id) == nil, let snapshot = quotaMonitor.bootstrapSnapshot() {
                database.updateSnapshot(snapshot, for: account.id)
                evaluateLowQuotaSwitchRecommendation()
            }

            setActiveAccount(account.id)
            if selectedAccountID == nil || previousActiveID != account.id {
                selectedAccountID = account.id
            }

            if previousActiveID != account.id || existingAccountID == nil {
                database.appendLog(level: .info, message: L10n.tr("检测到当前 ~/.codex/auth.json 正在使用账号 %@，已同步当前账号。", account.displayName))
            }

            try await persistDatabase()
        } catch {
            database.appendLog(level: .warning, message: L10n.tr("反向检查当前 auth.json 失败：%@", error.localizedDescription))
            try? await persistDatabase()
        }
    }

    func noteProgrammaticActivation(gracePeriod: TimeInterval = 1) {
        suppressActivationReconcileUntil = Date().addingTimeInterval(gracePeriod)
    }

    func reconcileCurrentAuthStateForAppActivation() async {
        if let suppressUntil = suppressActivationReconcileUntil, suppressUntil > Date() {
            return
        }
        suppressActivationReconcileUntil = nil
        await reconcileCurrentAuthState()
    }

    func openCodexHomeInFinder() {
        NSWorkspace.shared.open(paths.codexHome)
    }

    func openCodexCLI(for account: ManagedAccount, workingDirectoryURL: URL) async {
        guard launchingCLIAccountID == nil else { return }
        launchingCLIAccountID = account.id
        defer {
            if launchingCLIAccountID == account.id {
                launchingCLIAccountID = nil
            }
        }

        do {
            if account.isActive {
                try cliLauncher.launchCLI(
                    for: account,
                    mode: .globalCurrentAuth,
                    workingDirectoryURL: workingDirectoryURL,
                    appSupportDirectoryURL: paths.appSupportDirectoryURL
                )
                database.rememberCLIWorkingDirectory(workingDirectoryURL, for: account.id)
                try? await persistDatabase()
                pushBanner(level: .info, message: L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
                return
            }

            let cachedPayload = try latestPayloadForRefresh(for: account)
            var payload = cachedPayload

            if payload.authMode == .chatgpt {
                do {
                    let refreshed = try await oauthClient.refreshAuth(using: payload)
                    payload = refreshed.payload
                    try credentialStore.save(refreshed.payload, for: account.id)
                    let refreshedAccount = upsertAccount(identity: refreshed.identity, payload: refreshed.payload, makeActive: false)
                    database.appendLog(level: .info, message: L10n.tr("打开 CLI 前已在线刷新账号 %@ 的凭据。", refreshedAccount.displayName))
                    try? await persistDatabase()
                } catch {
                    database.appendLog(level: .warning, message: L10n.tr("打开 CLI 前在线刷新账号 %@ 失败，已回退当前本地凭据：%@", account.displayName, error.localizedDescription))
                    try? await persistDatabase()
                }
            }

            try cliLauncher.launchCLI(
                for: account,
                mode: .isolatedAccount(payload: payload),
                workingDirectoryURL: workingDirectoryURL,
                appSupportDirectoryURL: paths.appSupportDirectoryURL
            )
            database.rememberCLIWorkingDirectory(workingDirectoryURL, for: account.id)
            try? await persistDatabase()
            pushBanner(level: .info, message: L10n.tr("已为账号 %@ 打开 Codex CLI。", account.displayName))
        } catch {
            pushBanner(level: .error, message: L10n.tr("打开 Codex CLI 失败：%@", error.localizedDescription))
        }
    }

    func launchIsolatedCodex(for account: ManagedAccount) async {
        if hasLaunchedIsolatedInstance(for: account.id) {
            pushBanner(level: .info, message: L10n.tr("账号 %@ 的独立实例已在当前会话中启动。", account.displayName))
            return
        }
        guard canLaunchIsolatedCodex(for: account) else {
            pushBanner(level: .error, message: L10n.tr("当前活跃的 ChatGPT 账号不能直接启动独立实例，避免触发 refresh_token_reused。"))
            return
        }
        guard launchingIsolatedInstanceAccountID == nil else { return }
        launchingIsolatedInstanceAccountID = account.id
        defer {
            if launchingIsolatedInstanceAccountID == account.id {
                launchingIsolatedInstanceAccountID = nil
            }
        }

        do {
            let cachedPayload = try latestPayloadForRefresh(for: account)
            var payload = cachedPayload

            if account.isActive,
               let currentPayload = try authFileManager.readCurrentAuth(),
               currentPayload.accountIdentifier == account.codexAccountID
            {
                payload = currentPayload
                try credentialStore.save(currentPayload, for: account.id)
            }

            if payload.authMode == .chatgpt {
                do {
                    let refreshed = try await oauthClient.refreshAuth(using: payload)
                    payload = refreshed.payload
                    try credentialStore.save(refreshed.payload, for: account.id)
                    let refreshedAccount = upsertAccount(identity: refreshed.identity, payload: refreshed.payload, makeActive: account.isActive)
                    database.appendLog(level: .info, message: L10n.tr("独立实例启动前已在线刷新账号 %@ 的凭据。", refreshedAccount.displayName))
                    try? await persistDatabase()
                } catch {
                    database.appendLog(level: .warning, message: L10n.tr("独立实例启动前在线刷新账号 %@ 失败，已回退当前本地凭据：%@", account.displayName, error.localizedDescription))
                    try? await persistDatabase()
                }
            }

            _ = try instanceLauncher.launchIsolatedInstance(
                for: account,
                payload: payload,
                appSupportDirectoryURL: paths.appSupportDirectoryURL
            )
            launchedIsolatedInstanceAccountIDs.insert(account.id)
            pushBanner(level: .info, message: L10n.tr("已为账号 %@ 启动独立 Codex 实例。", account.displayName))
        } catch {
            pushBanner(level: .error, message: L10n.tr("启动独立 Codex 实例失败：%@", error.localizedDescription))
        }
    }

    func startBrowserLogin() async {
        addAccountError = nil
        addAccountStatus = L10n.tr("正在准备浏览器 OAuth。")
        browserCallbackInput = ""
        isAuthenticating = true

        do {
            let oauthClient = self.oauthClient
            let session = try await oauthClient.beginBrowserLogin(openURL: { NSWorkspace.shared.open($0) })
            browserSession = session
            browserAuthorizeURL = session.authorizeURL

            if let serverErrorDescription = session.serverErrorDescription {
                addAccountStatus = L10n.tr("浏览器已打开，但本地 1455 回调端口未就绪：%@。请登录后把最终跳转 URL 或 code 粘贴回来。", serverErrorDescription)
            } else {
                addAccountStatus = L10n.tr("浏览器已打开。若没有自动完成，请把最终跳转到 localhost:1455 的完整 URL 或 code 粘贴回来。")
                waitForBrowserCallback(session)
            }
        } catch {
            addAccountError = error.localizedDescription
            addAccountStatus = L10n.tr("浏览器登录失败。")
            database.appendLog(level: .error, message: L10n.tr("浏览器登录失败：%@", error.localizedDescription))
            try? await persistDatabase()
        }

        isAuthenticating = false
    }

    func submitBrowserCallback() async {
        guard let session = browserSession else {
            addAccountError = L10n.tr("当前没有待完成的浏览器登录会话。")
            return
        }

        let pastedInput = browserCallbackInput
        guard !pastedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            addAccountError = L10n.tr("请粘贴最终跳转 URL 或 authorization code。")
            return
        }

        browserWaitTask?.cancel()
        isAuthenticating = true
        addAccountError = nil
        addAccountStatus = L10n.tr("正在验证你粘贴的回调结果。")

        do {
            let result = try await oauthClient.completeBrowserLogin(session: session, pastedInput: pastedInput)
            try await finalizeLogin(result)
        } catch {
            addAccountError = error.localizedDescription
            addAccountStatus = L10n.tr("手动回调验证失败。")
            database.appendLog(level: .error, message: L10n.tr("手动回调验证失败：%@", error.localizedDescription))
            try? await persistDatabase()
        }

        isAuthenticating = false
    }

    func startAPIKeyLogin() async {
        addAccountError = nil
        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredDisplayName = apiKeyDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty else {
            addAccountError = L10n.tr("请输入 API Key。")
            return
        }

        addAccountStatus = L10n.tr("正在接入 API Key。")
        isAuthenticating = true

        do {
            let payload = try CodexAuthPayload(authMode: .apiKey, openAIAPIKey: apiKey).validated()
            let identity = try resolveIdentity(
                from: payload,
                preferredDisplayName: preferredDisplayName.isEmpty ? nil : preferredDisplayName
            )
            try await finalizeLogin(AuthLoginResult(payload: payload, identity: identity))
        } catch {
            addAccountError = error.localizedDescription
            addAccountStatus = L10n.tr("API Key 接入失败。")
            database.appendLog(level: .error, message: L10n.tr("API Key 接入失败：%@", error.localizedDescription))
            try? await persistDatabase()
        }

        isAuthenticating = false
    }

    func switchToAccount(_ account: ManagedAccount) async {
        guard !isSwitchInProgress else { return }
        switchingAccountID = account.id
        verifyingSwitchAccountID = nil
        restartRecommendedAccountID = nil
        shouldPromptRestartAfterSwitch = false
        pendingRestartPromptMessage = nil

        do {
            let payload = try await latestPayloadForSwitch(for: account)
            try authFileManager.activatePreservingFileIdentity(payload)
            setActiveAccount(account.id)
            selectedAccountID = account.id
            database.appendLog(level: .info, message: L10n.tr("已切换到账号 %@。", account.displayName))
            try await persistDatabase()
            switchingAccountID = nil
            verifyingSwitchAccountID = account.id
            await verifySwitch(at: Date(), for: account.id)
        } catch {
            switchingAccountID = nil
            verifyingSwitchAccountID = nil
            pushBanner(level: .error, message: L10n.tr("账号切换失败：%@", error.localizedDescription))
            database.appendLog(level: .error, message: L10n.tr("账号切换失败：%@", error.localizedDescription))
            try? await persistDatabase()
        }
    }

    func renameAccount(_ accountID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = database.accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }
        database.accounts[index].displayName = trimmed
        database.appendLog(level: .info, message: L10n.tr("已重命名账号为 %@。", trimmed))
        Task {
            try? await persistDatabase()
        }
    }

    func requestDeleteAccount(_ accountID: UUID) {
        pendingDeleteAccountID = accountID
    }

    func cancelPendingDelete() {
        pendingDeleteAccountID = nil
    }

    func deletePendingAccount(clearCurrentAuth: Bool) async {
        guard let accountID = pendingDeleteAccountID else { return }
        await deleteAccount(accountID, clearCurrentAuth: clearCurrentAuth)
    }

    func deleteAccount(_ accountID: UUID, clearCurrentAuth: Bool) async {
        guard let account = database.account(id: accountID) else { return }
        if pendingDeleteAccountID == accountID {
            pendingDeleteAccountID = nil
        }

        do {
            try credentialStore.delete(for: accountID)
            if account.isActive {
                if clearCurrentAuth {
                    try authFileManager.clearAuthFile()
                }
                setActiveAccount(nil)
            }
            database.removeAccount(id: accountID)
            selectedAccountID = database.accounts.first?.id
            database.appendLog(
                level: .info,
                message: clearCurrentAuth ? L10n.tr("已删除账号并清空当前 ~/.codex/auth.json。") : L10n.tr("已删除账号 %@。", account.displayName)
            )
            evaluateLowQuotaSwitchRecommendation()
            try await persistDatabase()
        } catch {
            pushBanner(level: .error, message: L10n.tr("删除账号失败：%@", error.localizedDescription))
        }
    }

    func refreshAccountStatus(_ account: ManagedAccount) async {
        _ = await refreshAccountStatus(accountID: account.id, showBanner: true)
    }

    func refreshAllAccountStatuses() async {
        guard !isRefreshingAllStatuses else { return }
        isRefreshingAllStatuses = true

        let accountIDs = database.accounts.map(\.id)
        var successCount = 0
        var partialCount = 0
        var failureCount = 0

        for accountID in accountIDs {
            switch await refreshAccountStatus(accountID: accountID, showBanner: false) {
            case .success:
                successCount += 1
            case .partial:
                partialCount += 1
            case .failure:
                failureCount += 1
            }
        }

        isRefreshingAllStatuses = false
        let level: SwitchLogLevel = failureCount == 0 && partialCount == 0 ? .info : .warning
        let message: String
        if failureCount == 0 && partialCount == 0 {
            message = L10n.tr("已完成 %d 个账号的状态与额度更新。", successCount)
        } else if failureCount == 0 {
            message = L10n.tr("状态更新完成：成功 %d 个，部分成功 %d 个。", successCount, partialCount)
        } else {
            message = L10n.tr("状态更新完成：成功 %d 个，部分成功 %d 个，失败 %d 个。", successCount, partialCount, failureCount)
        }
        banner = BannerState(level: level, message: message)
        database.appendLog(level: level, message: message)
        try? await persistDatabase()
    }

    func dismissAddAccountSheet() {
        browserWaitTask?.cancel()
        browserWaitTask = nil
        browserSession?.stop()
        browserSession = nil
        browserAuthorizeURL = nil
        browserCallbackInput = ""
        apiKeyInput = ""
        apiKeyDisplayName = ""
        addAccountError = nil
        addAccountStatus = L10n.tr("选择浏览器登录或 API Key 接入方式。")
        isAuthenticating = false
    }

    private func finalizeLogin(_ result: AuthLoginResult) async throws {
        let account = upsertAccount(identity: result.identity, payload: result.payload, makeActive: false)
        try credentialStore.save(result.payload, for: account.id)
        try authFileManager.activatePreservingFileIdentity(result.payload)
        setActiveAccount(account.id)
        selectedAccountID = account.id
        database.appendLog(level: .info, message: L10n.tr("已登录并激活账号 %@。", account.displayName))
        try await persistDatabase()
        await verifySwitch(at: Date(), for: account.id)
        dismissAddAccountSheet()
    }

    private func resolveIdentity(from payload: CodexAuthPayload, preferredDisplayName: String? = nil) throws -> AuthIdentity {
        switch payload.authMode {
        case .chatgpt:
            return try jwtDecoder.decodeIdentity(from: payload)
        case .apiKey:
            let validatedPayload = try payload.validated()
            let suffix = String((validatedPayload.openAIAPIKey ?? "").suffix(6))
            let fallbackDisplayName = suffix.isEmpty ? L10n.tr("API Key") : L10n.tr("API Key • %@", suffix)
            return AuthIdentity(
                accountID: validatedPayload.accountIdentifier,
                displayName: preferredDisplayName ?? fallbackDisplayName,
                email: validatedPayload.credentialSummary,
                planType: nil
            )
        }
    }

    private func upsertAccount(identity: AuthIdentity, payload: CodexAuthPayload, makeActive: Bool) -> ManagedAccount {
        let existing = database.accounts.first(where: { $0.codexAccountID == identity.accountID })
        let refreshDate = CodexDateCoding.parse(payload.lastRefresh)

        let account = ManagedAccount(
            id: existing?.id ?? UUID(),
            codexAccountID: identity.accountID,
            displayName: existing?.displayName ?? identity.displayName,
            email: identity.email ?? existing?.email,
            authMode: payload.authMode,
            createdAt: existing?.createdAt ?? Date(),
            lastUsedAt: existing?.lastUsedAt,
            lastQuotaSnapshotAt: existing?.lastQuotaSnapshotAt,
            lastRefreshAt: refreshDate,
            planType: identity.planType ?? existing?.planType,
            subscriptionDetails: existing?.subscriptionDetails,
            lastStatusCheckAt: existing?.lastStatusCheckAt,
            lastStatusMessage: existing?.lastStatusMessage,
            lastStatusLevel: existing?.lastStatusLevel,
            isActive: makeActive
        )
        database.upsert(account: account)
        return account
    }

    @discardableResult
    private func refreshAccountStatus(accountID: UUID, showBanner: Bool) async -> AccountStatusRefreshOutcome {
        guard !refreshingAccountIDs.contains(accountID), let currentAccount = database.account(id: accountID) else {
            return .failure
        }

        refreshingAccountIDs.insert(accountID)
        defer { refreshingAccountIDs.remove(accountID) }

        let startedAt = Date()

        do {
            let sourcePayload = try latestPayloadForRefresh(for: currentAccount)
            if sourcePayload.authMode == .apiKey {
                let isActive = database.account(id: accountID)?.isActive ?? currentAccount.isActive

                if isActive {
                    try authFileManager.activatePreservingFileIdentity(sourcePayload)
                }

                let statusMessage = isActive
                    ? L10n.tr("API Key 模式不支持在线额度同步，已同步当前 ~/.codex/auth.json。")
                    : L10n.tr("API Key 模式不支持在线额度同步，本地凭据可用。")
                let logMessage = isActive
                    ? L10n.tr("已确认 API Key 账号 %@ 可用，并同步当前 ~/.codex/auth.json。", currentAccount.displayName)
                    : L10n.tr("已确认 API Key 账号 %@ 的本地凭据可用。", currentAccount.displayName)

                updateStatusMetadata(
                    for: accountID,
                    level: .info,
                    message: statusMessage,
                    checkedAt: Date(),
                    planType: currentAccount.planType
                )

                if showBanner {
                    banner = BannerState(level: .info, message: logMessage)
                }
                database.appendLog(level: .info, message: logMessage)
                try await persistDatabase()
                return .success
            }

            let result = try await oauthClient.refreshAuth(using: sourcePayload)
            try credentialStore.save(result.payload, for: accountID)

            let isActive = database.account(id: accountID)?.isActive ?? currentAccount.isActive
            if isActive {
                try authFileManager.activatePreservingFileIdentity(result.payload)
            }

            let refreshedAccount = upsertAccount(identity: result.identity, payload: result.payload, makeActive: isActive)
            var outcome: AccountStatusRefreshOutcome = .success
            var bannerLevel: SwitchLogLevel = .info
            var statusMessage = isActive ? L10n.tr("状态已更新，并同步了当前 ~/.codex/auth.json。") : L10n.tr("状态已更新，账号凭据可用。")
            var logMessage = L10n.tr("已手动更新账号 %@ 的状态。", refreshedAccount.displayName)

            do {
                let usage = try await oauthClient.fetchUsageSnapshot(using: result.payload)
                database.updateSnapshot(usage.snapshot, for: refreshedAccount.id)
                evaluateLowQuotaSwitchRecommendation()
                updateAccountContactMetadata(for: refreshedAccount.id, email: usage.email, planType: usage.planType)
                updateSubscriptionMetadata(for: refreshedAccount.id, details: usage.subscriptionDetails)

                let quotaSummary = usage.snapshot.remainingSummary
                if usage.limitReached || !usage.allowed {
                    statusMessage = L10n.tr("状态与额度已更新：剩余 %@，当前已触达额度限制。", quotaSummary)
                } else {
                    statusMessage = L10n.tr("状态与额度已更新：剩余 %@。", quotaSummary)
                }
                logMessage = L10n.tr("已手动更新账号 %@ 的状态与额度。", refreshedAccount.displayName)
                updateStatusMetadata(
                    for: refreshedAccount.id,
                    level: .info,
                    message: statusMessage,
                    checkedAt: Date(),
                    planType: usage.planType ?? result.identity.planType
                )
            } catch {
                outcome = .partial
                bannerLevel = .warning
                statusMessage = L10n.tr("状态已更新，但额度同步失败：%@", error.localizedDescription)
                logMessage = L10n.tr("已手动更新账号 %@ 的状态，但额度同步失败。", refreshedAccount.displayName)
                updateStatusMetadata(
                    for: refreshedAccount.id,
                    level: .warning,
                    message: statusMessage,
                    checkedAt: Date(),
                    planType: result.identity.planType
                )

                if database.snapshot(for: refreshedAccount.id) == nil, let snapshot = quotaMonitor.bootstrapSnapshot() {
                    database.updateSnapshot(snapshot, for: refreshedAccount.id)
                    evaluateLowQuotaSwitchRecommendation()
                }
            }

            if showBanner {
                banner = BannerState(level: bannerLevel, message: logMessage)
            }
            database.appendLog(level: bannerLevel, message: logMessage)
            try await persistDatabase()

            if isActive {
                verifyingSwitchAccountID = accountID
                await verifySwitch(at: startedAt, for: accountID)
            }
            return outcome
        } catch {
            let message = L10n.tr("状态更新失败：%@", error.localizedDescription)
            updateStatusMetadata(for: accountID, level: .warning, message: message, checkedAt: Date(), planType: nil)
            if showBanner {
                banner = BannerState(level: .warning, message: message)
            }
            database.appendLog(level: .warning, message: L10n.tr("账号状态更新失败：%@", error.localizedDescription))
            try? await persistDatabase()
            return .failure
        }
    }

    private func latestPayloadForRefresh(for account: ManagedAccount) throws -> CodexAuthPayload {
        try credentialStore.loadLatest(for: account, authFileManager: authFileManager)
    }

    private func latestPayloadForSwitch(for account: ManagedAccount) async throws -> CodexAuthPayload {
        let cachedPayload = try latestPayloadForRefresh(for: account)

        if cachedPayload.authMode == .apiKey {
            return cachedPayload
        }

        do {
            let refreshed = try await oauthClient.refreshAuth(using: cachedPayload)
            try credentialStore.save(refreshed.payload, for: account.id)
            _ = upsertAccount(identity: refreshed.identity, payload: refreshed.payload, makeActive: account.isActive)
            database.appendLog(level: .info, message: L10n.tr("切换前已在线刷新账号 %@ 的凭据。", account.displayName))
            return refreshed.payload
        } catch {
            database.appendLog(level: .warning, message: L10n.tr("切换前在线刷新账号 %@ 失败，已回退本地缓存凭据：%@", account.displayName, error.localizedDescription))
            return cachedPayload
        }
    }

    private func updateStatusMetadata(
        for accountID: UUID,
        level: SwitchLogLevel,
        message: String,
        checkedAt: Date,
        planType: String?
    ) {
        guard let index = database.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        database.accounts[index].lastStatusCheckAt = checkedAt
        database.accounts[index].lastStatusMessage = message
        database.accounts[index].lastStatusLevel = level
        if let planType {
            database.accounts[index].planType = planType
        }
    }

    private func updateAccountContactMetadata(for accountID: UUID, email: String?, planType: String?) {
        guard let index = database.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let email, !email.isEmpty {
            database.accounts[index].email = email
        }
        if let planType, !planType.isEmpty {
            database.accounts[index].planType = planType
        }
    }

    private func updateSubscriptionMetadata(for accountID: UUID, details: SubscriptionDetails?) {
        guard
            let details,
            details.hasAnyValue,
            let index = database.accounts.firstIndex(where: { $0.id == accountID })
        else {
            return
        }

        database.accounts[index].subscriptionDetails = details.merged(over: database.accounts[index].subscriptionDetails)
    }

    func performBannerAction(_ action: BannerAction) async {
        switch action {
        case .restartCodex:
            guard !isRestartingCodex else { return }
            isRestartingCodex = true

            do {
                try await runtimeInspector.restartCodex()
                restartRecommendedAccountID = nil
                shouldPromptRestartAfterSwitch = false
                pendingRestartPromptMessage = nil
                pushBanner(level: .info, message: L10n.tr("已请求重启 Codex，新的授权信息会在应用恢复后重新加载。"))
            } catch {
                pushBanner(level: .error, message: L10n.tr("重启 Codex 失败：%@", error.localizedDescription), action: .restartCodex)
            }

            isRestartingCodex = false
        }
    }

    private func verifySwitch(at date: Date, for accountID: UUID) async {
        let runtimeInspector = self.runtimeInspector
        defer {
            if verifyingSwitchAccountID == accountID {
                verifyingSwitchAccountID = nil
            }
        }

        switch await runtimeInspector.verifySwitch(after: date, timeoutSeconds: 6) {
        case .verified:
            restartRecommendedAccountID = nil
            shouldPromptRestartAfterSwitch = false
            pendingRestartPromptMessage = nil
            pushBanner(level: .info, message: L10n.tr("Codex 运行态已经观测到新的认证/额度事件。"))
        case .restartRecommended:
            let message = L10n.tr("auth.json 已更新，但未观测到运行中 Codex 的热重载，可直接重启 Codex。")
            let action: BannerAction? = runtimeInspector.isCodexDesktopRunning() ? .restartCodex : nil
            restartRecommendedAccountID = action == nil ? nil : accountID
            shouldPromptRestartAfterSwitch = action != nil
            pendingRestartPromptMessage = action == nil ? nil : message
            pushBanner(level: .warning, message: message, action: action)
        case .noRunningClient:
            restartRecommendedAccountID = nil
            shouldPromptRestartAfterSwitch = false
            pendingRestartPromptMessage = nil
            pushBanner(level: .info, message: L10n.tr("auth.json 已更新；当前没有检测到运行中的 Codex 桌面端。"))
        case .authError(.refreshTokenReused):
            let message = L10n.tr("auth.json 已更新，但运行中的 Codex 仍持有旧授权并触发 refresh_token_reused，建议重启 Codex。")
            restartRecommendedAccountID = accountID
            shouldPromptRestartAfterSwitch = true
            pendingRestartPromptMessage = message
            pushBanner(level: .warning, message: message, action: .restartCodex)
        case let .authError(.generic(message)):
            let promptMessage = L10n.tr("auth.json 已更新，但运行中的 Codex 返回了认证错误：%@", message)
            restartRecommendedAccountID = accountID
            shouldPromptRestartAfterSwitch = true
            pendingRestartPromptMessage = promptMessage
            pushBanner(level: .warning, message: promptMessage, action: .restartCodex)
        }
    }

    func dismissRestartPrompt() {
        shouldPromptRestartAfterSwitch = false
        restartRecommendedAccountID = nil
        pendingRestartPromptMessage = nil
        if banner?.action == .restartCodex {
            banner = nil
        }
    }

    func dismissLowQuotaSwitchRecommendation() {
        dismissedLowQuotaRecommendationKey = lowQuotaSwitchRecommendation?.recommendationKey
        lowQuotaSwitchRecommendation = nil
    }

    func switchToRecommendedLowQuotaAccount() async {
        guard let recommendation = lowQuotaSwitchRecommendation,
              let account = database.account(id: recommendation.recommendedAccountID) else {
            lowQuotaSwitchRecommendation = nil
            return
        }

        lowQuotaSwitchRecommendation = nil
        await switchToAccount(account)
    }

    private func startQuotaMonitor() {
        quotaMonitor.setActiveAccountID(database.activeAccountID)
        quotaMonitor.start(
            onSnapshot: { [weak self] accountID, snapshot in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.database.updateSnapshot(snapshot, for: accountID)
                    self.database.appendLog(level: .info, message: L10n.tr("已为当前账号归档一条新的额度快照。"))
                    self.evaluateLowQuotaSwitchRecommendation()
                    try? await self.persistDatabase()
                }
            },
            onSignal: { [weak self] accountID, date in
                Task { @MainActor [weak self] in
                    guard let self, self.database.snapshot(for: accountID) == nil else { return }
                    self.database.appendLog(level: .info, message: L10n.tr("检测到本地 Codex 发出额度更新信号：%@", date.formatted(date: .abbreviated, time: .standard)))
                    try? await self.persistDatabase()
                }
            }
        )
    }

    private func setActiveAccount(_ accountID: UUID?) {
        database.setActiveAccount(accountID)
        quotaMonitor.setActiveAccountID(accountID)
        if accountID == nil {
            lowQuotaSwitchRecommendation = nil
            dismissedLowQuotaRecommendationKey = nil
            notifiedLowQuotaRecommendationKey = nil
        } else {
            dismissedLowQuotaRecommendationKey = nil
            notifiedLowQuotaRecommendationKey = nil
            evaluateLowQuotaSwitchRecommendation()
        }
    }

    private func waitForBrowserCallback(_ session: BrowserOAuthSession) {
        browserWaitTask?.cancel()
        browserWaitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.oauthClient.completeBrowserLogin(session: session)
                self.addAccountStatus = L10n.tr("浏览器回调已收到，正在完成登录。")
                try await self.finalizeLogin(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.addAccountError = error.localizedDescription
                self.addAccountStatus = L10n.tr("未能自动接收浏览器回调。你可以改为手动粘贴 redirect URL 或 code。")
            }
        }
    }

    private func pushBanner(level: SwitchLogLevel, message: String, action: BannerAction? = nil) {
        banner = BannerState(level: level, message: message, action: action)
        database.appendLog(level: level, message: message)
        bannerDismissTask?.cancel()
        let currentMessage = message
        bannerDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.bannerAutoDismissDuration)
            guard !Task.isCancelled else { return }
            if self.banner?.message == currentMessage {
                self.banner = nil
            }
        }
        Task {
            try? await persistDatabase()
        }
    }

    private func evaluateLowQuotaSwitchRecommendation() {
        guard let activeAccount = activeAccount,
              let activeSnapshot = database.snapshot(for: activeAccount.id),
              activeSnapshot.primary.remainingPercent <= 10
        else {
            lowQuotaSwitchRecommendation = nil
            dismissedLowQuotaRecommendationKey = nil
            notifiedLowQuotaRecommendationKey = nil
            return
        }

        guard let candidate = bestLowQuotaSwitchCandidate(excluding: activeAccount.id) else {
            lowQuotaSwitchRecommendation = nil
            return
        }

        let recommendation = LowQuotaSwitchRecommendation(
            activeAccountID: activeAccount.id,
            activeAccountName: activeAccount.displayName,
            activeSummary: activeSnapshot.remainingSummary,
            recommendedAccountID: candidate.account.id,
            recommendedAccountName: candidate.account.displayName,
            recommendedSummary: candidate.snapshot.remainingSummary
        )

        guard dismissedLowQuotaRecommendationKey != recommendation.recommendationKey else { return }

        let isNewRecommendation = lowQuotaSwitchRecommendation?.recommendationKey != recommendation.recommendationKey
        lowQuotaSwitchRecommendation = recommendation

        guard isNewRecommendation else { return }

        database.appendLog(
            level: .warning,
            message: L10n.tr("当前账号 %@ 的 5 小时额度已接近阈值，推荐切换到 %@。", activeAccount.displayName, candidate.account.displayName)
        )
        Task {
            try? await persistDatabase()
        }

        if notifiedLowQuotaRecommendationKey != recommendation.recommendationKey {
            notifiedLowQuotaRecommendationKey = recommendation.recommendationKey
            Task {
                await userNotifier.notifyLowQuotaRecommendation(
                    identifier: recommendation.recommendationKey,
                    title: recommendation.notificationTitle,
                    body: recommendation.notificationBody
                )
            }
        }
    }

    private func bestLowQuotaSwitchCandidate(excluding activeAccountID: UUID) -> (account: ManagedAccount, snapshot: QuotaSnapshot)? {
        database.accounts
            .filter { $0.id != activeAccountID }
            .compactMap { account -> (ManagedAccount, QuotaSnapshot)? in
                guard let snapshot = database.snapshot(for: account.id) else { return nil }
                return (account, snapshot)
            }
            .max { lhs, rhs in
                let leftScore = lhs.1.primary.remainingPercent + lhs.1.secondary.remainingPercent
                let rightScore = rhs.1.primary.remainingPercent + rhs.1.secondary.remainingPercent
                if leftScore == rightScore {
                    if lhs.1.primary.remainingPercent == rhs.1.primary.remainingPercent {
                        return lhs.1.secondary.remainingPercent < rhs.1.secondary.remainingPercent
                    }
                    return lhs.1.primary.remainingPercent < rhs.1.primary.remainingPercent
                }
                return leftScore < rightScore
            }
    }

    private func persistDatabase() async throws {
        try await databaseStore.save(database)
    }
}
