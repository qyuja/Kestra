import Foundation

enum KestraResourceBundle {
    static let bundle: Bundle = {
        // Keep this name independent from Bundle.module. SwiftPM's generated
        // accessor fatal-errors when its old app-root path is absent, which is
        // exactly the layout used by a correctly packaged macOS app.
        let resourceBundleName = "Kestra_Kestra.bundle"
        let appBundleURL = Bundle.main.bundleURL
        let packagedURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(resourceBundleName, isDirectory: true)
        let legacyPackagedURL = appBundleURL.appendingPathComponent(resourceBundleName, isDirectory: true)

        if let packagedBundle = Bundle(url: packagedURL) {
            return packagedBundle
        }
        if let legacyPackagedBundle = Bundle(url: legacyPackagedURL) {
            return legacyPackagedBundle
        }

        return Bundle.module
    }()
}
