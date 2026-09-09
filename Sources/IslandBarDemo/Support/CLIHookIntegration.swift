import Foundation

@MainActor
struct CLIHookIntegration {
    let provider: AIProvider
    var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if provider == .pi {
            return ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".pi/agent")
        }
        if provider == .opencode {
            let config = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"]
            let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            return config.map { URL(fileURLWithPath: $0) }
                ?? (xdg.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config"))
                    .appendingPathComponent("opencode")
        }
        if provider == .workbuddy {
            let current = home.appendingPathComponent(".workbuddy-ai")
            return FileManager.default.fileExists(atPath: current.path) ? current : home.appendingPathComponent(".workbuddy")
        }
        return home.appendingPathComponent(provider == .grok ? ".grok/hooks" : ".\(provider.rawValue)")
    }
    var filename: String { provider == .cursor ? "hooks.json" : provider == .grok ? "islandbar.json" : "settings.json" }
    var events: [String] {
        provider == .gemini ? ["BeforeAgent", "BeforeModel", "BeforeTool", "AfterAgent", "SessionEnd"] : ["UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd"] + (provider == .grok ? ["StopCancelled"] : [])
    }
    var argument: String { "--\(provider.rawValue)-hook" }
    var installed: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if provider == .cursor, FileManager.default.fileExists(atPath: "/Applications/Cursor.app") { return true }
        if provider == .workbuddy {
            return ["/Applications/WorkBuddy.app", home.appendingPathComponent("Applications/WorkBuddy.app").path]
                .contains { FileManager.default.fileExists(atPath: $0) }
        }
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        if provider == .opencode { paths.append(home.appendingPathComponent(".opencode/bin").path) }
        if let versions = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".nvm/versions/node"), includingPropertiesForKeys: nil) {
            paths += versions.map { $0.appendingPathComponent("bin").path }
        }
        let binaries = provider == .cursor ? ["cursor", "cursor-agent"] : [provider.rawValue]
        return paths.contains { path in binaries.contains { FileManager.default.isExecutableFile(atPath: path + "/" + $0) } }
    }
    var configured: Bool {
        if provider == .cursor { return CursorHookIntegration.isConfigured(at: directory.appendingPathComponent(filename)) }
        if provider == .pi {
            guard let expected = Bundle.module.url(forResource: "islandbar-pi", withExtension: "js"),
                  let data = try? Data(contentsOf: expected),
                  let installed = try? Data(contentsOf: directory.appendingPathComponent("extensions/islandbar.js")) else { return false }
            return data == installed
        }
        if provider == .opencode {
            guard let expected = Bundle.module.url(forResource: "islandbar-opencode", withExtension: "js"),
                  let data = try? Data(contentsOf: expected),
                  let installed = try? Data(contentsOf: directory.appendingPathComponent("plugins/islandbar.js")) else { return false }
            return data == installed
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["disableAllHooks"] as? Bool != true,
              let hooks = object["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(argument) == true }
            }
        }
    }
    func connect() throws {
        guard provider.isImplemented else { throw CocoaError(.featureUnsupported) }
        if provider == .cursor {
            try CursorHookIntegration.install(at: directory.appendingPathComponent(filename))
            return
        }
        if provider == .pi {
            guard let resource = Bundle.module.url(forResource: "islandbar-pi", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
            let target = directory.appendingPathComponent("extensions/islandbar.js")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: target, to: target.appendingPathExtension(UUID().uuidString + ".backup"))
            }
            try Data(contentsOf: resource).write(to: target, options: .atomic)
            return
        }
        if provider == .opencode {
            guard let resource = Bundle.module.url(forResource: "islandbar-opencode", withExtension: "js") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let target = directory.appendingPathComponent("plugins/islandbar.js")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: target, to: target.appendingPathExtension(UUID().uuidString + ".backup"))
            }
            try Data(contentsOf: resource).write(to: target, options: .atomic)
            return
        }
        try ClaudeHookMonitor.installHooks(configDirectory: directory, argument: argument, events: events, filename: filename)
    }
}
