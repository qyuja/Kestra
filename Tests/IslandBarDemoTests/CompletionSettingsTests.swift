import XCTest
@testable import IslandBarDemo

final class CompletionSettingsTests: XCTestCase {
    @MainActor
    func testEntranceAndExitPersistIndependently() {
        let name = "CompletionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionAnimationSettingsStore(defaults: defaults)
        store.selectAnimation(identifier: "fadeIn")
        store.setExitEffect(.fragments)
        store.setExitDirection(.fadeInRight)
        store.setDisplayPosition(.bottomLeading)
        let restored = CompletionAnimationSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.selectedAnimationIdentifier, "fadeIn")
        XCTAssertEqual(restored.exitEffect, .fragments)
        XCTAssertEqual(restored.exitDirection, .fadeInRight)
    }

    @MainActor
    func testPositionChangesPreserveCompatibleDirectionsAndNormalizeOthers() {
        let name = "CompletionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionAnimationSettingsStore(defaults: defaults)
        store.selectAnimation(identifier: "fadeInTopLeft")
        store.setDisplayPosition(.centerLeading)
        XCTAssertEqual(store.selectedAnimationIdentifier, "fadeInTopLeft")
        store.setDisplayPosition(.bottomTrailing)
        XCTAssertEqual(store.selectedAnimationIdentifier, "fadeInBottomRight")
        store.selectAnimation(identifier: "fadeInLeft")
        XCTAssertEqual(store.selectedAnimationIdentifier, "fadeInBottomRight")
        XCTAssertEqual(CompletionAnimationSettingsStore(defaults: defaults).selectedAnimationIdentifier, "fadeInBottomRight")
    }

    func testEveryPositionHasValidDefaultsAndDirectionsExitThroughEntryEdge() {
        for position in CompletionDisplayPosition.allCases {
            XCTAssertFalse(position.allowedAnimations.isEmpty)
            if position != .center { XCTAssertEqual(position.allowedAnimations.count, 3) }
        }
        for preset in AnimateCSSAnimationPreset.allCases {
            XCTAssertEqual(preset.transition.entryVector, preset.transition.exitVector)
        }
        XCTAssertEqual(CompletionDisplayPosition.topCenter.allowedAnimations, [.fadeInDown, .fadeInTopLeft, .fadeInTopRight])
        XCTAssertEqual(Set(CompletionDisplayPosition.topLeading.allowedAnimations), Set([.fadeInDown, .fadeInLeft, .fadeInTopLeft]))
    }
}
