import Foundation
import XCTest
@testable import IslandBarDemo

final class CodexCredentialSwapTests: XCTestCase {
    func testWorkspaceIdentityWithoutQuotaStillRejectsOtherWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeHome(root, token: "fixture")
        XCTAssertNil(try CodexCredentialSwap.workspaceID(at: root))
        let data = try JSONSerialization.data(withJSONObject: ["tokens": [
            "access_token": "fixture", "refresh_token": "fixture", "account_id": "team-a"
        ]])
        try data.write(to: root.appendingPathComponent("auth.json"))
        let store = TaskBridgeStore(paths: TaskBridgePaths(root: root.appendingPathComponent("bridge")))
        let profiles = try await store.registerAccount(email: "a@example.com", planType: "team", codexHome: root, workspaceID: "team-a")
        var identity = CodexAccountIdentity(email: "a@example.com", planType: "team")
        XCTAssertFalse(identity.matches(profiles[0]))
        identity.workspaceID = try CodexCredentialSwap.workspaceID(at: root)
        XCTAssertTrue(identity.matches(profiles[0]))
        XCTAssertNil(identity.usage)
        identity.workspaceID = "team-b"
        XCTAssertFalse(identity.matches(profiles[0]))
    }

    func testAccountRoundTripKeepsLatestSharedSettingsAndInstructions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active")
        let accountB = root.appendingPathComponent("account-b")
        let accountA = root.appendingPathComponent("account-a")
        let credentialA = try makeHome(active, token: "fixture-a")
        _ = try makeHome(accountB, token: "fixture-b")
        let sharedFiles = [
            "config.toml", "AGENTS.md", "AGENTS.override.md", "instructions.md",
            "skills/example/SKILL.md", "rules/default.rules", "hooks.json",
            "automations/example/automation.toml", "plugins/config.json",
            "sessions/example.jsonl", ".codex-global-state.json"
        ]
        for path in sharedFiles {
            let file = active.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("shared-original".utf8).write(to: file)
        }
        // A dormant account's old preferences must never replace shared configuration.
        try Data("old-account-settings".utf8).write(to: accountB.appendingPathComponent("config.toml"))
        let toB = CodexCredentialSwap(activeHome: active, backupDirectory: root.appendingPathComponent("backup-a"))
        try toB.prepare(targetHome: accountB, savedCurrentHome: accountA)
        try toB.install(targetHome: accountB)
        for path in sharedFiles {
            let file = active.appendingPathComponent(path)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "shared-original")
            try Data("edited-while-using-b".utf8).write(to: file)
        }
        let toA = CodexCredentialSwap(activeHome: active, backupDirectory: root.appendingPathComponent("backup-b"))
        try toA.prepare(targetHome: accountA, savedCurrentHome: accountB)
        try toA.install(targetHome: accountA)
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("auth.json")), credentialA)
        for path in sharedFiles {
            XCTAssertEqual(try String(contentsOf: active.appendingPathComponent(path), encoding: .utf8), "edited-while-using-b")
        }
        try toA.restore()
        for path in sharedFiles {
            XCTAssertEqual(try String(contentsOf: active.appendingPathComponent(path), encoding: .utf8), "edited-while-using-b")
        }
        XCTAssertEqual(try String(contentsOf: accountB.appendingPathComponent("config.toml"), encoding: .utf8), "old-account-settings")
    }

    func testSharedProfilePinsBothRootsAndIgnoresEmbeddedBrowsers() throws {
        let home = URL(fileURLWithPath: "/tmp/shared-codex")
        let desktop = URL(fileURLWithPath: "/tmp/Custom Codex Desktop")
        let profile = try CodexSharedProfile.resolve(openFiles: [
            home.path + "/sqlite/codex-dev.db",
            desktop.path + "/Default/Local Storage/leveldb/LOCK",
            desktop.path + "/codex-browser-app/Local Storage/leveldb/LOCK",
            desktop.path + "/Default/Partitions/codex-browser-app/Local Storage/leveldb/LOCK"
        ], expectedHome: home)
        XCTAssertEqual(profile.home.path, home.resolvingSymlinksInPath().path)
        XCTAssertEqual(profile.desktopData.path, desktop.resolvingSymlinksInPath().path)
        XCTAssertEqual(profile.launchEnvironment, [
            "CODEX_HOME": home.resolvingSymlinksInPath().path,
            "CODEX_ELECTRON_USER_DATA_PATH": desktop.resolvingSymlinksInPath().path
        ])
    }

    func testUnknownOrAmbiguousSharedProfileBlocksSwitch() {
        let home = URL(fileURLWithPath: "/tmp/shared-codex")
        let database = home.path + "/sqlite/codex.db"
        let desktop = "/tmp/desktop/Default/Local Storage/leveldb/LOCK"
        for paths in [
            [database], [desktop],
            [database, desktop, "/tmp/other/sqlite/codex.db"],
            [database, desktop, "/tmp/other/Default/Local Storage/leveldb/LOCK"]
        ] {
            XCTAssertThrowsError(try CodexSharedProfile.resolve(openFiles: paths, expectedHome: home))
        }
    }

    func testSwitchAndRestorePreserveProjectAndHistoryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active")
        let target = root.appendingPathComponent("target")
        let saved = root.appendingPathComponent("saved")
        let first = try makeHome(active, token: "fixture-a")
        let second = try makeHome(target, token: "fixture-b")
        let history = active.appendingPathComponent("state_5.sqlite")
        let projects = active.appendingPathComponent(".codex-global-state.json")
        try Data("history-sentinel".utf8).write(to: history)
        try Data("projects-sentinel".utf8).write(to: projects)
        let swap = CodexCredentialSwap(activeHome: active, backupDirectory: root.appendingPathComponent("backup"))
        try swap.prepare(targetHome: target, savedCurrentHome: saved)
        try swap.install(targetHome: target)
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("auth.json")), second)
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("auth.json")), first)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("auth.json")), second)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "history-sentinel")
        XCTAssertEqual(try String(contentsOf: projects, encoding: .utf8), "projects-sentinel")
        try swap.restore()
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("auth.json")), first)
        for file in [swap.backupFile, saved.appendingPathComponent("auth.json"), active.appendingPathComponent("auth.json")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testUnsupportedStorageAndInvalidTargetDoNotChangeActiveLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active")
        let target = root.appendingPathComponent("target")
        let first = try makeHome(active, token: "fixture-a")
        _ = try makeHome(target, token: "fixture-b")
        try Data("cli_auth_credentials_store = \"keyring\"\n".utf8).write(to: active.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try CodexCredentialSwap.validateFileAuth(at: active))
        let swap = CodexCredentialSwap(activeHome: active, backupDirectory: root.appendingPathComponent("backup"))
        XCTAssertThrowsError(try swap.install(targetHome: target), "Never replace a login without a backup")
        try Data("invalid".utf8).write(to: target.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try swap.prepare(targetHome: target, savedCurrentHome: root.appendingPathComponent("saved")))
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("auth.json")), first)
    }

    func testIncompleteOrMissingLifecycleBlocksRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: path)
        let record = CodexThreadRecord(id: "unknown", title: "Fixture", summary: "", updatedAt: .now, path: path)
        let snapshot = await CodexSessionActivityReader().snapshot(records: [record])
        XCTAssertEqual(snapshot.unknownThreadIDs, ["unknown"])
        try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"fixture\"}}".utf8).write(to: path)
        let incomplete = await CodexSessionActivityReader().snapshot(records: [record])
        XCTAssertEqual(incomplete.unknownThreadIDs, ["unknown"], "A record still being appended cannot authorize shutdown")
    }

    private func makeHome(_ home: URL, token: String) throws -> Data {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "refresh_token": "fixture-refresh"]])
        try data.write(to: home.appendingPathComponent("auth.json"))
        return data
    }
}
