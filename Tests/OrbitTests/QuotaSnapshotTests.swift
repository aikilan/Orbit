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

        XCTAssertEqual(countdown.text, "2d-03h-04m")
        XCTAssertEqual(countdown.tone, .normal)
    }

    func testResetCountdownWarnsWithinOneDay() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval((6 * 60 + 15) * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, "0d-06h-15m")
        XCTAssertEqual(countdown.tone, .warning)
    }

    func testResetCountdownDangersWithinFiveHours() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(
            until: now.addingTimeInterval((4 * 60 + 59) * 60),
            now: now
        )

        XCTAssertEqual(countdown.text, "0d-04h-59m")
        XCTAssertEqual(countdown.tone, .danger)
    }

    func testResetCountdownClampsExpiredResetTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let countdown = QuotaResetCountdown(until: now.addingTimeInterval(-60), now: now)

        XCTAssertEqual(countdown.text, "0d-00h-00m")
        XCTAssertEqual(countdown.tone, .danger)
    }

    func testWindowWithoutResetTimeHasNoCountdown() {
        let window = RateLimitWindowSnapshot(usedPercent: 20, windowMinutes: 300, resetsAt: nil)

        XCTAssertNil(window.resetCountdown(now: Date(timeIntervalSince1970: 1_000)))
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

        XCTAssertEqual(countdowns.fiveHour?.text, "0d-04h-30m")
        XCTAssertEqual(countdowns.fiveHour?.tone, .danger)
        XCTAssertEqual(countdowns.weekly?.text, "6d-22h-10m")
        XCTAssertEqual(countdowns.weekly?.tone, .normal)
    }
}
