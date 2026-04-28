import Foundation

struct RateLimitWindowSnapshot: Codable, Hashable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

enum QuotaResetCountdownTone: Equatable, Sendable {
    case normal
    case warning
    case danger
}

struct QuotaResetCountdown: Equatable, Sendable {
    let text: String
    let tone: QuotaResetCountdownTone

    init(
        until resetDate: Date,
        now: Date = Date(),
        warningThresholdMinutes: Int = 60,
        dangerThresholdMinutes: Int = 10
    ) {
        let remainingSeconds = max(0, Int(resetDate.timeIntervalSince(now).rounded(.down)))
        let totalMinutes = remainingSeconds / 60
        let days = totalMinutes / 1_440
        let hours = totalMinutes / 60
        let minutes = totalMinutes

        // 输出只保留当前量级，避免列表里倒计时信息过长影响账号扫描效率。
        if days >= 1 {
            text = "\(days)d"
        } else if hours >= 1 {
            text = "\(hours)h"
        } else {
            text = "\(minutes)m"
        }

        if remainingSeconds == 0 || totalMinutes < dangerThresholdMinutes {
            tone = .danger
        } else if totalMinutes < warningThresholdMinutes {
            tone = .warning
        } else {
            tone = .normal
        }
    }
}

struct CodexQuotaResetCountdowns: Equatable, Sendable {
    let fiveHour: QuotaResetCountdown?
    let weekly: QuotaResetCountdown?

    var isEmpty: Bool {
        fiveHour == nil && weekly == nil
    }
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

    func resetCountdown(now: Date = Date()) -> QuotaResetCountdown? {
        guard let resetsAt else { return nil }
        let isWeeklyWindow = windowMinutes >= 1_440
        return QuotaResetCountdown(
            until: resetsAt,
            now: now,
            warningThresholdMinutes: isWeeklyWindow ? 1_440 : 60,
            dangerThresholdMinutes: isWeeklyWindow ? 300 : 10
        )
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
    var secondary: RateLimitWindowSnapshot?
    var credits: CreditsSnapshot?
    var planType: String?
    var capturedAt: Date
    var source: QuotaSnapshotSource
}

extension QuotaSnapshot {
    var fiveHourWindow: RateLimitWindowSnapshot? {
        closestWindow(targetMinutes: 300) { $0.windowMinutes < 1440 }
    }

    var weeklyWindow: RateLimitWindowSnapshot? {
        closestWindow(targetMinutes: 10080) { $0.windowMinutes >= 1440 }
    }

    var remainingSummary: String {
        if let fiveHourWindow, let weeklyWindow {
            return L10n.tr("5h %@ / 7d %@", fiveHourWindow.remainingPercentText, weeklyWindow.remainingPercentText)
        }
        if let fiveHourWindow {
            return L10n.tr("5h %@", fiveHourWindow.remainingPercentText)
        }
        if let weeklyWindow {
            return L10n.tr("7d %@", weeklyWindow.remainingPercentText)
        }
        return primary.remainingPercentText
    }

    func resetCountdowns(now: Date = Date()) -> CodexQuotaResetCountdowns {
        CodexQuotaResetCountdowns(
            fiveHour: fiveHourWindow?.resetCountdown(now: now),
            weekly: weeklyWindow?.resetCountdown(now: now)
        )
    }

    private func closestWindow(
        targetMinutes: Int,
        where predicate: (RateLimitWindowSnapshot) -> Bool
    ) -> RateLimitWindowSnapshot? {
        let windows = [primary, secondary].compactMap { $0 }.filter(predicate)
        guard let firstWindow = windows.first else { return nil }

        return windows.dropFirst().reduce(firstWindow) { currentBest, candidate in
            let currentDistance = abs(currentBest.windowMinutes - targetMinutes)
            let candidateDistance = abs(candidate.windowMinutes - targetMinutes)

            if candidateDistance < currentDistance {
                return candidate
            }
            if candidateDistance > currentDistance {
                return currentBest
            }
            return candidate.windowMinutes > currentBest.windowMinutes ? candidate : currentBest
        }
    }
}
