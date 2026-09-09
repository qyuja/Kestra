import Foundation

/// A local, recoverable file-auth transaction. No credential is exposed through metadata or logs.
struct CodexCredentialSwap {
    let activeHome: URL
    let backupDirectory: URL

    var backupFile: URL { backupDirectory.appendingPathComponent("previous-auth.json") }

    static func workspaceID(at home: URL) throws -> String? {
        let data = try credentialData(at: home.appendingPathComponent("auth.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tokens = json?["tokens"] as? [String: Any]
        guard let id = tokens?["account_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    static func validateFileAuth(at home: URL) throws {
        let config = home.appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: config.path) {
            let content = try String(contentsOf: config, encoding: .utf8)
            let pattern = #"(?m)^\s*cli_auth_credentials_store\s*=\s*["']([^"']+)["']"#
            let regex = try NSRegularExpression(pattern: pattern)
            if let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content), content[range] != "file" {
                throw SwitchError("当前配置不是文件型登录缓存，未修改登录状态")
            }
        }
        _ = try credentialData(at: home.appendingPathComponent("auth.json"))
    }

    static func credentialData(at file: URL) throws -> Data {
        guard !(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw SwitchError("登录缓存是符号链接，未修改登录状态")
        }
        let data = try Data(contentsOf: file)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw SwitchError("未找到可用的 ChatGPT 文件型登录缓存，请重新登录")
        }
        return data
    }

    /// Call only after the desktop has exited and local account readers have stopped.
    func prepare(targetHome: URL, savedCurrentHome: URL) throws {
        try Self.validateFileAuth(at: activeHome)
        try Self.validateFileAuth(at: targetHome)
        let current = try Self.credentialData(at: activeHome.appendingPathComponent("auth.json"))
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.writeSecret(current, to: backupFile)
        try FileManager.default.createDirectory(at: savedCurrentHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = savedCurrentHome.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try Self.writeSecret(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: config)
        }
        try Self.writeSecret(current, to: savedCurrentHome.appendingPathComponent("auth.json"))
    }

    func install(targetHome: URL) throws {
        guard FileManager.default.fileExists(atPath: backupFile.path) else { throw SwitchError("登录备份尚未完成") }
        let target = try Self.credentialData(at: targetHome.appendingPathComponent("auth.json"))
        try Self.writeSecret(target, to: activeHome.appendingPathComponent("auth.json"))
    }

    func restore() throws {
        try Self.writeSecret(Self.credentialData(at: backupFile), to: activeHome.appendingPathComponent("auth.json"))
    }

    private static func writeSecret(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    struct SwitchError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
