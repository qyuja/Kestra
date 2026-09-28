import XCTest
@testable import AgentDeputy

final class ClaudeHookMonitorTests: XCTestCase {
    @MainActor
    func testOldAppHookDoesNotClaimNewExecutableIsConnected() throws {
        let events = ["UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd"]
        let oldCommand = "'/Applications/Kestra.app/Contents/MacOS/Kestra' --claude-hook"
        let newCommand = "'/Applications/AgentDeputy.app/Contents/MacOS/AgentDeputy' --claude-hook"
        let executable = URL(fileURLWithPath: "/Applications/AgentDeputy.app/Contents/MacOS/AgentDeputy")
        func settings(with command: String) throws -> Data {
            let hook = ["hooks": [["type": "command", "command": command]]]
            let object = ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [hook]) })]
            return try JSONSerialization.data(withJSONObject: object)
        }

        XCTAssertFalse(ClaudeHookMonitor.hasInstalledHooks(in: try settings(with: oldCommand), executable: executable))
        XCTAssertTrue(ClaudeHookMonitor.hasInstalledHooks(in: try settings(with: newCommand), executable: executable))
    }

    @MainActor
    func testLifecyclePreviewAndNoHistoricalCompletionReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func event(_ index: Int, _ kind: String, prompt: String? = nil) throws {
            var object = ["session_id": "test-session", "hook_event_name": kind, "cwd": "/tmp"]
            object["prompt"] = prompt
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("\(index).json"))
        }
        try event(0, "UserPromptSubmit", prompt: "first user message")
        try event(1, "Stop")
        let monitor = ClaudeHookMonitor(directory: directory)
        let baseline = monitor.poll(mode: .latestUser)
        XCTAssertTrue(baseline.completed.isEmpty)
        XCTAssertFalse(try XCTUnwrap(baseline.tasks.first).isRunning)
        try event(2, "UserPromptSubmit", prompt: "latest user message")
        let running = monitor.poll(mode: .firstUser)
        XCTAssertTrue(try XCTUnwrap(running.tasks.first).isRunning)
        XCTAssertEqual(running.tasks.first?.summary, "first user message")
        XCTAssertEqual(monitor.poll(mode: .latestUser).tasks.first?.summary, "latest user message")
        try event(3, "Stop")
        XCTAssertEqual(monitor.poll(mode: .latestUser).completed.count, 1)
        XCTAssertTrue(monitor.poll(mode: .latestUser).completed.isEmpty)
        try event(4, "UserPromptSubmit", prompt: "failure test")
        _ = monitor.poll(mode: .latestUser)
        try event(5, "StopFailure")
        let failed = monitor.poll(mode: .latestUser)
        XCTAssertFalse(try XCTUnwrap(failed.tasks.first).isRunning)
        XCTAssertTrue(failed.completed.isEmpty)
    }
}
