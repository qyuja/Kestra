import AppKit

/// Codex owns the OAuth callback and credential storage inside a fresh profile.
@MainActor
final class CodexAccountLogin {
    private var client: CodexAppServerClient?
    private var timeout: Task<Void, Never>?
    private var completion: ((Result<(CodexAccountIdentity, URL), Error>) -> Void)?

    func start(completion: @escaping (Result<(CodexAccountIdentity, URL), Error>) -> Void) {
        guard client == nil else { return }
        self.completion = completion
        let home = TaskBridgePaths.defaultRoot.appendingPathComponent("profiles/\(UUID().uuidString.lowercased())/codex", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let config = home.appendingPathComponent("config.toml")
            try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch {
            finish(.failure(error))
            return
        }
        let client = CodexAppServerClient(codexHome: home)
        self.client = client
        client.onInitialized = { [weak client] in client?.beginLogin() }
        client.onError = { [weak self] message in self?.finish(.failure(LoginError(message: message))) }
        client.onConnectionChanged = { [weak self] connected in
            if !connected { self?.finish(.failure(LoginError(message: "登录服务已退出，请重试"))) }
        }
        client.onLoginURL = { [weak self] url in
            guard NSWorkspace.shared.open(url) else {
                self?.finish(.failure(LoginError(message: "无法打开登录页面，请检查默认浏览器")))
                return
            }
        }
        client.onLoginCompleted = { [weak self, weak client] success, message in
            guard let self else { return }
            guard success else {
                self.finish(.failure(LoginError(message: message ?? "登录未完成")))
                return
            }
            client?.requestAccount { [weak self] result in
                self?.finish(result.map { ($0, home) })
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(LoginError(message: "登录超时，请重新添加账号")))
        }
        client.start()
    }

    func cancel() {
        finish(.failure(LoginError(message: "已取消登录")))
    }

    private func finish(_ result: Result<(CodexAccountIdentity, URL), Error>) {
        let callback = completion
        completion = nil
        timeout?.cancel()
        timeout = nil
        let client = client
        self.client = nil
        client?.onError = nil
        client?.onConnectionChanged = nil
        client?.onLoginCompleted = nil
        client?.stop()
        callback?(result)
    }

    private struct LoginError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
