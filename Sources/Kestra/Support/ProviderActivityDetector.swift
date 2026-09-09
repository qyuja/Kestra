import AppKit

@MainActor
enum ProviderActivityDetector {
    static func isFrontmost(_ provider: AIProvider) -> Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier else {
            return false
        }

        return provider.frontmostApplicationBundleIdentifiers.contains(bundleIdentifier)
    }
}
