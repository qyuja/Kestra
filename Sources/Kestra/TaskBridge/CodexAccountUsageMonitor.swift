import Foundation

struct CodexAccountQuotaState {
    let usage: CodexAccountUsage?
    let error: String?
    let updatedAt: Date

    static func resolve(_ result: Result<CodexAccountIdentity, Error>, for profile: CodexAccountProfile) -> Self {
        switch result {
        case .success(let identity):
            guard identity.matches(profile) else {
                return Self(usage: nil, error: "登录身份与该账号不匹配，请重新登录", updatedAt: .now)
            }
            return Self(usage: identity.usage, error: identity.usageError, updatedAt: .now)
        case .failure(let error):
            return Self(usage: nil, error: error.localizedDescription, updatedAt: .now)
        }
    }
}

/// Polls one profile at a time so reads cannot create a burst of app-server processes.
@MainActor
final class CodexAccountUsageMonitor {
    static let refreshInterval: TimeInterval = 30
    var onUpdate: (([String: CodexAccountQuotaState]) -> Void)?
    private var states: [String: CodexAccountQuotaState] = [:]
    private var profiles: [CodexAccountProfile] = []
    private var queue: [CodexAccountProfile] = []
    private var client: CodexAppServerClient?
    private var activeID: String?
    private var timer: Timer?
    private var refreshPending = false
    private var activeAccountID: String?
    private var activeHome: URL?

    func updateProfiles(_ profiles: [CodexAccountProfile], activeAccountID: String? = nil, activeHome: URL? = nil, refreshImmediately: Bool = true) {
        self.activeAccountID = activeAccountID
        self.activeHome = activeHome
        self.profiles = profiles.filter(\.isEnabled)
        let ids = Set(self.profiles.map(\.id))
        states = states.filter { ids.contains($0.key) }
        onUpdate?(states)
        if timer == nil {
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if refreshImmediately { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.removeAll()
        refreshPending = false
        activeID = nil
        let client = client
        self.client = nil
        client?.onError = nil
        client?.stop()
    }

    private func refresh() {
        guard client == nil else { refreshPending = true; return }
        queue = profiles
        readNext()
    }

    private func readNext() {
        guard client == nil else { return }
        guard !queue.isEmpty else {
            if refreshPending {
                refreshPending = false
                refresh()
            }
            return
        }
        let profile = queue.removeFirst()
        let home = profile.id == activeAccountID ? activeHome ?? profile.codexHomePath : profile.codexHomePath
        let client = CodexAppServerClient(codexHome: home)
        self.client = client
        activeID = profile.id
        client.onError = { [weak self] message in
            self?.finish(profile: profile, state: CodexAccountQuotaState(usage: nil, error: message, updatedAt: .now))
        }
        client.start()
        guard activeID == profile.id else { return }
        client.requestAccount { [weak self] result in
            self?.finish(profile: profile, state: .resolve(result, for: profile))
        }
    }

    private func finish(profile: CodexAccountProfile, state: CodexAccountQuotaState) {
        guard activeID == profile.id else { return }
        activeID = nil
        let client = client
        self.client = nil
        client?.onError = nil
        client?.stop()
        if profiles.contains(where: { $0.id == profile.id }) {
            states[profile.id] = state
            onUpdate?(states)
        }
        // Unwind the response handler before starting another process.
        Task { @MainActor [weak self] in
            guard let self, self.timer != nil else { return }
            self.readNext()
        }
    }
}
