import XCTest
import Sparkle
@testable import Kestra

final class KestraUpdaterTests: XCTestCase {
    @MainActor
    func testInstallReplyRequiresManualRequestAndNoAccountSwitch() {
        let updater = KestraUpdater()
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
        let suite = "KestraUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = KestraUpdater(defaults: defaults)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        XCTAssertFalse(KestraUpdater(defaults: defaults).automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(KestraUpdater(defaults: defaults).automaticallyChecksForUpdates)
    }

    @MainActor
    func testUpdateErrorIsVisibleAndAcknowledged() {
        let updater = KestraUpdater()
        var acknowledged = false
        updater.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "校验失败"])) {
            acknowledged = true
        }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(updater.statusText, "更新失败：校验失败")
        XCTAssertFalse(updater.isInstalling)
    }
}
