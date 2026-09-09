import Foundation

enum TaskBridgeTaskStatus: String, Codable, Sendable {
    case draft
    case running
    case paused
    case pausedQuota
    case waitingForHandoff
    case completed
    case failed
}

enum TaskBridgeSessionStatus: String, Codable, Sendable {
    case running
    case paused
    case completed
    case failed
}

/// Local account metadata only. Credentials remain owned by Codex.
struct CodexAccountProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var displayName: String
    var codexHomePath: URL
    var createdAt: Date
    var lastUsedAt: Date?
    var isEnabled: Bool
    var email: String? = nil
    var planType: String? = nil
    var workspaceID: String? = nil

    var isTeam: Bool {
        ["team", "business", "enterprise", "ent26", "edu"].contains { planType?.contains($0) == true }
    }
}

struct TaskBridgeSession: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let accountID: String
    let codexThreadID: String?
    let startedAt: Date
    var endedAt: Date?
    var status: TaskBridgeSessionStatus
}

struct TaskBridgeTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var projectPath: URL
    var branch: String?
    var worktreePath: URL
    var status: TaskBridgeTaskStatus
    var activeAccountID: String?
    var activeSessionID: String?
    var goal: String
    var completed: [String]
    var inProgress: [String]
    var decisions: [String]
    var filesChanged: [String]
    var tests: [String]
    var lastUserRequest: String?
    var nextStep: String?
    var sessions: [TaskBridgeSession]
    var latestHandoffID: String?
    let createdAt: Date
    var updatedAt: Date
}

struct HandoffSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    let sourceAccountID: String?
    let sourceSessionID: String?
    let createdAt: Date
    let markdown: String
}

struct TaskBridgeMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    let sessionID: String?
    let accountID: String?
    let body: String
    let createdAt: Date
}
