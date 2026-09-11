import Combine
import Foundation
import Sparkle

@MainActor
final class KestraUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController?
    private var canCheckUpdatesObservation: AnyCancellable?

    var isConfigured: Bool {
        updaterController != nil
    }

    override init() {
        if Self.hasSparkleConfiguration {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }

        super.init()
        if let updater = updaterController?.updater {
            canCheckForUpdates = updater.canCheckForUpdates
            canCheckUpdatesObservation = updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] canCheckForUpdates in
                    self?.canCheckForUpdates = canCheckForUpdates
                }
        }
    }

    func start() {
        guard let updaterController else { return }
        updaterController.startUpdater()
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        guard let updaterController, updaterController.updater.canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }

    private static var hasSparkleConfiguration: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
