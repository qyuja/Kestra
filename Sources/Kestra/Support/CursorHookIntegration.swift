import Foundation

/// Cursor's flat hook schema is not Claude Code's nested command-hook schema.
enum CursorHookIntegration {
    static let events = ["beforeSubmitPrompt", "preToolUse", "stop", "sessionEnd"]
    static let argument = "--cursor-hook"

    static func isConfigured(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let hooks = object["hooks"] as? [String: [[String: Any]]] else { return false }
        return events.allSatisfy { event in
            (hooks[event] ?? []).contains { ($0["command"] as? String)?.contains(argument) == true }
        }
    }

    static func install(at url: URL, executable: URL = Bundle.main.executableURL!) throws {
        var object: [String: Any] = ["version": 1]
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  existing["version"] == nil || existing["version"] as? Int == 1,
                  existing["hooks"] == nil || existing["hooks"] is [String: [[String: Any]]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
            try data.write(to: url.appendingPathExtension(UUID().uuidString + ".backup"), options: .atomic)
        }
        var hooks = object["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument
        for event in events {
            var handlers = (hooks[event] ?? []).filter { !(($0["command"] as? String)?.contains(argument) ?? false) }
            handlers.append(["command": command])
            hooks[event] = handlers
        }
        object["version"] = 1
        object["hooks"] = hooks
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func normalize(_ object: [String: Any]) -> [String: Any]? {
        guard let id = object["conversation_id"] as? String, !id.isEmpty,
              let event = object["hook_event_name"] as? String, events.contains(event) else { return nil }
        let kind: String
        switch event {
        case "beforeSubmitPrompt": kind = "UserPromptSubmit"
        case "preToolUse": kind = "PreToolUse"
        case "sessionEnd": kind = "SessionEnd"
        case "stop":
            switch object["status"] as? String {
            case "completed": kind = "Stop"
            case "aborted": kind = "StopCancelled"
            default: kind = "StopFailure"
            }
        default: return nil
        }
        var result: [String: Any] = ["session_id": id, "hook_event_name": kind]
        result["cwd"] = (object["workspace_roots"] as? [String])?.first
        result["model"] = object["model_id"] as? String ?? object["model"] as? String
        if event == "beforeSubmitPrompt" { result["prompt"] = object["prompt"] as? String }
        let parameters = object["model_params"] as? [[String: String]] ?? []
        result["effort"] = parameters.first { ["effort", "reasoning_effort"].contains($0["id"] ?? "") }?["value"]
        return result
    }
}
