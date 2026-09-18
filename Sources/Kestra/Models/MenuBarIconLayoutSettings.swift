import Combine
import Foundation
import SwiftUI

extension EnvironmentValues {
    @Entry var popoverLayoutMode: MenuBarIconLayoutMode = .normal
}

enum MenuBarIconLayoutMode: String, CaseIterable, Codable, Identifiable {
    case compact
    case normal

    var id: String { rawValue }

    func spacing(_ normal: CGFloat) -> CGFloat {
        self == .compact ? normal * 0.65 : normal
    }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .normal: "正常"
        }
    }
}

@MainActor
final class MenuBarIconLayoutSettingsStore: ObservableObject {
    @Published private(set) var mode: MenuBarIconLayoutMode

    private let defaults: UserDefaults
    private static let modeKey = "menubar.icon.layoutMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey)
            .flatMap(MenuBarIconLayoutMode.init(rawValue:)) ?? .normal
    }

    func setMode(_ mode: MenuBarIconLayoutMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }
}
