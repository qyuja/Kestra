import AppKit

/// Draws the compact status item image without creating another view or
/// window. The short and long quota windows remain split into left and right
/// arcs, with each arc colored by its remaining percentage.
@MainActor
struct MenubarStatusIconRenderer {
    private static var cachedBrandLogo: NSImage?
    static let imageSize = NSSize(width: 24, height: 24)

    static func makeImage(
        provider: AIProvider?,
        usage: CodexAccountUsage?,
        isRunning: Bool,
        rotationAngle: CGFloat,
        isDark: Bool
    ) -> NSImage {
        let geometry = IconGeometry()
        let windows = Array((usage?.displayWindows ?? []).prefix(2))
        let image = NSImage(size: geometry.imageSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        if let logo = logo(for: provider) {
            drawLogo(
                logo,
                in: logoRect(forWindowCount: windows.count, geometry: geometry),
                rotationAngle: isRunning ? rotationAngle : 0,
                tint: isDark ? .white : .black
            )
        }

        drawProgressRings(windows: windows, geometry: geometry)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func makeRingImage(
        usage: CodexAccountUsage?,
        isDark: Bool
    ) -> NSImage {
        let geometry = IconGeometry()
        let windows = Array((usage?.displayWindows ?? []).prefix(2))
        let image = NSImage(size: geometry.imageSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        drawProgressRings(windows: windows, geometry: geometry)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func makeLogoImage(
        provider: AIProvider?,
        usage: CodexAccountUsage?,
        isDark: Bool
    ) -> NSImage? {
        let geometry = IconGeometry()
        guard let logo = logo(for: provider) else { return nil }
        let side = geometry.logoSize(forWindowCount: min(usage?.displayWindows.count ?? 0, 2))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        drawLogo(
            logo,
            in: NSRect(x: 0, y: 0, width: side, height: side),
            rotationAngle: 0,
            tint: isDark ? .white : .black
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func logoFrame(for usage: CodexAccountUsage?) -> NSRect {
        logoRect(
            forWindowCount: min(usage?.displayWindows.count ?? 0, 2),
            geometry: IconGeometry()
        )
    }

    private struct IconGeometry {
        let imageSize: NSSize
        let center: NSPoint
        let ringRadius: CGFloat
        let ringLineWidth: CGFloat
        private let quotaLogoSize: CGFloat
        private let fallbackLogoSize: CGFloat

        init() {
            imageSize = NSSize(width: 24, height: 24)
            ringRadius = 10.5
            ringLineWidth = 2
            quotaLogoSize = 16
            fallbackLogoSize = 19

            center = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        }

        func logoSize(forWindowCount count: Int) -> CGFloat {
            switch count {
            case 1, 2: quotaLogoSize
            default: fallbackLogoSize
            }
        }
    }

    private static func logoRect(forWindowCount count: Int, geometry: IconGeometry) -> NSRect {
        let side = geometry.logoSize(forWindowCount: count)
        return NSRect(
            x: (geometry.imageSize.width - side) / 2,
            y: (geometry.imageSize.height - side) / 2,
            width: side,
            height: side
        )
    }

    private static func drawProgressRings(
        windows: [CodexAccountUsage.Window],
        geometry: IconGeometry
    ) {
        switch windows.count {
        case 1:
            drawSingleProgressRing(windows[0], geometry: geometry)
        case 2:
            // displayWindows is sorted from the shorter window to the longer
            // one. Use the left half for 5h and the right half for 7d.
            drawSplitProgressRing(
                shortWindow: windows[0],
                longWindow: windows[1],
                geometry: geometry
            )
        default:
            break
        }
    }

    private static func logo(for provider: AIProvider?) -> NSImage? {
        if let provider {
            if let providerLogo = AIProviderLogoCatalog.image(for: provider) {
                return providerLogo
            }

            if let symbol = NSImage(
                systemSymbolName: provider.symbolName,
                accessibilityDescription: provider.name
            ) {
                let configuration = NSImage.SymbolConfiguration(
                    pointSize: 14,
                    weight: .semibold
                )
                return symbol.withSymbolConfiguration(configuration) ?? symbol
            }
        }

        if let cachedBrandLogo {
            return cachedBrandLogo
        }

        guard let resourceURL = KestraResourceBundle.bundle.url(
            forResource: "kestra-logo-icon",
            withExtension: "png"
        ), let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        image.isTemplate = true
        cachedBrandLogo = image
        return image
    }

    private static func drawLogo(
        _ image: NSImage,
        in rect: NSRect,
        rotationAngle: CGFloat,
        tint: NSColor
    ) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: center.x, y: center.y)
        context?.rotate(by: rotationAngle)
        context?.translateBy(x: -center.x, y: -center.y)
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        // Provider assets are transparent masks. Tint the drawn mask so the
        // non-template composite remains legible on both menu bar appearances.
        tint.setFill()
        rect.fill(using: .sourceAtop)
        context?.restoreGState()
    }

    private static func drawSingleProgressRing(
        _ window: CodexAccountUsage.Window,
        geometry: IconGeometry
    ) {
        let color = QuotaProgressColor.forRemainingPercent(window.remainingPercent).nsColor
        drawTrack(geometry: geometry, color: color)

        let progress = CGFloat(window.remainingPercent) / 100
        guard progress > 0 else { return }

        if progress >= 1 {
            drawFullRing(geometry: geometry, color: color)
        } else {
            drawArc(
                geometry: geometry,
                startAngle: 90,
                endAngle: 90 - 360 * progress,
                clockwise: true,
                color: color
            )
        }
    }

    private static func drawSplitProgressRing(
        shortWindow: CodexAccountUsage.Window,
        longWindow: CodexAccountUsage.Window,
        geometry: IconGeometry
    ) {
        let shortColor = QuotaProgressColor
            .forRemainingPercent(shortWindow.remainingPercent)
            .nsColor
        let longColor = QuotaProgressColor
            .forRemainingPercent(longWindow.remainingPercent)
            .nsColor

        drawArc(
            geometry: geometry,
            startAngle: 90,
            endAngle: 270,
            clockwise: false,
            color: shortColor.withAlphaComponent(0.22)
        )
        drawArc(
            geometry: geometry,
            startAngle: 90,
            endAngle: -90,
            clockwise: true,
            color: longColor.withAlphaComponent(0.22)
        )

        let shortProgress = CGFloat(shortWindow.remainingPercent) / 100
        if shortProgress >= 1 {
            drawArc(
                geometry: geometry,
                startAngle: 90,
                endAngle: 270,
                clockwise: false,
                color: shortColor
            )
        } else if shortProgress > 0 {
            drawArc(
                geometry: geometry,
                startAngle: 90,
                endAngle: 90 + 180 * shortProgress,
                clockwise: false,
                color: shortColor
            )
        }

        let longProgress = CGFloat(longWindow.remainingPercent) / 100
        if longProgress >= 1 {
            drawArc(
                geometry: geometry,
                startAngle: 90,
                endAngle: -90,
                clockwise: true,
                color: longColor
            )
        } else if longProgress > 0 {
            drawArc(
                geometry: geometry,
                startAngle: 90,
                endAngle: 90 - 180 * longProgress,
                clockwise: true,
                color: longColor
            )
        }
    }

    private static func drawTrack(geometry: IconGeometry, color: NSColor) {
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: geometry.center.x - geometry.ringRadius,
                y: geometry.center.y - geometry.ringRadius,
                width: geometry.ringRadius * 2,
                height: geometry.ringRadius * 2
            )
        )
        path.lineWidth = geometry.ringLineWidth
        color.withAlphaComponent(0.22).setStroke()
        path.stroke()
    }

    private static func drawFullRing(geometry: IconGeometry, color: NSColor) {
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: geometry.center.x - geometry.ringRadius,
                y: geometry.center.y - geometry.ringRadius,
                width: geometry.ringRadius * 2,
                height: geometry.ringRadius * 2
            )
        )
        path.lineWidth = geometry.ringLineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func drawArc(
        geometry: IconGeometry,
        startAngle: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool,
        color: NSColor
    ) {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: geometry.center,
            radius: geometry.ringRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        path.lineWidth = geometry.ringLineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}
