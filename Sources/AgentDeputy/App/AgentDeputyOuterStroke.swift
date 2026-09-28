import AppKit

/// Continues the SVG's open rear panel around a closed track. One dash keeps
/// the original stroke length; positive phase moves it clockwise on screen.
struct AgentDeputyOuterStroke {
    let path: CGPath
    let visibleLength: CGFloat
    let lapLength: CGFloat

    init(outer: CGPath, inner: CGPath) throws {
        let bounds = outer.boundingBoxOfPath.union(inner.boundingBoxOfPath)
        var corner: (control1: CGPoint, control2: CGPoint, end: CGPoint)?
        outer.applyWithBlock { element in
            if element.pointee.type == .addCurveToPoint, corner == nil {
                let points = element.pointee.points
                corner = (points[0], points[1], points[2])
            }
        }
        guard let corner else {
            throw AgentDeputyLogoArtwork.ArtworkError.invalid("Outer logo path needs a rounded corner")
        }
        let radius = corner.end.x - bounds.minX
        let handle = corner.end.x - corner.control2.x
        guard radius > 0, bounds.width > radius * 2, bounds.height > radius * 2 else {
            throw AgentDeputyLogoArtwork.ArtworkError.invalid("Invalid outer logo track dimensions")
        }
        // Reuse the original left-side panel inset on the generated edges.
        // Using the inner panel's exact maxX/maxY puts both strokes on top of
        // each other when the moving segment reaches the right or bottom.
        let panelInset = inner.boundingBoxOfPath.minX - bounds.minX
        let left = bounds.minX, right = bounds.maxX + panelInset
        let top = bounds.minY, bottom = bounds.maxY + panelInset
        let track = CGMutablePath()
        // Reverse the asset's existing segment so its top end is the tail and
        // its lower-left end is the head. The initial dash remains the SVG.
        track.addPath(NSBezierPath(cgPath: outer).reversed.cgPath)
        track.addLine(to: CGPoint(x: left, y: bottom - radius))
        track.addCurve(to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(x: left, y: bottom - radius + handle),
            control2: CGPoint(x: left + radius - handle, y: bottom))
        track.addLine(to: CGPoint(x: right - radius, y: bottom))
        track.addCurve(to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right - radius + handle, y: bottom),
            control2: CGPoint(x: right, y: bottom - radius + handle))
        track.addLine(to: CGPoint(x: right, y: top + radius))
        track.addCurve(to: CGPoint(x: right - radius, y: top),
            control1: CGPoint(x: right, y: top + radius - handle),
            control2: CGPoint(x: right - radius + handle, y: top))
        track.addLine(to: outer.currentPoint)
        track.closeSubpath()
        path = track
        visibleLength = Self.length(of: outer)
        lapLength = Self.length(of: track)
    }

    private static func length(of path: CGPath) -> CGFloat {
        var current = CGPoint.zero, start = CGPoint.zero
        var result: CGFloat = 0
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: current = points[0]; start = current
            case .addLineToPoint:
                result += distance(current, points[0]); current = points[0]
            case .addCurveToPoint:
                let origin = current
                // Calculated once on load, never during animation frames.
                for step in 1...512 {
                    let t = CGFloat(step) / 512, u = 1 - t
                    let point = CGPoint(
                        x: u*u*u*origin.x + 3*u*u*t*points[0].x + 3*u*t*t*points[1].x + t*t*t*points[2].x,
                        y: u*u*u*origin.y + 3*u*u*t*points[0].y + 3*u*t*t*points[1].y + t*t*t*points[2].y)
                    result += distance(current, point); current = point
                }
            case .closeSubpath: result += distance(current, start); current = start
            default: break // The bundled path reader rejects unsupported commands.
            }
        }
        return result
    }
}
