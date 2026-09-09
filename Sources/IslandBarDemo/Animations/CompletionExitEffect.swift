import Foundation

enum CompletionExitEffect: String, CaseIterable, Identifiable {
    case fade, shrink, fragments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fade: return "淡出"
        case .shrink: return "缩小消失"
        case .fragments: return "碎片消散"
        }
    }
}

enum CompletionPreviewRequest {
    case full
    case entrance(String)
    case exit(CompletionExitEffect)
    case fadeExit(AnimateCSSAnimationPreset)
}
