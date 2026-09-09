import Foundation
import XCTest
@testable import Kestra

final class CursorHookTests: XCTestCase {
    func testInstallPreservesExistingHooksAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": [
            "stop": [["command": "existing-command"]],
            "afterFileEdit": [["command": "formatter"]]
        ]]).write(to: file)
        for _ in 0..<2 { try CursorHookIntegration.install(at: file, executable: URL(fileURLWithPath: "/test/My App/runner")) }
        XCTAssertTrue(CursorHookIntegration.isConfigured(at: file))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["stop"]?.count, 2)
        XCTAssertEqual(hooks["stop"]?.first?["command"] as? String, "existing-command")
        XCTAssertEqual(hooks["afterFileEdit"]?.first?["command"] as? String, "formatter")
        XCTAssertEqual(hooks["beforeSubmitPrompt"]?.first?["command"] as? String, "'/test/My App/runner' --cursor-hook")
    }

    func testCursorNormalizesOnlyAgentEventsAndWhitelistsFields() throws {
        var input: [String: Any] = ["conversation_id": "one", "generation_id": "turn-a",
            "hook_event_name": "beforeSubmitPrompt", "prompt": "user text",
            "workspace_roots": ["/project"], "model_id": "model-a",
            "model_params": [["id": "effort", "value": "high"]],
            "user_email": "private@example.com", "tool_input": "private"]
        let event = try XCTUnwrap(CursorHookIntegration.normalize(input))
        XCTAssertEqual(event["session_id"] as? String, "one")
        XCTAssertEqual(event["effort"] as? String, "high")
        XCTAssertNil(event["user_email"])
        XCTAssertNil(event["tool_input"])
        for (status, kind) in [("completed", "Stop"), ("aborted", "StopCancelled"), ("error", "StopFailure"), ("unknown", "StopFailure")] {
            input["hook_event_name"] = "stop"
            input["status"] = status
            let output = CursorHookIntegration.normalize(input)
            XCTAssertEqual(output?["hook_event_name"] as? String, kind)
            XCTAssertNil(output?["prompt"])
        }
        input["hook_event_name"] = "afterTabFileEdit"
        XCTAssertNil(CursorHookIntegration.normalize(input))
        input["hook_event_name"] = "subagentStop"
        XCTAssertNil(CursorHookIntegration.normalize(input))
    }
}
