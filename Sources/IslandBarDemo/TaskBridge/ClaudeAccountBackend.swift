import Foundation
import Security
import CryptoKit

struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
    let email: String
    let orgId: String
    let subscriptionType: String?

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard value?["loggedIn"] as? Bool == true,
              value?["authMethod"] as? String == "claude.ai",
              let email = value?["email"] as? String, !email.isEmpty,
              let org = value?["orgId"] as? String, !org.isEmpty else {
            throw ClaudeAccountError("尚未登录 Claude 订阅账号，或身份信息不完整")
        }
        return Self(email: email, orgId: org, subscriptionType: value?["subscriptionType"] as? String)
    }

    func matches(_ other: Self) -> Bool {
        email.caseInsensitiveCompare(other.email) == .orderedSame && orgId == other.orgId
    }
}

struct ClaudeAccountError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Only identity fields travel with credentials. Projects and preferences remain in place.
struct ClaudeLoginSnapshot: Codable {
    let credentials: Data
    let account: Data

    static func replacingAccount(in config: Data?, account: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: config ?? Data("{}".utf8)) as? [String: Any],
              let identity = try JSONSerialization.jsonObject(with: account) as? [String: Any] else {
            throw ClaudeAccountError("Claude 配置格式未知，未修改")
        }
        object["oauthAccount"] = identity
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    func validateTarget(_ expected: ClaudeAccountIdentity, now: Date = .now) throws {
        let identity = try JSONSerialization.jsonObject(with: account) as? [String: Any]
        let value = try JSONSerialization.jsonObject(with: credentials) as? [String: Any]
        let oauth = value?["claudeAiOauth"] as? [String: Any]
        guard let email = identity?["emailAddress"] as? String,
              email.caseInsensitiveCompare(expected.email) == .orderedSame,
              identity?["organizationUuid"] as? String == expected.orgId else {
            throw ClaudeAccountError("账号缓存身份不匹配，请重新登录")
        }
        guard let expiry = oauth?["expiresAt"] as? Double, expiry > now.timeIntervalSince1970 * 1000,
              let access = oauth?["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth?["refreshToken"] as? String, !refresh.isEmpty else {
            throw ClaudeAccountError("账号缓存已过期或不完整，请先重新登录")
        }
    }
}

enum ClaudeAccountBackend {
    static let credentialService = "Claude Code-credentials"
    static let vaultService = "com.kiannest.islandbar.claude-accounts"
    static var configFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    static func stagingService(_ directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.path.precomposedStringWithCanonicalMapping.utf8))
        return credentialService + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    static func readSecret(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeAccountError("无法读取 Claude 钥匙串（\(status)），未切换")
        }
        return data
    }

    static func writeSecret(_ data: Data, service: String, account: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as [CFString: Any]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClaudeAccountError("无法保存 Claude 钥匙串（\(status)）") }
    }

    static func snapshot(directory: URL? = nil) throws -> ClaudeLoginSnapshot {
        let config = directory?.appendingPathComponent(".claude.json") ?? configFile
        let service = directory.map(stagingService) ?? credentialService
        guard let credentials = try readSecret(service: service, account: NSUserName()),
              let value = try JSONSerialization.jsonObject(with: credentials) as? [String: Any],
              let oauth = value["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
            throw ClaudeAccountError("未找到受支持的 Claude 钥匙串登录缓存；不自动改写文件型凭据")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        guard let account = object?["oauthAccount"] as? [String: Any] else {
            throw ClaudeAccountError("未找到 Claude 账号身份配置")
        }
        // Preserve only the subscription credential, not unrelated provider secrets.
        return try ClaudeLoginSnapshot(
            credentials: JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]),
            account: JSONSerialization.data(withJSONObject: account))
    }

    static func install(_ snapshot: ClaudeLoginSnapshot) throws {
        let original = try Data(contentsOf: configFile)
        let updated = try ClaudeLoginSnapshot.replacingAccount(in: original, account: snapshot.account)
        let existing = try readSecret(service: credentialService, account: NSUserName()) ?? Data("{}".utf8)
        guard var object = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let incoming = try JSONSerialization.jsonObject(with: snapshot.credentials) as? [String: Any],
              incoming["claudeAiOauth"] != nil else { throw ClaudeAccountError("Claude 登录缓存格式未知") }
        object["claudeAiOauth"] = incoming["claudeAiOauth"]
        try writeSecret(JSONSerialization.data(withJSONObject: object), service: credentialService, account: NSUserName())
        do {
            try updated.write(to: configFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        } catch {
            try writeSecret(existing, service: credentialService, account: NSUserName())
            throw error
        }
    }

    static func run(executable: URL, arguments: [String], directory: URL? = nil, login: Bool = false) async throws -> Data {
        let worker = Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["USER"] = NSUserName()
            if let directory { environment["CLAUDE_CONFIG_DIR"] = directory.path }
            process.environment = environment
            process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
            let output = Pipe()
            process.standardOutput = login ? FileHandle.nullDevice : output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(login ? 180 : 15)
            do {
                while process.isRunning {
                    if Date() > deadline { throw ClaudeAccountError("Claude 命令超时，请重试") }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                // This process is our auth helper, never a user's Claude session.
                if process.isRunning { process.terminate() }
                await Task.detached {
                    let stopDeadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < stopDeadline { try? await Task.sleep(for: .milliseconds(50)) }
                }.value
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? output.fileHandleForWriting.close()
                _ = await reader.value
                throw error
            }
            try? output.fileHandleForWriting.close()
            let data = await reader.value
            guard process.terminationStatus == 0 else { throw ClaudeAccountError(login ? "登录未完成，请在浏览器完成授权后重试" : "Claude 未登录或命令执行失败") }
            return data
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func checkCompatibility(executable: URL) async throws {
        // Keychain naming and oauthAccount are private formats verified against this build.
        let version = try await run(executable: executable, arguments: ["--version"])
        guard String(decoding: version, as: UTF8.self).hasPrefix("2.1.234 ") else {
            throw ClaudeAccountError("当前仅验证 Claude Code 2.1.234，其他版本需先确认凭据兼容性")
        }
        let environment = ProcessInfo.processInfo.environment
        let overrides = ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
        guard !overrides.contains(where: { environment[$0] != nil }) else {
            throw ClaudeAccountError("检测到自定义 Claude 认证或目录配置，暂不支持切换")
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard !FileManager.default.fileExists(atPath: fallback.path),
              (try? configFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ClaudeAccountError("检测到文件型凭据或链接配置，暂不支持安全切换")
        }
    }

    static func requireNoClaudeProcesses() async throws {
        let data = try await run(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "comm="])
        guard !containsClaudeProcess(String(decoding: data, as: UTF8.self)) else {
            throw ClaudeAccountError("请先退出所有 Claude Code 会话（含空闲会话），切换后用 claude --resume 恢复；不会强制关闭任务")
        }
    }

    static func containsClaudeProcess(_ output: String) -> Bool {
        output.split(separator: "\n").contains(where: {
            let name = URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            return name == "claude" || name == "claude.exe" || name.hasPrefix("claude-")
        })
    }
}
