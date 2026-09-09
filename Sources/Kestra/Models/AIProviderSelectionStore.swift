import Combine
import Foundation

@MainActor
final class AIProviderSelectionStore: ObservableObject {
    @Published private(set) var selectedProviders: [AIProvider]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedValues = defaults.string(forKey: Self.defaultsKey)?
            .split(separator: ",")
            .compactMap { $0 == "claudeCowork" ? .claude : AIProvider(rawValue: String($0)) } ?? []
        let storedSet = Set(storedValues)
        selectedProviders = AIProvider.allCases.filter { storedSet.contains($0) }

        if selectedProviders.isEmpty {
            selectedProviders = [.codex]
        }
    }

    func isSelected(_ provider: AIProvider) -> Bool {
        selectedProviders.contains(provider)
    }

    func toggle(_ provider: AIProvider) {
        if selectedProviders.contains(provider) {
            guard selectedProviders.count > 1 else { return }
            selectedProviders.removeAll { $0 == provider }
        } else {
            selectedProviders.append(provider)
            selectedProviders = AIProvider.allCases.filter { selectedProviders.contains($0) }
        }

        persist()
    }

    private func persist() {
        defaults.set(
            selectedProviders.map(\.rawValue).joined(separator: ","),
            forKey: Self.defaultsKey
        )
    }

    private static let defaultsKey = "selectedAIProviders"
}
