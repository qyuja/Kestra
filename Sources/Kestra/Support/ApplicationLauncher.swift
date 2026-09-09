import AppKit

@MainActor
enum ApplicationLauncher {
    static var isClaudeDesktopInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
    }

    @discardableResult
    static func openClaudeDesktop() -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(applicationURL)
    }

    static func openCodex() {
        if let url = URL(string: "codex://threads/new"), NSWorkspace.shared.open(url) {
            return
        }

        openCodexApplication()
    }

    static func openCodexTask(_ task: CodexTask) {
        if task.provider != .codex {
            // Claude Code has no task deep link here. Reveal the working directory
            // instead of accidentally routing its session identifier to Codex.
            if let path = task.path { NSWorkspace.shared.open(path) }
            return
        }
        if let url = URL(string: "codex://threads/\(task.id)"), NSWorkspace.shared.open(url) {
            return
        }

        // Older Codex builds may register the scheme without implementing
        // task routing. Opening the app is still a useful fallback when a
        // task-specific deep link is unavailable.
        openCodexApplication()
    }

    private static func openCodexApplication() {
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) {
            NSWorkspace.shared.open(applicationURL)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    }
}
