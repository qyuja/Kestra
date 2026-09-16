import Foundation
import OSLog

struct CodexLimitRefreshPendingEvent: Codable, Equatable, Sendable {
    let accountID: String
    let resetAt: Date
    var windows: Set<CodexLimitWindowKey>

    var key: String {
        "\(accountID)|\(Int(resetAt.timeIntervalSince1970 / 60))"
    }
}

private struct CodexLimitRefreshAccountHistory: Codable, Equatable, Sendable {
    var windows: [String: CodexLimitRefreshWindowSnapshot] = [:]
    var pending: [CodexLimitRefreshPendingEvent] = []
}

private struct CodexLimitRefreshHistory: Codable, Equatable, Sendable {
    var accounts: [String: CodexLimitRefreshAccountHistory] = [:]
}

@MainActor
final class CodexLimitRefreshHistoryStore {
    private let paths: TaskBridgePaths
    private let logger = Logger(
        subsystem: KestraAppIdentity.bundleIdentifier,
        category: "limit-refresh-history"
    )
    private var history = CodexLimitRefreshHistory()

    init(paths: TaskBridgePaths = TaskBridgePaths()) {
        self.paths = paths
        load()
    }

    func observe(
        accountID: String,
        usage: CodexAccountUsage,
        recordPending: Bool,
        now: Date = .now
    ) -> [CodexLimitRefreshPendingEvent] {
        var account = history.accounts[accountID] ?? CodexLimitRefreshAccountHistory()
        let currentSnapshots = CodexLimitResetDetector.snapshot(for: usage)

        for key in CodexLimitWindowKey.allCases {
            guard let current = currentSnapshots[key] else {
                account.windows.removeValue(forKey: key.rawValue)
                continue
            }

            let previous = account.windows[key.rawValue]
            var next = current
            next.lastSentResetAt = previous?.lastSentResetAt

            if recordPending,
               let resetAt = CodexLimitResetDetector.resetDate(
                   from: previous,
                   to: next,
                   now: now
               ) {
                mergePending(
                    CodexLimitRefreshPendingEvent(
                        accountID: accountID,
                        resetAt: resetAt,
                        windows: [key]
                    ),
                    into: &account.pending
                )
            }

            account.windows[key.rawValue] = next
        }

        history.accounts[accountID] = account
        save()
        return account.pending
    }

    func pendingEvents(for accountID: String) -> [CodexLimitRefreshPendingEvent] {
        history.accounts[accountID]?.pending ?? []
    }

    func markSent(
        accountID: String,
        resetAt: Date,
        windows: Set<CodexLimitWindowKey>
    ) {
        guard var account = history.accounts[accountID] else { return }

        account.pending.removeAll { pending in
            pending.resetAt.timeIntervalSince(resetAt).magnitude <= CodexLimitResetDetector.resetTolerance
                && !pending.windows.isDisjoint(with: windows)
        }

        for key in windows {
            guard var snapshot = account.windows[key.rawValue],
                  let observedReset = snapshot.resetsAt,
                  observedReset.timeIntervalSince(resetAt).magnitude <= CodexLimitResetDetector.resetTolerance else {
                continue
            }
            snapshot.lastSentResetAt = observedReset
            account.windows[key.rawValue] = snapshot
        }

        history.accounts[accountID] = account
        save()
    }

    private func mergePending(
        _ event: CodexLimitRefreshPendingEvent,
        into pending: inout [CodexLimitRefreshPendingEvent]
    ) {
        guard let index = pending.firstIndex(where: { $0.key == event.key }) else {
            pending.append(event)
            return
        }

        pending[index].windows.formUnion(event.windows)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: paths.limitRefreshFile.path) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = try decoder.decode(CodexLimitRefreshHistory.self, from: Data(contentsOf: paths.limitRefreshFile))
        } catch {
            logger.error("Failed to load limit refresh history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try paths.ensureBaseDirectories()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(history).write(to: paths.limitRefreshFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.limitRefreshFile.path
            )
        } catch {
            logger.error("Failed to save limit refresh history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
