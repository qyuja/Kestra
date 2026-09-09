import Foundation

/// Credentials vary by account; both local configuration roots stay with the desktop.
struct CodexSharedProfile: Equatable {
    let home: URL
    let desktopData: URL

    var launchEnvironment: [String: String] {
        ["CODEX_HOME": home.path, "CODEX_ELECTRON_USER_DATA_PATH": desktopData.path]
    }

    static func resolve(openFiles: [String], expectedHome: URL) throws -> Self {
        let home = URL(fileURLWithPath: expectedHome.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        let homes = roots(in: openFiles, suffixes: ["/sqlite/codex.db", "/sqlite/codex-dev.db"])
        guard homes == Set([home]) else {
            throw CodexCredentialSwap.SwitchError("当前 Codex 数据目录与监听目录不一致或无法确认，未切换")
        }
        // Use the main Chromium profile, not embedded-browser partition stores.
        // This is an installed-desktop compatibility probe, not a public Codex API.
        let desktops = roots(in: openFiles, suffixes: ["/Default/Local Storage/leveldb/LOCK"])
        guard desktops.count == 1, let desktop = desktops.first else {
            throw CodexCredentialSwap.SwitchError("无法唯一确认 Codex 桌面设置目录，未切换")
        }
        return Self(home: home, desktopData: desktop)
    }

    private static func roots(in paths: [String], suffixes: [String]) -> Set<URL> {
        Set(paths.compactMap { path in
            guard path.hasPrefix("/"), let suffix = suffixes.first(where: { path.hasSuffix($0) }) else { return nil }
            return URL(fileURLWithPath: String(path.dropLast(suffix.count)), isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        })
    }
}
