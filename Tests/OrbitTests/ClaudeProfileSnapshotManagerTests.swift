import Foundation
import XCTest
@testable import Orbit

final class ClaudeProfileSnapshotManagerTests: XCTestCase {
    func testImportAndActivateProfileCopiesHomeAndSettings() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claudeHome = root.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = root.appendingPathComponent(".claude.json")
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)

        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try Data("original-home".utf8).write(to: claudeHome.appendingPathComponent("config.txt"))
        try Data("original-settings".utf8).write(to: settingsURL)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: root.appendingPathComponent(".codex", isDirectory: true),
            claudeHomeOverride: claudeHome,
            appSupportOverride: appSupport
        )
        let manager = ClaudeProfileSnapshotManager(paths: paths, fileManager: fileManager)

        let snapshotRef = try manager.importCurrentProfile()

        try Data("mutated-home".utf8).write(to: claudeHome.appendingPathComponent("config.txt"))
        try Data("mutated-settings".utf8).write(to: settingsURL)

        try manager.activateProfile(snapshotRef)

        let restoredHome = try String(contentsOf: claudeHome.appendingPathComponent("config.txt"))
        let restoredSettings = try String(contentsOf: settingsURL)
        XCTAssertEqual(restoredHome, "original-home")
        XCTAssertEqual(restoredSettings, "original-settings")
    }

    func testPrepareIsolatedAPIKeyRootCopiesCurrentProfile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claudeHome = root.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = root.appendingPathComponent(".claude.json")
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)

        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try Data("api-key-home".utf8).write(to: claudeHome.appendingPathComponent("config.txt"))
        try Data("api-key-settings".utf8).write(to: settingsURL)

        let paths = try AppPaths(
            fileManager: fileManager,
            codexHomeOverride: root.appendingPathComponent(".codex", isDirectory: true),
            claudeHomeOverride: claudeHome,
            appSupportOverride: appSupport
        )
        let manager = ClaudeProfileSnapshotManager(paths: paths, fileManager: fileManager)

        let isolatedRoot = try manager.prepareIsolatedAPIKeyRoot(for: UUID())

        let copiedHome = try String(contentsOf: isolatedRoot.appendingPathComponent(".claude/config.txt"))
        let copiedSettings = try String(contentsOf: isolatedRoot.appendingPathComponent(".claude.json"))
        XCTAssertEqual(copiedHome, "api-key-home")
        XCTAssertEqual(copiedSettings, "api-key-settings")
    }
}
