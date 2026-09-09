import Foundation

struct TaskBridgePaths: Sendable {
    let root: URL

    init(root: URL = TaskBridgePaths.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        KestraAppIdentity.applicationSupportDirectory
            .appendingPathComponent("task-bridge", isDirectory: true)
    }

    var accountsFile: URL { root.appendingPathComponent("accounts.json") }
    var tasksDirectory: URL { root.appendingPathComponent("tasks", isDirectory: true) }
    var messagesDirectory: URL { root.appendingPathComponent("messages", isDirectory: true) }
    var leasesDirectory: URL { root.appendingPathComponent("leases", isDirectory: true) }

    func taskDirectory(for taskID: String) -> URL {
        tasksDirectory.appendingPathComponent(safeComponent(taskID), isDirectory: true)
    }

    func handoffsDirectory(for taskID: String) -> URL {
        taskDirectory(for: taskID).appendingPathComponent("handoffs", isDirectory: true)
    }

    func taskFile(for taskID: String) -> URL {
        taskDirectory(for: taskID).appendingPathComponent("task.json")
    }

    func handoffJSONFile(taskID: String, handoffID: String) -> URL {
        handoffsDirectory(for: taskID).appendingPathComponent("\(safeComponent(handoffID)).json")
    }

    func handoffMarkdownFile(taskID: String, handoffID: String) -> URL {
        handoffsDirectory(for: taskID).appendingPathComponent("\(safeComponent(handoffID)).md")
    }

    /// Project-local copy that the Codex desktop Local environment can read.
    func projectHandoffMarkdownFile(projectPath: URL, taskID: String, handoffID: String) -> URL {
        projectTaskBridgeDirectory(projectPath: projectPath, taskID: taskID)
            .appendingPathComponent("\(safeComponent(handoffID)).md")
    }

    func projectTaskBridgeDirectory(projectPath: URL, taskID: String) -> URL {
        projectPath
            .appendingPathComponent(".codex/task-bridge", isDirectory: true)
            .appendingPathComponent(safeComponent(taskID), isDirectory: true)
    }

    func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        for directory in [root, tasksDirectory, messagesDirectory, leasesDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func ensureTaskDirectories(for taskID: String) throws {
        let fileManager = FileManager.default
        try ensureBaseDirectories()
        try fileManager.createDirectory(
            at: handoffsDirectory(for: taskID),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func ensureProjectTaskDirectories(projectPath: URL, taskID: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: projectTaskBridgeDirectory(projectPath: projectPath, taskID: taskID),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func safeComponent(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
                ? String(character)
                : "_"
        }.joined()
    }
}
