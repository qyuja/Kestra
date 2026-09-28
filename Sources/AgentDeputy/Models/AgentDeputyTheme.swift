import Combine
import Foundation

enum AgentDeputyThemeMode: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var nextMode: Self {
        switch self {
        case .auto: .light
        case .light: .dark
        case .dark: .auto
        }
    }
}

@MainActor
final class AgentDeputyThemeStore: ObservableObject {
    private static let modeKey = "appearance.themeMode"

    @Published private(set) var mode: AgentDeputyThemeMode

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AgentDeputyThemeMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? ""
        ) ?? .auto
    }

    func setMode(_ mode: AgentDeputyThemeMode) {
        guard self.mode != mode else { return }

        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }
}
