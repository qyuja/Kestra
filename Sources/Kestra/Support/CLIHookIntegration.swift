import Foundation

@MainActor
struct CLIHookIntegration {
    let provider: AIProvider

    static func renderedOhMyPiResourceData(bundleIdentifier: String = KestraAppIdentity.bundleIdentifier) throws -> Data {
        guard let resource = KestraResourceBundle.bundle.url(forResource: "kestra-omp", withExtension: "js"),
              let source = String(data: try Data(contentsOf: resource), encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data(
            source
                .replacingOccurrences(of: "__KESTRA_BUNDLE_IDENTIFIER__", with: bundleIdentifier)
                .utf8
        )
    }

    static func ohMyPiAgentDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        let configDirectoryName = environment["PI_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let expandedConfigDirectory = (configDirectoryName as NSString).expandingTildeInPath
        let configRoot = (expandedConfigDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: expandedConfigDirectory)
            : homeDirectory.appendingPathComponent(expandedConfigDirectory)
        ).standardizedFileURL
        let profileEnvironment = environment["OMP_PROFILE"] ?? environment["PI_PROFILE"] ?? ""
        let activeProfile = profileEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValidProfile = activeProfile.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
        let usesNamedProfile = isValidProfile && activeProfile != "default"
        let agentDirectoryOverride = usesNamedProfile ? nil : environment["PI_CODING_AGENT_DIR"]
        let profilesDirectory = configRoot.appendingPathComponent("profiles")
        let defaultDirectory = agentDirectoryOverride.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? configRoot.appendingPathComponent("agent")
        let activeDirectory = usesNamedProfile
            ? profilesDirectory.appendingPathComponent(activeProfile).appendingPathComponent("agent")
            : defaultDirectory
        var directories = [activeDirectory.standardizedFileURL]
        if usesNamedProfile { directories.append(defaultDirectory.standardizedFileURL) }
        let profiles = (try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            directories.append(profile.appendingPathComponent("agent").standardizedFileURL)
        }
        var seen = Set<URL>()
        return directories.filter { seen.insert($0).inserted }
    }

    var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if provider == .pi || provider == .ohMyPi {
            return ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(provider == .ohMyPi ? ".omp/agent" : ".pi/agent")
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
    // These installed Hook filenames are kept stable so an app rename does
    // not leave duplicate integrations in a client's config directory.
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
        let binaries: [String]
        if provider == .cursor {
            binaries = ["cursor", "cursor-agent"]
        } else if provider == .ohMyPi {
            binaries = ["omp", "oh-my-pi"]
        } else {
            binaries = [provider.rawValue]
        }
        return paths.contains { path in binaries.contains { FileManager.default.isExecutableFile(atPath: path + "/" + $0) } }
    }
    var configured: Bool {
        if provider == .cursor { return CursorHookIntegration.isConfigured(at: directory.appendingPathComponent(filename)) }
        if provider == .pi {
            guard let expected = KestraResourceBundle.bundle.url(forResource: "kestra-pi", withExtension: "js"),
                  let data = try? Data(contentsOf: expected),
                  let installed = try? Data(contentsOf: directory.appendingPathComponent("extensions/islandbar.js")) else { return false }
            return data == installed
        }
        if provider == .ohMyPi {
            guard let data = try? Self.renderedOhMyPiResourceData() else { return false }
            guard let activeDirectory = Self.ohMyPiAgentDirectories().first,
                  let installed = try? Data(contentsOf: activeDirectory.appendingPathComponent("extensions/kestra.js")) else { return false }
            return data == installed
        }
        if provider == .opencode {
            guard let expected = KestraResourceBundle.bundle.url(forResource: "kestra-opencode", withExtension: "js"),
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
            guard let resource = KestraResourceBundle.bundle.url(forResource: "kestra-pi", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
            let target = directory.appendingPathComponent("extensions/islandbar.js")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: target, to: target.appendingPathExtension(UUID().uuidString + ".backup"))
            }
            try Data(contentsOf: resource).write(to: target, options: .atomic)
            return
        }
        if provider == .ohMyPi {
            let data = try Self.renderedOhMyPiResourceData()
            let agentDirectories = Self.ohMyPiAgentDirectories()
            guard let activeDirectory = agentDirectories.first else { throw CocoaError(.fileNoSuchFile) }
            try Self.installOhMyPiExtension(data, in: activeDirectory)
            for profileDirectory in agentDirectories.dropFirst() {
                do {
                    try Self.installOhMyPiExtension(data, in: profileDirectory)
                } catch {
                    NSLog("Kestra: could not install the OMP extension in an additional profile: %@", error.localizedDescription)
                }
            }
            return
        }
        if provider == .opencode {
            guard let resource = KestraResourceBundle.bundle.url(forResource: "kestra-opencode", withExtension: "js") else {
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

    private static func installOhMyPiExtension(_ data: Data, in agentDirectory: URL) throws {
        let target = agentDirectory.appendingPathComponent("extensions/kestra.js")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: target), existing == data { return }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: target, to: target.appendingPathExtension(UUID().uuidString + ".backup"))
        }
        try data.write(to: target, options: .atomic)
    }
}
