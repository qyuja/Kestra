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
        XCTAssertEqual(AIProvider.allCases.count, 15)
        XCTAssertTrue(AIProvider.pi.isImplemented)
        XCTAssertTrue(AIProvider.ohMyPi.isImplemented)
        XCTAssertTrue(AIProvider.cursor.isImplemented)
        XCTAssertFalse(AIProvider.deepseekHarness.isImplemented)
        defaults.set("claudeCowork,claude,codex", forKey: "selectedAIProviders")
        XCTAssertEqual(AIProviderSelectionStore(defaults: defaults).selectedProviders, [.codex, .claude])
        XCTAssertEqual(AIProvider.claude.name, "Claude")
        XCTAssertEqual(AIProvider.codex.name, "ChatGPT")
        XCTAssertEqual(AIProvider.codex.rawValue, "codex")
    }

    @MainActor
    func testProviderOrderCanBeMovedAndPersists() throws {
        let suite = "KestraTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderSelectionStore(defaults: defaults)
        store.toggle(.claude)
        store.move(.claude, before: .codex)

        XCTAssertEqual(store.selectedProviders, [.claude, .codex])

        let restored = AIProviderSelectionStore(defaults: defaults)
        XCTAssertEqual(restored.selectedProviders, [.claude, .codex])
        XCTAssertEqual(Array(restored.orderedProviders.prefix(2)), [.claude, .codex])
    }

    @MainActor
    func testProviderOrderCanMoveDownPastTargetAndToTheBottom() throws {
        let suite = "KestraTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIProviderSelectionStore(defaults: defaults)
        store.move(.codex, relativeTo: .claude)
        XCTAssertEqual(Array(store.orderedProviders.prefix(2)), [.claude, .codex])

        store.move(.codex, relativeTo: .kiro)
        XCTAssertEqual(store.orderedProviders.last, .codex)
        XCTAssertEqual(
            AIProviderSelectionStore(defaults: defaults).orderedProviders.last,
            .codex
        )
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

    @MainActor
    func testOhMyPiUsesItsOfficialLogoAsset() {
        XCTAssertNotNil(AIProviderLogoCatalog.image(for: .ohMyPi))
        XCTAssertNotNil(
            MenubarStatusIconRenderer.makeLogoImage(
                provider: .ohMyPi,
                usage: nil,
                isDark: true
            )
        )
    }

    func testModelMetadataNeverUsesResponseContent() {
        XCTAssertEqual(TaskModelReader.model(in: ["type": "turn_context", "payload": ["model": "test-codex"]]), "test-codex")
        XCTAssertEqual(TaskModelReader.model(in: ["message": ["model": "test-claude", "content": "not a model"]]), "test-claude")
        XCTAssertNil(TaskModelReader.model(in: ["content": "gpt-test", "provider": "openai"]))
    }

    @MainActor
    func testOhMyPiExtensionUsesTheCurrentAppBundleForEvents() throws {
        let data = try CLIHookIntegration.renderedOhMyPiResourceData(bundleIdentifier: "com.example.kestra.test")
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(source.contains("com.example.kestra.test/oh-my-pi-events"))
        XCTAssertFalse(source.contains("__KESTRA_BUNDLE_IDENTIFIER__"))
    }

    @MainActor
    func testOhMyPiIntegrationDiscoversDefaultAndNamedProfileDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configRoot = home.appendingPathComponent(".omp-work")
        let profiles = configRoot.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("work/agent"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("personal/agent"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let directories = CLIHookIntegration.ohMyPiAgentDirectories(
            homeDirectory: home,
            environment: ["PI_CONFIG_DIR": ".omp-work"]
        )

        XCTAssertEqual(Set(directories.map { $0.resolvingSymlinksInPath().standardizedFileURL }), Set([
            configRoot.appendingPathComponent("agent").resolvingSymlinksInPath().standardizedFileURL,
            profiles.appendingPathComponent("personal/agent").resolvingSymlinksInPath().standardizedFileURL,
            profiles.appendingPathComponent("work/agent").resolvingSymlinksInPath().standardizedFileURL,
        ]))

        let customAgent = home.appendingPathComponent("custom-agent")
        try FileManager.default.createDirectory(at: customAgent, withIntermediateDirectories: true)
        let overriddenDirectories = CLIHookIntegration.ohMyPiAgentDirectories(
            homeDirectory: home,
            environment: ["PI_CONFIG_DIR": ".omp-work", "PI_CODING_AGENT_DIR": customAgent.path]
        )
        XCTAssertEqual(Set(overriddenDirectories.map { $0.resolvingSymlinksInPath().standardizedFileURL }), Set([
            customAgent.resolvingSymlinksInPath().standardizedFileURL,
            profiles.appendingPathComponent("personal/agent").resolvingSymlinksInPath().standardizedFileURL,
            profiles.appendingPathComponent("work/agent").resolvingSymlinksInPath().standardizedFileURL,
        ]))

        let activeProfileDirectories = CLIHookIntegration.ohMyPiAgentDirectories(
            homeDirectory: home,
            environment: [
                "PI_CONFIG_DIR": ".omp-work",
                "OMP_PROFILE": "work",
                "PI_CODING_AGENT_DIR": customAgent.path,
            ]
        )
        XCTAssertEqual(
            activeProfileDirectories.first?.resolvingSymlinksInPath().standardizedFileURL,
            profiles.appendingPathComponent("work/agent").resolvingSymlinksInPath().standardizedFileURL
        )
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
