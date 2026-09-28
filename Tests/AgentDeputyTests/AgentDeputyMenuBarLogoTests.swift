import AppKit
import QuartzCore
import XCTest
@testable import AgentDeputy

@MainActor
final class AgentDeputyMenuBarLogoTests: XCTestCase {
    func testLogoPreservesSVGOrientationInEitherHostCoordinateSystem() throws {
        for isFlipped in [false, true] {
            let host = CALayer()
            host.bounds = CGRect(x: 0, y: 0, width: 40, height: 26)
            host.isGeometryFlipped = isFlipped
            let logo = AgentDeputyMenuBarLogoLayer()
            host.addSublayer(logo.layer)
            logo.update(frame: CGRect(x: 9.5, y: 2.5, width: 21, height: 21),
                        isDark: false, scale: 2)

            let mark = try edge(named: "mark", in: logo.layer)
            let circle = try edge(named: "circle", in: logo.layer)
            // These are landmarks in the original SVG: the chevron points
            // right, and its signal dot sits above and to the right of it.
            let tip = host.convert(CGPoint(x: 150, y: 256 - 148), from: mark)
            let tail = host.convert(CGPoint(x: 124, y: 256 - 125), from: mark)
            let dot = host.convert(CGPoint(x: 210, y: 256 - 82), from: circle)
            XCTAssertGreaterThan(tip.x, tail.x, "The terminal chevron must not point left")
            XCTAssertGreaterThan(dot.x, tip.x)
            if isFlipped {
                XCTAssertLessThan(dot.y, tip.y, "In AppKit's flipped button, the dot must be above the mark")
            } else {
                XCTAssertGreaterThan(dot.y, tip.y)
            }
        }
    }

    func testVisibleArtworkIsCenteredAndDoesNotShiftWhenMotionStarts() throws {
        let host = CALayer()
        host.bounds = CGRect(x: 0, y: 0, width: 40, height: 26)
        host.isGeometryFlipped = true
        let logo = AgentDeputyMenuBarLogoLayer()
        host.addSublayer(logo.layer)
        let frame = CGRect(x: 9.5, y: 2.5, width: 21, height: 21)
        logo.update(frame: frame, isDark: false, scale: 2)
        let idleBounds = try visibleBounds(of: logo.layer, in: host)
        XCTAssertEqual(idleBounds.midX, frame.midX, accuracy: 0.0001)
        XCTAssertEqual(idleBounds.midY, frame.midY, accuracy: 0.0001)
        let mark = try edge(named: "mark", in: logo.layer)
        let originalMark = host.convert(try XCTUnwrap(mark.path).boundingBoxOfPath, from: mark)

        logo.setRunning(true)
        logo.update(frame: frame, isDark: false, scale: 2)
        XCTAssertEqual(host.convert(try XCTUnwrap(mark.path).boundingBoxOfPath, from: mark), originalMark,
                       "The fixed artwork must not jump when a task starts")
        XCTAssertTrue(frame.contains(try visibleBounds(of: logo.layer, in: host)),
                      "The complete outer track must fit inside the reserved menu bar space")
    }

    func testOuterStrokeMovesClockwiseAcrossTopThenDownRight() throws {
        let logo = AgentDeputyMenuBarLogoLayer()
        let outer = try edge(named: "outer", in: logo.layer)
        let idle = try render(outer)
        XCTAssertGreaterThan(alpha(idle, x: 150, y: 46), 200)
        XCTAssertEqual(alpha(idle, x: 46, y: 180), 0)
        XCTAssertEqual(alpha(idle, x: 100, y: 214), 0)

        logo.setRunning(true)
        let animation = try XCTUnwrap(outer.animation(forKey: "snakeTravel") as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "lineDashPhase")
        let initialPhase = outer.lineDashPhase
        let runningStart = try render(outer)
        XCTAssertGreaterThan(try XCTUnwrap(animation.toValue as? NSNumber).doubleValue,
                             Double(initialPhase), "The stroke must move clockwise on screen")
        outer.removeAllAnimations()

        let crossingTop = try render(outer, phase: initialPhase + 40)
        XCTAssertGreaterThan(alpha(crossingTop, x: 190, y: 46), 200)
        XCTAssertEqual(alpha(crossingTop, x: 46, y: 150), 0)

        let descendingRight = try render(outer, phase: initialPhase + 150)
        XCTAssertGreaterThan(alpha(descendingRight, x: 242, y: 95), 200)
        XCTAssertEqual(alpha(descendingRight, x: 46, y: 150), 0)
        let completedLap = try render(outer, phase: CGFloat(
            try XCTUnwrap(animation.toValue as? NSNumber).doubleValue))
        XCTAssertEqual(completedLap, runningStart, "One lap must return to the same visible stroke")
        // Quartz flattens a dashed cubic slightly differently from the original
        // solid stroke. Allow less than five square SVG pixels of edge coverage
        // difference: below 0.04 pixel at the actual menu bar icon size.
        let coverageDifference = stride(from: 3, to: idle.count, by: 4).reduce(0) {
            $0 + abs(Int(idle[$1]) - Int(runningStart[$1]))
        }
        XCTAssertLessThan(Double(coverageDifference) / 255, 5,
            "Starting motion must preserve the SVG silhouette")
    }

    func testEntireLapStaysClearOfInnerArtworkAndWithinCanvas() throws {
        let logo = AgentDeputyMenuBarLogoLayer()
        let outer = try edge(named: "outer", in: logo.layer)
        let fixed = try ["inner", "mark", "circle"].map { try render(edge(named: $0, in: logo.layer)) }
        logo.setRunning(true)
        let animation = try XCTUnwrap(outer.animation(forKey: "snakeTravel") as? CABasicAnimation)
        let endPhase = try XCTUnwrap(animation.toValue as? NSNumber).doubleValue
        outer.removeAllAnimations()

        let outline = try XCTUnwrap(outer.path).copy(strokingWithWidth: outer.lineWidth,
            lineCap: .round, lineJoin: .round, miterLimit: 10)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 256, height: 256).contains(outline.boundingBoxOfPath),
                      "Making room for the inner panel must not clip the outer stroke")
        for step in 0..<24 {
            let pixels = try render(outer, phase: CGFloat(endPhase * Double(step) / 24))
            let overlaps = stride(from: 3, to: pixels.count, by: 4).filter { index in
                pixels[index] > 0 && fixed.contains { $0[index] > 0 }
            }.count
            XCTAssertEqual(overlaps, 0, "Outer stroke intersects fixed artwork at phase \(step)/24")
        }
    }

    func testRefreshPreservesAnimationAndStoppingRestoresOriginalSVG() throws {
        let logo = AgentDeputyMenuBarLogoLayer()
        let outer = try edge(named: "outer", in: logo.layer)
        let original = try render(outer)
        logo.update(frame: CGRect(x: 0, y: 0, width: 21, height: 21), isDark: false, scale: 2)
        logo.setRunning(true)
        let start = try XCTUnwrap(outer.animation(forKey: "snakeTravel")).beginTime

        logo.update(frame: CGRect(x: 1, y: 0, width: 21, height: 21), isDark: true, scale: 2)
        logo.setRunning(true)
        XCTAssertEqual(try XCTUnwrap(outer.animation(forKey: "snakeTravel")).beginTime, start)
        XCTAssertEqual(try XCTUnwrap(outer.strokeColor), NSColor.white.cgColor)

        logo.setRunning(false)
        XCTAssertNil(outer.animationKeys())
        XCTAssertEqual(try render(outer), original)
        logo.setRunning(true)
        XCTAssertNotNil(outer.animation(forKey: "snakeTravel"))
    }

    func testInnerArtworkStaysFixedWhileOuterMoves() throws {
        let logo = AgentDeputyMenuBarLogoLayer()
        let fixedArtwork = try ["inner", "mark", "circle"].map {
            try edge(named: $0, in: logo.layer)
        }
        let originalPaths = fixedArtwork.map(\.path)
        logo.setRunning(true)
        logo.update(frame: CGRect(x: 1, y: 0, width: 23, height: 23), isDark: true, scale: 2)

        for (shape, originalPath) in zip(fixedArtwork, originalPaths) {
            XCTAssertNil(shape.animationKeys(), "\(shape.name ?? "") must remain at rest")
            XCTAssertTrue(CATransform3DIsIdentity(shape.transform))
            XCTAssertEqual(shape.path, originalPath)
        }
    }

    private func edge(named name: String, in layer: CALayer) throws -> CAShapeLayer {
        let artwork = try XCTUnwrap(layer.sublayers?.first)
        return try XCTUnwrap(artwork.sublayers?.first { $0.name == name } as? CAShapeLayer)
    }

    private func visibleBounds(of layer: CALayer, in host: CALayer) throws -> CGRect {
        try ["outer", "inner", "mark", "circle"].reduce(CGRect.null) { bounds, name in
            let shape = try edge(named: name, in: layer)
            let path = try XCTUnwrap(shape.path)
            let outline = shape.strokeColor == nil ? path : path.copy(strokingWithWidth: shape.lineWidth,
                lineCap: .round, lineJoin: .round, miterLimit: 10)
            return bounds.union(host.convert(outline.boundingBoxOfPath, from: shape))
        }
    }

    // Rasterize the actual stroke configuration to catch reversed direction,
    // incorrect corner geometry, and a discontinuity at the loop seam.
    private func render(_ shape: CAShapeLayer, phase: CGFloat? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256,
            bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(shape.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let pattern = shape.lineDashPattern {
            context.setLineDash(phase: phase ?? shape.lineDashPhase,
                               lengths: pattern.map { CGFloat($0.doubleValue) })
        }
        context.addPath(try XCTUnwrap(shape.path))
        if shape.fillColor != nil {
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
        } else {
            context.strokePath()
        }
        return Data(bytes: try XCTUnwrap(context.data), count: 256 * 256 * 4)
    }

    private func alpha(_ pixels: Data, x: Int, y: Int) -> UInt8 {
        pixels[(y * 256 + x) * 4 + 3]
    }
}
