import Foundation
import XCTest
@testable import Kestra

final class CodexLimitRefreshTests: XCTestCase {
    func testDetectorRequiresReplenishmentAfterResetBoundary() {
        let previousReset = Date(timeIntervalSince1970: 900)
        let currentReset = Date(timeIntervalSince1970: 1_300)
        let previous = CodexLimitRefreshWindowSnapshot(
            remainingPercent: 12,
            resetsAt: previousReset,
            lastSentResetAt: nil
        )
        let current = CodexLimitRefreshWindowSnapshot(
            remainingPercent: 100,
            resetsAt: currentReset,
            lastSentResetAt: nil
        )

        XCTAssertEqual(
            CodexLimitResetDetector.resetDate(
                from: previous,
                to: current,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            currentReset
        )

        let consumedAfterWindowMove = CodexLimitRefreshWindowSnapshot(
            remainingPercent: 10,
            resetsAt: currentReset,
            lastSentResetAt: nil
        )
        XCTAssertNil(
            CodexLimitResetDetector.resetDate(
                from: previous,
                to: consumedAfterWindowMove,
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    @MainActor
    func testHistoryPersistsPendingEventAndDeduplicatesIt() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KestraLimitRefresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskBridgePaths(root: root)
        let accountID = "account-a"
        let firstUsage = usage(remainingPercent: 12, resetsAt: 900)
        let resetUsage = usage(remainingPercent: 100, resetsAt: 1_300)
        let first = CodexLimitRefreshHistoryStore(paths: paths)

        XCTAssertTrue(first.observe(
            accountID: accountID,
            usage: firstUsage,
            recordPending: true,
            now: Date(timeIntervalSince1970: 1_000)
        ).isEmpty)
        let pending = first.observe(
            accountID: accountID,
            usage: resetUsage,
            recordPending: true,
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.windows, [.primary])

        let reloaded = CodexLimitRefreshHistoryStore(paths: paths)
        XCTAssertEqual(reloaded.pendingEvents(for: accountID), pending)
        XCTAssertEqual(
            reloaded.observe(
                accountID: accountID,
                usage: resetUsage,
                recordPending: true,
                now: Date(timeIntervalSince1970: 1_030)
            ),
            pending
        )

        reloaded.markSent(
            accountID: accountID,
            resetAt: Date(timeIntervalSince1970: 1_300),
            windows: [.primary]
        )
        XCTAssertTrue(reloaded.pendingEvents(for: accountID).isEmpty)
    }

    private func usage(remainingPercent: Int, resetsAt: TimeInterval) -> CodexAccountUsage {
        CodexAccountUsage(
            accountID: "account-a",
            primary: CodexAccountUsage.Window(
                remainingPercent: remainingPercent,
                minutes: 300,
                resetsAt: Date(timeIntervalSince1970: resetsAt)
            ),
            secondary: nil
        )
    }
}
