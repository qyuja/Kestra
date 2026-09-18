import AppKit

enum QuotaProgressColor: Equatable {
    case green
    case blue
    case yellow
    case orange
    case red

    static func forRemainingPercent(_ remainingPercent: Int) -> Self {
        let percent = min(max(remainingPercent, 0), 100)
        switch percent {
        case 80...:
            return .green
        case 50..<80:
            return .blue
        case 30..<50:
            return .yellow
        case 11..<30:
            return .orange
        default:
            return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .green:
            return .systemGreen
        case .blue:
            return .systemBlue
        case .yellow:
            return .systemYellow
        case .orange:
            return .systemOrange
        case .red:
            return .systemRed
        }
    }
}
