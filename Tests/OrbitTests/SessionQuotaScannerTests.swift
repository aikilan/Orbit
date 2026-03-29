import XCTest
@testable import Orbit

final class SessionQuotaScannerTests: XCTestCase {
    func testSeedOffsetsOnlyCapturesNewlyAppendedTokenCountEvents() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsDirectory = root.appendingPathComponent("sessions/2026/03/19", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let sessionFile = sessionsDirectory.appendingPathComponent("rollout.jsonl")
        try Data(makeEventLine(percent: 10).utf8).write(to: sessionFile)

        let scanner = SessionQuotaScanner(sessionsDirectoryURL: root.appendingPathComponent("sessions"), startedAt: .distantPast)
        scanner.seedOffsets()

        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(makeEventLine(percent: 42).utf8))
        try handle.close()

        let snapshots = scanner.pollNewSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(Int(snapshots[0].primary.usedPercent), 42)
    }

    func testLatestExistingSnapshotReturnsNewestSnapshot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsDirectory = root.appendingPathComponent("sessions/2026/03/19", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let sessionFile = sessionsDirectory.appendingPathComponent("rollout.jsonl")
        let contents = makeEventLine(percent: 20) + makeEventLine(percent: 67)
        try Data(contents.utf8).write(to: sessionFile)

        let scanner = SessionQuotaScanner(sessionsDirectoryURL: root.appendingPathComponent("sessions"))
        let snapshot = try XCTUnwrap(scanner.latestExistingSnapshot())

        XCTAssertEqual(Int(snapshot.primary.usedPercent), 67)
        XCTAssertEqual(snapshot.source, .importedBootstrap)
    }

    private func makeEventLine(percent: Int) -> String {
        """
        {"timestamp":"2026-03-19T10:00:00.000000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\(percent),"window_minutes":300,"resets_at":1773886336},"secondary":{"used_percent":55,"window_minutes":10080,"resets_at":1773889999},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"team"}}}
        \n
        """
    }
}
