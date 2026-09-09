import XCTest
@testable import Kestra

final class CodexSwitchTimingTests: XCTestCase {
    @MainActor
    func testStageDurationsAndTotalAreMonotonicAndFinishOnce() {
        var time = 100.0
        var events: [CodexSwitchTiming.Event] = []
        let timing = CodexSwitchTiming(now: { time }, emit: { events.append($0) })
        time += 0.25
        timing.begin(.initialTaskScan)
        time += 0.5
        timing.finish(.completed)
        timing.finish(.failed)
        timing.begin(.preflight)
        XCTAssertEqual(events.map(\.stage), ["initialTaskList", "initialTaskScan", "total"])
        XCTAssertEqual(events.map(\.elapsedMilliseconds), [250, 500, 750])
        XCTAssertEqual(events.map(\.totalMilliseconds), [250, 750, 750])
        XCTAssertEqual(Set(events.map(\.attempt)).count, 1)
        XCTAssertTrue(events.allSatisfy { $0.outcome == .completed })
    }

    @MainActor
    func testSuccessfulRecoveryStillReportsFailedAttempt() {
        var time = 0.0
        var events: [CodexSwitchTiming.Event] = []
        let timing = CodexSwitchTiming(now: { time }, emit: { events.append($0) })
        timing.begin(.launchApplication)
        time = 2
        timing.begin(.recoveryLaunch, previousOutcome: .failed)
        time = 3
        timing.finish(.failed, stageOutcome: .completed)
        XCTAssertEqual(events.map(\.outcome), [.completed, .failed, .completed, .failed])
        XCTAssertEqual(events.last?.elapsedMilliseconds, 3000)
    }

    @MainActor
    func testCancellationClosesCurrentStageAndTotal() {
        var events: [CodexSwitchTiming.Event] = []
        let timing = CodexSwitchTiming(now: { 1 }, emit: { events.append($0) })
        timing.finish(.cancelled)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.outcome == .cancelled })
    }
}
