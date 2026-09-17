import Combine
import Foundation

enum KestraThemeMode: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
final class KestraThemeStore: ObservableObject {
    private static let modeKey = "appearance.themeMode"

    @Published private(set) var mode: KestraThemeMode

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = KestraThemeMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? ""
        ) ?? .dark
    }

    func setMode(_ mode: KestraThemeMode) {
        guard self.mode != mode else { return }

        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }
}
