import SwiftUI

/// Task sources are agent clients, not the models they invoke.
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, cursor, pi, opencode, gemini, qwen, grok, workbuddy
    case deepseekHarness, cline, copilot, windsurf, kiro

    static let primaryProviders: [AIProvider] = [.codex, .claude, .cursor, .pi, .opencode, .gemini]
    static let additionalProviders: [AIProvider] = allCases.filter { !primaryProviders.contains($0) }
    static let hookProviders: [AIProvider] = [.opencode, .gemini, .qwen, .grok, .workbuddy, .pi, .cursor]
    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .grok: "Grok Build"
        case .workbuddy: "WorkBuddy"
        case .cursor: "Cursor"
        case .pi: "Pi"
        case .deepseekHarness: "DeepSeek Harness"
        case .cline: "Cline"
        case .copilot: "GitHub Copilot"
        case .windsurf: "Windsurf"
        case .kiro: "Kiro"
        }
    }
    var symbolName: String {
        switch self {
        case .codex: "curlybraces"
        case .claude: "sun.max.fill"
        case .opencode: "terminal"
        case .gemini: "sparkles"
        case .qwen: "q.circle"
        case .grok: "xmark"
        case .workbuddy: "person.crop.square"
        case .cursor: "cursorarrow"
        case .pi: "p.circle"
        case .deepseekHarness: "water.waves"
        case .cline: "terminal"
        case .copilot: "airplane"
        case .windsurf: "wind"
        case .kiro: "k.circle"
        }
    }
    var logoResourceName: String { self == .codex ? "chatgpt" : rawValue }
    var tint: Color { self == .claude ? .orange : .green }
    var integrationStatus: String {
        switch self {
        case .pi: "Pi 扩展 · CLI / 加载扩展的宿主"
        case .cursor: "本机 Agent Hooks · 不含 Tab 补全"
        case .claude: "Code 已适配 · Cowork 尚未接入"
        default: isImplemented ? "任务监听" : "任务协议适配尚未完成"
        }
    }
    var isImplemented: Bool { self == .codex || self == .claude || Self.hookProviders.contains(self) }
    var frontmostApplicationBundleIdentifiers: Set<String> {
        self == .codex ? ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"] : []
    }
}
