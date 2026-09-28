import Foundation
import XCTest
@testable import AgentDeputy

final class AgentDeputyThemeTests: XCTestCase {
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
