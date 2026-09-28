import AppKit
import SwiftUI

@MainActor
enum AIProviderLogoCatalog {
    private static var cache = [String: NSImage]()
    private static let supportedExtensions = ["png", "svg"]

    static func image(for provider: AIProvider) -> NSImage? {
        let resourceName = provider.logoResourceName
        if let cachedImage = cache[resourceName] {
            return cachedImage
        }

        for fileExtension in supportedExtensions {
            guard let resourceURL = AgentDeputyResourceBundle.bundle.url(
                forResource: resourceName,
                withExtension: fileExtension
            ), let image = NSImage(contentsOf: resourceURL) else {
                continue
            }

            // Icons8's source artwork is monochrome and transparent. Keeping it
            // as a template lets each surface choose an adaptive tint while the
            // provider's recognizable silhouette remains intact.
            image.isTemplate = true
            cache[resourceName] = image
            return image
        }

        return nil
    }
}

@MainActor
struct AppBrandIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    private static var cachedLogos = [String: NSImage]()

    var size: CGFloat = 14
    var weight: Font.Weight = .semibold

    var body: some View {
        Group {
            if let logo = logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size, weight: weight))
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AgentDeputyAppIdentity.displayName)
    }

    private var logoImage: NSImage? {
        let resourceName = colorScheme == .dark
            ? "agentdeputy-logo-icon-dark"
            : "agentdeputy-logo-icon"
        if let cachedLogo = Self.cachedLogos[resourceName] {
            return cachedLogo
        }

        guard let resourceURL = AgentDeputyResourceBundle.bundle.url(
            forResource: resourceName,
            withExtension: "png"
        ), let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        Self.cachedLogos[resourceName] = image
        return image
    }
}

struct AIProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 12
    var weight: Font.Weight = .semibold

    var body: some View {
        Group {
            if let logo = AIProviderLogoCatalog.image(for: provider) {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: provider.symbolName)
                    .font(.system(size: size, weight: weight))
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.name)
    }
}
