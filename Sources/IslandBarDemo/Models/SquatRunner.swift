import AppKit
import Combine

/// One loop contains a complete descent and return to standing (frames 0...7).
struct SquatMotion {
    private(set) var frame = 0
    private var elapsed = 0.0
    private(set) var runningCount = 0
    private var frameCount = 8
    private var idleFrame = 0
    private var cycleDuration = 1.2

    init(frameCount: Int = 8, idleFrame: Int = 0, cycleDuration: Double = 1.2) {
        self.frameCount = max(1, frameCount)
        self.idleFrame = min(max(0, idleFrame), self.frameCount - 1)
        self.cycleDuration = cycleDuration.isFinite && cycleDuration > 0 ? cycleDuration : 1.2
        frame = self.idleFrame
    }

    var frameDuration: Double {
        max(0.36, cycleDuration / sqrt(Double(max(1, runningCount)))) / Double(frameCount)
    }

    mutating func configure(frameCount: Int, idleFrame: Int, cycleDuration: Double) {
        self.frameCount = max(1, frameCount)
        self.idleFrame = min(max(0, idleFrame), self.frameCount - 1)
        self.cycleDuration = cycleDuration.isFinite && cycleDuration > 0 ? cycleDuration : 1.2
        frame = self.idleFrame
        elapsed = 0
    }

    mutating func setRunningCount(_ count: Int) {
        runningCount = max(0, count)
        if runningCount == 0 { frame = idleFrame; elapsed = 0 }
    }

    mutating func advance(_ seconds: Double) -> Int {
        guard runningCount > 0, seconds.isFinite, seconds > 0 else { return 0 }
        elapsed += seconds
        var completed = 0
        while elapsed >= frameDuration {
            elapsed -= frameDuration
            frame = (frame + 1) % frameCount
            if frame == idleFrame { completed += 1 }
        }
        return completed
    }
}

@MainActor
final class SquatRunner: ObservableObject {
    @Published private(set) var total: Int
    @Published private(set) var options: [MenuBarIconOption]
    @Published private(set) var selectedIconID: String
    @Published private(set) var pluginErrors: [String]

    private let defaults: UserDefaults
    private let countKey = "runner.barbellSquat.completedCount"
    private static let selectedIconKey = "runner.menuBarIcon.selectedIconID"
    private let pluginsDirectory: URL
    private var plugins: [String: MenuBarIconPlugin] = [:]
    private var motion = SquatMotion()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    var onFrame: (() -> Void)?
    var image: NSImage? { plugins[selectedIconID]?.image(at: motion.frame) }

    init(defaults: UserDefaults = .standard, pluginsDirectory: URL? = nil) {
        self.defaults = defaults
        self.pluginsDirectory = pluginsDirectory ?? Self.defaultPluginsDirectory
        total = max(0, defaults.integer(forKey: countKey))
        options = []
        selectedIconID = MenuBarIconPluginCatalog.squatID
        pluginErrors = []
        reloadPlugins()
    }

    func update(runningCount: Int) {
        motion.setRunningCount(runningCount)
        refreshTimer()
    }

    func selectIcon(_ id: String) {
        guard let plugin = plugins[id] else {
            appendPluginError("无法选择图标插件：\(id)")
            onFrame?()
            return
        }

        selectedIconID = id
        defaults.set(id, forKey: Self.selectedIconKey)
        configureMotion(for: plugin)
        refreshTimer()
        onFrame?()
    }

    func reloadPlugins() {
        let builtIns = MenuBarIconPluginCatalog.builtIns()
        let result = MenuBarIconPluginLoader.load(from: pluginsDirectory, builtIns: builtIns.plugins)
        plugins = Dictionary(uniqueKeysWithValues: result.plugins.map { ($0.option.id, $0) })
        options = result.plugins.map(\.option)
        pluginErrors = builtIns.errors + result.errors

        let requestedID = defaults.string(forKey: Self.selectedIconKey)
        let fallbackID = plugins[MenuBarIconPluginCatalog.squatID] != nil
            ? MenuBarIconPluginCatalog.squatID
            : result.plugins.first?.option.id

        if let requestedID, let requestedPlugin = plugins[requestedID] {
            selectedIconID = requestedID
            configureMotion(for: requestedPlugin)
        } else if let fallbackID, let fallbackPlugin = plugins[fallbackID] {
            if let requestedID {
                pluginErrors.append("已保存的图标插件“\(requestedID)”不可用，已回退为“\(fallbackPlugin.option.name)”")
                defaults.set(fallbackID, forKey: Self.selectedIconKey)
            }
            selectedIconID = fallbackID
            configureMotion(for: fallbackPlugin)
        } else {
            selectedIconID = ""
            motion.configure(frameCount: 1, idleFrame: 0, cycleDuration: 1.2)
        }

        refreshTimer()
        onFrame?()
    }

    func openPluginsDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: pluginsDirectory,
                withIntermediateDirectories: true
            )
            if !NSWorkspace.shared.open(pluginsDirectory) {
                appendPluginError("无法打开图标插件目录")
            }
        } catch {
            appendPluginError("创建图标插件目录失败：\(error.localizedDescription)")
        }
    }

    private func tick() {
        guard let plugin = plugins[selectedIconID], plugin.isAnimated else {
            timer?.invalidate()
            timer = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        // Do not count imaginary repetitions while asleep or the UI is blocked.
        let delta = min(max(0, now - lastTick), 0.08)
        lastTick = now
        let oldFrame = motion.frame
        let completed = motion.advance(delta)
        if completed > 0, plugin.countsTowardSquat {
            total += completed
            defaults.set(total, forKey: countKey)
        }
        if motion.frame != oldFrame { onFrame?() }
    }

    private func configureMotion(for plugin: MenuBarIconPlugin) {
        motion.configure(
            frameCount: max(1, plugin.frames.count),
            idleFrame: plugin.idleFrame,
            cycleDuration: plugin.cycleDuration
        )
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    private func refreshTimer() {
        guard motion.runningCount > 0,
              plugins[selectedIconID]?.isAnimated == true else {
            timer?.invalidate()
            timer = nil
            return
        }

        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func appendPluginError(_ message: String) {
        pluginErrors.append(message)
    }

    private static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.kiannest.islandbar/icon-plugins", isDirectory: true)
    }
}
