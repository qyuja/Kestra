import Combine
import AppKit
import Foundation
import OSLog

@MainActor
final class CodexTaskStore: ObservableObject {
    let claudeAccounts = ClaudeAccountStore()
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var isConnected = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCompletedTask: CodexTask?
    @Published private(set) var claudeStatus = "正在检查 Claude Code…"
    private let claudeMonitor = ClaudeHookMonitor()
    private var claudeTasks: [CodexTask] = []
    private var otherTasks: [CodexTask] = []
    @Published private(set) var cliStatuses: [AIProvider: String] = [:]
    private let cliMonitors = AIProvider.hookProviders.map { provider in
        (provider, ClaudeHookMonitor(directory: ClaudeHookMonitor.eventsDirectory.deletingLastPathComponent().appendingPathComponent(provider.rawValue + "-events"), provider: provider))
    }

    func connectCLI(_ provider: AIProvider) {
        do { try CLIHookIntegration(provider: provider).connect(); refreshClaude() }
        catch { cliStatuses[provider] = "连接失败：\(error.localizedDescription)" }
    }

    func connectClaude() {
        do { try ClaudeHookMonitor.installHooks(); refreshClaude() }
        catch { claudeStatus = "连接失败：\(error.localizedDescription)" }
    }

    private func refreshClaude() {
        otherTasks = []
        for (provider, monitor) in cliMonitors {
            let integration = CLIHookIntegration(provider: provider)
            let snapshot = monitor.poll(mode: previewSettings.mode)
            otherTasks += snapshot.tasks
            cliStatuses[provider] = monitor.error ?? (!integration.installed ? "本机尚未安装，或未找到 \(provider.name)" : !integration.configured ? "未找到监听配置" : "当前没任务")
            for task in snapshot.completed {
                lastCompletedTask = task
                onTaskCompleted?(task)
            }
        }
        let snapshot = claudeMonitor.poll(mode: previewSettings.mode)
        claudeTasks = snapshot.tasks
        if let error = claudeMonitor.error { claudeStatus = error }
        else if ClaudeHookMonitor.executable == nil { claudeStatus = "本机尚未安装 Claude Code，或未找到 claude 可执行文件" }
        else if !ClaudeHookMonitor.isConfigured { claudeStatus = "未找到 Claude Code 监听配置" }
        else { claudeStatus = "当前没任务" }
        reconcileTasks()
        for task in snapshot.completed {
            lastCompletedTask = task
            onTaskCompleted?(task)
        }
    }

    private let logger = Logger(
        subsystem: "com.kiannest.islandbar",
        category: "codex-monitor"
    )
    private var switchTiming: CodexSwitchTiming?

    var totalTaskCount: Int {
        tasks.count
    }

    var runningTaskCount: Int {
        tasks.reduce(into: 0) { count, task in
            if task.isRunning { count += 1 }
        }
    }

    func tasks(for provider: AIProvider) -> [CodexTask] {
        tasks.filter { $0.provider == provider }
    }

    func runningTasks(for provider: AIProvider) -> [CodexTask] {
        tasks(for: provider).filter(\.isRunning)
    }

    func runningTaskCount(for provider: AIProvider) -> Int {
        runningTasks(for: provider).count
    }

    func recentTasks(for provider: AIProvider) -> [CodexTask] {
        tasks(for: provider)
            .filter { !$0.isRunning }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map { $0 }
    }

    var runningTasks: [CodexTask] {
        runningTasks(for: .codex)
    }

    var recentTasks: [CodexTask] {
        recentTasks(for: .codex)
    }

    var onTaskCompleted: ((CodexTask) -> Void)?

    private let appServerClient: CodexAppServerClient
    @Published private(set) var accountProfiles: [CodexAccountProfile] = []
    @Published private(set) var currentAccountEmail: String?
    @Published private(set) var currentAccountID: String?
    @Published private(set) var accountQuotas: [String: CodexAccountQuotaState] = [:]
    private let accountUsageMonitor = CodexAccountUsageMonitor()
    @Published private(set) var isAddingAccount = false
    @Published private(set) var switchingAccountID: String?
    private let accountLogin = CodexAccountLogin()
    private let restartSwitcher = CodexRestartSwitcher()
    private var switchCheckTimeout: Task<Void, Never>?
    @Published private(set) var accountSwitchError: String?
    @Published private(set) var isRegisteringAccount = false
    @Published private(set) var accountMessage: String?
    private let accountStore = TaskBridgeStore()

    func addAccount() { loginAccount(replacing: nil) }

    func reloginAccount(_ profile: CodexAccountProfile) {
        guard profile.id != currentAccountID else {
            accountMessage = "当前账号请先在 Codex 中重新登录；此入口只更新非当前账号的登录缓存"
            return
        }
        loginAccount(replacing: profile)
    }

    func renameAccount(_ profile: CodexAccountProfile, name: String) {
        guard !isAddingAccount, switchingAccountID == nil, !isRegisteringAccount else { return }
        isRegisteringAccount = true
        Task {
            defer { isRegisteringAccount = false }
            do {
                accountProfiles = try await accountStore.renameAccount(id: profile.id, name: name)
                accountMessage = "备注已保存"
            } catch { accountMessage = error.localizedDescription }
        }
    }

    func removeAccount(_ profile: CodexAccountProfile) {
        guard profile.id != currentAccountID, !isAddingAccount,
              switchingAccountID == nil, !isRegisteringAccount else { return }
        isRegisteringAccount = true
        accountUsageMonitor.stop()
        Task {
            defer { isRegisteringAccount = false; refreshAccountMonitoring() }
            do {
                accountProfiles = try await accountStore.removeAccount(id: profile.id)
                accountMessage = "已移除登记，登录缓存、项目和历史保留"
            } catch { accountMessage = error.localizedDescription }
        }
    }

    private func loginAccount(replacing profile: CodexAccountProfile?) {
        guard !isAddingAccount, switchingAccountID == nil, !isRegisteringAccount else { return }
        isAddingAccount = true
        accountMessage = "请在浏览器中登录其他账号"
        accountLogin.start { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                defer { self.isAddingAccount = false }
                do {
                    var (identity, home) = try result.get()
                    identity.workspaceID = try CodexCredentialSwap.workspaceID(at: home)
                    if let profile {
                        self.accountProfiles = try await self.accountStore.renewAccount(id: profile.id, identity: identity, home: home)
                    } else {
                        self.accountProfiles = try await self.accountStore.registerAccount(
                        email: identity.email, planType: identity.planType, codexHome: home,
                        workspaceID: identity.workspaceID
                    )
                    }
                    self.accountMessage = profile == nil ? "账号已添加" : "登录已更新，可以切换到此账号"
                    self.refreshAccountMonitoring()
                } catch { self.accountMessage = error.localizedDescription }
            }
        }
    }

    func cancelAccountLogin() { accountLogin.cancel() }

    func shutdownAccounts() {
        claudeAccounts.cancelLogin()
        switchTiming?.finish(.cancelled)
        switchTiming = nil
        accountUsageMonitor.stop()
        accountLogin.cancel()
        switchCheckTimeout?.cancel()
        switchingAccountID = nil
    }

    func openCurrentCodex() {
        ApplicationLauncher.openCodex()
    }

    var accountSwitchBlockedReason: String? {
        CodexAccountSwitchPolicy.blockingReason(
            runningCount: runningTaskCount, connected: isConnected,
            lastUpdated: lastUpdated, hasError: lastError != nil
        )
    }

    func dismissAccountSwitchError() { accountSwitchError = nil }

    private func refreshAccountMonitoring(refreshImmediately: Bool = true) {
        accountUsageMonitor.updateProfiles(accountProfiles, activeAccountID: currentAccountID, activeHome: appServerClient.codexHome, refreshImmediately: refreshImmediately)
    }

    func switchAccount(_ profile: CodexAccountProfile) {
        guard switchingAccountID == nil, !isAddingAccount, !isRegisteringAccount else { return }
        guard profile.id != currentAccountID else { return }
        if let reason = accountSwitchBlockedReason { accountSwitchError = reason; return }
        switchingAccountID = profile.id
        switchTiming = CodexSwitchTiming()
        accountMessage = nil
        switchCheckTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.finishAccountSwitch(error: "检查任务状态超时，未切换账号")
        }
        appServerClient.requestThreadList { [weak self] result in
            guard let self, self.switchingAccountID == profile.id else { return }
            Task { @MainActor in
                do {
                    let records = try result.get()
                    self.switchTiming?.begin(.initialTaskScan)
                    guard records.allSatisfy({ record in
                        record.path.map { FileManager.default.isReadableFile(atPath: $0.path) } == true
                    }) else {
                        self.finishAccountSwitch(error: "部分任务状态不可读，未切换账号")
                        return
                    }
                    let snapshot = await CodexSessionActivityReader().snapshot(records: records)
                    guard self.switchingAccountID == profile.id else { return }
                    guard snapshot.unknownThreadIDs.isEmpty else {
                        self.finishAccountSwitch(error: "部分任务缺少可确认的生命周期状态，未切换账号")
                        return
                    }
                    guard snapshot.activeThreadIDs.isEmpty, self.accountSwitchBlockedReason == nil else {
                        self.finishAccountSwitch(error: self.accountSwitchBlockedReason ?? "任务已开始运行，未切换账号")
                        return
                    }
                    self.switchCheckTimeout?.cancel()
                    self.switchCheckTimeout = nil
                    try await self.restartCodex(into: profile)
                    self.finishAccountSwitch(error: nil)
                } catch { self.finishAccountSwitch(error: error.localizedDescription) }
            }
        }
    }

    private func finishAccountSwitch(error: String?) {
        switchTiming?.finish(error == nil ? .completed : .failed)
        switchTiming = nil
        switchCheckTimeout?.cancel()
        switchCheckTimeout = nil
        accountMessage = error
        accountSwitchError = error
        switchingAccountID = nil
    }

    private func restartCodex(into target: CodexAccountProfile) async throws {
        switchTiming?.begin(.preflight)
        typealias SwitchError = CodexCredentialSwap.SwitchError
        guard let source = accountProfiles.first(where: { $0.id == currentAccountID }) else {
            throw SwitchError("无法确认当前账号，未切换")
        }
        let activeHome = appServerClient.codexHome
        guard target.codexHomePath.standardizedFileURL.resolvingSymlinksInPath() != activeHome else {
            throw SwitchError("目标账号没有独立登录缓存，请重新添加账号")
        }
        try CodexCredentialSwap.validateFileAuth(at: activeHome)
        try CodexCredentialSwap.validateFileAuth(at: target.codexHomePath)
        let app = try restartSwitcher.currentApplication()
        switchTiming?.begin(.sourceProfile)
        let sharedProfile = try await restartSwitcher.sharedProfile(of: app, expectedHome: activeHome)
        guard let appURL = app.bundleURL else { throw SwitchError("无法确定当前 Codex 应用位置") }
        accountUsageMonitor.stop()
        defer { refreshAccountMonitoring(refreshImmediately: false) }
        switchTiming?.begin(.targetIdentity)
        let targetIdentity = try await restartSwitcher.identity(at: target.codexHomePath)
        guard targetIdentity.matches(target) else { throw SwitchError("目标账号登录态不匹配，请重新添加") }
        switchTiming?.begin(.sourceIdentity)
        let sourceIdentity = try await restartSwitcher.identity(at: activeHome)
        guard sourceIdentity.matches(source) else { throw SwitchError("当前登录账号已变化，请重新打开 IslandBar 同步") }

        // Refresh the complete task list after the slower identity checks.
        switchTiming?.begin(.finalTaskList)
        let records = try await latestRecordsForSwitch()
        switchTiming?.begin(.finalTaskScan)
        guard records.allSatisfy({ $0.path.map { FileManager.default.isReadableFile(atPath: $0.path) } == true }) else {
            throw SwitchError("部分任务状态不可读，未关闭 Codex")
        }
        let snapshot = await CodexSessionActivityReader().snapshot(records: records)
        guard snapshot.unknownThreadIDs.isEmpty else { throw SwitchError("部分任务状态无法确认，未关闭 Codex") }
        guard snapshot.activeThreadIDs.isEmpty, accountSwitchBlockedReason == nil else {
            throw SwitchError(accountSwitchBlockedReason ?? "任务已开始运行，未关闭 Codex")
        }
        // No force-quit: if the app refuses or asks to save, leave its login intact.
        switchTiming?.begin(.quitApplication)
        try await restartSwitcher.quit(app)
        switchTiming?.begin(.stopMonitor)
        stop()
        defer { start() }
        let backup = TaskBridgePaths.defaultRoot.appendingPathComponent("switches/\(UUID().uuidString.lowercased())", isDirectory: true)
        let swap = CodexCredentialSwap(activeHome: activeHome, backupDirectory: backup)
        let savedHome = source.codexHomePath.standardizedFileURL.resolvingSymlinksInPath() == activeHome
            ? TaskBridgePaths.defaultRoot.appendingPathComponent("profiles/\(UUID().uuidString.lowercased())/codex", isDirectory: true)
            : source.codexHomePath
        var prepared = false
        var launched = false
        do {
            switchTiming?.begin(.backupCredentials)
            try swap.prepare(targetHome: target.codexHomePath, savedCurrentHome: savedHome)
            prepared = true
            switchTiming?.begin(.saveAccountMapping)
            accountProfiles = try await accountStore.relocateAccount(id: source.id, home: savedHome)
            switchTiming?.begin(.installCredentials)
            try swap.install(targetHome: target.codexHomePath)
            switchTiming?.begin(.launchApplication)
            let newApp = try await restartSwitcher.launch(appURL: appURL, profile: sharedProfile)
            launched = true
            switchTiming?.begin(.verifyProfile)
            let actualProfile = try await restartSwitcher.sharedProfile(of: newApp, expectedHome: activeHome)
            guard actualProfile == sharedProfile else { throw SwitchError("重启后未复用原桌面设置目录，未确认切换成功") }
            switchTiming?.begin(.verifyIdentity)
            let verified = try await restartSwitcher.identity(at: activeHome)
            guard verified.matches(target) else { throw SwitchError("重启后的账号校验未通过") }
            switchTiming?.begin(.publishAccount)
            currentAccountID = target.id
            currentAccountEmail = verified.email
        } catch {
            if !launched, NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
                do {
                    switchTiming?.begin(.restoreCredentials, previousOutcome: .failed)
                    if prepared { try swap.restore() }
                    switchTiming?.begin(.recoveryLaunch)
                    _ = try await restartSwitcher.launch(appURL: appURL, profile: sharedProfile)
                    switchTiming?.finish(.failed, stageOutcome: .completed)
                } catch {
                    currentAccountID = nil
                    throw SwitchError("切换和恢复启动均未完成。登录备份保存在：\(backup.path)")
                }
            } else if launched {
                // Never close a newly running app again without another idle check.
                currentAccountID = nil
                currentAccountEmail = nil
            }
            throw error
        }
    }

    private func latestRecordsForSwitch() async throws -> [CodexThreadRecord] {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !finished else { return }
                finished = true
                continuation.resume(throwing: CodexCredentialSwap.SwitchError("检查任务状态超时"))
            }
            appServerClient.requestThreadList { result in
                guard !finished else { return }
                finished = true
                timeout.cancel()
                continuation.resume(with: result)
            }
        }
    }

    func loadAccounts() async {
        do { accountProfiles = try await accountStore.loadAccountProfiles() }
        catch { accountMessage = "读取账号列表失败：\(error.localizedDescription)" }
    }

    func registerCurrentAccount() {
        guard !isRegisteringAccount, switchingAccountID == nil else { return }
        isRegisteringAccount = true
        accountMessage = nil
        appServerClient.requestAccount { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                defer {
                    self.isRegisteringAccount = false
                    self.refreshAccountMonitoring()
                }
                do {
                    let identity = try result.get()
                    self.currentAccountEmail = identity.email
                    let home = self.appServerClient.codexHome
                    if !self.accountProfiles.contains(where: { identity.matches($0) }) {
                        self.accountProfiles = try await self.accountStore.registerAccount(
                        email: identity.email, planType: identity.planType, codexHome: home,
                        workspaceID: identity.usage?.accountID
                        )
                    }
                    self.currentAccountID = self.accountProfiles.first { identity.matches($0) }?.id
                    self.accountMessage = "当前账号已登记"
                } catch {
                    self.currentAccountEmail = nil
                    self.currentAccountID = nil
                    self.accountMessage = "添加账号失败：\(error.localizedDescription)"
                }
            }
        }
    }
    private let previewSettings: CodexTaskPreviewSettingsStore
    private var activityReader = CodexSessionActivityReader()
    private var monitoringGeneration = 0
    private var activeStateTimer: Timer?
    private var metadataTimer: Timer?
    private var latestMessageTask: Task<Void, Never>?
    private var latestMessageRequestID = 0
    private var isMonitoring = false
    private var isRefreshing = false
    private var isReadingActivity = false
    private var isReadingLatestMessages = false
    private var activeThreadIDs = Set<String>()
    private var monitoredRecords: [CodexThreadRecord] = []
    private var knownTasksByID = [String: CodexTask]()
    private var pendingCompletionEvents: [String: CodexTaskCompletionEvent] = [:]
    private let sessionReader = CodexSessionReader()

    private let activeStatePollingInterval: TimeInterval = 0.5
    private let metadataPollingInterval: TimeInterval = 2.0

    init(previewSettings: CodexTaskPreviewSettingsStore) {
        self.previewSettings = previewSettings
        appServerClient = CodexAppServerClient()
        accountUsageMonitor.onUpdate = { [weak self] states in self?.accountQuotas = states }

        appServerClient.onConnectionChanged = { [weak self] connected in
            self?.isConnected = connected
        }
        appServerClient.onError = { [weak self] message in
            self?.lastError = message
        }
        appServerClient.onActivityChanged = { [weak self] in
            self?.refreshFromActivityNotification()
        }
    }

    func start() {
        guard !isMonitoring else { return }

        isMonitoring = true
        refreshClaude()

        appServerClient.start()
        refreshTasks()

        let activeStateTimer = Timer(
            timeInterval: activeStatePollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.readActivity()
                self?.refreshClaude()
            }
        }
        RunLoop.main.add(activeStateTimer, forMode: .common)
        self.activeStateTimer = activeStateTimer

        let metadataTimer = Timer(
            timeInterval: metadataPollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTasks()
            }
        }
        RunLoop.main.add(metadataTimer, forMode: .common)
        self.metadataTimer = metadataTimer
    }

    func stop() {
        monitoringGeneration += 1
        isRefreshing = false
        isReadingActivity = false
        isMonitoring = false
        activeStateTimer?.invalidate()
        activeStateTimer = nil
        metadataTimer?.invalidate()
        metadataTimer = nil
        latestMessageTask?.cancel()
        latestMessageTask = nil
        latestMessageRequestID += 1
        isReadingLatestMessages = false
        monitoredRecords.removeAll(keepingCapacity: false)
        appServerClient.stop()
    }

    func refreshNow() {
        refreshClaude()
        refreshTasks()
        readActivity()
    }

    private func refreshFromActivityNotification() {
        guard isMonitoring else { return }

        // app-server notifications are a low-latency hint. Session events are
        // still polled because another Codex process owns the actual turn.
        readActivity()
        refreshTasks()
    }

    private func refreshTasks() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = monitoringGeneration

        appServerClient.requestThreadList { [weak self] result in
            guard let self else { return }
            guard generation == self.monitoringGeneration else { return }
            self.isRefreshing = false

            switch result {
            case .success(let records):
                self.lastError = nil
                self.lastUpdated = .now
                self.monitoredRecords = records
                self.apply(records: records)
                self.refreshLatestMessages(for: records)
                self.readActivity(for: records)
                self.emitPendingCompletionsIfPossible()
                self.logger.debug(
                    "Codex snapshot tasks=\(self.tasks.count, privacy: .public) running=\(self.runningTaskCount, privacy: .public)"
                )
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.logger.error("Codex snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func refreshLatestMessages(for records: [CodexThreadRecord]) {
        latestMessageTask?.cancel()
        latestMessageTask = nil
        latestMessageRequestID += 1
        let requestID = latestMessageRequestID

        let recordsToRead = recordsForVisibleCards(from: records)
        guard !recordsToRead.isEmpty else {
            isReadingLatestMessages = false
            return
        }
        let previewMode = previewSettings.mode
        let sessionReader = self.sessionReader
        isReadingLatestMessages = true

        let readTask = Task { @MainActor [weak self] in
            let messages = await sessionReader.latestMessages(
                for: recordsToRead,
                mode: previewMode
            )

            let models = await sessionReader.models(for: recordsToRead)
            guard let self else { return }
            guard requestID == self.latestMessageRequestID else { return }
            self.isReadingLatestMessages = false
            guard self.isMonitoring, !Task.isCancelled else { return }
            self.applyLatestMessages(messages)
            for (id, configuration) in models {
                self.knownTasksByID[id]?.model = configuration.model
                self.knownTasksByID[id]?.effort = configuration.effort
            }
            self.reconcileTasks()
        }
        latestMessageTask = readTask
    }

    private func recordsForVisibleCards(
        from records: [CodexThreadRecord]
    ) -> [CodexThreadRecord] {
        let runningRecords = records
            .filter { activeThreadIDs.contains($0.id) }
            .prefix(8)
        let runningIDs = Set(runningRecords.map(\.id))
        let recentRecords = records
            .filter { !activeThreadIDs.contains($0.id) && !runningIDs.contains($0.id) }
            .prefix(6)

        return Array(runningRecords) + Array(recentRecords)
    }

    private func applyLatestMessages(_ messages: [String: String]) {
        var didChange = false

        for (threadID, message) in messages {
            guard let task = knownTasksByID[threadID], task.summary != message else {
                continue
            }

            knownTasksByID[threadID] = CodexTask(
                id: task.id,
                title: task.title,
                summary: message,
                updatedAt: task.updatedAt,
                path: task.path,
                isRunning: task.isRunning,
                model: task.model,
                effort: task.effort,
                startedAt: task.startedAt,
                endedAt: task.endedAt
            )
            didChange = true
        }

        if didChange {
            reconcileTasks()
        }
    }

    private func readActivity() {
        readActivity(for: monitoredRecords)
    }

    private func readActivity(for records: [CodexThreadRecord]) {
        guard !isReadingActivity else { return }
        guard !records.isEmpty else { return }

        isReadingActivity = true
        let generation = monitoringGeneration
        let activityReader = self.activityReader
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                await activityReader.snapshot(records: records)
            }.value

            guard let self else { return }
            guard generation == self.monitoringGeneration else { return }
            self.isReadingActivity = false

            guard self.isMonitoring else { return }
            self.applyActivity(snapshot)
        }
    }

    private func applyActivity(_ snapshot: CodexActivitySnapshot) {
        activeThreadIDs = snapshot.activeThreadIDs
        for (id, date) in snapshot.startedAt {
            knownTasksByID[id]?.startedAt = date
            knownTasksByID[id]?.endedAt = nil
        }
        for (id, date) in snapshot.endedAt { knownTasksByID[id]?.endedAt = date }
        for completion in snapshot.completedTasks {
            pendingCompletionEvents[completion.id] = completion
        }

        reconcileTasks()
        emitPendingCompletionsIfPossible()
        logger.debug(
            "Codex activity active=\(self.activeThreadIDs.count, privacy: .public) completed=\(snapshot.completedTasks.count, privacy: .public)"
        )
    }

    private func apply(records: [CodexThreadRecord]) {
        var nextTasksByID = [String: CodexTask](minimumCapacity: records.count)

        for record in records {
            let previousTask = knownTasksByID[record.id]
            let summary = previousTask?.summary ?? record.summary
            nextTasksByID[record.id] = CodexTask(
                id: record.id,
                title: record.title,
                summary: summary,
                updatedAt: record.updatedAt,
                path: record.path,
                isRunning: activeThreadIDs.contains(record.id),
                model: previousTask?.model,
                effort: previousTask?.effort,
                startedAt: previousTask?.startedAt,
                endedAt: previousTask?.endedAt
            )
        }

        // A running lock can be observed a moment before thread/list catches
        // up. Keep a small placeholder so the running count remains honest.
        for threadID in activeThreadIDs where nextTasksByID[threadID] == nil {
            let previousTask = knownTasksByID[threadID]
            nextTasksByID[threadID] = CodexTask(
                id: threadID,
                title: previousTask?.title ?? "Codex 任务",
                summary: previousTask?.summary ?? "正在运行，等待任务信息同步…",
                updatedAt: previousTask?.updatedAt ?? .now,
                path: previousTask?.path,
                isRunning: true,
                model: previousTask?.model,
                effort: previousTask?.effort,
                startedAt: previousTask?.startedAt,
                endedAt: previousTask?.endedAt
            )
        }

        knownTasksByID = nextTasksByID
        reconcileTasks()
    }

    private func reconcileTasks() {
        let nextTasks = (knownTasksByID.values
            .map { task in
                var task = task
                task.isRunning = activeThreadIDs.contains(task.id)
                return task
            }
            + claudeTasks + otherTasks).sorted {
                if $0.isRunning != $1.isRunning {
                    return $0.isRunning && !$1.isRunning
                }
                return $0.updatedAt > $1.updatedAt
            }

        if tasks != nextTasks {
            tasks = nextTasks
        }
    }

    private func emitPendingCompletionsIfPossible() {
        guard !pendingCompletionEvents.isEmpty else { return }

        let events = pendingCompletionEvents.values.sorted {
            $0.id < $1.id
        }

        for event in events {
            guard let task = knownTasksByID[event.threadID] ?? tasks.first(where: { $0.id == event.threadID }) else {
                continue
            }

            pendingCompletionEvents.removeValue(forKey: event.id)
            let completedTask = CodexTask(
                id: task.id,
                title: task.title,
                summary: task.summary,
                updatedAt: task.updatedAt,
                path: task.path,
                isRunning: false,
                model: task.model,
                effort: task.effort,
                startedAt: task.startedAt,
                endedAt: task.endedAt
            )
            lastCompletedTask = completedTask
            onTaskCompleted?(completedTask)
            logger.info(
                "Codex task completed id=\(event.threadID, privacy: .public) turn=\(event.turnID, privacy: .public)"
            )
        }
    }
}
