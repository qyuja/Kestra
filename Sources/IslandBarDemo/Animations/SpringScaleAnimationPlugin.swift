import SwiftUI

struct SpringScaleAnimationPlugin: CompletionAnimationPlugin {
    static let pluginIdentifier = "spring-scale"

    let identifier = Self.pluginIdentifier
    let displayName = "弹性缩放"

    func makeView(
        content: AnyView,
        configuration: CompletionAnimationConfiguration
    ) -> AnyView {
        AnyView(
            SpringScaleAnimationView(
                content: content,
                configuration: configuration
            )
        )
    }
}

private struct SpringScaleAnimationView: View {
    let content: AnyView
    let configuration: CompletionAnimationConfiguration

    @State private var isVisible = false

    private var initialScale: CGFloat {
        configuration.entryVector.isCorner ? 0.18 : 0.76
    }

    var body: some View {
        content
            .frame(width: 368, height: 86)
            .background(
                RoundedRectangle(
                    cornerRadius: configuration.cardCornerRadius,
                    style: .continuous
                )
                .fill(Color.black)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: configuration.cardCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: configuration.cardCornerRadius,
                    style: .continuous
                )
            )
            .scaleEffect(
                isVisible ? 1 : initialScale,
                anchor: configuration.animationAnchor
            )
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(
                    .spring(
                        response: 0.42 * configuration.durationScale,
                        dampingFraction: 0.66,
                        blendDuration: 0.05
                    )
                ) {
                    isVisible = true
                }
            }
    }
}
