import Combine
import SwiftUI

struct CompletionAnimationConfiguration: Equatable {
    var speed: Double = 1
    var dwellDuration: Double = 5
    var displayPosition: CompletionDisplayPosition = .topCenter
    var entryMode: CompletionEntryMode = .automatic
    var dropWidth: CGFloat = 14
    var dropHeight: CGFloat = 18
    var cardCornerRadius: CGFloat = 22
    var contentRevealDelay: Double = 0.28

    static let standard = CompletionAnimationConfiguration()

    var durationScale: Double {
        1 / min(max(speed, 0.25), 3)
    }

    var entryVector: CompletionEntryVector {
        CompletionEntryVectorResolver.resolve(
            position: displayPosition,
            mode: entryMode
        )
    }

    var animationAnchor: UnitPoint {
        let vector = entryVector
        let anchorX: CGFloat = vector.x < 0 ? 0 : vector.x > 0 ? 1 : 0.5
        let anchorY: CGFloat = vector.y > 0 ? 0 : vector.y < 0 ? 1 : 0.5
        return UnitPoint(x: anchorX, y: anchorY)
    }
}

struct CompletionAnimationTransition: Equatable {
    let entryVector: CompletionEntryVector
    let exitVector: CompletionEntryVector
    let entryDuration: Double
    let exitDuration: Double

    static let fade = CompletionAnimationTransition(
        entryVector: .zero,
        exitVector: .zero,
        entryDuration: 0.42,
        exitDuration: 0.28
    )

    func entryOffset(for panelSize: CGSize) -> CGSize {
        offset(for: entryVector, panelSize: panelSize)
    }

    func exitOffset(for panelSize: CGSize) -> CGSize {
        offset(for: exitVector, panelSize: panelSize)
    }

    func replacing(
        entryVector: CompletionEntryVector,
        exitVector: CompletionEntryVector
    ) -> CompletionAnimationTransition {
        CompletionAnimationTransition(
            entryVector: entryVector,
            exitVector: exitVector,
            entryDuration: entryDuration,
            exitDuration: exitDuration
        )
    }

    private func offset(
        for vector: CompletionEntryVector,
        panelSize: CGSize
    ) -> CGSize {
        CGSize(
            width: vector.x * panelSize.width,
            height: vector.y * panelSize.height
        )
    }
}

@MainActor
protocol CompletionAnimationPlugin {
    var identifier: String { get }
    var displayName: String { get }
    var transition: CompletionAnimationTransition { get }

    func makeView(
        content: AnyView,
        configuration: CompletionAnimationConfiguration
    ) -> AnyView
}

extension CompletionAnimationPlugin {
    var transition: CompletionAnimationTransition {
        .fade
    }
}

@MainActor
final class CompletionAnimationRegistry {
    private var pluginMap: [String: any CompletionAnimationPlugin] = [:]
    private(set) var plugins: [any CompletionAnimationPlugin] = []

    init() {
        for preset in AnimateCSSAnimationPlugin.presets {
            register(AnimateCSSAnimationPlugin(preset: preset))
        }
    }

    func register(_ plugin: any CompletionAnimationPlugin) {
        if let index = plugins.firstIndex(where: { $0.identifier == plugin.identifier }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
        pluginMap[plugin.identifier] = plugin
    }

    func plugin(for identifier: String) -> (any CompletionAnimationPlugin)? {
        pluginMap[identifier]
    }
}

enum CompletionAnimationPreferences {
    static let identifierKey = "completionAnimation.identifier"
    static let speedKey = "completionAnimation.speed"
    static let dwellDurationKey = "completionAnimation.dwellDuration"
    static let displayPositionKey = "completionAnimation.displayPosition"
    static let entryModeKey = "completionAnimation.entryMode"
    static let suppressWhenProviderActiveKey = "completionAnimation.suppressWhenProviderActive"

    static func selectedIdentifier(
        from defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: identifierKey)
    }

    static func displayPosition(
        from defaults: UserDefaults = .standard
    ) -> CompletionDisplayPosition {
        guard let rawValue = defaults.string(forKey: displayPositionKey) else {
            return .topCenter
        }
        return CompletionDisplayPosition(rawValue: rawValue) ?? .topCenter
    }

    static func entryMode(
        from defaults: UserDefaults = .standard
    ) -> CompletionEntryMode {
        guard let rawValue = defaults.string(forKey: entryModeKey) else {
            return .automatic
        }
        return CompletionEntryMode(rawValue: rawValue) ?? .automatic
    }

    static func suppressWhenProviderActive(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: suppressWhenProviderActiveKey) != nil else {
            return true
        }
        return defaults.bool(forKey: suppressWhenProviderActiveKey)
    }

    static func configuration(
        from defaults: UserDefaults = .standard
    ) -> CompletionAnimationConfiguration {
        var configuration = CompletionAnimationConfiguration.standard
        if let speed = defaults.object(forKey: speedKey) as? Double {
            configuration.speed = speed
        }
        if let dwellDuration = defaults.object(forKey: dwellDurationKey) as? Double {
            configuration.dwellDuration = dwellDuration
        }
        configuration.displayPosition = displayPosition(from: defaults)
        configuration.entryMode = entryMode(from: defaults)
        return configuration
    }

    static func saveIdentifier(
        _ identifier: String,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(identifier, forKey: identifierKey)
    }

    static func saveDisplayPosition(
        _ position: CompletionDisplayPosition,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(position.rawValue, forKey: displayPositionKey)
    }

    static func saveEntryMode(
        _ entryMode: CompletionEntryMode,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(entryMode.rawValue, forKey: entryModeKey)
    }

    static func saveSuppressWhenProviderActive(
        _ suppress: Bool,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(suppress, forKey: suppressWhenProviderActiveKey)
    }
}

@MainActor
final class CompletionAnimationSettingsStore: ObservableObject {
    @Published private(set) var exitEffect: CompletionExitEffect
    @Published private(set) var exitDirection: AnimateCSSAnimationPreset
    @Published private(set) var selectedAnimationIdentifier: String
    @Published private(set) var speed: Double
    @Published private(set) var dwellDuration: Double
    @Published private(set) var displayPosition: CompletionDisplayPosition
    @Published private(set) var entryMode: CompletionEntryMode
    @Published private(set) var suppressWhenProviderActive: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        exitEffect = CompletionExitEffect(rawValue: defaults.string(forKey: "completionAnimation.exitEffect") ?? "fade") ?? .fade
        exitDirection = AnimateCSSAnimationPreset(rawValue: defaults.string(forKey: "completionAnimation.exitDirection") ?? "fadeIn") ?? .fadeIn
        let savedIdentifier = CompletionAnimationPreferences.selectedIdentifier(from: defaults)
        let hasSupportedAnimation = savedIdentifier.map {
            AnimateCSSAnimationPreset(rawValue: $0) != nil
        } ?? false
        let animationIdentifier: String
        if hasSupportedAnimation, let savedIdentifier {
            animationIdentifier = savedIdentifier
        } else {
            animationIdentifier = AnimateCSSAnimationPlugin.defaultIdentifier
            CompletionAnimationPreferences.saveIdentifier(animationIdentifier, to: defaults)
        }
        selectedAnimationIdentifier = animationIdentifier

        let configuration = CompletionAnimationPreferences.configuration(from: defaults)
        speed = min(max(configuration.speed, 0.5), 2)
        dwellDuration = min(max(configuration.dwellDuration, 1), 30)
        displayPosition = CompletionAnimationPreferences.displayPosition(from: defaults)
        // The selected fadeIn/fadeOut preset already carries its direction.
        // Normalize the legacy manual override so it cannot contradict the
        // animation selected in the settings UI.
        entryMode = .automatic
        CompletionAnimationPreferences.saveEntryMode(.automatic, to: defaults)
        suppressWhenProviderActive = CompletionAnimationPreferences
            .suppressWhenProviderActive(from: defaults)
        normalizeAnimation()
    }

    var configuration: CompletionAnimationConfiguration {
        var configuration = CompletionAnimationConfiguration.standard
        configuration.speed = speed
        configuration.dwellDuration = dwellDuration
        configuration.displayPosition = displayPosition
        configuration.entryMode = .automatic
        return configuration
    }

    func selectAnimation(identifier: String) {
        guard identifier == AnimateCSSAnimationPreset.fadeIn.rawValue || displayPosition.allowedAnimations.contains(where: { $0.rawValue == identifier }) else { return }
        selectedAnimationIdentifier = identifier
        CompletionAnimationPreferences.saveIdentifier(identifier, to: defaults)
    }

    func setSpeed(_ speed: Double) {
        let clampedSpeed = min(max(speed, 0.5), 2)
        self.speed = clampedSpeed
        defaults.set(clampedSpeed, forKey: CompletionAnimationPreferences.speedKey)
    }

    func setExitEffect(_ effect: CompletionExitEffect) {
        exitEffect = effect
        defaults.set(effect.rawValue, forKey: "completionAnimation.exitEffect")
    }

    func setExitDirection(_ direction: AnimateCSSAnimationPreset) {
        exitDirection = direction
        defaults.set(direction.rawValue, forKey: "completionAnimation.exitDirection")
    }

    func setDwellDuration(_ duration: Double) {
        let clampedDuration = min(max(duration, 1), 30)
        dwellDuration = clampedDuration
        defaults.set(
            clampedDuration,
            forKey: CompletionAnimationPreferences.dwellDurationKey
        )
    }

    func setDisplayPosition(_ position: CompletionDisplayPosition) {
        displayPosition = position
        CompletionAnimationPreferences.saveDisplayPosition(position, to: defaults)
        normalizeAnimation()
    }

    private func normalizeAnimation() {
        if selectedAnimationIdentifier != AnimateCSSAnimationPreset.fadeIn.rawValue,
           !displayPosition.allowedAnimations.contains(where: { $0.rawValue == selectedAnimationIdentifier }),
           let preset = displayPosition.allowedAnimations.first {
            selectAnimation(identifier: preset.rawValue)
        }
    }

    func setSuppressWhenProviderActive(_ suppress: Bool) {
        suppressWhenProviderActive = suppress
        CompletionAnimationPreferences.saveSuppressWhenProviderActive(
            suppress,
            to: defaults
        )
    }
}
