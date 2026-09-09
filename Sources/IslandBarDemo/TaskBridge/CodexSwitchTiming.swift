import Foundation
import OSLog

/// Monotonic timings with a random correlation ID, never account IDs or error payloads.
@MainActor
final class CodexSwitchTiming {
    enum Stage: String {
        case initialTaskList, initialTaskScan, preflight, sourceProfile
        case targetIdentity, sourceIdentity, finalTaskList, finalTaskScan
        case quitApplication, stopMonitor, backupCredentials, saveAccountMapping
        case installCredentials, launchApplication, verifyProfile, verifyIdentity
        case publishAccount, restoreCredentials, recoveryLaunch
    }
    enum Outcome: String { case completed, failed, cancelled }
    struct Event {
        let attempt: String
        let stage: String
        let outcome: Outcome
        let elapsedMilliseconds: Double
        let totalMilliseconds: Double
    }

    private static let logger = Logger(subsystem: "com.kiannest.islandbar", category: "AccountSwitchTiming")
    private let attempt = UUID().uuidString
    private let now: () -> TimeInterval
    private let emit: (Event) -> Void
    private let started: TimeInterval
    private var stageStarted: TimeInterval
    private var stage: Stage
    private var finished = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: ((Event) -> Void)? = nil) {
        self.now = now
        self.emit = emit ?? { event in
            Self.logger.notice("attempt=\(event.attempt, privacy: .public) stage=\(event.stage, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) elapsed_ms=\(event.elapsedMilliseconds, privacy: .public) total_ms=\(event.totalMilliseconds, privacy: .public)")
        }
        started = now()
        stageStarted = started
        stage = .initialTaskList
    }

    func begin(_ next: Stage, previousOutcome: Outcome = .completed) {
        guard !finished else { return }
        let time = now()
        record(stage.rawValue, outcome: previousOutcome, from: stageStarted, at: time)
        stage = next
        stageStarted = time
    }

    func finish(_ outcome: Outcome, stageOutcome: Outcome? = nil) {
        guard !finished else { return }
        finished = true
        let time = now()
        record(stage.rawValue, outcome: stageOutcome ?? outcome, from: stageStarted, at: time)
        record("total", outcome: outcome, from: started, at: time)
    }

    private func record(_ stage: String, outcome: Outcome, from start: TimeInterval, at end: TimeInterval) {
        emit(Event(attempt: attempt, stage: stage, outcome: outcome,
                   elapsedMilliseconds: (end - start) * 1_000,
                   totalMilliseconds: (end - started) * 1_000))
    }
}
