import AppKit
import Foundation
import XCTest
@testable import AgentDeputy

final class AgentDeputyThemeTests: XCTestCase {
    func testAccentStaysOnBrandAndReadsClearlyOnDarkSurfaces() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColor = AgentDeputyPalette.nsColor(for: light)
        let darkColor = AgentDeputyPalette.nsColor(for: dark)

        XCTAssertEqual(lightColor.redComponent, 91.0 / 255, accuracy: 0.001)
        XCTAssertEqual(lightColor.greenComponent, 92.0 / 255, accuracy: 0.001)
        XCTAssertEqual(lightColor.blueComponent, 226.0 / 255, accuracy: 0.001)
        XCTAssertEqual(darkColor.redComponent, 193.0 / 255, accuracy: 0.001)
        XCTAssertEqual(darkColor.greenComponent, 182.0 / 255, accuracy: 0.001)
        XCTAssertEqual(darkColor.blueComponent, 1, accuracy: 0.001)
        XCTAssertGreaterThan(darkColor.redComponent, lightColor.redComponent)
        XCTAssertEqual(AgentDeputyPalette.selectedFillNSColor(for: light).alphaComponent, 0.14, accuracy: 0.001)
        XCTAssertEqual(AgentDeputyPalette.selectedFillNSColor(for: dark).alphaComponent, 0.25, accuracy: 0.001)

        for (appearance, expected) in [(light, lightColor), (dark, darkColor)] {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = AgentDeputyPalette.accentNSColor.usingColorSpace(.sRGB)
            }
            let actual = try XCTUnwrap(resolved)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        }
    }

    func testThemeCycleMovesFromAutoToLightToDarkAndBackToAuto() {
        XCTAssertEqual(AgentDeputyThemeMode.auto.nextMode, .light)
        XCTAssertEqual(AgentDeputyThemeMode.light.nextMode, .dark)
        XCTAssertEqual(AgentDeputyThemeMode.dark.nextMode, .auto)
    }

    @MainActor
    func testThemeDefaultsToAutoAndPersistsSelectedMode() {
        let suite = "AgentDeputyThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentDeputyThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .auto)

        store.setMode(.dark)
        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(AgentDeputyThemeStore(defaults: defaults).mode, .dark)

        store.setMode(.light)
        XCTAssertEqual(store.mode, .light)
        XCTAssertEqual(AgentDeputyThemeStore(defaults: defaults).mode, .light)

        store.setMode(.auto)
        XCTAssertEqual(AgentDeputyThemeStore(defaults: defaults).mode, .auto)
    }
}
