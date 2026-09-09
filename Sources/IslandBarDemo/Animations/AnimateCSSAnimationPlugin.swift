import SwiftUI

enum AnimateCSSAnimationPreset: String, CaseIterable, Codable, Identifiable {
    case fadeIn
    case fadeInDown
    case fadeInLeft
    case fadeInRight
    case fadeInUp
    case fadeInTopLeft
    case fadeInTopRight
    case fadeInBottomLeft
    case fadeInBottomRight

    var id: String { rawValue }

    var directionName: String {
        switch self {
        case .fadeIn: return "Fade"
        case .fadeInDown: return "Top"
        case .fadeInUp: return "Bottom"
        default: return String(rawValue.dropFirst(6))
        }
    }

    var exitName: String {
        switch self {
        case .fadeIn:
            return "fadeOut"
        case .fadeInDown:
            return "fadeOutDown"
        case .fadeInLeft:
            return "fadeOutLeft"
        case .fadeInRight:
            return "fadeOutRight"
        case .fadeInUp:
            return "fadeOutUp"
        case .fadeInTopLeft:
            return "fadeOutTopLeft"
        case .fadeInTopRight:
            return "fadeOutTopRight"
        case .fadeInBottomLeft:
            return "fadeOutBottomLeft"
        case .fadeInBottomRight:
            return "fadeOutBottomRight"
        }
    }

    var displayName: String {
        "\(rawValue) / \(exitName)"
    }

    var transition: CompletionAnimationTransition {
        let entryVector: CompletionEntryVector
        let exitVector: CompletionEntryVector

        switch self {
        case .fadeIn:
            entryVector = .zero
            exitVector = .zero
        case .fadeInDown:
            entryVector = CompletionEntryVector(x: 0, y: 1)
            exitVector = CompletionEntryVector(x: 0, y: 1)
        case .fadeInLeft:
            entryVector = CompletionEntryVector(x: -1, y: 0)
            exitVector = CompletionEntryVector(x: -1, y: 0)
        case .fadeInRight:
            entryVector = CompletionEntryVector(x: 1, y: 0)
            exitVector = CompletionEntryVector(x: 1, y: 0)
        case .fadeInUp:
            entryVector = CompletionEntryVector(x: 0, y: -1)
            exitVector = CompletionEntryVector(x: 0, y: -1)
        case .fadeInTopLeft:
            entryVector = CompletionEntryVector(x: -1, y: 1)
            exitVector = CompletionEntryVector(x: -1, y: 1)
        case .fadeInTopRight:
            entryVector = CompletionEntryVector(x: 1, y: 1)
            exitVector = CompletionEntryVector(x: 1, y: 1)
        case .fadeInBottomLeft:
            entryVector = CompletionEntryVector(x: -1, y: -1)
            exitVector = CompletionEntryVector(x: -1, y: -1)
        case .fadeInBottomRight:
            entryVector = CompletionEntryVector(x: 1, y: -1)
            exitVector = CompletionEntryVector(x: 1, y: -1)
        }

        return CompletionAnimationTransition(
            entryVector: entryVector,
            exitVector: exitVector,
            entryDuration: 0.7,
            exitDuration: 0.42
        )
    }
}

struct AnimateCSSAnimationPlugin: CompletionAnimationPlugin {
    static let defaultPreset = AnimateCSSAnimationPreset.fadeInDown
    static let presets = AnimateCSSAnimationPreset.allCases

    static var defaultIdentifier: String {
        defaultPreset.rawValue
    }

    let preset: AnimateCSSAnimationPreset

    init(preset: AnimateCSSAnimationPreset = Self.defaultPreset) {
        self.preset = preset
    }

    var identifier: String {
        preset.rawValue
    }

    var displayName: String {
        preset.displayName
    }

    var transition: CompletionAnimationTransition {
        preset.transition
    }

    func makeView(
        content: AnyView,
        configuration: CompletionAnimationConfiguration
    ) -> AnyView {
        AnyView(
            AnimateCSSAnimationView(
                content: content,
                configuration: configuration
            )
        )
    }
}

private struct AnimateCSSAnimationView: View {
    let content: AnyView
    let configuration: CompletionAnimationConfiguration

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
    }
}
