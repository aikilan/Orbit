import XCTest
@testable import CodexAccountSwitcher

final class L10nTests: XCTestCase {
    func testManualLanguagePreferenceOverridesLocalization() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)
        XCTAssertEqual(L10n.tr("新增账号"), "Add Account")

        L10n.setLanguagePreference(.simplifiedChinese)
        XCTAssertEqual(L10n.tr("新增账号"), "新增账号")
    }

    func testResourceBundleResolvesFromPackagedAppResourcesDirectory() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = rootURL.appendingPathComponent("CodexAccountSwitcher.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourceBundleURL = resourcesURL
            .appendingPathComponent("CodexAccountSwitcher_CodexAccountSwitcher.bundle", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourceBundleURL, withIntermediateDirectories: true)

        let appInfo: NSDictionary = [
            "CFBundleExecutable": "CodexAccountSwitcher",
            "CFBundleIdentifier": "com.openai.CodexAccountSwitcher.tests",
            "CFBundleName": "CodexAccountSwitcher",
            "CFBundlePackageType": "APPL",
        ]
        XCTAssertTrue(appInfo.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))

        let resourceInfo: NSDictionary = [
            "CFBundleIdentifier": "com.openai.CodexAccountSwitcher.resources",
            "CFBundleName": "CodexAccountSwitcherResources",
            "CFBundlePackageType": "BNDL",
        ]
        XCTAssertTrue(resourceInfo.write(to: resourceBundleURL.appendingPathComponent("Info.plist"), atomically: true))

        fileManager.createFile(atPath: macOSURL.appendingPathComponent("CodexAccountSwitcher").path, contents: Data())

        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        XCTAssertEqual(L10n.resourceBundle(mainBundle: appBundle)?.bundleURL, resourceBundleURL)
    }
}
