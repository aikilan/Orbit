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
    var codexAccountID: String
    var displayName: String
    var email: String?
    var authMode: CodexAuthMode
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
    var switchLogs: [SwitchLogEntry]
    var cliWorkingDirectoriesByAccountID: [String: [String]] = [:]
    var activeAccountID: UUID?

    static let currentVersion = 2

    static let empty = AppDatabase(
        version: currentVersion,
        accounts: [],
        quotaSnapshots: [:],
        switchLogs: [],
        cliWorkingDirectoriesByAccountID: [:],
        activeAccountID: nil
    )

    func account(id: UUID?) -> ManagedAccount? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    func snapshot(for accountID: UUID) -> QuotaSnapshot? {
        quotaSnapshots[accountID.uuidString]
    }

    func cliWorkingDirectories(for accountID: UUID) -> [String] {
        cliWorkingDirectoriesByAccountID[accountID.uuidString] ?? []
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
        if let index = accounts.firstIndex(where: { $0.id == account.id || $0.codexAccountID == account.codexAccountID }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    mutating func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        quotaSnapshots.removeValue(forKey: id.uuidString)
        cliWorkingDirectoriesByAccountID.removeValue(forKey: id.uuidString)
        if activeAccountID == id {
            activeAccountID = nil
        }
    }

    mutating func updateSnapshot(_ snapshot: QuotaSnapshot, for accountID: UUID) {
        quotaSnapshots[accountID.uuidString] = snapshot
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].lastQuotaSnapshotAt = snapshot.capturedAt
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

    mutating func rememberCLIWorkingDirectory(_ directoryURL: URL, for accountID: UUID) {
        let normalizedPath = directoryURL.standardizedFileURL.path
        let key = accountID.uuidString
        var directories = cliWorkingDirectoriesByAccountID[key] ?? []
        directories.removeAll(where: { $0 == normalizedPath })
        directories.insert(normalizedPath, at: 0)
        if directories.count > 8 {
            directories = Array(directories.prefix(8))
        }
        cliWorkingDirectoriesByAccountID[key] = directories
    }
}

extension AppDatabase {
    private enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case quotaSnapshots
        case switchLogs
        case cliWorkingDirectoriesByAccountID
        case activeAccountID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let accounts = try container.decodeIfPresent([ManagedAccount].self, forKey: .accounts) ?? []
        let quotaSnapshots = try container.decodeIfPresent([String: QuotaSnapshot].self, forKey: .quotaSnapshots) ?? [:]
        let switchLogs = try container.decodeIfPresent([SwitchLogEntry].self, forKey: .switchLogs) ?? []
        let cliWorkingDirectoriesByAccountID = try container.decodeIfPresent([String: [String]].self, forKey: .cliWorkingDirectoriesByAccountID) ?? [:]
        let activeAccountID = try container.decodeIfPresent(UUID.self, forKey: .activeAccountID)

        self.init(
            version: version,
            accounts: accounts,
            quotaSnapshots: quotaSnapshots,
            switchLogs: switchLogs,
            cliWorkingDirectoriesByAccountID: cliWorkingDirectoriesByAccountID,
            activeAccountID: activeAccountID
        )
    }
}
