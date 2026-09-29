import AppKit

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let previewSettings = CodexTaskPreviewSettingsStore()
    let taskStore: CodexTaskStore
    let taskBridgeStore = TaskBridgeStore()
    let providerSelection = AIProviderSelectionStore()
    private let completionAnimationRegistry = CompletionAnimationRegistry()
    let animationSettings = CompletionAnimationSettingsStore()
    let limitRefreshSettings = CodexLimitRefreshSettingsStore()
    let updater = AgentDeputyUpdater()
    let launchAtLogin = AgentDeputyLaunchAtLogin()
    let themeStore = AgentDeputyThemeStore()
    let menuBarIconLayoutSettings = MenuBarIconLayoutSettingsStore()

    private(set) var isIslandVisible = false

    private var statusItemController: IslandStatusItemController?
    private var completionPanelController: CodexCompletionPanelController?

    override init() {
        taskStore = CodexTaskStore(
            previewSettings: previewSettings,
            limitRefreshSettings: limitRefreshSettings
        )
        super.init()
    }

    private static let retiredClientHookArguments: Set<String> = [
        "--cursor-hook", "--pi-hook", "--ohMyPi-hook", "--opencode-hook",
        "--gemini-hook", "--qwen-hook", "--grok-hook", "--workbuddy-hook",
    ]

    static func isRetiredClientHookInvocation(arguments: [String]) -> Bool {
        arguments.contains(where: retiredClientHookArguments.contains)
    }

    static func main() {
        // Previous releases installed callbacks in other clients. Consume
        // those stale invocations before touching application state.
        if isRetiredClientHookInvocation(arguments: CommandLine.arguments) {
            return
        }

        if CommandLine.arguments.contains("--codex-attention-hook") {
            do {
                let decision = try CodexAttentionHookMonitor.processPermissionRequest()
                if let output = CodexAttentionHookMonitor.hookOutput(for: decision) {
                    FileHandle.standardOutput.write(output)
                }
            } catch {
                FileHandle.standardError.write(Data("AgentDeputy: failed to record Codex attention event\n".utf8))
            }
            return
        }

        do {
            try AgentDeputyAppIdentity.migrateLegacyState()
        } catch {
            NSLog("AgentDeputy: failed to migrate legacy state: %@", error.localizedDescription)
        }

        if CommandLine.arguments.contains("--claude-hook") {
            ClaudeHookMonitor.receiveEvent()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is intentionally an accessory-only app. The status item popover
        // owns the task list, provider selection, settings, and actions.
        NSApp.setActivationPolicy(.accessory)
        updater.canRestart = { [weak self] in
            guard let self else { return false }
            return self.taskStore.switchingAccountID == nil
        }
        updater.start()

        let taskBridgeStore = taskBridgeStore
        Task {
            do {
                try await taskBridgeStore.bootstrap()
            } catch {
            NSLog("AgentDeputy: failed to initialize task bridge: %@", error.localizedDescription)
            }
        }

        let completionPanelController = CodexCompletionPanelController(
            onOpenTask: { task in
                ApplicationLauncher.openCodexTask(task)
            },
            onPermissionDecision: { [weak self] event, decision in
                self?.taskStore.respondToCodexPermission(event, decision: decision) ?? false
            },
            animationRegistry: completionAnimationRegistry,
            animationSettings: animationSettings,
            themeStore: themeStore
        )
        self.completionPanelController = completionPanelController

        let statusItemController = IslandStatusItemController(
            store: taskStore,
            providerSelection: providerSelection,
            previewSettings: previewSettings,
            updater: updater,
            launchAtLogin: launchAtLogin,
            limitRefreshSettings: limitRefreshSettings,
            themeStore: themeStore,
            menuBarIconLayoutSettings: menuBarIconLayoutSettings,
            onOpenTask: { task in
                ApplicationLauncher.openCodexTask(task)
            },
            onOpenCodex: { [weak self] in self?.taskStore.openCurrentCodex() },
            onOpenClaude: {
                if !ApplicationLauncher.openClaudeDesktop() {
                    NSSound.beep()
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            animationPlugins: completionAnimationRegistry,
            animationSettings: animationSettings
        )
        self.statusItemController = statusItemController

        taskStore.onTaskCompleted = { [weak self] task in
            self?.completionPanelController?.enqueue(task)
        }
        taskStore.onAttentionRequested = { [weak self] task, event in
            self?.completionPanelController?.enqueueAttention(task, event: event)
        }
        taskStore.start()
        Task {
            await taskStore.loadAccounts()
            taskStore.registerCurrentAccount()
        }

        DispatchQueue.main.async { [weak self] in
            self?.showIsland()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        taskStore.shutdownAccounts()
        taskStore.stop()
    }

    func showIsland() {
        statusItemController?.show()
        isIslandVisible = true
    }

    func hideIsland() {
        statusItemController?.hide()
        isIslandVisible = false
    }

    func toggleIsland() {
        isIslandVisible ? hideIsland() : showIsland()
    }
}
