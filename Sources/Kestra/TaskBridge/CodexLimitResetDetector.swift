import Foundation

enum CodexLimitWindowKey: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
}

struct CodexLimitRefreshWindowSnapshot: Codable, Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?
    var lastSentResetAt: Date?
}

enum CodexLimitResetDetector {
    /// The server may move a rolling reset timestamp by a few seconds while
    /// serving the same snapshot. A minute is large enough to avoid treating
    /// that clock movement as a real reset.
    static let resetTolerance: TimeInterval = 60

    static func snapshot(for usage: CodexAccountUsage) -> [CodexLimitWindowKey: CodexLimitRefreshWindowSnapshot] {
        var snapshots: [CodexLimitWindowKey: CodexLimitRefreshWindowSnapshot] = [:]
        if let primary = usage.primary {
            snapshots[.primary] = CodexLimitRefreshWindowSnapshot(
                remainingPercent: primary.remainingPercent,
                resetsAt: primary.resetsAt,
                lastSentResetAt: nil
            )
        }
        if let secondary = usage.secondary {
            snapshots[.secondary] = CodexLimitRefreshWindowSnapshot(
                remainingPercent: secondary.remainingPercent,
                resetsAt: secondary.resetsAt,
                lastSentResetAt: nil
            )
        }
        return snapshots
    }

    static func resetDate(
        from previous: CodexLimitRefreshWindowSnapshot?,
        to current: CodexLimitRefreshWindowSnapshot,
        now: Date
    ) -> Date? {
        guard
            let previous,
            let previousReset = previous.resetsAt,
            let currentReset = current.resetsAt,
            currentReset.timeIntervalSince(previousReset) > resetTolerance
        else {
            return nil
        }

        // A quota reset should cross the observed reset boundary and replenish
        // the bucket. A later reset timestamp with a lower balance is normal
        // rolling-window consumption, not a reset and must not trigger a
        // message.
        let replenished = current.remainingPercent >= 95
            && current.remainingPercent >= previous.remainingPercent + 5
        let crossedBoundary = previousReset <= now && currentReset > now
        guard replenished, crossedBoundary else {
            return nil
        }

        if let lastSentResetAt = previous.lastSentResetAt,
           currentReset.timeIntervalSince(lastSentResetAt) <= resetTolerance {
            return nil
        }

        return currentReset
    }
}
