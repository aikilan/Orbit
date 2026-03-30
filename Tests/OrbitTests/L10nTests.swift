import XCTest
@testable import Orbit

final class L10nTests: XCTestCase {
    func testEnglishTranslationExistsForClaudePatchedRuntimeHelpText() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)

        XCTAssertEqual(
            L10n.tr("打开 CLI 会启动应用生成的 Claude Code patched runtime，并自动桥接当前账号的 OpenAI 兼容凭据。"),
            "Launching the CLI uses the app-managed patched Claude Code runtime and automatically bridges the current account's OpenAI-compatible credentials."
        )
    }

    func testEnglishTranslationExistsForProviderCredentialStatusMessage() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)

        XCTAssertEqual(
            L10n.tr("Provider API Key 本地凭据可用。"),
            "Provider API Key local credential is available."
        )
    }

    func testSystemLanguagePreferenceUsesFirstSupportedLanguage() {
        XCTAssertEqual(
            L10n.resolvedSystemLanguagePreference(preferredLanguages: ["en-US", "zh-Hans"]),
            .english
        )
        XCTAssertEqual(
            L10n.resolvedSystemLanguagePreference(preferredLanguages: ["ja-JP", "zh-Hans", "en-US"]),
            .simplifiedChinese
        )
    }

    func testSystemLanguagePreferenceFallsBackToEnglishWhenNoSupportedLanguageExists() {
        XCTAssertEqual(
            L10n.resolvedSystemLanguagePreference(preferredLanguages: ["ja-JP", "fr-FR"]),
            .english
        )
    }

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

    func testCLILaunchCardStringsAreLocalizedInEnglish() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)
        XCTAssertEqual(L10n.tr("最近目录"), "Recent Directories")
        XCTAssertEqual(L10n.tr("选择目录并打开 %@", "Claude Code"), "Choose Directory and Open Claude Code")
        XCTAssertEqual(L10n.tr("先选择一个目录打开 %@，后续会在这里快速重开。", "Codex CLI"), "Choose a directory to open Codex CLI first. You can relaunch it here later.")
    }

    func testResourceBundleResolvesFromPackagedAppResourcesDirectory() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = rootURL.appendingPathComponent("Orbit.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourceBundleURL = resourcesURL
            .appendingPathComponent("Orbit_Orbit.bundle", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourceBundleURL, withIntermediateDirectories: true)

        let appInfo: NSDictionary = [
            "CFBundleExecutable": "Orbit",
            "CFBundleIdentifier": "com.openai.Orbit.tests",
            "CFBundleName": "Orbit",
            "CFBundlePackageType": "APPL",
        ]
        XCTAssertTrue(appInfo.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))

        let resourceInfo: NSDictionary = [
            "CFBundleIdentifier": "com.openai.Orbit.resources",
            "CFBundleName": "OrbitResources",
            "CFBundlePackageType": "BNDL",
        ]
        XCTAssertTrue(resourceInfo.write(to: resourceBundleURL.appendingPathComponent("Info.plist"), atomically: true))

        fileManager.createFile(atPath: macOSURL.appendingPathComponent("Orbit").path, contents: Data())

        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        XCTAssertEqual(L10n.resourceBundle(mainBundle: appBundle)?.bundleURL, resourceBundleURL)
    }
}
