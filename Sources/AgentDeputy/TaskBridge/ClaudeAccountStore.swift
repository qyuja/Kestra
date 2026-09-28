import AppKit
import Combine

struct ClaudeAccountProfile: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var identity: ClaudeAccountIdentity
}

@MainActor
final class ClaudeAccountStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeAccountProfile] = []
    @Published private(set) var currentID: String?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let root = TaskBridgePaths.defaultRoot.appendingPathComponent("claude", isDirectory: true)
    private var metadata: URL { root.appendingPathComponent("accounts.json") }
    private var recovery: URL { root.appendingPathComponent("pending-switch.json") }
    private var operation: Task<Void, Never>?
    @Published private(set) var loggingIn = false
    private var loadedIdentity = false

    init() {
        do {
            if FileManager.default.fileExists(atPath: metadata.path) {
                profiles = try JSONDecoder().decode([ClaudeAccountProfile].self, from: Data(contentsOf: metadata))
            }
            if FileManager.default.fileExists(atPath: recovery.path) { message = "上次切换未确认，请先恢复原账号" }
        } catch { message = "Claude 账号记录读取失败：\(error.localizedDescription)" }
    }

    var needsRecovery: Bool { FileManager.default.fileExists(atPath: recovery.path) }

    private func save(_ profiles: [ClaudeAccountProfile]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: metadata, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        self.profiles = profiles
    }

    private func perform(_ body: @escaping (URL) async throws -> Void) {
        guard !busy else { return }
        guard let executable = ClaudeHookMonitor.executable else { message = "本机尚未安装 Claude Code"; return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await ClaudeAccountBackend.checkCompatibility(executable: executable)
                try await body(executable)
            } catch { message = error.localizedDescription }
        }
    }

    func cancelLogin() { if loggingIn { operation?.cancel() } }

    func loadIfNeeded() {
        guard !loadedIdentity, !busy, !needsRecovery else { return }
        loadedIdentity = true
        refresh()
    }

    private func identity(_ executable: URL, directory: URL? = nil) async throws -> ClaudeAccountIdentity {
        try await ClaudeAccountIdentity.parse(ClaudeAccountBackend.run(executable: executable, arguments: ["auth", "status"], directory: directory))
    }

    private func register(_ identity: ClaudeAccountIdentity, snapshot: ClaudeLoginSnapshot, replacing: ClaudeAccountProfile? = nil) throws -> String {
        if let replacing, !replacing.identity.matches(identity) {
            throw ClaudeAccountError("登录邮箱或组织不匹配，原账号未修改")
        }
        var updated = profiles
        let existing = replacing ?? profiles.first { $0.identity.matches(identity) }
        let id = existing?.id ?? UUID().uuidString.lowercased()
        try ClaudeAccountBackend.writeVaultSecret(JSONEncoder().encode(snapshot), account: id)
        if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].identity = identity }
        else { updated.append(ClaudeAccountProfile(id: id, name: identity.email, identity: identity)) }
        try save(updated)
        return id
    }

    func refresh() {
        perform { executable in
            guard !self.needsRecovery else { throw ClaudeAccountError("请先恢复未完成的切换") }
            self.currentID = nil
            let identity = try await self.identity(executable)
            self.currentID = try self.register(identity, snapshot: ClaudeAccountBackend.snapshot())
            self.message = "当前账号已同步"
        }
    }

    func login(replacing: ClaudeAccountProfile? = nil) {
        perform { executable in
            self.loggingIn = true
            defer { self.loggingIn = false }
            guard !self.needsRecovery else { throw ClaudeAccountError("请先恢复未完成的切换") }
            try await ClaudeAccountBackend.requireNoClaudeProcesses()
            let hasCredentials = try ClaudeAccountBackend.readSecret(service: ClaudeAccountBackend.credentialService, account: NSUserName()) != nil
            // First login goes through the official CLI in its normal home.
            let directory = hasCredentials ? self.root.appendingPathComponent("logins/\(UUID().uuidString.lowercased())", isDirectory: true) : nil
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let settings = ClaudeHookMonitor.configDirectory.appendingPathComponent("settings.json")
                if FileManager.default.fileExists(atPath: settings.path) {
                    try FileManager.default.copyItem(at: settings, to: directory.appendingPathComponent("settings.json"))
                }
            }
            self.message = "请在浏览器完成 Claude 登录；最多等待 3 分钟"
            var arguments = ["auth", "login", "--claudeai"]
            if let replacing { arguments += ["--email", replacing.identity.email] }
            _ = try await ClaudeAccountBackend.run(executable: executable, arguments: arguments, directory: directory, login: true)
            let identity = try await self.identity(executable, directory: directory)
            let id = try self.register(identity, snapshot: ClaudeAccountBackend.snapshot(directory: directory), replacing: replacing)
            if directory == nil { self.currentID = id }
            else if self.currentID == id { self.currentID = nil }
            self.message = directory == nil ? "已登录并保存账号" : "登录缓存已保存，点击账号切换使其生效；会话和配置未迁移"
        }
    }

    func switchAccount(_ profile: ClaudeAccountProfile, hasRunningTasks: Bool) {
        guard !hasRunningTasks else { message = "Claude 有运行中任务，不能切换"; return }
        perform { executable in
            guard !self.needsRecovery else { throw ClaudeAccountError("请先恢复未完成的切换") }
            try await ClaudeAccountBackend.requireNoClaudeProcesses()
            guard let saved = try ClaudeAccountBackend.readVaultSecret(account: profile.id) else {
                throw ClaudeAccountError("账号缓存不存在，请重新登录")
            }
            let target = try JSONDecoder().decode(ClaudeLoginSnapshot.self, from: saved)
            try target.validateTarget(profile.identity)
            let source = try ClaudeAccountBackend.snapshot()
            let backupID = "recovery-" + UUID().uuidString.lowercased()
            try ClaudeAccountBackend.writeVaultSecret(JSONEncoder().encode(source), account: backupID)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(backupID).write(to: self.recovery, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.recovery.path)
            do {
                // Refresh the outgoing snapshot so refreshed tokens are not lost.
                if let identity = try? await self.identity(executable) { _ = try self.register(identity, snapshot: source) }
                try await ClaudeAccountBackend.requireNoClaudeProcesses()
                try ClaudeAccountBackend.install(target)
                let actual = try await self.identity(executable)
                guard actual.matches(profile.identity) else { throw ClaudeAccountError("切换后身份校验失败") }
                _ = try self.register(actual, snapshot: ClaudeAccountBackend.snapshot())
                try FileManager.default.removeItem(at: self.recovery)
                self.currentID = profile.id
                self.message = "已切换；在原项目运行 claude --resume 选择原会话"
            } catch {
                do {
                    try await ClaudeAccountBackend.requireNoClaudeProcesses()
                    try ClaudeAccountBackend.install(source)
                    try FileManager.default.removeItem(at: self.recovery)
                    self.message = "切换失败，已还原原登录缓存：\(error.localizedDescription)"
                } catch { self.currentID = nil; self.message = "切换未完成，原登录缓存已备份，请关闭 Claude 后点击恢复原账号" }
            }
        }
    }

    func recover() {
        perform { _ in
            try await ClaudeAccountBackend.requireNoClaudeProcesses()
            let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: self.recovery))
            guard let data = try ClaudeAccountBackend.readVaultSecret(account: id) else { throw ClaudeAccountError("未找到恢复缓存") }
            try ClaudeAccountBackend.install(JSONDecoder().decode(ClaudeLoginSnapshot.self, from: data))
            try FileManager.default.removeItem(at: self.recovery)
            self.currentID = nil
            self.message = "已恢复原登录缓存，请刷新账号身份"
        }
    }

    func rename(_ profile: ClaudeAccountProfile, name: String) {
        guard !busy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            var updated = profiles
            guard let index = updated.firstIndex(where: { $0.id == profile.id }) else { return }
            updated[index].name = name
            try save(updated)
        } catch { message = error.localizedDescription }
    }

    func remove(_ profile: ClaudeAccountProfile) {
        guard !busy, profile.id != currentID, !needsRecovery else { return }
        do { try save(profiles.filter { $0.id != profile.id }); message = "已移除登记，钥匙串缓存和会话保留" }
        catch { message = error.localizedDescription }
    }
}
