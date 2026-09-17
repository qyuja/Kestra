import Foundation
import XCTest
@testable import Kestra

final class KestraThemeTests: XCTestCase {
    @MainActor
    func testThemeDefaultsToDarkAndPersistsSelectedMode() {
        let suite = "KestraThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KestraThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .dark)

        store.setMode(.light)
        XCTAssertEqual(store.mode, .light)
        XCTAssertEqual(KestraThemeStore(defaults: defaults).mode, .light)
    }
}
