import AppKit
import Foundation

enum CodexAttentionKind: String, Codable, Sendable {
    case userInput
    case permission

    var title: String {
        switch self {
        case .userInput: "需要回答"
        case .permission: "需要授权"
        }
    }

    var symbolName: String {
        switch self {
        case .userInput: "questionmark"
        case .permission: "lock"
        }
    }
}

struct CodexAttentionEvent: Codable, Sendable {
    let sessionID: String
    let turnID: String
    let requestID: String
    let kind: CodexAttentionKind
    let timestamp: Date
    var permission: CodexPermissionRequest? = nil
}

struct CodexPermissionRequest: Codable, Sendable {
    let id: UUID
    let toolName: String
    let reason: String?
    let input: String
    let canApprove: Bool
    let expiresAt: Date
}

enum CodexPermissionDecision: String, Codable, Sendable, Equatable {
    case allow
    case deny
    case openInCodex
}

/// Codex runs these callbacks in the process that owns the interactive turn.
/// A separate app-server connection cannot receive another client's requests.
@MainActor
final class CodexAttentionHookMonitor {
    private static let hookArgument = "--codex-attention-hook"
    private static let decisionWindow: TimeInterval = 60
    private static let hookTimeout = 65
    private static let maximumDisplayedInputBytes = 32 * 1024
    private static let eventsDirectory = AgentDeputyAppIdentity.applicationSupportDirectory
        .appendingPathComponent("codex-attention-events", isDirectory: true)

    private let directory: URL
    private let startedAt = Date.now
    private(set) var error: String?

    init(directory: URL = eventsDirectory) {
        self.directory = directory
    }

    static func receiveEvent(
        input: Data = FileHandle.standardInput.readDataToEndOfFile(),
        directory: URL = eventsDirectory
    ) throws -> CodexAttentionEvent? {
        guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = event(from: object) else { return nil }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = eventURL(for: event.permission?.id ?? UUID(), in: directory)
        try JSONEncoder().encode(event).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return event
    }

    static func processPermissionRequest(
        input: Data = FileHandle.standardInput.readDataToEndOfFile(),
        directory: URL = eventsDirectory,
        isAppRunning: Bool = isUIPresent,
        maximumWait: TimeInterval? = nil
    ) throws -> CodexPermissionDecision? {
        // A hook without the menu-bar process must not stall Codex for a minute.
        guard isAppRunning,
              let request = try receiveEvent(input: input, directory: directory)?.permission else { return nil }
        let response = decisionURL(for: request.id, in: directory)
        defer {
            try? FileManager.default.removeItem(at: response)
            try? FileManager.default.removeItem(at: eventURL(for: request.id, in: directory))
        }
        let deadline = maximumWait.map { min(request.expiresAt, Date.now.addingTimeInterval($0)) }
            ?? request.expiresAt

        while Date.now < deadline {
            if let data = try? Data(contentsOf: response),
               let decision = try? JSONDecoder().decode(CodexPermissionDecision.self, from: data) {
                return decision
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    static func hookOutput(for decision: CodexPermissionDecision?) -> Data? {
        let behavior: String
        switch decision {
        case .allow: behavior = "allow"
        case .deny: behavior = "deny"
        case .openInCodex, nil: return nil
        }
        let message = behavior == "deny" ? ",\"message\":\"用户在 AgentDeputy 中拒绝本次授权。\"" : ""
        return Data("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"\(behavior)\"\(message)}}}\n".utf8)
    }

    func respond(to event: CodexAttentionEvent, with decision: CodexPermissionDecision) throws {
        guard let request = event.permission,
              Date.now < request.expiresAt.addingTimeInterval(-1) else {
            throw CocoaError(.userCancelled)
        }
        guard decision != .allow || request.canApprove else { throw CocoaError(.userCancelled) }
        let response = Self.decisionURL(for: request.id, in: directory)
        try JSONEncoder().encode(decision).write(to: response, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response.path)
    }

    static func event(from object: [String: Any]) -> CodexAttentionEvent? {
        guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let turnID = object["turn_id"] as? String, !turnID.isEmpty,
              let eventName = object["hook_event_name"] as? String else { return nil }

        let kind: CodexAttentionKind
        let requestID: String
        switch eventName {
        case "PermissionRequest":
            guard let toolName = object["tool_name"] as? String, !toolName.isEmpty else { return nil }
            kind = .permission
            requestID = (object["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(turnID):\(toolName)"
        default:
            return nil
        }

        var event = CodexAttentionEvent(
            sessionID: sessionID,
            turnID: turnID,
            requestID: requestID,
            kind: kind,
            timestamp: .now
        )
        if kind == .permission {
            let toolInput = object["tool_input"]
            let serialized = toolInput.flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            }
            let fullInput = serialized.flatMap { data in
                data.count <= maximumDisplayedInputBytes ? String(data: data, encoding: .utf8) : nil
            }
            let displayedInput = fullInput ?? "请求内容不可完整显示，请在 Codex 中审批"
            let reason = (toolInput as? [String: Any])?["description"] as? String
            event.permission = CodexPermissionRequest(
                id: UUID(),
                toolName: (object["tool_name"] as? String) ?? "工具",
                reason: reason,
                input: displayedInput,
                canApprove: fullInput != nil,
                expiresAt: Date.now.addingTimeInterval(decisionWindow)
            )
        }
        return event
    }

    private static var isUIPresent: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: AgentDeputyAppIdentity.bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
    }

    private static func decisionURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).decision")
    }

    private static func eventURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func poll() -> [CodexAttentionEvent] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            var events: [CodexAttentionEvent] = []
            var fileError: String?
            for file in files {
                let event: CodexAttentionEvent
                do {
                    event = try JSONDecoder().decode(CodexAttentionEvent.self, from: Data(contentsOf: file))
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    fileError = "读取 Codex 交互提醒失败：\(error.localizedDescription)"
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    fileError = "清理 Codex 交互提醒失败：\(error.localizedDescription)"
                    continue
                }
                if event.timestamp >= startedAt,
                   event.permission.map({ $0.expiresAt > .now }) ?? true {
                    events.append(event)
                }
            }
            error = fileError
            return events.sorted { $0.timestamp < $1.timestamp }
        } catch {
            self.error = "读取 Codex 交互提醒失败：\(error.localizedDescription)"
            return []
        }
    }

    static func isConfigured(
        configDirectory: URL = CodexAppServerClient.defaultCodexHome,
        executable: URL? = Bundle.main.executableURL
    ) -> Bool {
        guard let executable,
              let data = try? Data(contentsOf: configDirectory.appendingPathComponent("hooks.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        let command = hookCommand(executable: executable)
        let groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String) == command && ($0["timeout"] as? Int) == hookTimeout
            }
        }
    }

    static func installHooks(
        configDirectory: URL = CodexAppServerClient.defaultCodexHome,
        executable: URL? = Bundle.main.executableURL
    ) throws {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        let file = configDirectory.appendingPathComponent("hooks.json")
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  existing["hooks"] == nil || existing["hooks"] is [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
            let backup = configDirectory.appendingPathComponent("hooks.agentdeputy-backup-\(UUID().uuidString).json")
            try data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }

        let handler: [String: Any] = [
            "type": "command",
            "command": hookCommand(executable: executable),
            "timeout": hookTimeout,
            "statusMessage": "等待 AgentDeputy 审批"
        ]
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let eventName = "PermissionRequest"
        guard hooks[eventName] == nil || hooks[eventName] is [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var groups = hooks[eventName] as? [[String: Any]] ?? []
        groups = groups.compactMap { group in
            var group = group
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let retained = handlers.filter {
                !(($0["command"] as? String)?.contains(hookArgument) ?? false)
            }
            guard !retained.isEmpty else { return nil }
            group["hooks"] = retained
            return group
        }
        groups.append(["hooks": [handler]])
        hooks[eventName] = groups
        object["hooks"] = hooks
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func hookCommand(executable: URL) -> String {
        let path = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(path)' \(hookArgument)"
    }
}
