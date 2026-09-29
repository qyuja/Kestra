import Foundation
import XCTest
@testable import AgentDeputy

final class CodexAttentionHookMonitorTests: XCTestCase {
    @MainActor
    func testPermissionHookPersistsFullReviewContentOnlyUntilPolling() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = CodexAttentionHookMonitor(directory: directory)

        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-1",
            "turn_id": "turn-1",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_use_id": "call-1",
            "tool_input": ["question": "private question"]
        ])
        let created = try XCTUnwrap(CodexAttentionHookMonitor.receiveEvent(input: input, directory: directory))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let saved = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertTrue(saved.contains("private question"))
        XCTAssertEqual(created.permission?.toolName, "Bash")
        XCTAssertTrue(created.permission?.canApprove == true)
        let mode = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(files.first).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        let event = try XCTUnwrap(monitor.poll().first)
        XCTAssertEqual(event.sessionID, "thread-1")
        XCTAssertEqual(event.turnID, "turn-1")
        XCTAssertEqual(event.requestID, "call-1")
        XCTAssertEqual(event.kind, .permission)
        XCTAssertTrue(event.permission?.input.contains("private question") == true)
        XCTAssertTrue(monitor.poll().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testPermissionRequestIsRecordedWithoutToolArguments() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = CodexAttentionHookMonitor(directory: directory)
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-2",
            "turn_id": "turn-2",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "secret command"]
        ])

        _ = try CodexAttentionHookMonitor.receiveEvent(input: input, directory: directory)

        let event = try XCTUnwrap(monitor.poll().first)
        XCTAssertEqual(event.kind, .permission)
        XCTAssertEqual(event.sessionID, "thread-2")
        XCTAssertEqual(event.requestID, "turn-2:Bash")
        XCTAssertTrue(event.permission?.input.contains("secret command") == true)
    }

    @MainActor
    func testUnrelatedHookEventIsIgnored() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-3",
            "turn_id": "turn-3",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_use_id": "call-3"
        ])

        _ = try CodexAttentionHookMonitor.receiveEvent(input: input, directory: directory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testApprovalWritesOneShotDecisionAndHookOutput() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = CodexAttentionHookMonitor(directory: directory)
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-approval",
            "turn_id": "turn-approval",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"]
        ])
        let event = try XCTUnwrap(CodexAttentionHookMonitor.receiveEvent(input: input, directory: directory))
        try monitor.respond(to: event, with: .allow)

        let decisionFile = directory.appendingPathComponent("\(try XCTUnwrap(event.permission).id.uuidString).decision")
        XCTAssertEqual(try JSONDecoder().decode(CodexPermissionDecision.self, from: Data(contentsOf: decisionFile)), .allow)
        let output = try XCTUnwrap(CodexAttentionHookMonitor.hookOutput(for: .allow))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual((specific["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        let denyOutput = try XCTUnwrap(CodexAttentionHookMonitor.hookOutput(for: .deny))
        let denyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: denyOutput) as? [String: Any])
        let denySpecific = try XCTUnwrap(denyObject["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual((denySpecific["decision"] as? [String: Any])?["behavior"] as? String, "deny")
        XCTAssertNil(CodexAttentionHookMonitor.hookOutput(for: .openInCodex))
        XCTAssertNil(CodexAttentionHookMonitor.hookOutput(for: nil))
    }

    @MainActor
    func testOversizedPermissionCannotBeApprovedFromPopup() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-large",
            "turn_id": "turn-large",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": String(repeating: "x", count: 40_000)]
        ])
        let event = try XCTUnwrap(CodexAttentionHookMonitor.receiveEvent(input: input, directory: directory))
        XCTAssertFalse(try XCTUnwrap(event.permission).canApprove)
        XCTAssertThrowsError(try CodexAttentionHookMonitor(directory: directory).respond(to: event, with: .allow))
        XCTAssertNoThrow(try CodexAttentionHookMonitor(directory: directory).respond(to: event, with: .deny))
    }

    @MainActor
    func testNoRunningAppDoesNotDelayOrRecordApproval() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-no-app",
            "turn_id": "turn-no-app",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"]
        ])
        XCTAssertNil(try CodexAttentionHookMonitor.processPermissionRequest(
            input: input, directory: directory, isAppRunning: false
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testHookWaitsForDecisionFromAnotherProcessBoundary() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-wait",
            "turn_id": "turn-wait",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"]
        ])

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            guard let file = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "json" }),
                let data = try? Data(contentsOf: file),
                let event = try? JSONDecoder().decode(CodexAttentionEvent.self, from: data),
                let request = event.permission else { return }
            let response = directory.appendingPathComponent("\(request.id.uuidString).decision")
            try? JSONEncoder().encode(CodexPermissionDecision.deny).write(to: response)
        }

        let decision = try CodexAttentionHookMonitor.processPermissionRequest(
            input: input, directory: directory, isAppRunning: true, maximumWait: 2
        )
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(CodexAttentionHookMonitor.hookOutput(for: .openInCodex))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains(where: { $0.pathExtension == "decision" }))
    }

    @MainActor
    func testHookTimeoutReturnsNoDecision() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "thread-timeout",
            "turn_id": "turn-timeout",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"]
        ])
        XCTAssertNil(try CodexAttentionHookMonitor.processPermissionRequest(
            input: input, directory: directory, isAppRunning: true, maximumWait: 0.1
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testCorruptAttentionFileIsRemovedInsteadOfRetained() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("invalid event".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let monitor = CodexAttentionHookMonitor(directory: directory)
        XCTAssertTrue(monitor.poll().isEmpty)
        XCTAssertNotNil(monitor.error)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testInstallationPreservesOtherHooksAndDoesNotDuplicateItsOwn() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/Applications/AgentDeputy.app/Contents/MacOS/AgentDeputy")
        let file = directory.appendingPathComponent("hooks.json")
        let existing: [String: Any] = [
            "description": "existing hooks",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "^Bash$",
                    "hooks": [["type": "command", "command": "existing-hook"]]
                ]],
                "PermissionRequest": [[
                    "hooks": [[
                        "type": "command",
                        "command": "'/Applications/AgentDeputy.app/Contents/MacOS/AgentDeputy' --codex-attention-hook",
                        "timeout": 3
                    ]]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        XCTAssertFalse(CodexAttentionHookMonitor.isConfigured(configDirectory: directory, executable: executable))
        try CodexAttentionHookMonitor.installHooks(configDirectory: directory, executable: executable)
        try CodexAttentionHookMonitor.installHooks(configDirectory: directory, executable: executable)

        XCTAssertTrue(CodexAttentionHookMonitor.isConfigured(configDirectory: directory, executable: executable))
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let preToolGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolGroups.count, 1)
        XCTAssertEqual(object["description"] as? String, "existing hooks")
        XCTAssertEqual((hooks["PermissionRequest"] as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testInvalidExistingHookConfigIsNotOverwritten() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hooks.json")
        let original = Data("not json".utf8)
        try original.write(to: file)

        XCTAssertThrowsError(try CodexAttentionHookMonitor.installHooks(
            configDirectory: directory,
            executable: URL(fileURLWithPath: "/Applications/AgentDeputy.app/Contents/MacOS/AgentDeputy")
        ))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeputyAttentionTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
