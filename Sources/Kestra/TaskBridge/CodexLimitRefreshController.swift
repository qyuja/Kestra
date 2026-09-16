import Combine
import Foundation
import OSLog

@MainActor
final class CodexLimitRefreshController {
    private struct PendingRefresh {
        let event: CodexLimitRefreshPendingEvent
        let profile: CodexAccountProfile
        let attempt: Int
        let availableAt: Date

        var key: String { event.key }
    }

    private let settings: CodexLimitRefreshSettingsStore
    private let historyStore: CodexLimitRefreshHistoryStore
    private let logger = Logger(
        subsystem: KestraAppIdentity.bundleIdentifier,
        category: "limit-refresh"
    )

    private var profilesByID: [String: CodexAccountProfile] = [:]
    private var pending: [String: PendingRefresh] = [:]
    private var active: PendingRefresh?
    private var client: CodexAppServerClient?
    private var hasRunningTasks = false
    private var cancellables = Set<AnyCancellable>()

    private(set) var lastStatus: String?

    init(
        settings: CodexLimitRefreshSettingsStore,
        historyStore: CodexLimitRefreshHistoryStore = CodexLimitRefreshHistoryStore()
    ) {
        self.settings = settings
        self.historyStore = historyStore

        settings.$isEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                guard enabled else {
                    self.stop()
                    self.lastStatus = "额度重置问候已关闭"
                    return
                }
                self.loadPersistedPendingEvents()
                self.drainIfPossible()
            }
            .store(in: &cancellables)
    }

    func observe(
        profiles: [CodexAccountProfile],
        states: [String: CodexAccountQuotaState],
        hasRunningTasks: Bool,
        now: Date = .now
    ) {
        self.hasRunningTasks = hasRunningTasks
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        for profile in profiles where profile.isEnabled {
            guard let usage = states[profile.id]?.usage else { continue }
            _ = historyStore.observe(
                accountID: profile.id,
                usage: usage,
                recordPending: settings.isEnabled,
                now: now
            )
        }

        loadPersistedPendingEvents()
        drainIfPossible()
    }

    func updateRunningTaskState(_ hasRunningTasks: Bool) {
        self.hasRunningTasks = hasRunningTasks
        if hasRunningTasks, active != nil {
            stop()
            lastStatus = "检测到运行中任务，额度重置问候已暂存"
            return
        }
        drainIfPossible()
    }

    /// Stops an in-flight greeting without deleting its durable pending event.
    /// This is used when the app is shutting down or Codex is being switched.
    func stop() {
        if let active {
            enqueue(active)
        }
        active = nil
        client?.onError = nil
        client?.stop()
        client = nil
    }

    private func loadPersistedPendingEvents() {
        guard settings.isEnabled else { return }

        for (accountID, profile) in profilesByID where profile.isEnabled {
            for event in historyStore.pendingEvents(for: accountID) {
                enqueue(
                    PendingRefresh(
                        event: event,
                        profile: profile,
                        attempt: 0,
                        availableAt: .now
                    )
                )
            }
        }
    }

    private func enqueue(_ refresh: PendingRefresh) {
        guard pending[refresh.key] == nil, active?.key != refresh.key else { return }
        pending[refresh.key] = refresh
    }

    private func drainIfPossible() {
        guard settings.isEnabled, !hasRunningTasks, active == nil, client == nil else { return }
        let staleKeys = pending.values.compactMap { refresh in
            profilesByID[refresh.event.accountID]?.isEnabled == true ? nil : refresh.key
        }
        for key in staleKeys {
            pending.removeValue(forKey: key)
        }

        guard let queued = pending.values
            .filter({ $0.availableAt <= .now })
            .sorted(by: { $0.availableAt < $1.availableAt })
            .first else { return }

        guard let currentProfile = profilesByID[queued.event.accountID], currentProfile.isEnabled else {
            pending.removeValue(forKey: queued.key)
            return
        }

        let next = PendingRefresh(
            event: queued.event,
            profile: currentProfile,
            attempt: queued.attempt,
            availableAt: queued.availableAt
        )

        pending.removeValue(forKey: next.key)
        active = next
        sendGreeting(for: next)
    }

    private func sendGreeting(for refresh: PendingRefresh) {
        let client = CodexAppServerClient(codexHome: refresh.profile.codexHomePath)
        self.client = client
        client.canContinueGreeting = { [weak self] in
            guard let self else { return false }
            return !self.hasRunningTasks && self.active?.key == refresh.key
        }
        client.onError = { [weak self] message in
            self?.finish(refresh, result: .failure(CodexLimitRefreshError.server(message)))
        }
        client.start()

        guard active?.key == refresh.key else { return }
        guard client.isRunning else {
            finish(refresh, result: .failure(CodexLimitRefreshError.server("Codex app-server 未启动")))
            return
        }

        client.sendGreeting(message: CodexLimitRefreshSettingsStore.greetingMessage) { [weak self] result in
            self?.finish(refresh, result: result)
        }
    }

    private func finish(
        _ refresh: PendingRefresh,
        result: Result<Void, Error>
    ) {
        guard active?.key == refresh.key else { return }

        active = nil
        client?.onError = nil
        client?.stop()
        client = nil

        switch result {
        case .success:
            historyStore.markSent(
                accountID: refresh.event.accountID,
                resetAt: refresh.event.resetAt,
                windows: refresh.event.windows
            )
            lastStatus = "已为 \(refresh.profile.displayName) 发送限额重置问候"
            logger.info(
                "Greeting sent after quota reset account=\(refresh.event.accountID, privacy: .public)"
            )
        case .failure(let error):
            let nextAttempt = refresh.attempt + 1
            let delay = min(300.0, 30.0 * pow(2, Double(min(refresh.attempt, 3))))
            enqueue(
                PendingRefresh(
                    event: refresh.event,
                    profile: refresh.profile,
                    attempt: nextAttempt,
                    availableAt: .now.addingTimeInterval(delay)
                )
            )
            lastStatus = "限额重置问候发送失败，将稍后重试：\(error.localizedDescription)"
            logger.error(
                "Greeting failed account=\(refresh.event.accountID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        drainIfPossible()
    }
}

private enum CodexLimitRefreshError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        }
    }
}
