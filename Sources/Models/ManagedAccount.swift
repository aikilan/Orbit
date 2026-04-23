import Foundation

struct SubscriptionDetails: Codable, Hashable, Sendable {
    var allowed: Bool? = nil
    var limitReached: Bool? = nil
}

extension SubscriptionDetails {
    var hasAnyValue: Bool {
        allowed != nil
            || limitReached != nil
    }

    func merged(over existing: SubscriptionDetails?) -> SubscriptionDetails {
        SubscriptionDetails(
            allowed: allowed ?? existing?.allowed,
            limitReached: limitReached ?? existing?.limitReached
        )
    }

    var usageStatusText: String {
        var parts = [String]()
        if allowed == false {
            parts.append(L10n.tr("不可用"))
        }
        if limitReached == true {
            parts.append(L10n.tr("额度受限"))
        }
        if parts.isEmpty, allowed == true {
            parts.append(L10n.tr("可用"))
        }
        return parts.isEmpty ? L10n.tr("未知") : parts.joined(separator: " / ")
    }

    var availabilityText: String {
        if let allowed {
            return allowed ? L10n.tr("可用") : L10n.tr("不可用")
        }
        return L10n.tr("未知")
    }

    var limitStatusText: String {
        switch limitReached {
        case .some(true):
            return L10n.tr("已触达")
        case .some(false):
            return L10n.tr("未触达")
        case .none:
            return L10n.tr("未知")
        }
    }
}

struct ManagedAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var platform: PlatformKind
    var accountIdentifier: String
    var displayName: String
    var email: String?
    var authKind: ManagedAuthKind
    var providerRule: ProviderRule
    var providerPresetID: String?
    var providerDisplayName: String?
    var providerBaseURL: String?
    var providerAPIKeyEnvName: String?
    var defaultModel: String?
    var defaultModelReasoningEffort: String?
    var defaultCLITarget: CLIEnvironmentTarget
    var createdAt: Date
    var lastUsedAt: Date?
    var lastQuotaSnapshotAt: Date?
    var lastRefreshAt: Date?
    var planType: String?
    var subscriptionDetails: SubscriptionDetails? = nil
    var lastStatusCheckAt: Date?
    var lastStatusMessage: String?
    var lastStatusLevel: SwitchLogLevel?
    var isActive: Bool

    init(
        id: UUID,
        platform: PlatformKind = .codex,
        accountIdentifier: String,
        displayName: String,
        email: String?,
        authKind: ManagedAuthKind,
        providerRule: ProviderRule? = nil,
        providerPresetID: String? = nil,
        providerDisplayName: String? = nil,
        providerBaseURL: String? = nil,
        providerAPIKeyEnvName: String? = nil,
        defaultModel: String? = nil,
        defaultModelReasoningEffort: String? = nil,
        defaultCLITarget: CLIEnvironmentTarget? = nil,
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
        self.id = id
        self.platform = platform
        self.accountIdentifier = accountIdentifier
        self.displayName = displayName
        self.email = email
        self.authKind = authKind
        self.providerRule = providerRule ?? Self.legacyProviderRule(for: authKind)
        self.providerPresetID = providerPresetID
        self.providerDisplayName = providerDisplayName
        self.providerBaseURL = providerBaseURL
        self.providerAPIKeyEnvName = providerAPIKeyEnvName
        self.defaultModel = defaultModel
        self.defaultModelReasoningEffort = defaultModelReasoningEffort
        self.defaultCLITarget = defaultCLITarget ?? (providerRule ?? Self.legacyProviderRule(for: authKind)).defaultTarget
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastQuotaSnapshotAt = lastQuotaSnapshotAt
        self.lastRefreshAt = lastRefreshAt
        self.planType = planType
        self.subscriptionDetails = subscriptionDetails
        self.lastStatusCheckAt = lastStatusCheckAt
        self.lastStatusMessage = lastStatusMessage
        self.lastStatusLevel = lastStatusLevel
        self.isActive = isActive
    }
}

extension ManagedAccount {
    var accountListBadgeTitle: String {
        if providerRule == .githubCopilot {
            return "GitHub Copilot"
        }
        if (providerRule == .openAICompatible || providerRule == .claudeCompatible),
           let preset = ProviderCatalog.preset(id: providerPresetID),
           !preset.isCustom {
            return preset.displayName
        }
        return platform.displayName
    }

    var resolvedProviderDisplayName: String {
        ProviderCatalog.providerDisplayName(
            presetID: providerPresetID,
            fallbackDisplayName: providerDisplayName,
            fallbackRule: providerRule
        )
    }

    var resolvedProviderBaseURL: String {
        let trimmed = providerBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return ProviderCatalog.preset(id: providerPresetID)?.baseURL ?? ""
    }

    var resolvedProviderAPIKeyEnvName: String {
        let trimmed = providerAPIKeyEnvName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return ProviderCatalog.preset(id: providerPresetID)?.apiKeyEnvName ?? ""
    }

    var resolvedDefaultModel: String {
        let trimmed = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return ProviderCatalog.preset(id: providerPresetID)?.defaultModel ?? ""
    }

    var resolvedDefaultModelReasoningEffort: String {
        let trimmed = defaultModelReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "medium" : trimmed
    }

    var allowedCLITargets: [CLIEnvironmentTarget] {
        switch providerRule {
        case .chatgptOAuth, .openAICompatible, .claudeCompatible, .githubCopilot:
            return [.codex, .claude]
        case .claudeProfile:
            return [.claude]
        }
    }

    var supportsCodexCLI: Bool {
        allowedCLITargets.contains(.codex)
    }

    var supportsClaudeCLI: Bool {
        allowedCLITargets.contains(.claude)
    }

    var supportsResponsesAPI: Bool {
        if providerRule == .githubCopilot {
            return true
        }
        return ProviderCatalog.supportsResponsesAPI(
            presetID: providerPresetID,
            baseURL: resolvedProviderBaseURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case accountIdentifier
        case displayName
        case email
        case authKind
        case providerRule
        case providerPresetID
        case providerDisplayName
        case providerBaseURL
        case providerAPIKeyEnvName
        case defaultModel
        case defaultModelReasoningEffort
        case defaultCLITarget
        case createdAt
        case lastUsedAt
        case lastQuotaSnapshotAt
        case lastRefreshAt
        case planType
        case subscriptionDetails
        case lastStatusCheckAt
        case lastStatusMessage
        case lastStatusLevel
        case isActive
        case codexAccountID
        case authMode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.platform = try container.decodeIfPresent(PlatformKind.self, forKey: .platform) ?? .codex
        self.accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
            ?? container.decode(String.self, forKey: .codexAccountID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.authKind = try container.decodeIfPresent(ManagedAuthKind.self, forKey: .authKind)
            ?? container.decode(ManagedAuthKind.self, forKey: .authMode)
        self.providerRule = try container.decodeIfPresent(ProviderRule.self, forKey: .providerRule)
            ?? Self.legacyProviderRule(for: authKind)
        self.providerPresetID = try container.decodeIfPresent(String.self, forKey: .providerPresetID)
        self.providerDisplayName = try container.decodeIfPresent(String.self, forKey: .providerDisplayName)
        self.providerBaseURL = try container.decodeIfPresent(String.self, forKey: .providerBaseURL)
        self.providerAPIKeyEnvName = try container.decodeIfPresent(String.self, forKey: .providerAPIKeyEnvName)
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        self.defaultModelReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultModelReasoningEffort)
        self.defaultCLITarget = try container.decodeIfPresent(CLIEnvironmentTarget.self, forKey: .defaultCLITarget)
            ?? providerRule.defaultTarget
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.lastQuotaSnapshotAt = try container.decodeIfPresent(Date.self, forKey: .lastQuotaSnapshotAt)
        self.lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.subscriptionDetails = try container.decodeIfPresent(SubscriptionDetails.self, forKey: .subscriptionDetails)
        self.lastStatusCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastStatusCheckAt)
        self.lastStatusMessage = try container.decodeIfPresent(String.self, forKey: .lastStatusMessage)
        self.lastStatusLevel = try container.decodeIfPresent(SwitchLogLevel.self, forKey: .lastStatusLevel)
        self.isActive = try container.decode(Bool.self, forKey: .isActive)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(accountIdentifier, forKey: .accountIdentifier)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encode(authKind, forKey: .authKind)
        try container.encode(providerRule, forKey: .providerRule)
        try container.encodeIfPresent(providerPresetID, forKey: .providerPresetID)
        try container.encodeIfPresent(providerDisplayName, forKey: .providerDisplayName)
        try container.encodeIfPresent(providerBaseURL, forKey: .providerBaseURL)
        try container.encodeIfPresent(providerAPIKeyEnvName, forKey: .providerAPIKeyEnvName)
        try container.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try container.encodeIfPresent(defaultModelReasoningEffort, forKey: .defaultModelReasoningEffort)
        try container.encode(defaultCLITarget, forKey: .defaultCLITarget)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(lastQuotaSnapshotAt, forKey: .lastQuotaSnapshotAt)
        try container.encodeIfPresent(lastRefreshAt, forKey: .lastRefreshAt)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(subscriptionDetails, forKey: .subscriptionDetails)
        try container.encodeIfPresent(lastStatusCheckAt, forKey: .lastStatusCheckAt)
        try container.encodeIfPresent(lastStatusMessage, forKey: .lastStatusMessage)
        try container.encodeIfPresent(lastStatusLevel, forKey: .lastStatusLevel)
        try container.encode(isActive, forKey: .isActive)
    }

    private static func legacyProviderRule(for authKind: ManagedAuthKind) -> ProviderRule {
        switch authKind {
        case .chatgpt:
            return .chatgptOAuth
        case .claudeProfile:
            return .claudeProfile
        case .openAIAPIKey:
            return .openAICompatible
        case .anthropicAPIKey:
            return .claudeCompatible
        case .providerAPIKey:
            return .openAICompatible
        case .githubCopilot:
            return .githubCopilot
        }
    }
}

struct ClaudeRateLimitValueSnapshot: Codable, Hashable, Sendable {
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?
}

struct ClaudeRateLimitSnapshot: Codable, Hashable, Sendable {
    var requests: ClaudeRateLimitValueSnapshot
    var inputTokens: ClaudeRateLimitValueSnapshot
    var outputTokens: ClaudeRateLimitValueSnapshot
    var capturedAt: Date
    var source: QuotaSnapshotSource
}

enum SwitchLogLevel: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

struct SwitchLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: SwitchLogLevel
    var message: String
}

struct AppDatabase: Codable, Sendable {
    var version: Int
    var accounts: [ManagedAccount]
    var quotaSnapshots: [String: QuotaSnapshot]
    var claudeRateLimitSnapshots: [String: ClaudeRateLimitSnapshot]
    var copilotQuotaSnapshots: [String: CopilotQuotaSnapshot] = [:]
    var switchLogs: [SwitchLogEntry]
    var cliLaunchHistoryByAccountID: [String: [CLILaunchRecord]] = [:]
    var copilotSessionQueueItems: [CopilotSessionQueueItem] = []
    var copilotSessionSyncSettings = CopilotSessionSyncSettings()
    var activeAccountID: UUID?

    static let currentVersion = 10

    static let empty = AppDatabase(
        version: currentVersion,
        accounts: [],
        quotaSnapshots: [:],
        claudeRateLimitSnapshots: [:],
        copilotQuotaSnapshots: [:],
        switchLogs: [],
        cliLaunchHistoryByAccountID: [:],
        copilotSessionQueueItems: [],
        copilotSessionSyncSettings: CopilotSessionSyncSettings(),
        activeAccountID: nil
    )

    func account(id: UUID?) -> ManagedAccount? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    func snapshot(for accountID: UUID) -> QuotaSnapshot? {
        quotaSnapshots[accountID.uuidString]
    }

    func claudeRateLimitSnapshot(for accountID: UUID) -> ClaudeRateLimitSnapshot? {
        claudeRateLimitSnapshots[accountID.uuidString]
    }

    func copilotQuotaSnapshot(for accountID: UUID) -> CopilotQuotaSnapshot? {
        copilotQuotaSnapshots[accountID.uuidString]
    }

    func cliWorkingDirectories(for accountID: UUID) -> [String] {
        cliLaunchHistory(for: accountID).map(\.path)
    }

    func cliLaunchHistory(for accountID: UUID) -> [CLILaunchRecord] {
        cliLaunchHistoryByAccountID[accountID.uuidString] ?? []
    }

    func defaultCLITarget(for account: ManagedAccount) -> CLIEnvironmentTarget {
        if account.allowedCLITargets.contains(account.defaultCLITarget) {
            return account.defaultCLITarget
        }
        return account.allowedCLITargets.first ?? .codex
    }

    mutating func setActiveAccount(_ id: UUID?) {
        activeAccountID = id
        for index in accounts.indices {
            accounts[index].isActive = accounts[index].id == id
            if accounts[index].isActive {
                accounts[index].lastUsedAt = Date()
            }
        }
    }

    mutating func upsert(account: ManagedAccount) {
        if let index = accounts.firstIndex(where: {
            $0.id == account.id || ($0.platform == account.platform && $0.accountIdentifier == account.accountIdentifier)
        }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        normalizeCLIEnvironmentState()
    }

    mutating func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        quotaSnapshots.removeValue(forKey: id.uuidString)
        claudeRateLimitSnapshots.removeValue(forKey: id.uuidString)
        copilotQuotaSnapshots.removeValue(forKey: id.uuidString)
        cliLaunchHistoryByAccountID.removeValue(forKey: id.uuidString)
        if activeAccountID == id {
            activeAccountID = nil
        }
    }

    mutating func updateSnapshot(_ snapshot: QuotaSnapshot, for accountID: UUID) {
        quotaSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastQuotaSnapshotAt = snapshot.capturedAt
    }

    mutating func updateClaudeRateLimitSnapshot(_ snapshot: ClaudeRateLimitSnapshot, for accountID: UUID) {
        claudeRateLimitSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastRefreshAt = snapshot.capturedAt
    }

    mutating func updateCopilotQuotaSnapshot(_ snapshot: CopilotQuotaSnapshot, for accountID: UUID) {
        copilotQuotaSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastQuotaSnapshotAt = snapshot.capturedAt
        accounts[index].lastRefreshAt = snapshot.capturedAt
    }

    mutating func appendLog(level: SwitchLogLevel, message: String) {
        switchLogs.insert(
            SwitchLogEntry(id: UUID(), timestamp: Date(), level: level, message: message),
            at: 0
        )
        if switchLogs.count > 200 {
            switchLogs = Array(switchLogs.prefix(200))
        }
    }

    mutating func setDefaultCLITarget(_ target: CLIEnvironmentTarget, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }
        if accounts[index].allowedCLITargets.contains(target) {
            accounts[index].defaultCLITarget = target
        }
    }

    mutating func rememberCLILaunch(
        _ directoryURL: URL,
        target: CLIEnvironmentTarget,
        for accountID: UUID
    ) {
        let normalizedPath = directoryURL.standardizedFileURL.path
        let key = accountID.uuidString
        var history = cliLaunchHistoryByAccountID[key] ?? []
        history.removeAll(where: { $0.path == normalizedPath && $0.target == target })
        history.insert(
            CLILaunchRecord(
                path: normalizedPath,
                target: target,
                lastUsedAt: Date()
            ),
            at: 0
        )
        if history.count > 8 {
            history = Array(history.prefix(8))
        }
        cliLaunchHistoryByAccountID[key] = history
    }

    mutating func removeCLILaunchRecord(id: UUID, for accountID: UUID) {
        let key = accountID.uuidString
        guard var history = cliLaunchHistoryByAccountID[key] else {
            return
        }
        history.removeAll(where: { $0.id == id })
        if history.isEmpty {
            cliLaunchHistoryByAccountID.removeValue(forKey: key)
        } else {
            cliLaunchHistoryByAccountID[key] = history
        }
    }

    @discardableResult
    mutating func upsertCopilotSessionQueueItem(_ item: CopilotSessionQueueItem) -> CopilotSessionQueueItem? {
        if let index = copilotSessionQueueItems.firstIndex(where: { $0.matchesImportIdentity(of: item) }) {
            let replacedItem = copilotSessionQueueItems[index]
            copilotSessionQueueItems[index] = item
            rememberCopilotSessionMonitorWorkspace(item.workspacePath)
            return replacedItem
        } else {
            copilotSessionQueueItems.insert(item, at: 0)
            rememberCopilotSessionMonitorWorkspace(item.workspacePath)
            return nil
        }
    }

    mutating func removeCopilotSessionQueueItem(id: UUID) {
        copilotSessionQueueItems.removeAll(where: { $0.id == id })
    }

    mutating func archiveCopilotSessionQueueItem(id: UUID) {
        guard let index = copilotSessionQueueItems.firstIndex(where: { $0.id == id }) else { return }
        copilotSessionQueueItems[index].status = .archived
    }

    mutating func markCopilotSessionQueueItemSent(id: UUID, target: CopilotSessionQueueExecutionTarget) {
        guard let index = copilotSessionQueueItems.firstIndex(where: { $0.id == id }) else { return }
        copilotSessionQueueItems[index].status = .sent
        copilotSessionQueueItems[index].lastSentAt = Date()
        copilotSessionQueueItems[index].lastExecutionTarget = target
    }

    mutating func markCopilotSessionQueueItemMaterialized(
        id: UUID,
        accountID: UUID,
        codexHomeURL: URL?,
        threadID: String,
        threadPath: String?
    ) {
        guard let index = copilotSessionQueueItems.firstIndex(where: { $0.id == id }) else { return }
        copilotSessionQueueItems[index].status = .sent
        copilotSessionQueueItems[index].codexThreadID = threadID
        copilotSessionQueueItems[index].codexThreadPath = threadPath
        copilotSessionQueueItems[index].codexThreadAccountID = accountID
        copilotSessionQueueItems[index].codexThreadCodexHomePath = codexHomeURL?.path
        copilotSessionQueueItems[index].materializedAt = Date()
        copilotSessionQueueItems[index].lastSentAt = Date()
        copilotSessionQueueItems[index].lastExecutionTarget = .desktop
    }

    mutating func setCopilotSessionAutoMonitorEnabled(_ isEnabled: Bool) {
        copilotSessionSyncSettings.isAutoMonitorEnabled = isEnabled
    }

    mutating func rememberCopilotSessionMonitorWorkspace(_ workspacePath: String) {
        let normalizedPath = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL.path
        guard !normalizedPath.isEmpty else { return }
        var paths = copilotSessionSyncSettings.monitoredWorkspacePaths
        paths.removeAll(where: { $0 == normalizedPath })
        paths.insert(normalizedPath, at: 0)
        copilotSessionSyncSettings.monitoredWorkspacePaths = paths
    }

    mutating func moveAccount(id accountID: UUID, to destinationAccountID: UUID) {
        guard
            let sourceIndex = accounts.firstIndex(where: { $0.id == accountID }),
            let destinationIndex = accounts.firstIndex(where: { $0.id == destinationAccountID }),
            sourceIndex != destinationIndex
        else {
            return
        }

        let destinationOffset = sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
        let account = accounts.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationOffset ? destinationOffset - 1 : destinationOffset
        let insertionIndex = min(max(adjustedDestination, 0), accounts.count)
        accounts.insert(account, at: insertionIndex)
    }

    mutating func normalizeCLIEnvironmentState() {
        for account in accounts {
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
                continue
            }
            if !accounts[index].allowedCLITargets.contains(accounts[index].defaultCLITarget) {
                accounts[index].defaultCLITarget = accounts[index].allowedCLITargets.first ?? .codex
            }
        }
    }
}

extension AppDatabase {
    private enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case quotaSnapshots
        case claudeRateLimitSnapshots
        case copilotQuotaSnapshots
        case switchLogs
        case cliLaunchHistoryByAccountID
        case copilotSessionQueueItems
        case copilotSessionSyncSettings
        case cliWorkingDirectoriesByAccountID
        case activeAccountID
        case cliEnvironmentProfiles
        case defaultCLIEnvironmentIDByAccountID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let accounts = try container.decodeIfPresent([ManagedAccount].self, forKey: .accounts) ?? []
        let quotaSnapshots = try container.decodeIfPresent([String: QuotaSnapshot].self, forKey: .quotaSnapshots) ?? [:]
        let claudeRateLimitSnapshots = try container.decodeIfPresent([String: ClaudeRateLimitSnapshot].self, forKey: .claudeRateLimitSnapshots) ?? [:]
        let copilotQuotaSnapshots = try container.decodeIfPresent([String: CopilotQuotaSnapshot].self, forKey: .copilotQuotaSnapshots) ?? [:]
        let switchLogs = try container.decodeIfPresent([SwitchLogEntry].self, forKey: .switchLogs) ?? []
        let cliEnvironmentProfiles = try container.decodeIfPresent([CLIEnvironmentProfile].self, forKey: .cliEnvironmentProfiles)
            ?? CLIEnvironmentProfile.builtInProfiles
        let defaultCLIEnvironmentIDByAccountID = try container.decodeIfPresent([String: String].self, forKey: .defaultCLIEnvironmentIDByAccountID) ?? [:]
        let cliLaunchHistoryByAccountID = try container.decodeIfPresent([String: [CLILaunchRecord]].self, forKey: .cliLaunchHistoryByAccountID) ?? [:]
        let copilotSessionQueueItems = try container.decodeIfPresent([CopilotSessionQueueItem].self, forKey: .copilotSessionQueueItems) ?? []
        let copilotSessionSyncSettings = try container.decodeIfPresent(CopilotSessionSyncSettings.self, forKey: .copilotSessionSyncSettings) ?? CopilotSessionSyncSettings()
        let legacyCLIDirectories = try container.decodeIfPresent([String: [String]].self, forKey: .cliWorkingDirectoriesByAccountID) ?? [:]
        let activeAccountID = try container.decodeIfPresent(UUID.self, forKey: .activeAccountID)

        let migratedAccounts = accounts.map { account -> ManagedAccount in
            var migrated = account
            if migrated.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                switch migrated.authKind {
                case .openAIAPIKey:
                    migrated.defaultModel = "gpt-5.4"
                case .anthropicAPIKey:
                    migrated.defaultModel = "claude-sonnet-4.5"
                default:
                    break
                }
            }
            if migrated.authKind == .openAIAPIKey {
                migrated.authKind = .providerAPIKey
                migrated.providerRule = .openAICompatible
                migrated.providerPresetID = migrated.providerPresetID ?? "openai"
                migrated.providerDisplayName = migrated.providerDisplayName ?? "OpenAI"
                migrated.providerBaseURL = migrated.providerBaseURL ?? "https://api.openai.com/v1"
                migrated.providerAPIKeyEnvName = migrated.providerAPIKeyEnvName ?? "OPENAI_API_KEY"
            } else if migrated.authKind == .anthropicAPIKey {
                migrated.authKind = .providerAPIKey
                migrated.providerRule = .claudeCompatible
                migrated.providerPresetID = migrated.providerPresetID ?? "anthropic"
                migrated.providerDisplayName = migrated.providerDisplayName ?? "Anthropic"
                migrated.providerBaseURL = migrated.providerBaseURL ?? "https://api.anthropic.com/v1"
                migrated.providerAPIKeyEnvName = migrated.providerAPIKeyEnvName ?? "ANTHROPIC_API_KEY"
            }

            if let environmentID = defaultCLIEnvironmentIDByAccountID[migrated.id.uuidString],
               let profile = cliEnvironmentProfiles.first(where: { $0.id == environmentID }),
               migrated.allowedCLITargets.contains(profile.target)
            {
                migrated.defaultCLITarget = profile.target
            } else if !migrated.allowedCLITargets.contains(migrated.defaultCLITarget) {
                migrated.defaultCLITarget = migrated.allowedCLITargets.first ?? migrated.defaultCLITarget
            }
            return migrated
        }

        var database = AppDatabase(
            version: max(version, Self.currentVersion),
            accounts: migratedAccounts,
            quotaSnapshots: quotaSnapshots,
            claudeRateLimitSnapshots: claudeRateLimitSnapshots,
            copilotQuotaSnapshots: copilotQuotaSnapshots,
            switchLogs: switchLogs,
            cliLaunchHistoryByAccountID: cliLaunchHistoryByAccountID,
            copilotSessionQueueItems: copilotSessionQueueItems,
            copilotSessionSyncSettings: copilotSessionSyncSettings,
            activeAccountID: activeAccountID
        )

        if database.cliLaunchHistoryByAccountID.isEmpty, !legacyCLIDirectories.isEmpty {
            for account in database.accounts {
                let key = account.id.uuidString
                let legacyRecords = (legacyCLIDirectories[key] ?? []).map {
                    CLILaunchRecord(
                        path: $0,
                        target: database.defaultCLITarget(for: account)
                    )
                }
                if !legacyRecords.isEmpty {
                    database.cliLaunchHistoryByAccountID[key] = legacyRecords
                }
            }
        }

        database.normalizeCLIEnvironmentState()
        self = database
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(quotaSnapshots, forKey: .quotaSnapshots)
        try container.encode(claudeRateLimitSnapshots, forKey: .claudeRateLimitSnapshots)
        try container.encode(copilotQuotaSnapshots, forKey: .copilotQuotaSnapshots)
        try container.encode(switchLogs, forKey: .switchLogs)
        try container.encode(cliLaunchHistoryByAccountID, forKey: .cliLaunchHistoryByAccountID)
        try container.encode(copilotSessionQueueItems, forKey: .copilotSessionQueueItems)
        try container.encode(copilotSessionSyncSettings, forKey: .copilotSessionSyncSettings)
        try container.encodeIfPresent(activeAccountID, forKey: .activeAccountID)
    }
}
