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

    func testStandaloneProviderIsLocalizedButMixedTermsStayUnchanged() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)
        XCTAssertEqual(L10n.tr("供应商"), "Provider")
        XCTAssertEqual(L10n.tr("编辑供应商"), "Edit Provider")

        L10n.setLanguagePreference(.simplifiedChinese)
        XCTAssertEqual(L10n.tr("供应商"), "供应商")
        XCTAssertEqual(L10n.tr("Provider API Key"), "Provider API Key")
    }

    func testAddAccountSheetStringsAreLocalizedInEnglish() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)
        XCTAssertEqual(L10n.tr("接入方式"), "Setup Method")
        XCTAssertEqual(L10n.tr("ChatGPT 浏览器登录"), "ChatGPT Browser Sign-in")
        XCTAssertEqual(L10n.tr("规则"), "Rule")
        XCTAssertEqual(L10n.tr("默认模型"), "Default Model")
        XCTAssertEqual(L10n.tr("API Key 环境变量"), "API Key Environment Variable")
        XCTAssertEqual(L10n.tr("选择账号接入方式。"), "Choose how to add the account.")
        XCTAssertEqual(
            L10n.tr("通过浏览器登录 ChatGPT 账号，后续可以直接打开 Codex CLI 或 Claude Code。"),
            "Sign in with a ChatGPT account in the browser. You can then open Codex CLI or Claude Code directly."
        )
    }

    func testResourceBundleResolvesFromPackagedAppResourcesDirectory() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = rootURL.appendingPathComponent("LLMAccountSwitcher.app", isDirectory: true)
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
            "CFBundleExecutable": "LLMAccountSwitcher",
            "CFBundleIdentifier": "com.openai.LLMAccountSwitcher.tests",
            "CFBundleName": "LLM Account Switcher",
            "CFBundlePackageType": "APPL",
        ]
        XCTAssertTrue(appInfo.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))

        let resourceInfo: NSDictionary = [
            "CFBundleIdentifier": "com.openai.CodexAccountSwitcher.resources",
            "CFBundleName": "CodexAccountSwitcherResources",
            "CFBundlePackageType": "BNDL",
        ]
        XCTAssertTrue(resourceInfo.write(to: resourceBundleURL.appendingPathComponent("Info.plist"), atomically: true))

        fileManager.createFile(atPath: macOSURL.appendingPathComponent("LLMAccountSwitcher").path, contents: Data())

        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        XCTAssertEqual(L10n.resourceBundle(mainBundle: appBundle)?.bundleURL, resourceBundleURL)
    }
}
