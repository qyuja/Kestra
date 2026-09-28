import AppKit
import SwiftUI
import XCTest
@testable import AgentDeputy

@MainActor
final class AppBrandIconTests: XCTestCase {
    func testRearPanelRemainsVisibleAfterSwitchingThemes() throws {
        // The rear panel used to keep its navy light-theme pixels on a dark
        // background. Render the actual view to cover its environment and cache.
        for scheme in [ColorScheme.dark, .light, .dark] {
            let renderer = ImageRenderer(content: AppBrandIcon(size: 256)
                .environment(\.colorScheme, scheme))
            let renderedImage = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: renderedImage)
            let rearPanel = try XCTUnwrap(bitmap.colorAt(x: 46, y: 110)?.usingColorSpace(.sRGB))

            XCTAssertGreaterThan(rearPanel.alphaComponent, 0.9)
            if scheme == .dark {
                XCTAssertGreaterThan(rearPanel.brightnessComponent, 0.8,
                    "The rear panel must remain light against a dark surface")
            } else {
                XCTAssertLessThan(rearPanel.brightnessComponent, 0.35,
                    "The light appearance must retain the original dark outline")
            }
        }
    }
}
