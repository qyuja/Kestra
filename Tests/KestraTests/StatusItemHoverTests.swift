import XCTest
import ObjectiveC
@testable import Kestra

final class StatusItemHoverTests: XCTestCase {
    func testTrackingCallbacksAreVisibleToAppKit() {
        XCTAssertNotNil(class_getInstanceMethod(IslandStatusItemController.self, NSSelectorFromString("mouseEntered:")))
        XCTAssertNotNil(class_getInstanceMethod(IslandStatusItemController.self, NSSelectorFromString("mouseExited:")))
    }

    func testMenuBarAppearanceRedrawIsGatedByActualModeChange() {
        var gate = MenuBarAppearanceRedrawGate()

        XCTAssertTrue(gate.shouldRedraw(for: false))
        XCTAssertFalse(gate.shouldRedraw(for: false))
        XCTAssertFalse(gate.shouldRedraw(for: false))
        XCTAssertTrue(gate.shouldRedraw(for: true))
        XCTAssertFalse(gate.shouldRedraw(for: true))

        gate.record(false)
        XCTAssertFalse(gate.shouldRedraw(for: false))
        XCTAssertTrue(gate.shouldRedraw(for: true))
    }
}
