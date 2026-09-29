import Foundation

struct CodexTaskStatusIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let reason: String
}

enum CodexAccountSwitchPolicy {
    static func blockingReason(runningCount: Int, connected: Bool, lastUpdated: Date?, hasError: Bool, now: Date = .now) -> String? {
        if runningCount > 0 { return "任务运行中，暂不可切换账号" }
        guard connected else { return "Codex 监听未连接，无法读取任务状态" }
        guard !hasError else { return "读取 Codex 任务失败，请刷新任务状态" }
        guard let lastUpdated, now.timeIntervalSince(lastUpdated) <= 5 else { return "任务状态尚未刷新，请在账号管理中刷新任务状态" }
        return nil
    }

    static func issues(records: [CodexThreadRecord], snapshot: CodexActivitySnapshot) -> [CodexTaskStatusIssue] {
        var seen = Set<String>()
        return records.compactMap { record in
            guard seen.insert(record.id).inserted else { return nil }
            let reason: String
            if record.path.map({ FileManager.default.isReadableFile(atPath: $0.path) }) != true {
                reason = "会话文件不可读"
            } else if snapshot.unknownThreadIDs.contains(record.id) {
                reason = "缺少可确认的生命周期状态"
            } else if snapshot.activeThreadIDs.contains(record.id) {
                reason = "运行中"
            } else {
                return nil
            }
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexTaskStatusIssue(id: record.id, title: title.isEmpty ? "未命名任务" : title, reason: reason)
        }
    }

    static func issueSummary(_ issues: [CodexTaskStatusIssue], action: String) -> String {
        let examples = issues.prefix(3).map { "\($0.title) [\($0.id)]：\($0.reason)" }.joined(separator: "；")
        let remainder = issues.count > 3 ? "；其余 \(issues.count - 3) 个见设置中的账号管理" : ""
        return "\(issues.count) 个任务仍在运行或状态无法确认，\(action)：\(examples)\(remainder)"
    }
}
