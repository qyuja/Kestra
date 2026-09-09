import Foundation

enum HandoffDocumentBuilder {
    static func markdown(
        for task: TaskBridgeTask,
        sourceSession: TaskBridgeSession?,
        generatedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        # Task Handoff

        - Task ID: \(task.id)
        - Project: \(task.projectPath.path)
        - Worktree: \(task.worktreePath.path)
        - Branch: \(task.branch ?? "未指定")
        - Source account: \(sourceSession?.accountID ?? task.activeAccountID ?? "未指定")
        - Source session: \(sourceSession?.id ?? task.activeSessionID ?? "未指定")
        - Generated at: \(formatter.string(from: generatedAt))

        ## Goal

        \(task.goal)

        ## Completed

        \(bullets(task.completed))

        ## In progress

        \(bullets(task.inProgress))

        ## Decisions

        \(bullets(task.decisions))

        ## Files changed

        \(bullets(task.filesChanged))

        ## Tests

        \(bullets(task.tests))

        ## Last user request

        \(task.lastUserRequest ?? "未记录")

        ## Next step

        \(task.nextStep ?? "请先检查当前工作树和实际文件状态，再决定下一步。")

        ## Continuation instruction

        请先读取当前项目状态和上面的交接内容，不要重复已经完成的工作；确认实际文件和测试结果后，从 Next step 继续。
        """
    }

    private static func bullets(_ values: [String]) -> String {
        values.isEmpty ? "- 暂无记录" : values.map { "- \($0)" }.joined(separator: "\n")
    }
}
