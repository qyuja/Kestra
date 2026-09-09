import Foundation

struct CodexThreadRecord: Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let updatedAt: Date
    let path: URL?
}

struct CodexTask: Identifiable, Equatable {
    enum ClaudeMode: String { case code = "Code", cowork = "Cowork" }
    let id: String
    let title: String
    let summary: String
    let updatedAt: Date
    let path: URL?
    var isRunning: Bool

    var provider: AIProvider = .codex
    var model: String? = nil
    var effort: String? = nil
    var claudeMode: ClaudeMode? = nil
    var startedAt: Date? = nil
    var endedAt: Date? = nil

    func timeText(at date: Date) -> String {
        if isRunning {
            guard let startedAt else { return "计时中" }
            let seconds = Int(max(0, date.timeIntervalSince(startedAt)))
            if seconds >= 3600 {
                return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        let seconds = Int(max(0, date.timeIntervalSince(endedAt ?? updatedAt)))
        if seconds < 60 { return "<1m ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var threadName: String { title }

    var modelText: String {
        [model ?? "模型未知", effort].compactMap { $0 }.joined(separator: " · ")
    }

    var latestMessage: String { summary }

    var statusText: String {
        isRunning ? "运行中" : "空闲"
    }

    var shortIdentifier: String {
        String(id.prefix(8))
    }

}
