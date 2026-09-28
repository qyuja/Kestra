import XCTest
@testable import AgentDeputy

final class AgentDeputyAppIdentityTests: XCTestCase {
    func testRebrandCopiesExistingAccountDataWithoutRemovingPreviousAppState() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let oldFile = supportDirectory(in: home, identifier: "com.kiannest.kestra")
            .appendingPathComponent("task-bridge/accounts.json")
        let newFile = supportDirectory(in: home, identifier: AgentDeputyAppIdentity.bundleIdentifier)
            .appendingPathComponent("task-bridge/accounts.json")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("account".utf8).write(to: oldFile)

        try AgentDeputyAppIdentity.migrateLegacyState(homeDirectory: home)

        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "account")
        XCTAssertEqual(try String(contentsOf: oldFile, encoding: .utf8), "account")
        XCTAssertEqual(AgentDeputyAppIdentity.migratedApplicationSupportURL(oldFile, homeDirectory: home), newFile)
    }

    func testBothPreviousAppNamespacesRewriteAccountPaths() {
        let home = temporaryHome()
        let current = supportDirectory(in: home, identifier: AgentDeputyAppIdentity.bundleIdentifier)
        for oldIdentifier in AgentDeputyAppIdentity.legacyBundleIdentifiers {
            let oldPath = supportDirectory(in: home, identifier: oldIdentifier)
                .appendingPathComponent("task-bridge/profiles/account/codex", isDirectory: true)
            let newPath = current.appendingPathComponent("task-bridge/profiles/account/codex", isDirectory: true)
            XCTAssertEqual(AgentDeputyAppIdentity.migratedApplicationSupportURL(oldPath, homeDirectory: home), newPath)
        }
        let unrelated = home.appendingPathComponent("Library/Other", isDirectory: true)
        XCTAssertEqual(AgentDeputyAppIdentity.migratedApplicationSupportURL(unrelated, homeDirectory: home), unrelated)
    }

    func testPartialMigrationMergesNestedDataWithoutOverwritingCurrentFiles() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = supportDirectory(in: home, identifier: "com.kiannest.kestra")
            .appendingPathComponent("task-bridge", isDirectory: true)
        let current = supportDirectory(in: home, identifier: AgentDeputyAppIdentity.bundleIdentifier)
            .appendingPathComponent("task-bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("accounts.json"))
        try Data("extra".utf8).write(to: old.appendingPathComponent("history.json"))
        try Data("current".utf8).write(to: current.appendingPathComponent("accounts.json"))

        try AgentDeputyAppIdentity.migrateLegacyState(homeDirectory: home)

        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("accounts.json"), encoding: .utf8), "current")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("history.json"), encoding: .utf8), "extra")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("accounts.json"), encoding: .utf8), "old")
    }

    func testNewestOldReleaseTakesPrecedenceOverIslandBarData() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for (identifier, value) in [("com.kiannest.kestra", "newer"), ("com.kiannest.islandbar", "older")] {
            let file = supportDirectory(in: home, identifier: identifier).appendingPathComponent("accounts.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }

        try AgentDeputyAppIdentity.migrateLegacyState(homeDirectory: home)

        let currentFile = supportDirectory(in: home, identifier: AgentDeputyAppIdentity.bundleIdentifier)
            .appendingPathComponent("accounts.json")
        XCTAssertEqual(try String(contentsOf: currentFile, encoding: .utf8), "newer")
    }

    func testMigratesSettingsFromPreviousNamespacesWithoutTouchingRealDefaults() throws {
        let suiteName = "AgentDeputyMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let current = suiteName + ".current"
        let previous = suiteName + ".previous"
        let island = suiteName + ".oldest"
        defer {
            for domain in [current, previous, island, suiteName] {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        defaults.setPersistentDomain(["theme": "dark", "shared": "newer"], forName: previous)
        defaults.setPersistentDomain(["preview": "first", "shared": "oldest"], forName: island)
        defaults.setPersistentDomain(["shared": "current"], forName: current)

        try AgentDeputyAppIdentity.migrateLegacyState(defaults: defaults,
            homeDirectory: temporaryHome(), currentIdentifier: current, oldIdentifiers: [previous, island])

        let migrated = try XCTUnwrap(defaults.persistentDomain(forName: current))
        XCTAssertEqual(migrated["theme"] as? String, "dark")
        XCTAssertEqual(migrated["preview"] as? String, "first")
        XCTAssertEqual(migrated["shared"] as? String, "current")
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeputyIdentity-\(UUID().uuidString)", isDirectory: true)
    }

    private func supportDirectory(in home: URL, identifier: String) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }
}
