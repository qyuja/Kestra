import Combine
import Foundation

@MainActor
final class CodexLimitRefreshSettingsStore: ObservableObject {
    static let greetingMessage = "你好。请只回复一句简短的问候，不要执行任何操作。"

    private static let enabledKey = "codex.limitRefresh.enabled"

    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }

        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
