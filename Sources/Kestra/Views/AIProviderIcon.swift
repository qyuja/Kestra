import AppKit
import SwiftUI

@MainActor
enum AIProviderLogoCatalog {
    private static var cache = [String: NSImage]()

    static func image(for provider: AIProvider) -> NSImage? {
        let resourceName = provider.logoResourceName
        if let cachedImage = cache[resourceName] {
            return cachedImage
        }

        guard let resourceURL = KestraResourceBundle.bundle.url(
            forResource: resourceName,
            withExtension: "png"
        ), let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        // Icons8's source artwork is monochrome and transparent. Keeping it
        // as a template lets each surface choose an adaptive tint while the
        // provider's recognizable silhouette remains intact.
        image.isTemplate = true
        cache[resourceName] = image
        return image
    }
}

@MainActor
struct AppBrandIcon: View {
    private static var cachedLogo: NSImage?

    var size: CGFloat = 14
    var weight: Font.Weight = .semibold

    var body: some View {
        Group {
            if let logo = logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size, weight: weight))
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Kestra")
    }

    private var logoImage: NSImage? {
        if let cachedLogo = Self.cachedLogo {
            return cachedLogo
        }

        guard let resourceURL = KestraResourceBundle.bundle.url(
            forResource: "kestra-logo-icon",
            withExtension: "png"
        ), let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        Self.cachedLogo = image
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
