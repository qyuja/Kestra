import XCTest
import ObjectiveC
@testable import Kestra

final class StatusItemHoverTests: XCTestCase {
    func testTrackingCallbacksAreVisibleToAppKit() {
        XCTAssertNotNil(class_getInstanceMethod(IslandStatusItemController.self, NSSelectorFromString("mouseEntered:")))
        XCTAssertNotNil(class_getInstanceMethod(IslandStatusItemController.self, NSSelectorFromString("mouseExited:")))
    }
}
