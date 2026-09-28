import Combine
import Foundation

@MainActor
final class AIProviderSelectionStore: ObservableObject {
    @Published private(set) var selectedProviders: [AIProvider]
    @Published private(set) var orderedProviders: [AIProvider]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultOrder = Self.defaultProviderOrder
        let storedOrder = defaults.string(forKey: Self.orderDefaultsKey)?
            .split(separator: ",")
            .compactMap { AIProvider(rawValue: String($0)) } ?? []
        var normalizedOrder: [AIProvider] = []
        for provider in storedOrder + defaultOrder {
            if !normalizedOrder.contains(provider) {
                normalizedOrder.append(provider)
            }
        }
        orderedProviders = normalizedOrder

        let storedValues = defaults.string(forKey: Self.defaultsKey)?
            .split(separator: ",")
            .compactMap { $0 == "claudeCowork" ? .claude : AIProvider(rawValue: String($0)) } ?? []
        let storedSet = Set(storedValues)
        selectedProviders = normalizedOrder.filter { storedSet.contains($0) }

        if selectedProviders.isEmpty {
            selectedProviders = [.codex]
        }
    }

    func isSelected(_ provider: AIProvider) -> Bool {
        selectedProviders.contains(provider)
    }

    func toggle(_ provider: AIProvider) {
        var selectedSet = Set(selectedProviders)
        if selectedProviders.contains(provider) {
            guard selectedProviders.count > 1 else { return }
            selectedSet.remove(provider)
        } else {
            selectedSet.insert(provider)
        }

        selectedProviders = orderedProviders.filter { selectedSet.contains($0) }
        persist()
    }

    func move(_ provider: AIProvider, before target: AIProvider) {
        guard let targetIndex = orderedProviders.firstIndex(of: target) else { return }
        move(provider, toInsertionIndex: targetIndex)
    }

    func move(_ provider: AIProvider, relativeTo target: AIProvider) {
        guard let sourceIndex = orderedProviders.firstIndex(of: provider),
              let targetIndex = orderedProviders.firstIndex(of: target)
        else { return }

        let insertionIndex = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        move(provider, toInsertionIndex: insertionIndex)
    }

    private func move(_ provider: AIProvider, toInsertionIndex insertionIndex: Int) {
        guard let sourceIndex = orderedProviders.firstIndex(of: provider) else { return }

        var reordered = orderedProviders
        let movedProvider = reordered.remove(at: sourceIndex)
        let adjustedIndex = sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
        reordered.insert(movedProvider, at: min(max(0, adjustedIndex), reordered.count))
        orderedProviders = reordered

        let selectedSet = Set(selectedProviders)
        selectedProviders = reordered.filter { selectedSet.contains($0) }
        persist()
    }

    private func persist() {
        defaults.set(
            selectedProviders.map(\.rawValue).joined(separator: ","),
            forKey: Self.defaultsKey
        )
        defaults.set(
            orderedProviders.map(\.rawValue).joined(separator: ","),
            forKey: Self.orderDefaultsKey
        )
    }

    private static let defaultProviderOrder = AIProvider.primaryProviders + AIProvider.additionalProviders
    private static let defaultsKey = "selectedAIProviders"
    private static let orderDefaultsKey = "orderedAIProviders"
}
