import Foundation

struct RateLimitWindowSnapshot: Codable, Hashable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

extension RateLimitWindowSnapshot {
    var normalizedUsedPercent: Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(usedPercent, 0), 100)
    }

    var remainingPercent: Double {
        100 - normalizedUsedPercent
    }

    var remainingPercentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }
}

struct CreditsSnapshot: Codable, Hashable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: Double?
}

enum QuotaSnapshotSource: String, Codable, Hashable, Sendable {
    case sessionTokenCount
    case appServerSignal
    case importedBootstrap
    case onlineUsageRefresh
}

extension QuotaSnapshotSource {
    var displayName: String {
        switch self {
        case .sessionTokenCount:
            return L10n.tr("本地会话事件")
        case .appServerSignal:
            return L10n.tr("运行态信号")
        case .importedBootstrap:
            return L10n.tr("本地历史快照")
        case .onlineUsageRefresh:
            return L10n.tr("在线刷新")
        }
    }
}

struct QuotaSnapshot: Codable, Hashable, Sendable {
    var primary: RateLimitWindowSnapshot
    var secondary: RateLimitWindowSnapshot
    var credits: CreditsSnapshot?
    var planType: String?
    var capturedAt: Date
    var source: QuotaSnapshotSource
}

extension QuotaSnapshot {
    var remainingSummary: String {
        L10n.tr("5h %@ / 7d %@", primary.remainingPercentText, secondary.remainingPercentText)
    }
}
