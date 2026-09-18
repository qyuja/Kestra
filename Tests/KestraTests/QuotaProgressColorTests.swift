import XCTest
@testable import Kestra

final class QuotaProgressColorTests: XCTestCase {
    func testRemainingPercentMapsToRequestedColorBands() {
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(100), .green)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(80), .green)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(79), .blue)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(50), .blue)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(49), .yellow)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(30), .yellow)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(29), .orange)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(11), .orange)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(10), .red)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(0), .red)
    }

    func testRemainingPercentIsClampedBeforeMapping() {
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(-1), .red)
        XCTAssertEqual(QuotaProgressColor.forRemainingPercent(101), .green)
    }
}
