import XCTest
@testable import AgentDeputy

final class AgentDeputyLogoArtworkTests: XCTestCase {
    func testArtworkUsesSVGGeometryAndStrokeWidth() throws {
        let source = try svgSource().replacingOccurrences(of: "H160", with: "H170")
            .replacingOccurrences(of: "stroke-width=\"18\"", with: "stroke-width=\"22\"")
        let artwork = try AgentDeputyLogoArtwork.parse(Data(source.utf8))
        let outer = try XCTUnwrap(artwork.elements.first { $0.id == "outer" })
        XCTAssertEqual(outer.path.currentPoint.x, 170)
        XCTAssertEqual(outer.lineWidth, 22)
        XCTAssertFalse(outer.isFilled)
    }

    func testUnsupportedCommandRejectsPartialArtwork() throws {
        let source = try svgSource().replacingOccurrences(of: "V78", with: "v78")
        XCTAssertThrowsError(try AgentDeputyLogoArtwork.parse(Data(source.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported logo path command"))
        }
    }

    func testMissingAndDuplicateLayerIDsAreRejected() throws {
        let source = try svgSource()
        for replacement in ["", "id=\"inner\""] {
            let invalid = source.replacingOccurrences(of: "id=\"outer\"", with: replacement)
            XCTAssertThrowsError(try AgentDeputyLogoArtwork.parse(Data(invalid.utf8)))
        }
    }

    private func svgSource() throws -> String {
        let url = try XCTUnwrap(AgentDeputyResourceBundle.bundle.url(forResource: "logo-template", withExtension: "svg"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
