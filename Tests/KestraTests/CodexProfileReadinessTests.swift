import XCTest
@testable import Kestra

final class CodexProfileReadinessTests: XCTestCase {
    @MainActor
    func testRetriesMissingStartupFilesUntilReady() async throws {
        let home = URL(fileURLWithPath: "/tmp/codex-readiness")
        var probes = 0
        let profile = try await CodexRestartSwitcher.waitForSharedProfile(retryDelay: .zero) {
            probes += 1
            return try CodexSharedProfile.resolve(openFiles: probes < 3 ? [] : [
                "/tmp/codex-readiness/sqlite/codex.db",
                "/tmp/codex-desktop/Default/Local Storage/leveldb/LOCK"
            ], expectedHome: home)
        }
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(profile.home.path, home.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @MainActor
    func testConflictingHomeIsNotRetriedEvenWithoutDesktopFiles() async {
        var probes = 0
        do {
            _ = try await CodexRestartSwitcher.waitForSharedProfile(retryDelay: .zero) {
                probes += 1
                return try CodexSharedProfile.resolve(openFiles: ["/tmp/wrong/sqlite/codex.db"],
                    expectedHome: URL(fileURLWithPath: "/tmp/expected"))
            }
            XCTFail("Conflicting directory accepted")
        } catch {
            XCTAssertFalse(error is CodexSharedProfile.ProbeError)
        }
        XCTAssertEqual(probes, 1)
    }

    @MainActor
    func testMissingEvidenceExhaustsBoundedRetries() async {
        var probes = 0
        do {
            _ = try await CodexRestartSwitcher.waitForSharedProfile(attempts: 3, retryDelay: .zero) {
                probes += 1
                throw CodexSharedProfile.ProbeError.notReady
            }
            XCTFail("Missing evidence accepted")
        } catch {
            XCTAssertTrue(error is CodexSharedProfile.ProbeError)
        }
        XCTAssertEqual(probes, 3)
    }
}
