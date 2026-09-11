import XCTest
@testable import Kestra

final class KestraAppIdentityTests: XCTestCase {
    func testRewritesPersistedLegacyApplicationSupportPaths() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KestraIdentity-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let legacyPath = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(KestraAppIdentity.legacyBundleIdentifier, isDirectory: true)
            .appendingPathComponent("task-bridge/profiles/account/codex", isDirectory: true)
        let expectedPath = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(KestraAppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("task-bridge/profiles/account/codex", isDirectory: true)

        XCTAssertEqual(
            KestraAppIdentity.migratedApplicationSupportURL(legacyPath, homeDirectory: home),
            expectedPath
        )
        XCTAssertEqual(
            KestraAppIdentity.migratedApplicationSupportURL(
                home.appendingPathComponent("Library/Other", isDirectory: true),
                homeDirectory: home
            ),
            home.appendingPathComponent("Library/Other", isDirectory: true)
        )
    }

    func testMovesLegacyApplicationDataIntoKestraDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KestraIdentity-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(KestraAppIdentity.legacyBundleIdentifier, isDirectory: true)
        let legacyFile = legacyRoot.appendingPathComponent("task-bridge/accounts.json")
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyFile)
        defer { try? FileManager.default.removeItem(at: home) }

        try KestraAppIdentity.migrateLegacyState(homeDirectory: home)

        let currentFile = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(KestraAppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("task-bridge/accounts.json")
        XCTAssertEqual(try String(contentsOf: currentFile, encoding: .utf8), "legacy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testPreservesCurrentFilesWhenMergingPartialMigration() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KestraIdentity-\(UUID().uuidString)", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacyRoot = support.appendingPathComponent(KestraAppIdentity.legacyBundleIdentifier, isDirectory: true)
        let currentRoot = support.appendingPathComponent(KestraAppIdentity.bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("accounts.json"))
        try Data("current".utf8).write(to: currentRoot.appendingPathComponent("settings.json"))
        defer { try? FileManager.default.removeItem(at: home) }

        try KestraAppIdentity.migrateLegacyState(homeDirectory: home)

        XCTAssertEqual(try String(contentsOf: currentRoot.appendingPathComponent("accounts.json"), encoding: .utf8), "legacy")
        XCTAssertEqual(try String(contentsOf: currentRoot.appendingPathComponent("settings.json"), encoding: .utf8), "current")
    }

    func testMigratesLegacyUserDefaultsWithoutOverwritingKestraValues() throws {
        let suiteName = "KestraIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: KestraAppIdentity.legacyBundleIdentifier)
            defaults.removePersistentDomain(forName: KestraAppIdentity.bundleIdentifier)
            defaults.removeSuite(named: suiteName)
        }
        defaults.setPersistentDomain(["legacyOnly": "copied", "shared": "legacy"], forName: KestraAppIdentity.legacyBundleIdentifier)
        defaults.setPersistentDomain(["shared": "current"], forName: KestraAppIdentity.bundleIdentifier)

        try KestraAppIdentity.migrateLegacyState(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)

        let current = try XCTUnwrap(defaults.persistentDomain(forName: KestraAppIdentity.bundleIdentifier))
        XCTAssertEqual(current["legacyOnly"] as? String, "copied")
        XCTAssertEqual(current["shared"] as? String, "current")
    }
}
