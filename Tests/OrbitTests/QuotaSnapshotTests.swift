import Foundation
import XCTest
@testable import Orbit

final class QuotaSnapshotTests: XCTestCase {
    func testResetCountdownFormatsMultiDayRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval((2 * 24 * 60 + 3 * 60 + 4) * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, ">=2d")
        XCTAssertEqual(countdown.tone, .normal)
    }

    func testResetCountdownFormatsHourlyRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval((6 * 60 + 15) * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, ">=6h")
        XCTAssertEqual(countdown.tone, .normal)
    }

    func testResetCountdownKeepsExactHourlyRemainingTimeUnprefixed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval(6 * 60 * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, "6h")
        XCTAssertEqual(countdown.tone, .normal)
    }

    func testResetCountdownWarnsWithinOneHour() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval(45 * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, "45m")
        XCTAssertEqual(countdown.tone, .warning)
    }

    func testResetCountdownDangersWithinTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval(9 * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, "9m")
        XCTAssertEqual(countdown.tone, .danger)
    }

    func testResetCountdownClampsExpiredResetTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(until: now.addingTimeInterval(-60), now: now)

        XCTAssertEqual(countdown.text, "0m")
        XCTAssertEqual(countdown.tone, .danger)
    }

    func testWindowWithoutResetTimeHasNoCountdown() {
        let window = RateLimitWindowSnapshot(usedPercent: 20, windowMinutes: 300, resetsAt: nil)

        XCTAssertNil(window.resetCountdown(now: Date(timeIntervalSince1970: 1_000)))
    }

    func testWeeklyWindowKeepsDailyWarningTone() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = RateLimitWindowSnapshot(
            usedPercent: 20,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(12 * 60 * 60)
        )

        let countdown = window.resetCountdown(now: now)

        XCTAssertEqual(countdown?.text, "12h")
        XCTAssertEqual(countdown?.tone, .warning)
    }

    func testQuotaSnapshotProvidesSeparateFiveHourAndWeeklyCountdowns() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = QuotaSnapshot(
            primary: RateLimitWindowSnapshot(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval((4 * 60 + 30) * 60)
            ),
            secondary: RateLimitWindowSnapshot(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval((6 * 24 * 60 + 22 * 60 + 10) * 60)
            ),
            credits: nil,
            planType: "plus",
            capturedAt: now,
            source: .onlineUsageRefresh
        )

        let countdowns = snapshot.resetCountdowns(now: now)

        XCTAssertEqual(countdowns.fiveHour?.text, ">=4h")
        XCTAssertEqual(countdowns.fiveHour?.tone, .normal)
        XCTAssertEqual(countdowns.weekly?.text, ">=6d")
        XCTAssertEqual(countdowns.weekly?.tone, .normal)
    }
}
