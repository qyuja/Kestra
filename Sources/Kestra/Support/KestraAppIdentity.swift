import Foundation

enum KestraAppIdentity {
    static let name = "Kestra"
    static let bundleIdentifier = "com.kiannest.kestra"

    // Kept only so an upgrade can find data created by the pre-Kestra build.
    static let legacyBundleIdentifier = "com.kiannest.islandbar"

    static var applicationSupportDirectory: URL {
        applicationSupportDirectory(for: bundleIdentifier)
    }

    static var legacyApplicationSupportDirectory: URL {
        applicationSupportDirectory(for: legacyBundleIdentifier)
    }

    /// Moves the old app-owned files once and merges non-conflicting children
    /// when a partial migration already created the new directory. Existing
    /// new files always win; the legacy directory is never deleted.
    static func migrateLegacyState(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        homeDirectory: URL? = nil
    ) throws {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let legacyDirectory = applicationSupportDirectory(for: legacyBundleIdentifier, homeDirectory: home)
        let currentDirectory = applicationSupportDirectory(for: bundleIdentifier, homeDirectory: home)

        try migrateDirectory(
            from: legacyDirectory,
            to: currentDirectory,
            fileManager: fileManager
        )
        migrateDefaults(defaults)
    }

    private static func applicationSupportDirectory(
        for bundleIdentifier: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private static func migrateDirectory(
        from legacyDirectory: URL,
        to currentDirectory: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyDirectory.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw MigrationError(message: "旧应用数据位置不是目录")
        }

        var currentIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: currentDirectory.path, isDirectory: &currentIsDirectory) {
            guard currentIsDirectory.boolValue else {
                throw MigrationError(message: "Kestra 应用数据位置不是目录")
            }

            let children = try fileManager.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            for child in children {
                let destination = currentDirectory.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.moveItem(at: child, to: destination)
            }
            return
        }

        try fileManager.createDirectory(
            at: currentDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
    }

    private static func migrateDefaults(_ defaults: UserDefaults) {
        guard let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier), !legacy.isEmpty else {
            return
        }

        var current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        var changed = false
        for (key, value) in legacy where current[key] == nil {
            current[key] = value
            changed = true
        }
        if changed {
            defaults.setPersistentDomain(current, forName: bundleIdentifier)
        }
    }

    private struct MigrationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }
}
