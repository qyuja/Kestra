import XCTest
@testable import AgentDeputy

final class ClientTaskTests: XCTestCase {
    @MainActor
    func testOnlyCodexAndClaudeCodeRemainAndLegacySelectionsAreFiltered() throws {
        let suite = "AgentDeputyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("opencode,claude,cursor,codex,pi,ohMyPi", forKey: "orderedAIProviders")
        defaults.set("codex,glm,deepseek,claude,cursor,opencode", forKey: "selectedAIProviders")

        let store = AIProviderSelectionStore(defaults: defaults)
        XCTAssertEqual(AIProvider.allCases, [.codex, .claude])
        XCTAssertEqual(store.orderedProviders, [.claude, .codex])
        XCTAssertEqual(store.selectedProviders, [.claude, .codex])
        XCTAssertEqual(AIProvider.claude.name, "Claude Code")
        XCTAssertEqual(AIProvider.codex.name, "ChatGPT")
        XCTAssertEqual(AIProvider.codex.rawValue, "codex")

        defaults.set("claudeCowork,opencode", forKey: "selectedAIProviders")
        XCTAssertEqual(AIProviderSelectionStore(defaults: defaults).selectedProviders, [.codex])
    }

    @MainActor
    func testProviderOrderCanBeMovedAndPersists() throws {
        let suite = "AgentDeputyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderSelectionStore(defaults: defaults)
        store.toggle(.claude)
        store.move(.claude, before: .codex)

        XCTAssertEqual(store.selectedProviders, [.claude, .codex])

        let restored = AIProviderSelectionStore(defaults: defaults)
        XCTAssertEqual(restored.selectedProviders, [.claude, .codex])
        XCTAssertEqual(restored.orderedProviders, [.claude, .codex])
    }

    @MainActor
    func testProviderOrderCanMoveDownAcrossTheOnlyOtherProvider() throws {
        let suite = "AgentDeputyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderSelectionStore(defaults: defaults)
        store.move(.codex, relativeTo: .claude)
        XCTAssertEqual(store.orderedProviders, [.claude, .codex])
        store.move(.codex, relativeTo: .claude)
        XCTAssertEqual(store.orderedProviders, [.codex, .claude])
        XCTAssertEqual(AIProviderSelectionStore(defaults: defaults).orderedProviders, [.codex, .claude])
    }

    @MainActor
    func testRetiredClientHookCallbacksDoNotLaunchTheMenuBarApp() {
        XCTAssertTrue(AppDelegate.isRetiredClientHookInvocation(arguments: ["AgentDeputy", "--pi-hook"]))
        XCTAssertTrue(AppDelegate.isRetiredClientHookInvocation(arguments: ["AgentDeputy", "--workbuddy-hook", "Stop"]))
        XCTAssertFalse(AppDelegate.isRetiredClientHookInvocation(arguments: ["AgentDeputy", "--claude-hook"]))
        XCTAssertFalse(AppDelegate.isRetiredClientHookInvocation(arguments: ["AgentDeputy"]))
    }

    func testRunningProviderTieBreakUsesTheLatestTaskUpdate() {
        let olderUpdate = CodexTask(
            id: "codex-task",
            title: "Codex task",
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 250),
            path: nil,
            isRunning: true,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        let newerUpdate = CodexTask(
            id: "claude-task",
            title: "Claude task",
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 300),
            path: nil,
            isRunning: true,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        let selected = MenuBarRunningProviderSelector.select([
            (provider: .codex, tasks: [olderUpdate]),
            (provider: .claude, tasks: [newerUpdate]),
        ])

        XCTAssertEqual(selected, .claude)
    }

    func testModelMetadataNeverUsesResponseContent() {
        XCTAssertEqual(TaskModelReader.model(in: ["type": "turn_context", "payload": ["model": "test-codex"]]), "test-codex")
        XCTAssertEqual(TaskModelReader.model(in: ["message": ["model": "test-claude", "content": "not a model"]]), "test-claude")
        XCTAssertNil(TaskModelReader.model(in: ["content": "gpt-test", "provider": "openai"]))
    }
}
