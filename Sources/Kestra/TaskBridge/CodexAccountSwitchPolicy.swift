import Foundation

enum CodexAccountSwitchPolicy {
    static func blockingReason(runningCount: Int, connected: Bool, lastUpdated: Date?, hasError: Bool, now: Date = .now) -> String? {
        if runningCount > 0 { return "任务运行中，暂不可切换账号" }
        guard connected, !hasError, let lastUpdated, now.timeIntervalSince(lastUpdated) <= 5 else {
            return "无法确认任务状态，暂不可切换账号"
        }
        return nil
    }
}
