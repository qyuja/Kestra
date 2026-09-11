import Foundation

/// Owns the bridge's local state. It deliberately has no credential access.
actor TaskBridgeStore {
    let paths: TaskBridgePaths

    init(paths: TaskBridgePaths = TaskBridgePaths()) {
        self.paths = paths
    }

    func bootstrap() throws {
        try paths.ensureBaseDirectories()
    }

    func saveAccountProfiles(_ profiles: [CodexAccountProfile]) throws {
        try paths.ensureBaseDirectories()
        try writeJSON(profiles, to: paths.accountsFile)
    }

    func relocateAccount(id: String, home: URL) throws -> [CodexAccountProfile] {
        var profiles = try loadAccountProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CodexCredentialSwap.SwitchError("当前账号记录不存在，未切换")
        }
        profiles[index].codexHomePath = home.standardizedFileURL.resolvingSymlinksInPath()
        profiles[index].lastUsedAt = .now
        try saveAccountProfiles(profiles)
        return profiles
    }

    func loadAccountProfiles() throws -> [CodexAccountProfile] {
        guard FileManager.default.fileExists(atPath: paths.accountsFile.path) else {
            return []
        }
        let profiles = try readJSON([CodexAccountProfile].self, from: paths.accountsFile)
        let migratedProfiles = profiles.map { profile in
            var profile = profile
            profile.codexHomePath = KestraAppIdentity.migratedApplicationSupportURL(profile.codexHomePath)
            return profile
        }
        if migratedProfiles != profiles {
            try saveAccountProfiles(migratedProfiles)
        }
        return migratedProfiles
    }

    func renameAccount(id: String, name: String) throws -> [CodexAccountProfile] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CodexCredentialSwap.SwitchError("备注不能为空") }
        var profiles = try loadAccountProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CodexCredentialSwap.SwitchError("账号已不存在")
        }
        profiles[index].displayName = name
        try saveAccountProfiles(profiles)
        return profiles
    }

    // Removing registration never removes shared projects, history or credentials.
    func removeAccount(id: String) throws -> [CodexAccountProfile] {
        var profiles = try loadAccountProfiles()
        profiles.removeAll { $0.id == id }
        try saveAccountProfiles(profiles)
        return profiles
    }

    func renewAccount(id: String, identity: CodexAccountIdentity, home: URL) throws -> [CodexAccountProfile] {
        var profiles = try loadAccountProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CodexCredentialSwap.SwitchError("账号已不存在")
        }
        let existing = profiles[index]
        guard identity.email.lowercased() == existing.email?.lowercased(),
              existing.workspaceID.map({ $0 == identity.workspaceID }) ?? (existing.planType == identity.planType) else {
            throw CodexCredentialSwap.SwitchError("登录的邮箱或工作区不匹配，原账号未修改")
        }
        profiles[index].codexHomePath = home.standardizedFileURL.resolvingSymlinksInPath()
        profiles[index].planType = identity.planType
        profiles[index].workspaceID = identity.workspaceID
        profiles[index].lastUsedAt = .now
        try saveAccountProfiles(profiles)
        return profiles
    }

    func registerAccount(email: String, planType: String?, codexHome: URL, workspaceID: String? = nil) throws -> [CodexAccountProfile] {
        var profiles = try loadAccountProfiles()
        let home = codexHome.standardizedFileURL.resolvingSymlinksInPath()
        let isTeam = ["team", "business", "enterprise", "ent26", "edu"].contains { planType?.contains($0) == true }
        if let index = profiles.firstIndex(where: {
            $0.email?.lowercased() == email.lowercased() &&
            $0.codexHomePath.standardizedFileURL.resolvingSymlinksInPath() == home &&
            $0.isTeam == isTeam &&
            ($0.workspaceID == nil || workspaceID == nil || $0.workspaceID == workspaceID)
        }) {
            profiles[index].planType = planType
            profiles[index].lastUsedAt = .now
            if let workspaceID { profiles[index].workspaceID = workspaceID }
        } else {
            profiles.append(CodexAccountProfile(
                id: UUID().uuidString.lowercased(), displayName: email,
                codexHomePath: home, createdAt: .now, lastUsedAt: .now,
                isEnabled: true, email: email, planType: planType, workspaceID: workspaceID
            ))
        }
        try saveAccountProfiles(profiles)
        return profiles
    }

    func saveTask(_ task: TaskBridgeTask) throws {
        try paths.ensureTaskDirectories(for: task.id)
        try writeJSON(task, to: paths.taskFile(for: task.id))
    }

    func loadTask(id: String) throws -> TaskBridgeTask {
        try readJSON(TaskBridgeTask.self, from: paths.taskFile(for: id))
    }

    @discardableResult
    func createHandoff(
        for task: TaskBridgeTask,
        sourceSession: TaskBridgeSession? = nil,
        generatedAt: Date = .now
    ) throws -> HandoffSnapshot {
        try paths.ensureTaskDirectories(for: task.id)
        try paths.ensureProjectTaskDirectories(projectPath: task.projectPath, taskID: task.id)
        let snapshot = HandoffSnapshot(
            id: UUID().uuidString.lowercased(),
            taskID: task.id,
            sourceAccountID: sourceSession?.accountID ?? task.activeAccountID,
            sourceSessionID: sourceSession?.id ?? task.activeSessionID,
            createdAt: generatedAt,
            markdown: HandoffDocumentBuilder.markdown(
                for: task,
                sourceSession: sourceSession,
                generatedAt: generatedAt
            )
        )
        try writeJSON(snapshot, to: paths.handoffJSONFile(taskID: task.id, handoffID: snapshot.id))
        try writeText(snapshot.markdown, to: paths.handoffMarkdownFile(taskID: task.id, handoffID: snapshot.id))
        try writeText(
            snapshot.markdown,
            to: paths.projectHandoffMarkdownFile(
                projectPath: task.projectPath,
                taskID: task.id,
                handoffID: snapshot.id
            )
        )
        return snapshot
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), to: url)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func writeText(_ value: String, to url: URL) throws {
        try write(Data(value.utf8), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
