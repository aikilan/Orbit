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
}
