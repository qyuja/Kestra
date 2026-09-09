import Foundation
import XCTest
@testable import Kestra

final class TaskModelEffortTests: XCTestCase {
    func testEffortComesFromMetadataNotMessageText() {
        let context: [String: Any] = ["type": "turn_context", "payload": [
            "model": "model-a", "effort": "high",
            "collaboration_mode": ["settings": ["reasoning_effort": "low"]]
        ]]
        XCTAssertEqual(TaskModelReader.configuration(in: context), .init(model: "model-a", effort: "high"))
        XCTAssertEqual(TaskModelReader.configuration(in: ["type": "turn_context", "payload": [
            "model": "model-b", "collaboration_mode": ["settings": ["reasoning_effort": "xhigh"]]
        ]])?.effort, "xhigh")
        XCTAssertNil(TaskModelReader.configuration(in: ["message": ["model": "model-a", "content": "effort: high"]])?.effort)
    }

    func testLatestTurnUpdatesEffortAndDoesNotInheritMissingEffort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var lines = ""
        func append(model: String, effort: String?) throws {
            var payload = ["model": model]
            payload["effort"] = effort
            let data = try JSONSerialization.data(withJSONObject: ["type": "turn_context", "payload": payload])
            lines += String(decoding: data, as: UTF8.self) + "\n"
            try Data(lines.utf8).write(to: file)
        }
        let reader = CodexSessionReader()
        let records = [CodexThreadRecord(id: "test", title: "test", summary: "", updatedAt: .now, path: file)]
        try append(model: "model-a", effort: "high")
        let first = await reader.models(for: records)
        XCTAssertEqual(first["test"]?.effort, "high")
        try append(model: "model-a", effort: "low")
        let second = await reader.models(for: records)
        XCTAssertEqual(second["test"]?.effort, "low")
        try append(model: "model-b", effort: nil)
        let third = await reader.models(for: records)
        XCTAssertEqual(third["test"]?.model, "model-b")
        XCTAssertNil(third["test"]?.effort)
    }

    func testCardModelLabel() {
        var task = CodexTask(id: "test", title: "test", summary: "", updatedAt: .now, path: nil, isRunning: true, model: "model-a", effort: "high")
        XCTAssertEqual(task.modelText, "model-a · high")
        task.effort = nil
        XCTAssertEqual(task.modelText, "model-a")
    }
}
