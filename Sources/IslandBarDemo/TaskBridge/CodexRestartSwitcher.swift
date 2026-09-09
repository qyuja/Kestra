import AppKit

@MainActor
final class CodexRestartSwitcher {
    typealias SwitchError = CodexCredentialSwap.SwitchError

    func identity(at home: URL) async throws -> CodexAccountIdentity {
        let client = CodexAppServerClient(codexHome: home)
        defer { client.stop() }
        client.start()
        var identity: CodexAccountIdentity = try await withCheckedThrowingContinuation { continuation in
            client.requestAccount(includeUsage: false) { continuation.resume(with: $0) }
        }
        // File-auth account_id distinguishes workspaces without querying rate limits.
        identity.workspaceID = try CodexCredentialSwap.workspaceID(at: home)
        return identity
    }

    func currentApplication() throws -> NSRunningApplication {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard apps.count == 1, let app = apps.first else {
            throw SwitchError(apps.isEmpty ? "请先打开 Codex" : "检测到多个 Codex 实例，请先只保留当前使用的一个")
        }
        return app
    }

    func quit(_ app: NSRunningApplication) async throws {
        guard app.terminate() else { throw SwitchError("Codex 未接受退出请求，未修改登录状态") }
        for _ in 0..<100 {
            if app.isTerminated { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SwitchError("Codex 尚未退出，未强制关闭或修改登录状态")
    }

    func sharedProfile(of app: NSRunningApplication, expectedHome: URL) async throws -> CodexSharedProfile {
        let pid = app.processIdentifier
        let paths = try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-a", "-p", String(pid), "-Fn"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SwitchError("无法确认当前 Codex 使用的数据目录") }
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .filter { $0.hasPrefix("n/") }
                .map { String($0.dropFirst()) }
        }.value
        return try CodexSharedProfile.resolve(openFiles: paths, expectedHome: expectedHome)
    }

    func launch(appURL: URL, profile: CodexSharedProfile) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        // Explicit desktop data also preserves CODEX_HOME through Codex's shell-env loading.
        configuration.environment = profile.launchEnvironment
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try await Task.sleep(for: .milliseconds(750))
        guard !app.isTerminated else { throw SwitchError("Codex 启动后已退出") }
        return app
    }
}
