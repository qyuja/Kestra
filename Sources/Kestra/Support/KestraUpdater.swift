import Combine
import Foundation
import Sparkle

@MainActor
final class KestraUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusText = "检查并安装更新"
    @Published private(set) var availableVersion: String?
    @Published private(set) var isInstalling = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks")
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let defaults: UserDefaults
    private var updater: SPUUpdater?
    private var canCheckUpdatesObservation: AnyCancellable?
    var canRestart: () -> Bool = { true }
    var isConfigured: Bool { updater != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyChecksForUpdates = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        super.init()
        if Self.hasSparkleConfiguration {
            updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
            canCheckUpdatesObservation = updater?.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        } else {
            statusText = "当前构建未配置更新源"
        }
    }

    func start() {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        // Scheduled checks only notify. Installing/relaunching requires the header button.
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            canCheckForUpdates = updater.canCheckForUpdates
        } catch {
            statusText = "更新器启动失败：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates, !isInstalling else { return }
        isInstalling = true
        statusText = "正在检查更新…"
        updater.checkForUpdates()
    }

    private static var hasSparkleConfiguration: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// Keep update feedback in the popover instead of opening Sparkle's modal windows.
// Sparkle still owns signature verification, replacement, and relaunch.
extension KestraUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyChecksForUpdates, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        isInstalling = true
        statusText = "正在检查更新…"
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        availableVersion = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            statusText = "此版本需手动下载，请前往 GitHub Releases"
            reply(.dismiss)
        } else if state.userInitiated && canRestart() {
            isInstalling = true
            statusText = "正在下载 \(appcastItem.displayVersionString)…"
            reply(.install)
        } else {
            statusText = "发现新版本 \(appcastItem.displayVersionString)，点击升级"
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        availableVersion = nil
        statusText = error.localizedDescription
        isInstalling = false
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        statusText = "更新失败：\(error.localizedDescription)"
        isInstalling = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { statusText = "正在后台下载…" }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { statusText = "正在校验并解压…" }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard isInstalling, canRestart() else {
            statusText = "暂未安装，请等待账号操作完成后重试"
            isInstalling = false
            reply(.skip)
            return
        }
        statusText = "正在安装并重启…"
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        statusText = "正在重启 Kestra…"
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        isInstalling = false
        acknowledgement()
    }
    func dismissUpdateInstallation() { isInstalling = false }
}
