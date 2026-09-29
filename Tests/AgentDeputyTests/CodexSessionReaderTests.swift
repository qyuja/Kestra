import Foundation
import XCTest
@testable import AgentDeputy

final class CodexSessionReaderTests: XCTestCase {
    func testPreviewUsesUserInputTextAndHonorsFirstOrLastSelection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try appendJSON([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "input_text": "First request"]],
                "internal_chat_message_metadata_passthrough": [
                    "content_item_kinds": ["user.text"]
                ]
            ]
        ], to: fixture.path)
        try appendJSON([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Assistant reply"]]
            ]
        ], to: fixture.path)
        try appendJSON([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "input_text": "Latest request"]],
                "internal_chat_message_metadata_passthrough": [
                    "content_item_kinds": ["user.text"]
                ]
            ]
        ], to: fixture.path)

        let record = makeRecord(fixture.path)
        let reader = CodexSessionReader()

        let first = await reader.latestMessages(for: [record], mode: .firstUser)
        let latest = await reader.latestMessages(for: [record], mode: .latestUser)

        XCTAssertEqual(first[record.id], "First request")
        XCTAssertEqual(latest[record.id], "Latest request")
    }

    func testActivityReaderEmitsOnlyACompletionObservedAfterTheInitialBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let record = makeRecord(fixture.path)
        let reader = CodexSessionActivityReader()

        let initial = await reader.snapshot(records: [record])
        XCTAssertFalse(initial.activeThreadIDs.contains(record.id))
        XCTAssertTrue(initial.completedTasks.isEmpty)

        try appendJSON([
            "type": "event_msg",
            "payload": [
                "type": "task_started",
                "turn_id": "turn-1"
            ]
        ], to: fixture.path)
        let running = await reader.snapshot(records: [record])
        XCTAssertTrue(running.activeThreadIDs.contains(record.id))
        XCTAssertTrue(running.completedTasks.isEmpty)

        try appendJSON([
            "type": "event_msg",
            "payload": [
                "type": "task_complete",
                "turn_id": "turn-1"
            ]
        ], to: fixture.path)
        let completed = await reader.snapshot(records: [record])

        XCTAssertFalse(completed.activeThreadIDs.contains(record.id))
        XCTAssertEqual(
            completed.completedTasks,
            [CodexTaskCompletionEvent(threadID: record.id, turnID: "turn-1")]
        )
    }

    func testActivityReaderRestoresACurrentlyRunningTurnFromTheInitialTail() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try appendJSON([
            "type": "event_msg",
            "payload": [
                "type": "task_started",
                "turn_id": "turn-1"
            ]
        ], to: fixture.path)

        let record = makeRecord(fixture.path)
        let snapshot = await CodexSessionActivityReader().snapshot(records: [record])

        XCTAssertTrue(snapshot.activeThreadIDs.contains(record.id))
        XCTAssertTrue(snapshot.completedTasks.isEmpty)
    }

    func testSetupOnlySessionHasKnownIdleStateAcrossChunksAndLaterSettings() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = makeRecord(fixture.path)
        try appendJSON(["type": "session_meta", "payload": ["id": record.id]], to: fixture.path)
        try appendJSON([
            "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "settings": String(repeating: "x", count: 70_000)]
        ], to: fixture.path)
        let reader = CodexSessionActivityReader()

        let initial = await reader.snapshot(records: [record])
        XCTAssertTrue(initial.unknownThreadIDs.isEmpty, "A never-started session must not block account switching")
        XCTAssertTrue(initial.activeThreadIDs.isEmpty)
        XCTAssertTrue(initial.completedTasks.isEmpty)

        try appendJSON(["type": "event_msg", "payload": ["type": "thread_settings_applied"]], to: fixture.path)
        let updated = await reader.snapshot(records: [record])
        XCTAssertTrue(updated.unknownThreadIDs.isEmpty)
        XCTAssertTrue(updated.activeThreadIDs.isEmpty)
    }

    func testSetupOnlySessionStopsBeingIdleWhenTaskContentArrives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = makeRecord(fixture.path)
        try appendJSON(["type": "session_meta", "payload": ["id": record.id]], to: fixture.path)
        let reader = CodexSessionActivityReader()
        let idle = await reader.snapshot(records: [record])
        XCTAssertTrue(idle.unknownThreadIDs.isEmpty)

        try appendJSON(["type": "event_msg", "payload": ["type": "user_message", "message": "Start work"]], to: fixture.path)
        let unconfirmed = await reader.snapshot(records: [record])
        XCTAssertEqual(unconfirmed.unknownThreadIDs, [record.id])

        try appendJSON(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "new-turn"]], to: fixture.path)
        let running = await reader.snapshot(records: [record])
        XCTAssertEqual(running.activeThreadIDs, [record.id])
        XCTAssertTrue(running.unknownThreadIDs.isEmpty)

        try appendJSON(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "new-turn"]], to: fixture.path)
        let completed = await reader.snapshot(records: [record])
        XCTAssertTrue(completed.activeThreadIDs.isEmpty)
        XCTAssertTrue(completed.unknownThreadIDs.isEmpty)
        XCTAssertEqual(completed.completedTasks, [CodexTaskCompletionEvent(threadID: record.id, turnID: "new-turn")])
    }

    func testSetupOnlySessionIsUnknownWhileAnAppendedRecordIsIncomplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = makeRecord(fixture.path)
        try appendJSON(["type": "session_meta", "payload": ["id": record.id]], to: fixture.path)
        let reader = CodexSessionActivityReader()
        let idle = await reader.snapshot(records: [record])
        XCTAssertTrue(idle.unknownThreadIDs.isEmpty)

        let handle = try FileHandle(forWritingTo: fixture.path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\"}".utf8))
        let incomplete = await reader.snapshot(records: [record])
        XCTAssertEqual(incomplete.unknownThreadIDs, [record.id])
        let initialIncomplete = await CodexSessionActivityReader().snapshot(records: [record])
        XCTAssertEqual(initialIncomplete.unknownThreadIDs, [record.id])

        try handle.write(contentsOf: Data("}\n".utf8))
        let complete = await reader.snapshot(records: [record])
        XCTAssertTrue(complete.unknownThreadIDs.isEmpty)
    }

    func testNonSetupOrMalformedRecordsWithoutLifecycleRemainUnknown() async throws {
        let recordsWithoutLifecycle = [
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\n",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}\n",
            "{\"type\":\"turn_context\",\"payload\":{}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"future_event\"}}\n",
            "not-json\n"
        ]
        for content in recordsWithoutLifecycle {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let record = makeRecord(fixture.path)
            try appendJSON(["type": "session_meta", "payload": ["id": record.id]], to: fixture.path)
            let reader = CodexSessionActivityReader()
            _ = await reader.snapshot(records: [record])
            let handle = try FileHandle(forWritingTo: fixture.path)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
            try handle.close()

            let updated = await reader.snapshot(records: [record])
            XCTAssertEqual(updated.unknownThreadIDs, [record.id], content)
            let initial = await CodexSessionActivityReader().snapshot(records: [record])
            XCTAssertEqual(initial.unknownThreadIDs, [record.id], content)
        }
    }

    func testActivityReaderEmitsInteractiveQuestionsFromProtocolItems() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = makeRecord(fixture.path)
        let reader = CodexSessionActivityReader()
        _ = await reader.snapshot(records: [record])

        try appendJSON([
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn-42"]
        ], to: fixture.path)
        _ = await reader.snapshot(records: [record])

        try appendJSON([
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "request_user_input",
                "call_id": "call-1",
                "arguments": "private question"
            ]
        ], to: fixture.path)
        try appendJSON([
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "request_user_input_async",
                "call_id": "call-2"
            ]
        ], to: fixture.path)
        try appendJSON([
            "type": "response_item",
            "payload": ["type": "function_call_output", "call_id": "call-1"]
        ], to: fixture.path)

        let snapshot = await reader.snapshot(records: [record])
        XCTAssertEqual(snapshot.attentionEvents.map(\.requestID), ["call-1", "call-2"])
        XCTAssertTrue(snapshot.attentionEvents.allSatisfy { $0.kind == .userInput && $0.turnID == "turn-42" })
        XCTAssertTrue(snapshot.activeThreadIDs.contains(record.id))
        let nextSnapshot = await reader.snapshot(records: [record])
        XCTAssertTrue(nextSnapshot.attentionEvents.isEmpty)
    }

    func testActivityReaderDoesNotReplayQuestionOnInitialScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try appendJSON(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "old"]], to: fixture.path)
        try appendJSON([
            "type": "response_item",
            "payload": ["type": "function_call", "name": "request_user_input", "call_id": "old-call"]
        ], to: fixture.path)

        let snapshot = await CodexSessionActivityReader().snapshot(records: [makeRecord(fixture.path)])
        XCTAssertTrue(snapshot.attentionEvents.isEmpty)
    }

    func testLifecycleTimingRestoresStartAndUsesCompletionTimestamp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = makeRecord(fixture.path)
        try appendJSON(["type": "event_msg", "timestamp": "2026-09-05T10:00:00.000Z",
                        "payload": ["type": "task_started", "turn_id": "one"]], to: fixture.path)
        let reader = CodexSessionActivityReader()
        let running = await reader.snapshot(records: [record])
        let start = try XCTUnwrap(running.startedAt[record.id])
        try appendJSON(["type": "event_msg", "timestamp": "2026-09-05T10:02:00Z",
                        "payload": ["type": "task_complete", "turn_id": "one"]], to: fixture.path)
        let finished = await reader.snapshot(records: [record])
        XCTAssertEqual(finished.startedAt[record.id], start)
        XCTAssertEqual(try XCTUnwrap(finished.endedAt[record.id]).timeIntervalSince(start), 120)
        var task = CodexTask(id: "test", title: "", summary: "", updatedAt: start.addingTimeInterval(100),
                             path: nil, isRunning: true, startedAt: start)
        XCTAssertEqual(task.timeText(at: start.addingTimeInterval(125)), "2:05")
        XCTAssertEqual(task.timeText(at: start.addingTimeInterval(3661)), "1:01:01")
        task.isRunning = false
        task.endedAt = start.addingTimeInterval(120)
        XCTAssertEqual(task.timeText(at: start.addingTimeInterval(180)), "1m ago")
    }

    private func makeFixture() throws -> (directory: URL, path: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeputyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        return (directory, path)
    }

    private func makeRecord(_ path: URL) -> CodexThreadRecord {
        CodexThreadRecord(
            id: "thread-1",
            title: "Test task",
            summary: "Fallback preview",
            updatedAt: .now,
            path: path
        )
    }

    private func appendJSON(_ object: [String: Any], to path: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
