import Foundation
import XCTest
@testable import Orbit

final class AppSessionLoggerTests: XCTestCase {
    func testFirstLaunchCreatesLatestLog() throws {
        let appSupportDirectoryURL = try makeAppSupportDirectory()
        let logger = try AppSessionLogger(appSupportDirectoryURL: appSupportDirectoryURL)
        defer { logger.close() }

        logger.info("startup.begin")

        XCTAssertTrue(FileManager.default.fileExists(atPath: logger.latestLogURL.path))
        let log = try String(contentsOf: logger.latestLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("startup.begin"))
    }

    func testSecondLaunchArchivesPreviousLatestLog() throws {
        let appSupportDirectoryURL = try makeAppSupportDirectory()

        let firstLogger = try AppSessionLogger(appSupportDirectoryURL: appSupportDirectoryURL)
        firstLogger.info("startup.first")
        firstLogger.close()

        let secondLogger = try AppSessionLogger(appSupportDirectoryURL: appSupportDirectoryURL)
        defer { secondLogger.close() }
        secondLogger.info("startup.second")

        let archivedLogs = try archivedLogs(in: secondLogger.logsDirectoryURL)
        XCTAssertEqual(archivedLogs.count, 1)

        let latestLog = try String(contentsOf: secondLogger.latestLogURL, encoding: .utf8)
        let archivedLog = try String(contentsOf: archivedLogs[0], encoding: .utf8)
        XCTAssertTrue(latestLog.contains("startup.second"))
        XCTAssertFalse(latestLog.contains("startup.first"))
        XCTAssertTrue(archivedLog.contains("startup.first"))
    }

    func testLaunchArchiveKeepsOnlyLatestTenFiles() throws {
        let fileManager = FileManager.default
        let appSupportDirectoryURL = try makeAppSupportDirectory()
        let logsDirectoryURL = appSupportDirectoryURL.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

        for index in 0..<12 {
            let fileName = String(format: "launch-20240101-0000%02d-1.log", index)
            let url = logsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            fileManager.createFile(atPath: url.path, contents: Data("log-\(index)".utf8))
        }

        let logger = try AppSessionLogger(appSupportDirectoryURL: appSupportDirectoryURL)
        defer { logger.close() }

        let archivedLogs = try archivedLogs(in: logger.logsDirectoryURL)
        XCTAssertEqual(archivedLogs.count, 10)
        XCTAssertFalse(archivedLogs.map(\.lastPathComponent).contains("launch-20240101-000000-1.log"))
        XCTAssertFalse(archivedLogs.map(\.lastPathComponent).contains("launch-20240101-000001-1.log"))
    }

    func testLogSanitizesHomePathAndRedactsSensitiveMetadata() throws {
        let appSupportDirectoryURL = try makeAppSupportDirectory()
        let logger = try AppSessionLogger(appSupportDirectoryURL: appSupportDirectoryURL)
        defer { logger.close() }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        logger.info(
            "startup.paths",
            metadata: [
                "config_path": homePath + "/Library/Application Support/Orbit",
                "api_key": "secret-api-key",
                "refresh_token": "secret-refresh-token",
            ]
        )

        let log = try String(contentsOf: logger.latestLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("config_path=\"~/Library/Application Support/Orbit\""))
        XCTAssertTrue(log.contains("api_key=<redacted>"))
        XCTAssertTrue(log.contains("refresh_token=<redacted>"))
        XCTAssertFalse(log.contains("secret-api-key"))
        XCTAssertFalse(log.contains("secret-refresh-token"))
    }

    private func makeAppSupportDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appSupportDirectoryURL = root.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
        return appSupportDirectoryURL
    }

    private func archivedLogs(in directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
