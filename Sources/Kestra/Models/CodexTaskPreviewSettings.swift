import Combine
import Foundation

enum CodexTaskPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case firstUser = "firstUser"
    case latestUser = "latestUser"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstUser:
            "第一条"
        case .latestUser:
            "最后一条"
        }
    }

}

@MainActor
final class CodexTaskPreviewSettingsStore: ObservableObject {
    private static let modeKey = "codex.taskPreviewMode"

    @Published private(set) var mode: CodexTaskPreviewMode

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = CodexTaskPreviewMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? ""
        ) ?? .latestUser
    }

    func setMode(_ mode: CodexTaskPreviewMode) {
        guard self.mode != mode else { return }

        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }
}
