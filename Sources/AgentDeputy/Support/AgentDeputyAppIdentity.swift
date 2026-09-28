import Foundation

enum AgentDeputyAppIdentity {
    static let name = "AgentDeputy"
    private static let productionBundleIdentifier = "com.kiannest.agentdeputy"
    private static let developmentBundleIdentifier = "com.kiannest.agentdeputy.dev"
    static var displayName: String {
        bundleIdentifier == developmentBundleIdentifier ? "\(name) Dev" : name
    }
    static let bundleIdentifier: String = {
        Bundle.main.bundleIdentifier == developmentBundleIdentifier
            ? developmentBundleIdentifier
            : productionBundleIdentifier
    }()

    // Newest source wins when older releases left overlapping state behind.
    static let legacyBundleIdentifiers: [String] = {
        let suffix = bundleIdentifier == developmentBundleIdentifier ? ".dev" : ""
        return ["com.kiannest.kestra\(suffix)", "com.kiannest.islandbar\(suffix)"]
    }()

    static var applicationSupportDirectory: URL {
        applicationSupportDirectory(for: bundleIdentifier)
    }

    /// Paths embedded in account metadata must follow the copied directory.
    static func migratedApplicationSupportURL(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let currentRoot = applicationSupportDirectory(
            for: bundleIdentifier,
            homeDirectory: homeDirectory
        ).standardizedFileURL
        let path = url.standardizedFileURL.path
        for oldIdentifier in legacyBundleIdentifiers {
            let oldRoot = applicationSupportDirectory(for: oldIdentifier, homeDirectory: homeDirectory)
                .standardizedFileURL
            let oldPrefix = oldRoot.path + "/"
            guard path.hasPrefix(oldPrefix) else { continue }
            return currentRoot
                .appendingPathComponent(String(path.dropFirst(oldPrefix.count)), isDirectory: url.hasDirectoryPath)
                .standardizedFileURL
        }
        return url
    }

    /// Copy rather than move: an installed older app may still be running.
    /// Existing AgentDeputy files always win after a partial migration.
    static func migrateLegacyState(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        homeDirectory: URL? = nil,
        currentIdentifier: String = bundleIdentifier,
        oldIdentifiers: [String] = legacyBundleIdentifiers
    ) throws {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let currentDirectory = applicationSupportDirectory(for: currentIdentifier, homeDirectory: home)
        for oldIdentifier in oldIdentifiers {
            let oldDirectory = applicationSupportDirectory(for: oldIdentifier, homeDirectory: home)
            try copyNonConflicting(from: oldDirectory, to: currentDirectory, fileManager: fileManager)
        }
        migrateDefaults(defaults, from: oldIdentifiers, to: currentIdentifier)
    }

    private static func applicationSupportDirectory(
        for bundleIdentifier: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private static func copyNonConflicting(
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
        if fileManager.fileExists(atPath: currentDirectory.path, isDirectory: &currentIsDirectory),
           !currentIsDirectory.boolValue {
            throw MigrationError(message: "AgentDeputy 应用数据位置不是目录")
        }
        try fileManager.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let children = try fileManager.contentsOfDirectory(
            at: legacyDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )
        for child in children {
            let destination = currentDirectory.appendingPathComponent(child.lastPathComponent)
            var destinationIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
                let childIsDirectory = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if childIsDirectory && destinationIsDirectory.boolValue {
                    try copyNonConflicting(from: child, to: destination, fileManager: fileManager)
                }
                continue
            }
            try fileManager.copyItem(at: child, to: destination)
        }
    }

    private static func migrateDefaults(_ defaults: UserDefaults, from oldIdentifiers: [String], to currentIdentifier: String) {
        var current = defaults.persistentDomain(forName: currentIdentifier) ?? [:]
        var changed = false
        for oldIdentifier in oldIdentifiers {
            guard let legacy = defaults.persistentDomain(forName: oldIdentifier) else { continue }
            for (key, value) in legacy where current[key] == nil {
                current[key] = value
                changed = true
            }
        }
        if changed {
            defaults.setPersistentDomain(current, forName: currentIdentifier)
        }
    }

    private struct MigrationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }
}
