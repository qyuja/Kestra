import XCTest
@testable import Kestra

final class ClientTaskTests: XCTestCase {
    @MainActor
    func testClientSelectionDropsLegacyModelsButPreservesClients() throws {
        let suite = "KestraTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex,glm,deepseek,claude", forKey: "selectedAIProviders")
        XCTAssertEqual(AIProviderSelectionStore(defaults: defaults).selectedProviders, [.codex, .claude])
        XCTAssertEqual(AIProvider.allCases.count, 14)
        XCTAssertTrue(AIProvider.pi.isImplemented)
        XCTAssertTrue(AIProvider.cursor.isImplemented)
        XCTAssertFalse(AIProvider.deepseekHarness.isImplemented)
        defaults.set("claudeCowork,claude,codex", forKey: "selectedAIProviders")
        XCTAssertEqual(AIProviderSelectionStore(defaults: defaults).selectedProviders, [.codex, .claude])
        XCTAssertEqual(AIProvider.claude.name, "Claude")
        XCTAssertEqual(AIProvider.codex.name, "ChatGPT")
        XCTAssertEqual(AIProvider.codex.rawValue, "codex")
    }

    func testModelMetadataNeverUsesResponseContent() {
        XCTAssertEqual(TaskModelReader.model(in: ["type": "turn_context", "payload": ["model": "test-codex"]]), "test-codex")
        XCTAssertEqual(TaskModelReader.model(in: ["message": ["model": "test-claude", "content": "not a model"]]), "test-claude")
        XCTAssertNil(TaskModelReader.model(in: ["content": "gpt-test", "provider": "openai"]))
    }

    @MainActor
    func testEveryHookClientRetainsModelAndSeparatesFailureFromCompletion() throws {
        for provider in [.claude] + AIProvider.hookProviders {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let monitor = ClaudeHookMonitor(directory: directory, provider: provider)
            _ = monitor.poll(mode: .latestUser)
            func write(_ number: Int, kind: String, model: String? = nil) throws {
                var event = ["session_id": "same-id", "hook_event_name": kind, "prompt": "user input"]
                event["model"] = model
                try JSONSerialization.data(withJSONObject: event).write(to: directory.appendingPathComponent("\(number).json"))
            }
            try write(1, kind: "UserPromptSubmit", model: "model-a")
            XCTAssertTrue(try XCTUnwrap(monitor.poll(mode: .latestUser).tasks.first).isRunning)
            try write(2, kind: "ModelUpdate", model: "model-b")
            let updated = monitor.poll(mode: .latestUser)
            XCTAssertEqual(updated.tasks.first?.model, "model-b")
            XCTAssertEqual(updated.tasks.first?.provider, provider)
            XCTAssertEqual(updated.tasks.first?.claudeMode, provider == .claude ? .code : nil)
            XCTAssertTrue(try XCTUnwrap(updated.tasks.first).isRunning)
            try write(3, kind: "Stop")
            XCTAssertEqual(monitor.poll(mode: .latestUser).completed.first?.model, "model-b")
            XCTAssertTrue(monitor.poll(mode: .latestUser).completed.isEmpty)
            try write(4, kind: "UserPromptSubmit")
            _ = monitor.poll(mode: .latestUser)
            try write(5, kind: "StopFailure")
            try write(6, kind: "Stop")
            XCTAssertTrue(monitor.poll(mode: .latestUser).completed.isEmpty)
        }
    }
}
