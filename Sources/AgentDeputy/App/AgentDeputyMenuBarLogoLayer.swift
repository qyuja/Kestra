import AppKit
import QuartzCore

/// Loads the actual SVG artwork and moves only its outer stroke using Core
/// Animation. No timer or per-frame menu bar image rendering is needed.
@MainActor
final class AgentDeputyMenuBarLogoLayer {
    let layer = CALayer()
    private let artwork = CALayer()
    private let outer = CAShapeLayer()
    private var originalOuterPath: CGPath?
    private var outerMotion: AgentDeputyOuterStroke?
    private var shapes: [CAShapeLayer] = []
    private var viewBox = CGRect(x: 0, y: 0, width: 256, height: 256)
    private let snakeAnimationKey = "snakeTravel"

    init() {
        layer.addSublayer(artwork)
        do {
            let svg = try AgentDeputyLogoArtwork.loadBundled()
            viewBox = svg.viewBox
            artwork.bounds = CGRect(origin: .zero, size: viewBox.size)
            var visibleBounds = CGRect.null
            for element in svg.elements {
                let shape = element.id == "outer" ? outer : CAShapeLayer()
                shape.name = element.id
                shape.frame = artwork.bounds
                let path = layerPath(element.path)
                shape.path = path
                shape.lineWidth = element.lineWidth
                shape.lineCap = .round
                shape.lineJoin = .round
                shape.fillColor = element.isFilled ? NSColor.black.cgColor : nil
                shape.strokeColor = element.lineWidth > 0 ? NSColor.black.cgColor : nil
                artwork.addSublayer(shape)
                shapes.append(shape)
                let outline = element.lineWidth > 0
                    ? path.copy(strokingWithWidth: element.lineWidth, lineCap: .round,
                                lineJoin: .round, miterLimit: 10)
                    : path
                visibleBounds = visibleBounds.union(outline.boundingBoxOfPath)
            }
            // Center the SVG's ink, not its asymmetric transparent padding.
            // Keep this anchor fixed throughout the outer stroke's entire lap.
            artwork.anchorPoint = CGPoint(x: visibleBounds.midX / viewBox.width,
                                          y: visibleBounds.midY / viewBox.height)
            originalOuterPath = outer.path
            if let outerElement = svg.elements.first(where: { $0.id == "outer" }),
               let innerElement = svg.elements.first(where: { $0.id == "inner" }) {
                outerMotion = try AgentDeputyOuterStroke(outer: outerElement.path, inner: innerElement.path)
            }
        } catch {
            // A broken packaged asset must not prevent task monitoring from starting.
            NSLog("AgentDeputy menu bar SVG could not be loaded: %@", error.localizedDescription)
            if shapes.isEmpty {
                artwork.bounds = viewBox
                if let url = AgentDeputyResourceBundle.bundle.url(forResource: "agentdeputy-logo-icon", withExtension: "png") {
                    artwork.contents = NSImage(contentsOf: url)
                    artwork.contentsGravity = .resizeAspect
                }
            }
        }
    }

    func update(frame: CGRect, isDark: Bool, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        artwork.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let artworkScale = min(frame.width / viewBox.width, frame.height / viewBox.height)
        // Paths are normalized to y-up. NSStatusBarButton's backing layer is
        // y-down, so reflect only Y at that boundary; never rotate the SVG.
        let yDirection: CGFloat = layer.superlayer?.isGeometryFlipped == true ? -1 : 1
        artwork.setAffineTransform(
            CGAffineTransform(scaleX: artworkScale, y: artworkScale * yDirection)
        )
        let tint = (isDark ? NSColor.white : NSColor.black).cgColor
        for shape in shapes {
            if shape.strokeColor != nil { shape.strokeColor = tint }
            if shape.fillColor != nil { shape.fillColor = tint }
            shape.contentsScale = scale
        }
        CATransaction.commit()
    }

    func setRunning(_ isRunning: Bool) {
        guard isRunning else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outer.removeAnimation(forKey: snakeAnimationKey)
            outer.path = originalOuterPath
            outer.lineDashPattern = nil
            outer.lineDashPhase = 0
            CATransaction.commit()
            return
        }

        // Quota refreshes and theme changes must not restart an active lap.
        guard outer.animation(forKey: snakeAnimationKey) == nil, let motion = outerMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.path = layerPath(motion.path)
        outer.lineDashPattern = [NSNumber(value: Double(motion.visibleLength)),
                                 NSNumber(value: Double(motion.lapLength - motion.visibleLength))]
        outer.lineDashPhase = 0
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        // Positive dash phase moves the visible stroke clockwise on screen.
        animation.toValue = motion.lapLength
        animation.duration = 2.4
        animation.beginTime = outer.convertTime(CACurrentMediaTime(), from: nil)
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        outer.add(animation, forKey: snakeAnimationKey)
        CATransaction.commit()
    }

    private func layerPath(_ path: CGPath) -> CGPath {
        // Normalize SVG coordinates to y-up; update adapts to the host layer.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -viewBox.minX, ty: viewBox.maxY)
        return path.copy(using: &flip)!
    }
}
