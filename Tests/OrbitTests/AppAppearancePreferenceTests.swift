import AppKit
import SwiftUI
import XCTest
@testable import Orbit

final class AppAppearancePreferenceTests: XCTestCase {
    func testResolvedFallsBackToSystemForUnknownValue() {
        XCTAssertEqual(AppAppearancePreference.resolved(from: "unknown"), .system)
    }

    func testColorSchemeMappingMatchesPreference() {
        XCTAssertNil(AppAppearancePreference.system.colorScheme)
        XCTAssertEqual(AppAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppAppearancePreference.dark.colorScheme, .dark)
    }

    func testEnglishTitlesAreLocalized() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)

        XCTAssertEqual(AppAppearancePreference.system.title, "Follow System")
        XCTAssertEqual(AppAppearancePreference.light.title, "Light")
        XCTAssertEqual(AppAppearancePreference.dark.title, "Dark")
    }

    func testOrbitPaletteBackgroundResolvesForLightAndDarkAppearance() throws {
        let light = try rgbComponents(for: OrbitPalette.background, appearanceName: .aqua)
        let dark = try rgbComponents(for: OrbitPalette.background, appearanceName: .darkAqua)

        XCTAssertEqual(light.red, 0.972, accuracy: 0.001)
        XCTAssertEqual(light.green, 0.976, accuracy: 0.001)
        XCTAssertEqual(light.blue, 0.986, accuracy: 0.001)
        XCTAssertEqual(light.alpha, 1, accuracy: 0.001)

        XCTAssertEqual(dark.red, 0.066, accuracy: 0.001)
        XCTAssertEqual(dark.green, 0.074, accuracy: 0.001)
        XCTAssertEqual(dark.blue, 0.095, accuracy: 0.001)
        XCTAssertEqual(dark.alpha, 1, accuracy: 0.001)
    }

    func testOrbitPalettePanelResolvesForLightAndDarkAppearance() throws {
        let light = try rgbComponents(for: OrbitPalette.panel, appearanceName: .aqua)
        let dark = try rgbComponents(for: OrbitPalette.panel, appearanceName: .darkAqua)

        XCTAssertEqual(light.red, 1, accuracy: 0.001)
        XCTAssertEqual(light.green, 1, accuracy: 0.001)
        XCTAssertEqual(light.blue, 1, accuracy: 0.001)
        XCTAssertEqual(light.alpha, 0.92, accuracy: 0.001)

        XCTAssertEqual(dark.red, 0.162, accuracy: 0.001)
        XCTAssertEqual(dark.green, 0.179, accuracy: 0.001)
        XCTAssertEqual(dark.blue, 0.22, accuracy: 0.001)
        XCTAssertEqual(dark.alpha, 0.98, accuracy: 0.001)
    }

    private func rgbComponents(
        for color: Color,
        appearanceName: NSAppearance.Name
    ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let nsColor = NSColor(color)
        var resolvedColor: NSColor?

        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = nsColor.usingColorSpace(.deviceRGB)
        }

        let color = try XCTUnwrap(resolvedColor)
        return (
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}
