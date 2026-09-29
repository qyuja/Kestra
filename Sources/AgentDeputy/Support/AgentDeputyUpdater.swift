import Combine
import Foundation
import Sparkle

@MainActor
protocol AgentDeputyUpdateEngine: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    func start() throws
    func checkForUpdates()
    func checkForUpdateInformation()
}

extension SPUUpdater: AgentDeputyUpdateEngine {}

@MainActor
final class AgentDeputyUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusText = "尚未检查更新"
    @Published private(set) var availableVersion: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var isChecking = false
    @Published private(set) var downloadPercentage: Int?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks")
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let defaults: UserDefaults
    private var updater: (any AgentDeputyUpdateEngine)?
    private var canCheckUpdatesObservation: AnyCancellable?
    private var expectedDownloadBytes: UInt64 = 0
    private var receivedDownloadBytes: UInt64 = 0
    private var hasStarted = false
    var canRestart: () -> Bool = { true }
    var isConfigured: Bool { updater != nil }

    init(defaults: UserDefaults = .standard, updateEngine: (any AgentDeputyUpdateEngine)? = nil) {
        self.defaults = defaults
        automaticallyChecksForUpdates = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        super.init()
        if let updateEngine {
            updater = updateEngine
        } else if Self.hasSparkleConfiguration {
            let sparkleUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
            updater = sparkleUpdater
            canCheckUpdatesObservation = sparkleUpdater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        } else {
            statusText = "当前构建未配置更新源"
        }
    }

    func start() {
        guard let updater, !hasStarted else { return }
        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        // Override the old persisted 24-hour interval as well as the bundle default.
        updater.updateCheckInterval = 3_600
        // Scheduled checks only notify. Installing/relaunching requires the header button.
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            hasStarted = true
            canCheckForUpdates = updater.canCheckForUpdates
            checkForUpdatesAutomatically()
        } catch {
            statusText = "更新器启动失败：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard let updater, hasStarted, updater.canCheckForUpdates,
              !updater.sessionInProgress, !isInstalling, !isChecking else { return }
        isChecking = true
        statusText = "正在检查更新…"
        // A probe reports through SPUUpdaterDelegate and never offers installation.
        updater.checkForUpdateInformation()
        canCheckForUpdates = updater.canCheckForUpdates
    }

    func checkForUpdatesAutomatically() {
        guard automaticallyChecksForUpdates else { return }
        checkForUpdates()
    }

    func installAvailableUpdate() {
        guard let updater, hasStarted, availableVersion != nil, updater.canCheckForUpdates,
              !updater.sessionInProgress, !isInstalling, !isChecking, canRestart() else { return }
        resetDownloadProgress()
        isInstalling = true
        statusText = "正在检查更新…"
        updater.checkForUpdates()
        canCheckForUpdates = updater.canCheckForUpdates
    }

    private func resetDownloadProgress() {
        expectedDownloadBytes = 0
        receivedDownloadBytes = 0
        downloadPercentage = nil
    }

    private func updateDownloadProgress() {
        guard expectedDownloadBytes > 0 else {
            downloadPercentage = nil
            statusText = "正在后台下载…"
            return
        }
        let fraction = min(Double(receivedDownloadBytes) / Double(expectedDownloadBytes), 1)
        let percentage = Int((fraction * 100).rounded(.down))
        guard downloadPercentage != percentage else { return }
        downloadPercentage = percentage
        statusText = "正在下载… \(percentage)%"
    }

    private static var hasSparkleConfiguration: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension AgentDeputyUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updates {
            isChecking = true
            statusText = "正在检查更新…"
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !isInstalling else { return }
        if item.isInformationOnlyUpdate {
            availableVersion = nil
            statusText = "此版本需手动下载，请前往 GitHub Releases"
        } else {
            availableVersion = item.displayVersionString
            statusText = "发现新版本 \(item.displayVersionString)，点击升级"
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        statusText = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isChecking = false
        isInstalling = false
        resetDownloadProgress()
        canCheckForUpdates = updater.canCheckForUpdates
        if let error {
            let nsError = error as NSError
            if nsError.domain != SUSparkleErrorDomain || nsError.code != Int(SUError.noUpdateError.rawValue) {
                statusText = "更新失败：\(error.localizedDescription)"
            }
        }
    }
}

// Keep update feedback in the popover instead of opening Sparkle's modal windows.
// Sparkle still owns signature verification, replacement, and relaunch.
extension AgentDeputyUpdater: SPUUserDriver {
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
        if appcastItem.isInformationOnlyUpdate {
            availableVersion = nil
            statusText = "此版本需手动下载，请前往 GitHub Releases"
            isInstalling = false
            reply(.dismiss)
        } else if state.userInitiated && canRestart() {
            availableVersion = appcastItem.displayVersionString
            isInstalling = true
            statusText = "正在下载 \(appcastItem.displayVersionString)…"
            reply(.install)
        } else if state.userInitiated {
            availableVersion = appcastItem.displayVersionString
            statusText = "发现新版本 \(appcastItem.displayVersionString)，等待账号操作完成后重试"
            isInstalling = false
            reply(.dismiss)
        } else {
            availableVersion = appcastItem.displayVersionString
            statusText = "发现新版本 \(appcastItem.displayVersionString)，点击升级"
            isInstalling = false
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
        resetDownloadProgress()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        resetDownloadProgress()
        statusText = "正在后台下载…"
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadBytes = expectedContentLength
        updateDownloadProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = receivedDownloadBytes.addingReportingOverflow(length)
        receivedDownloadBytes = overflow ? .max : total
        updateDownloadProgress()
    }
    func showDownloadDidStartExtractingUpdate() {
        resetDownloadProgress()
        statusText = "正在校验并解压…"
    }
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
        statusText = "正在重启 AgentDeputy…"
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        isInstalling = false
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        isInstalling = false
        resetDownloadProgress()
    }
}
