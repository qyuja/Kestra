import CoreGraphics
import Foundation

enum CompletionDisplayPosition: String, CaseIterable, Codable, Identifiable {
    case topLeading
    case topCenter
    case topTrailing
    case centerLeading
    case center
    case centerTrailing
    case bottomLeading
    case bottomCenter
    case bottomTrailing

    var id: String { rawValue }

    var allowedAnimations: [AnimateCSSAnimationPreset] {
        switch self {
        case .topCenter: return [.fadeInDown, .fadeInTopLeft, .fadeInTopRight]
        case .bottomCenter: return [.fadeInUp, .fadeInBottomLeft, .fadeInBottomRight]
        case .centerLeading: return [.fadeInLeft, .fadeInTopLeft, .fadeInBottomLeft]
        case .centerTrailing: return [.fadeInRight, .fadeInTopRight, .fadeInBottomRight]
        case .topLeading: return [.fadeInTopLeft, .fadeInDown, .fadeInLeft]
        case .topTrailing: return [.fadeInTopRight, .fadeInDown, .fadeInRight]
        case .bottomLeading: return [.fadeInBottomLeft, .fadeInUp, .fadeInLeft]
        case .bottomTrailing: return [.fadeInBottomRight, .fadeInUp, .fadeInRight]
        case .center: return AnimateCSSAnimationPreset.allCases
        }
    }

    var title: String {
        switch self {
        case .topLeading:
            return "左上"
        case .topCenter:
            return "上中"
        case .topTrailing:
            return "右上"
        case .centerLeading:
            return "左侧"
        case .center:
            return "正中"
        case .centerTrailing:
            return "右侧"
        case .bottomLeading:
            return "左下"
        case .bottomCenter:
            return "下中"
        case .bottomTrailing:
            return "右下"
        }
    }

    var iconName: String {
        switch self {
        case .topLeading:
            return "arrow.up.left"
        case .topCenter:
            return "arrow.up"
        case .topTrailing:
            return "arrow.up.right"
        case .centerLeading:
            return "arrow.left"
        case .center:
            return "viewfinder"
        case .centerTrailing:
            return "arrow.right"
        case .bottomLeading:
            return "arrow.down.left"
        case .bottomCenter:
            return "arrow.down"
        case .bottomTrailing:
            return "arrow.down.right"
        }
    }
}

enum CompletionEntryMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case fromEdge
    case fromCorner
    case fromTop
    case fromBottom
    case fromLeft
    case fromRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .fromEdge:
            return "对应边"
        case .fromCorner:
            return "对应角"
        case .fromTop:
            return "从上方"
        case .fromBottom:
            return "从下方"
        case .fromLeft:
            return "从左侧"
        case .fromRight:
            return "从右侧"
        }
    }

    var iconName: String {
        switch self {
        case .automatic:
            return "wand.and.stars"
        case .fromEdge:
            return "rectangle.portrait"
        case .fromCorner:
            return "rectangle.portrait.rotate"
        case .fromTop:
            return "arrow.down"
        case .fromBottom:
            return "arrow.up"
        case .fromLeft:
            return "arrow.right"
        case .fromRight:
            return "arrow.left"
        }
    }
}

struct CompletionEntryVector: Equatable {
    let x: CGFloat
    let y: CGFloat

    static let zero = CompletionEntryVector(x: 0, y: 0)

    var isCorner: Bool {
        x != 0 && y != 0
    }
}

enum CompletionEntryVectorResolver {
    static func resolve(
        position: CompletionDisplayPosition,
        mode: CompletionEntryMode
    ) -> CompletionEntryVector {
        switch mode {
        case .automatic:
            return automaticVector(for: position)
        case .fromEdge:
            return edgeVector(for: position)
        case .fromCorner:
            return cornerVector(for: position)
        case .fromTop:
            return CompletionEntryVector(x: 0, y: 1)
        case .fromBottom:
            return CompletionEntryVector(x: 0, y: -1)
        case .fromLeft:
            return CompletionEntryVector(x: -1, y: 0)
        case .fromRight:
            return CompletionEntryVector(x: 1, y: 0)
        }
    }

    static func exitVector(
        position: CompletionDisplayPosition,
        mode: CompletionEntryMode
    ) -> CompletionEntryVector {
        switch mode {
        case .automatic:
            return .zero
        case .fromEdge:
            return edgeExitVector(for: position)
        case .fromCorner:
            return cornerVector(for: position)
        case .fromTop:
            return CompletionEntryVector(x: 0, y: -1)
        case .fromBottom:
            return CompletionEntryVector(x: 0, y: 1)
        case .fromLeft:
            return CompletionEntryVector(x: -1, y: 0)
        case .fromRight:
            return CompletionEntryVector(x: 1, y: 0)
        }
    }

    private static func automaticVector(
        for position: CompletionDisplayPosition
    ) -> CompletionEntryVector {
        switch position {
        case .topLeading:
            return CompletionEntryVector(x: -1, y: 1)
        case .topTrailing:
            return CompletionEntryVector(x: 1, y: 1)
        case .bottomLeading:
            return CompletionEntryVector(x: -1, y: -1)
        case .bottomTrailing:
            return CompletionEntryVector(x: 1, y: -1)
        default:
            return edgeVector(for: position)
        }
    }

    private static func edgeVector(
        for position: CompletionDisplayPosition
    ) -> CompletionEntryVector {
        switch position {
        case .centerLeading:
            return CompletionEntryVector(x: -1, y: 0)
        case .centerTrailing:
            return CompletionEntryVector(x: 1, y: 0)
        case .bottomLeading, .bottomCenter, .bottomTrailing:
            return CompletionEntryVector(x: 0, y: -1)
        case .topLeading, .topCenter, .topTrailing, .center:
            return CompletionEntryVector(x: 0, y: 1)
        }
    }

    private static func cornerVector(
        for position: CompletionDisplayPosition
    ) -> CompletionEntryVector {
        switch position {
        case .topLeading:
            return CompletionEntryVector(x: -1, y: 1)
        case .topTrailing:
            return CompletionEntryVector(x: 1, y: 1)
        case .bottomLeading:
            return CompletionEntryVector(x: -1, y: -1)
        case .bottomTrailing:
            return CompletionEntryVector(x: 1, y: -1)
        case .centerLeading:
            return CompletionEntryVector(x: -1, y: 0)
        case .centerTrailing:
            return CompletionEntryVector(x: 1, y: 0)
        case .bottomCenter:
            return CompletionEntryVector(x: 0, y: -1)
        case .topCenter, .center:
            return CompletionEntryVector(x: 0, y: 1)
        }
    }

    private static func edgeExitVector(
        for position: CompletionDisplayPosition
    ) -> CompletionEntryVector {
        switch position {
        case .centerLeading:
            return CompletionEntryVector(x: -1, y: 0)
        case .centerTrailing:
            return CompletionEntryVector(x: 1, y: 0)
        case .bottomLeading, .bottomCenter, .bottomTrailing:
            return CompletionEntryVector(x: 0, y: 1)
        case .topLeading, .topCenter, .topTrailing, .center:
            return CompletionEntryVector(x: 0, y: -1)
        }
    }
}
