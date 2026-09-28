import SwiftUI

/// Task sources are agent clients, not the models they invoke.
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude

    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude Code"
        }
    }
    var symbolName: String {
        switch self {
        case .codex: "curlybraces"
        case .claude: "sun.max.fill"
        }
    }
    var logoResourceName: String {
        switch self {
        case .codex: "chatgpt"
        case .claude: "claude"
        }
    }
    var tint: Color { self == .claude ? .orange : .green }
    var frontmostApplicationBundleIdentifiers: Set<String> {
        self == .codex ? ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"] : []
    }
}
