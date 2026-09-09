import Foundation

/// Local command hooks carry the official Claude Code lifecycle JSON on stdin.
@MainActor
final class ClaudeHookMonitor {
    static let eventsDirectory = KestraAppIdentity.applicationSupportDirectory
        .appendingPathComponent("claude-events", isDirectory: true)
    static let legacyEventsDirectory = KestraAppIdentity.legacyApplicationSupportDirectory
        .appendingPathComponent("claude-events", isDirectory: true)
    static var configDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        paths += [home.path + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths += versions.map { $0.appendingPathComponent("bin/claude").path }
        }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private var seen = Set<String>()
    private var sessions: [String: CodexTask] = [:]
    private var firstPrompts: [String: String] = [:]
    private var lastPrompts: [String: String] = [:]
    private var initialized = false
    private(set) var error: String?
    private let directories: [URL]
    private let provider: AIProvider

    init(directory: URL = ClaudeHookMonitor.eventsDirectory, provider: AIProvider = .claude, legacyDirectory: URL? = nil) {
        self.directories = [directory] + (legacyDirectory.map { [$0] } ?? []).filter { $0 != directory }
        self.provider = provider
    }

    static func receiveEvent(provider: AIProvider = .claude) {
        if provider == .claude && ProcessInfo.processInfo.environment["GROK_SESSION_ID"] != nil { return }
        let eventsDirectory = provider == .claude ? Self.eventsDirectory : Self.eventsDirectory.deletingLastPathComponent().appendingPathComponent(provider.rawValue + "-events")
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if provider == .cursor {
                guard let normalized = CursorHookIntegration.normalize(object) else { return }
                object = normalized
            }
            if provider == .workbuddy, object["hook_event_name"] == nil {
                object["hook_event_name"] = CommandLine.arguments.last
            }
            if provider == .grok {
                object["session_id"] = object["sessionId"]
                if object["subagentType"] != nil { return }
                if object["hook_event_name"] as? String == "Stop", object["reason"] as? String != "end_turn" { return }
            }
            guard object["session_id"] is String, object["hook_event_name"] is String else { return }
            try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = eventsDirectory.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
            // Only persist lifecycle metadata and user text, never tool payloads.
            let allowed = ["session_id", "hook_event_name", "prompt", "cwd"]
            var filtered = object.filter { allowed.contains($0.key) }
            filtered["model"] = TaskModelReader.model(in: object)
            filtered["effort"] = TaskModelReader.configuration(in: object)?.effort
            if filtered["model"] == nil,
               let transcript = object["transcript_path"] as? String {
                filtered["model"] = TaskModelReader.latestModel(at: URL(fileURLWithPath: transcript))
            }
            if provider == .gemini {
                let names = ["BeforeAgent": "UserPromptSubmit", "BeforeModel": "ModelUpdate", "BeforeTool": "PreToolUse", "AfterAgent": "Stop", "SessionEnd": "SessionEnd"]
                filtered["hook_event_name"] = names[object["hook_event_name"] as? String ?? ""]
                if let request = object["llm_request"] as? [String: Any] {
                    filtered["model"] = TaskModelReader.model(in: request)
                }
            }
            if provider == .qwen { filtered["prompt"] = object["submitted_prompt"] as? String }
            try JSONSerialization.data(withJSONObject: filtered).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            FileHandle.standardError.write(Data("Kestra: failed to record Claude hook event\n".utf8))
        }
    }

    static var isConfigured: Bool {
        guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent("settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["disableAllHooks"] as? Bool != true,
              let hooks = object["hooks"] as? [String: [[String: Any]]] else { return false }
        return ["UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd"].allSatisfy { event in
            (hooks[event] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("--claude-hook") == true
                }
            }
        }
    }

    static func installHooks(configDirectory: URL = ClaudeHookMonitor.configDirectory, argument: String = "--claude-hook", events: [String] = ["UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd"], filename: String = "settings.json") throws {
        let url = configDirectory.appendingPathComponent(filename)
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
            try data.write(to: configDirectory.appendingPathComponent("settings.kestra-backup-\(UUID().uuidString).json"), options: .atomic)
        }
        let binary = Bundle.main.executableURL!.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "'\(binary)' \(argument)"
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            for index in entries.indices {
                if let handlers = entries[index]["hooks"] as? [[String: Any]] {
                    entries[index]["hooks"] = handlers.filter { !(($0["command"] as? String)?.contains(argument) ?? false) }
                }
            }
            let eventCommand = argument == "--workbuddy-hook" ? command + " " + event : command
            entries.append(["hooks": [["type": "command", "command": eventCommand, "timeout": ["--claude-hook", "--grok-hook", "--workbuddy-hook"].contains(argument) ? 5 : 5000]]])
            hooks[event] = entries
        }
        object["hooks"] = hooks
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    func poll(mode: CodexTaskPreviewMode) -> (tasks: [CodexTask], completed: [CodexTask]) {
        var completed: [CodexTask] = []
        defer { initialized = true }
        do {
            for directory in directories {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in files {
                    let seenKey = directory.path + "\u{0}" + file.lastPathComponent
                    guard !seen.contains(seenKey) else { continue }
                    let data = try Data(contentsOf: file)
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = event["session_id"] as? String,
                          let kind = event["hook_event_name"] as? String else { continue }
                    seen.insert(seenKey)
                    guard ["UserPromptSubmit", "PreToolUse", "ModelUpdate", "Stop", "StopFailure", "StopCancelled", "SessionEnd"].contains(kind) else { continue }
                    let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
                    let wasRunning = sessions[id]?.isRunning ?? false
                    if kind == "UserPromptSubmit", let prompt = event["prompt"] as? String {
                        if firstPrompts[id] == nil { firstPrompts[id] = prompt }
                        lastPrompts[id] = prompt
                    }
                    let running = kind == "ModelUpdate" ? wasRunning : initialized && (kind == "UserPromptSubmit" || kind == "PreToolUse")
                    var task = CodexTask(id: provider.rawValue + ":" + id, title: String((firstPrompts[id] ?? "\(provider.name) 任务").prefix(100)), summary: lastPrompts[id] ?? "", updatedAt: date, path: (event["cwd"] as? String).map { URL(fileURLWithPath: $0) } ?? sessions[id]?.path, isRunning: running, provider: provider, model: TaskModelReader.model(in: event) ?? sessions[id]?.model)
                    let previous = sessions[id]
                    // This adapter observes Code hooks only; never infer Cowork from the app name.
                    task.claudeMode = provider == .claude ? .code : nil
                    task.effort = TaskModelReader.configuration(in: event)?.effort
                        ?? (task.model == previous?.model ? previous?.effort : nil)
                    task.startedAt = kind == "UserPromptSubmit" || (running && !wasRunning)
                        ? date : previous?.startedAt
                    task.endedAt = running ? nil : previous?.endedAt
                    if ["Stop", "StopFailure", "StopCancelled"].contains(kind) {
                        task.endedAt = previous?.endedAt ?? date
                    } else if kind == "SessionEnd", wasRunning {
                        task.endedAt = date
                    }
                    sessions[id] = task
                    if initialized, wasRunning, kind == "Stop" { completed.append(task) }
                }
            }
            error = nil
        } catch { self.error = "读取 \(provider.name) 事件失败：\(error.localizedDescription)" }
        let tasks = sessions.map { id, task in
            CodexTask(id: task.id, title: task.title, summary: (mode == .firstUser ? firstPrompts[id] : lastPrompts[id]) ?? "", updatedAt: task.updatedAt, path: task.path, isRunning: task.isRunning, provider: provider, model: task.model, effort: task.effort, claudeMode: task.claudeMode, startedAt: task.startedAt, endedAt: task.endedAt)
        }
        return (tasks, completed)
    }
}
