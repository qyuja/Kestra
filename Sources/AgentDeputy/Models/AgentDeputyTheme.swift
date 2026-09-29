import AppKit
import Combine
import Foundation
import SwiftUI

enum AgentDeputyPalette {
    // Keep the logo's violet hue, but use a softer, lighter variant over dark
    // surfaces so selected controls remain legible without a neon effect.
    private static let lightAccent = NSColor(srgbRed: 91 / 255, green: 92 / 255, blue: 226 / 255, alpha: 1)
    private static let darkAccent = NSColor(srgbRed: 193 / 255, green: 182 / 255, blue: 1, alpha: 1)

    static func nsColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? darkAccent : lightAccent
    }

    static let accentNSColor = NSColor(name: nil, dynamicProvider: nsColor(for:))
    static let accent = Color(nsColor: accentNSColor)

    static func selectedFillNSColor(for appearance: NSAppearance) -> NSColor {
        let opacity: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.25 : 0.14
        return nsColor(for: appearance).withAlphaComponent(opacity)
    }

    static let selectedFill = Color(nsColor: NSColor(name: nil, dynamicProvider: selectedFillNSColor(for:)))
}

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
