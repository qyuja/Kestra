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

    private(set) var isIslandVisible = false

    private var statusItemController: IslandStatusItemController?
    private var completionPanelController: CodexCompletionPanelController?

    override init() {
        taskStore = CodexTaskStore(previewSettings: previewSettings)
        super.init()
    }

    static func main() {
        do {
            try KestraAppIdentity.migrateLegacyState()
        } catch {
            NSLog("Kestra: failed to migrate legacy state: %@", error.localizedDescription)
        }

        for provider in [AIProvider.gemini, .qwen, .grok, .workbuddy, .cursor] where CommandLine.arguments.contains("--\(provider.rawValue)-hook") {
            ClaudeHookMonitor.receiveEvent(provider: provider)
            return
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

        let taskBridgeStore = taskBridgeStore
        Task {
            do {
                try await taskBridgeStore.bootstrap()
            } catch {
                NSLog("Kestra: failed to initialize task bridge: %@", error.localizedDescription)
            }
        }

        let completionPanelController = CodexCompletionPanelController(
            onOpenTask: { task in
                ApplicationLauncher.openCodexTask(task)
            },
            animationRegistry: completionAnimationRegistry,
            animationSettings: animationSettings
        )
        self.completionPanelController = completionPanelController

        let statusItemController = IslandStatusItemController(
            store: taskStore,
            providerSelection: providerSelection,
            previewSettings: previewSettings,
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
