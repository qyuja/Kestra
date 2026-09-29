import XCTest
import Sparkle
@testable import AgentDeputy

final class AgentDeputyUpdaterTests: XCTestCase {
    @MainActor
    func testLaunchImmediatelyChecksAndUsesHourlySchedule() {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        updater.start()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        XCTAssertEqual(engine.updateCheckInterval, 3_600)
        XCTAssertFalse(engine.automaticallyDownloadsUpdates)
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    func testDisabledAutomaticChecksStillAllowManualDetectionWithoutInstalling() {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        updater.automaticallyChecksForUpdates = false
        updater.start()
        XCTAssertEqual(engine.actions, ["start"])
        updater.checkForUpdates()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    func testOverlappingDetectionRequestsUseOnlyOneCheck() {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        updater.start()
        updater.checkForUpdates()
        updater.checkForUpdates()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    func testFailedUpdaterStartDoesNotSendCheck() {
        let engine = UpdateEngineSpy()
        engine.startError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "启动失败"])
        let updater = makeUpdater(engine: engine)
        updater.start()
        XCTAssertEqual(engine.actions, ["start"])
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.statusText, "更新器启动失败：启动失败")
    }

    @MainActor
    func testEachPanelOpenCanCheckAgainAfterPreviousCycleCompletes() {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.start()
        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
        XCTAssertTrue(updater.canCheckForUpdates)
        updater.checkForUpdatesAutomatically()
        XCTAssertEqual(engine.actions, ["start", "probe", "probe"])
        XCTAssertTrue(updater.isChecking)

        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
        updater.automaticallyChecksForUpdates = false
        updater.checkForUpdatesAutomatically()
        XCTAssertEqual(engine.actions, ["start", "probe", "probe"])
        updater.checkForUpdates()
        XCTAssertEqual(engine.actions, ["start", "probe", "probe", "probe"])
    }

    @MainActor
    func testFailedProbeClearsBusyStateAndPreservesError() {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.start()
        XCTAssertTrue(updater.isChecking)
        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation,
                        error: NSError(domain: "network", code: 1001, userInfo: [NSLocalizedDescriptionKey: "无法连接"]))
        XCTAssertFalse(updater.isChecking)
        XCTAssertFalse(updater.isInstalling)
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertEqual(updater.statusText, "更新失败：无法连接")
        updater.checkForUpdates()
        XCTAssertEqual(engine.actions, ["start", "probe", "probe"])
    }

    @MainActor
    func testDetectionRequiresExplicitInstallRequestEvenWithAutomaticChecksDisabled() throws {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.automaticallyChecksForUpdates = false
        updater.start()
        updater.checkForUpdates()
        let item = try makeUpdateItem()
        updater.updater(callbackUpdater, didFindValidUpdate: item)
        XCTAssertEqual(updater.availableVersion, "0.1.21")
        XCTAssertFalse(updater.isInstalling)
        updater.installAvailableUpdate()
        XCTAssertEqual(engine.actions, ["start", "probe"])

        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
        updater.canRestart = { false }
        updater.installAvailableUpdate()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        updater.canRestart = { true }
        updater.installAvailableUpdate()
        XCTAssertEqual(engine.actions, ["start", "probe", "install"])
        XCTAssertTrue(updater.isInstalling)

        var choice: SPUUserUpdateChoice?
        updater.showUpdateFound(with: item, state: try makeUpdateState(userInitiated: true)) { choice = $0 }
        XCTAssertEqual(choice, .install)
        updater.checkForUpdates()
        XCTAssertEqual(engine.actions, ["start", "probe", "install"])
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .install)
        updater.canRestart = { false }
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .skip)
    }

    @MainActor
    func testInformationOnlyUpdateNeverEnablesInstallButton() throws {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.start()
        let item = try makeUpdateItem(informationOnly: true)
        updater.updater(callbackUpdater, didFindValidUpdate: item)
        XCTAssertNil(updater.availableVersion)
        XCTAssertEqual(updater.statusText, "此版本需手动下载，请前往 GitHub Releases")
        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
        updater.installAvailableUpdate()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    func testNoUpdateCallbackClearsVersionAndRestoresCheckControls() throws {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.start()
        updater.updater(callbackUpdater, didFindValidUpdate: try makeUpdateItem())
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                            userInfo: [NSLocalizedDescriptionKey: "已是最新版本"])
        updater.updaterDidNotFindUpdate(callbackUpdater, error: error)
        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: error)
        XCTAssertNil(updater.availableVersion)
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertFalse(updater.isChecking)
        XCTAssertFalse(updater.isInstalling)
        XCTAssertEqual(updater.statusText, "已是最新版本")
    }

    @MainActor
    func testScheduledDiscoveryDoesNotInstallOrStartAnOverlappingManualCheck() throws {
        let engine = UpdateEngineSpy()
        let updater = makeUpdater(engine: engine)
        let callbackUpdater = ReadyCallbackUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updater, delegate: nil)
        updater.start()
        engine.sessionInProgress = false
        engine.canCheckForUpdates = true
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
        try updater.updater(callbackUpdater, mayPerform: .updatesInBackground)
        let item = try makeUpdateItem()
        updater.updater(callbackUpdater, didFindValidUpdate: item)
        updater.checkForUpdates()
        updater.installAvailableUpdate()
        XCTAssertEqual(engine.actions, ["start", "probe"])
        var choice: SPUUserUpdateChoice?
        updater.showUpdateFound(with: item, state: try makeUpdateState(userInitiated: false)) { choice = $0 }
        XCTAssertEqual(choice, .dismiss)
        XCTAssertFalse(updater.isInstalling)
        updater.updater(callbackUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        XCTAssertFalse(updater.isChecking)
        XCTAssertTrue(updater.canCheckForUpdates)
    }

    @MainActor
    func testDownloadPercentageClearsOnExtractionAndError() {
        let updater = AgentDeputyUpdater()
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        updater.showDownloadDidReceiveData(ofLength: 300)
        XCTAssertEqual(updater.downloadPercentage, 30)
        updater.showDownloadDidStartExtractingUpdate()
        XCTAssertNil(updater.downloadPercentage)
        XCTAssertEqual(updater.statusText, "正在校验并解压…")
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        updater.showDownloadDidReceiveData(ofLength: 300)
        updater.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: {})
        XCTAssertNil(updater.downloadPercentage)
    }

    @MainActor
    func testDownloadByteOverflowCannotResetProgress() {
        let updater = AgentDeputyUpdater()
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(.max)
        updater.showDownloadDidReceiveData(ofLength: .max - 1)
        updater.showDownloadDidReceiveData(ofLength: 100)
        XCTAssertEqual(updater.downloadPercentage, 100)
    }

    @MainActor
    func testDownloadProgressAccumulatesChunks() {
        let updater = AgentDeputyUpdater()
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        XCTAssertEqual(updater.statusText, "正在下载… 0%")
        updater.showDownloadDidReceiveData(ofLength: 250)
        XCTAssertEqual(updater.statusText, "正在下载… 25%")
        updater.showDownloadDidReceiveData(ofLength: 125)
        XCTAssertEqual(updater.statusText, "正在下载… 37%")
    }

    @MainActor
    func testRepeatedContentLengthPreservesReceivedBytesAndCapsPercentage() {
        let updater = AgentDeputyUpdater()
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        updater.showDownloadDidReceiveData(ofLength: 500)
        updater.showDownloadDidReceiveExpectedContentLength(2_000)
        XCTAssertEqual(updater.statusText, "正在下载… 25%")
        updater.showDownloadDidReceiveData(ofLength: 3_000)
        XCTAssertEqual(updater.statusText, "正在下载… 100%")
    }

    @MainActor
    func testNewDownloadResetsProgressAndUnknownLengthDoesNotInventPercentage() {
        let updater = AgentDeputyUpdater()
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        updater.showDownloadDidReceiveData(ofLength: 600)
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(0)
        updater.showDownloadDidReceiveData(ofLength: 400)
        XCTAssertEqual(updater.statusText, "正在后台下载…")
        updater.showDownloadDidReceiveExpectedContentLength(1_000)
        XCTAssertEqual(updater.statusText, "正在下载… 40%")
    }

    @MainActor
    func testInstallReplyRequiresManualRequestAndNoAccountSwitch() {
        let updater = AgentDeputyUpdater()
        var choice: SPUUserUpdateChoice?
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .skip)
        updater.showUserInitiatedUpdateCheck(cancellation: {})
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .install)
        updater.canRestart = { false }
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .skip)
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    func testAutomaticCheckPreferenceSurvivesRecreation() {
        let suite = "AgentDeputyUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = AgentDeputyUpdater(defaults: defaults)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        XCTAssertFalse(AgentDeputyUpdater(defaults: defaults).automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(AgentDeputyUpdater(defaults: defaults).automaticallyChecksForUpdates)
    }

    @MainActor
    func testUpdateErrorIsVisibleAndAcknowledged() {
        let updater = AgentDeputyUpdater()
        var acknowledged = false
        updater.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "校验失败"])) {
            acknowledged = true
        }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(updater.statusText, "更新失败：校验失败")
        XCTAssertFalse(updater.isInstalling)
    }

    @MainActor
    private func makeUpdater(engine: UpdateEngineSpy) -> AgentDeputyUpdater {
        let suite = "AgentDeputyUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AgentDeputyUpdater(defaults: defaults, updateEngine: engine)
    }

    private func makeUpdateItem(informationOnly: Bool = false) throws -> SUAppcastItem {
        var dictionary: [String: Any] = ["sparkle:version": "1021", "sparkle:shortVersionString": "0.1.21"]
        if informationOnly {
            dictionary["link"] = "https://example.com/release"
        } else {
            dictionary["enclosure"] = ["url": "https://example.com/AgentDeputy.zip", "length": "1000"]
        }
        // Sparkle exposes this fixture initializer but not its designated parser initializer.
        // These fixtures have no OS/application-version-dependent constraints.
        return try XCTUnwrap(SUAppcastItem(dictionary: dictionary))
    }

    private func makeUpdateState(userInitiated: Bool) throws -> SPUUserUpdateState {
        // Use Sparkle's public secure-coding initializer instead of its private state initializer.
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(SPUUserUpdateStage.notDownloaded.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        return try XCTUnwrap(SPUUserUpdateState(coder: decoder))
    }
}

@MainActor
private final class ReadyCallbackUpdater: SPUUpdater {
    override var canCheckForUpdates: Bool { true }
}

@MainActor
private final class UpdateEngineSpy: AgentDeputyUpdateEngine {
    var canCheckForUpdates = false
    var sessionInProgress = false
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    var updateCheckInterval: TimeInterval = 86_400
    var startError: Error?
    private(set) var actions: [String] = []

    func start() throws {
        actions.append("start")
        if let startError { throw startError }
        canCheckForUpdates = true
    }

    func checkForUpdates() {
        actions.append("install")
        sessionInProgress = true
        canCheckForUpdates = false
    }

    func checkForUpdateInformation() {
        actions.append("probe")
        sessionInProgress = true
        canCheckForUpdates = false
    }
}
