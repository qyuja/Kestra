import SwiftUI

struct LiquidDropAnimationPlugin: CompletionAnimationPlugin {
    static let pluginIdentifier = "liquid-drop"

    let identifier = Self.pluginIdentifier
    let displayName = "水滴弹出"

    func makeView(
        content: AnyView,
        configuration: CompletionAnimationConfiguration
    ) -> AnyView {
        AnyView(
            LiquidDropAnimationView(
                content: content,
                configuration: configuration
            )
        )
    }
}

private struct LiquidDropAnimationView: View {
    let content: AnyView
    let configuration: CompletionAnimationConfiguration

    @State private var liquidProgress: CGFloat = 0
    @State private var contentIsVisible = false

    private var liquidShape: LiquidDropShape {
        LiquidDropShape(
            progress: liquidProgress,
            configuration: configuration
        )
    }

    private var initialScale: CGFloat {
        configuration.entryVector.isCorner ? 0.18 : 1
    }

    var body: some View {
        ZStack {
            liquidShape
                .fill(Color.black)

            content
                .opacity(contentIsVisible ? 1 : 0)
        }
            .frame(width: 368, height: 86)
            .clipShape(liquidShape)
            .contentShape(liquidShape)
            .scaleEffect(
                contentIsVisible ? 1 : initialScale,
                anchor: configuration.animationAnchor
            )
            .onAppear {
                let durationScale = configuration.durationScale

                // The shape grows from the configured edge or corner. Corner
                // entries also scale the complete surface from that same anchor.
                withAnimation(.easeOut(duration: 0.14 * durationScale)) {
                    liquidProgress = 0.2
                }
                withAnimation(
                    .spring(
                        response: 0.46 * durationScale,
                        dampingFraction: 0.70,
                        blendDuration: 0.06
                    )
                    .delay(0.08 * durationScale)
                ) {
                    liquidProgress = 1
                }

                withAnimation(
                    .easeOut(duration: 0.18 * durationScale)
                        .delay(configuration.contentRevealDelay * durationScale)
                ) {
                    contentIsVisible = true
                }
            }
    }
}

private struct LiquidDropShape: Shape {
    var progress: CGFloat
    let configuration: CompletionAnimationConfiguration

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(progress, 0), 1)
        let widthProgress = min(progress * 1.08, 1)
        let heightProgress = min(progress * 1.04, 1)
        let width = interpolate(
            from: configuration.dropWidth,
            to: rect.width,
            value: widthProgress
        )
        let height = interpolate(
            from: configuration.dropHeight,
            to: rect.height,
            value: heightProgress
        )

        guard configuration.entryVector.x == 0,
              configuration.entryVector.y > 0 else {
            return directionalBlobPath(
                in: rect,
                width: width,
                height: height,
                progress: progress
            )
        }

        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let bottom = rect.minY + height
        let targetRadius = min(configuration.cardCornerRadius, height / 2)
        let bottomRadius = min(width / 2, height / 2, configuration.cardCornerRadius)
        let topRadius = interpolate(
            from: min(width / 2, height / 2),
            to: targetRadius,
            value: progress
        )
        let tipness = 1 - smoothStep(progress, start: 0.16, end: 0.62)
        let topSpan = max(0, width - topRadius * 2) * (1 - tipness)
        let topLeft = rect.midX - topSpan / 2
        let topRight = rect.midX + topSpan / 2
        let sideTop = topRadius + (height * 0.44 - topRadius) * tipness

        var path = Path()
        path.move(to: CGPoint(x: topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: topRight, y: rect.minY))

        path.addCurve(
            to: CGPoint(x: right, y: sideTop),
            control1: CGPoint(x: right, y: rect.minY),
            control2: CGPoint(
                x: right,
                y: sideTop * 0.55 + rect.minY * 0.45
            )
        )
        path.addLine(to: CGPoint(x: right, y: bottom - bottomRadius))

        path.addCurve(
            to: CGPoint(x: right - bottomRadius, y: bottom),
            control1: CGPoint(
                x: right,
                y: bottom - bottomRadius * 0.42
            ),
            control2: CGPoint(
                x: right - bottomRadius * 0.42,
                y: bottom
            )
        )
        path.addLine(to: CGPoint(x: left + bottomRadius, y: bottom))

        path.addCurve(
            to: CGPoint(x: left, y: bottom - bottomRadius),
            control1: CGPoint(
                x: left + bottomRadius * 0.42,
                y: bottom
            ),
            control2: CGPoint(
                x: left,
                y: bottom - bottomRadius * 0.42
            )
        )
        path.addLine(to: CGPoint(x: left, y: sideTop))

        path.addCurve(
            to: CGPoint(x: topLeft, y: rect.minY),
            control1: CGPoint(
                x: left,
                y: sideTop * 0.55 + rect.minY * 0.45
            ),
            control2: CGPoint(x: left, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    private func directionalBlobPath(
        in rect: CGRect,
        width: CGFloat,
        height: CGFloat,
        progress: CGFloat
    ) -> Path {
        let vector = configuration.entryVector
        let originX: CGFloat
        if vector.x < 0 {
            originX = rect.minX
        } else if vector.x > 0 {
            originX = rect.maxX - width
        } else {
            originX = rect.midX - width / 2
        }

        let originY: CGFloat
        if vector.y > 0 {
            originY = rect.minY
        } else if vector.y < 0 {
            originY = rect.maxY - height
        } else {
            originY = rect.midY - height / 2
        }

        let bounds = CGRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )
        let startRadius = min(width, height) / 2
        let finalRadius = min(
            configuration.cardCornerRadius,
            min(rect.width, rect.height) / 2
        )
        let radius = interpolate(
            from: startRadius,
            to: finalRadius,
            value: progress
        )

        return Path(roundedRect: bounds, cornerRadius: radius)
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        value: CGFloat
    ) -> CGFloat {
        start + (end - start) * value
    }

    private func smoothStep(
        _ value: CGFloat,
        start: CGFloat,
        end: CGFloat
    ) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        let normalized = min(max((value - start) / (end - start), 0), 1)
        return normalized * normalized * (3 - 2 * normalized)
    }
}
