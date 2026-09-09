import AppKit
import XCTest
@testable import IslandBarDemo

final class SquatRunnerTests: XCTestCase {
    @MainActor
    func testLoadsFramesAndPersistedCount() {
        let suite = "SquatRunnerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let pluginsDirectory = makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: pluginsDirectory)
        }
        defaults.set(42, forKey: "runner.barbellSquat.completedCount")
        let runner = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertEqual(runner.total, 42)
        XCTAssertNotNil(runner.image)
    }

    @MainActor
    func testBuiltInOptionsAndStaticSparklesDoNotChangeSquatTotal() {
        let suite = "SquatRunnerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let pluginsDirectory = makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: pluginsDirectory)
        }

        let runner = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertEqual(runner.options.map(\.id), ["barbell-squat", "sparkles"])
        XCTAssertEqual(runner.selectedIconID, "barbell-squat")

        runner.selectIcon("sparkles")
        XCTAssertNotNil(runner.image)
        runner.update(runningCount: 3)
        XCTAssertEqual(runner.total, 0)
    }

    @MainActor
    func testLoadsInjectedSystemSymbolPluginAndPersistsSelection() throws {
        let suite = "SquatRunnerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let pluginsDirectory = makeTemporaryDirectory()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: pluginsDirectory)
        }

        try writeManifest(
            [
                "schemaVersion": 1,
                "id": "circle-example",
                "name": "Circle Example",
                "systemSymbol": "circle"
            ],
            in: pluginsDirectory.appendingPathComponent("circle-example", isDirectory: true)
        )

        let runner = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertTrue(runner.options.contains { $0.id == "circle-example" })
        XCTAssertTrue(runner.pluginErrors.isEmpty)
        runner.selectIcon("circle-example")
        XCTAssertEqual(runner.selectedIconID, "circle-example")
        XCTAssertNotNil(runner.image)

        let reloaded = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertEqual(reloaded.selectedIconID, "circle-example")
        XCTAssertNotNil(reloaded.image)
    }

    @MainActor
    func testRejectsBuiltinConflictAndInvalidResourcePathsWithoutCrashing() throws {
        let suite = "SquatRunnerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let pluginsDirectory = makeTemporaryDirectory()
        let outsideImage = pluginsDirectory.appendingPathComponent("outside.png")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: pluginsDirectory)
        }

        try pngData(width: 2, height: 2).write(to: outsideImage)
        let pathPlugin = pluginsDirectory.appendingPathComponent("outside-path", isDirectory: true)
        try FileManager.default.createDirectory(at: pathPlugin, withIntermediateDirectories: true)
        try writeManifest(
            [
                "schemaVersion": 1,
                "id": "outside-path",
                "name": "Outside Path",
                "frames": ["../outside.png"]
            ],
            in: pathPlugin
        )

        let conflictPlugin = pluginsDirectory.appendingPathComponent("builtin-conflict", isDirectory: true)
        try writeManifest(
            [
                "schemaVersion": 1,
                "id": "sparkles",
                "name": "Conflict",
                "systemSymbol": "circle"
            ],
            in: conflictPlugin
        )

        let runner = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertFalse(runner.options.contains { $0.id == "outside-path" })
        XCTAssertFalse(runner.options.contains { $0.id == "sparkles" && $0.name == "Conflict" })
        XCTAssertGreaterThanOrEqual(runner.pluginErrors.count, 2)
    }

    @MainActor
    func testRejectsSymlinkOutsidePackageAndOversizedDimensions() throws {
        let suite = "SquatRunnerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let pluginsDirectory = makeTemporaryDirectory()
        let outsideImage = pluginsDirectory.appendingPathComponent("outside-symlink.png")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: pluginsDirectory)
        }

        try pngData(width: 2, height: 2).write(to: outsideImage)
        let symlinkPlugin = pluginsDirectory.appendingPathComponent("symlink-plugin", isDirectory: true)
        try writeManifest(
            [
                "schemaVersion": 1,
                "id": "symlink-plugin",
                "name": "Symlink Plugin",
                "frames": ["frame.png"]
            ],
            in: symlinkPlugin
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkPlugin.appendingPathComponent("frame.png"),
            withDestinationURL: outsideImage
        )

        let oversizedPlugin = pluginsDirectory.appendingPathComponent("oversized-plugin", isDirectory: true)
        try writeManifest(
            [
                "schemaVersion": 1,
                "id": "oversized-plugin",
                "name": "Oversized Plugin",
                "frames": ["frame.png"]
            ],
            in: oversizedPlugin
        )
        try pngData(width: 513, height: 2).write(to: oversizedPlugin.appendingPathComponent("frame.png"))

        let runner = SquatRunner(defaults: defaults, pluginsDirectory: pluginsDirectory)
        XCTAssertFalse(runner.options.contains { $0.id == "symlink-plugin" })
        XCTAssertFalse(runner.options.contains { $0.id == "oversized-plugin" })
        XCTAssertGreaterThanOrEqual(runner.pluginErrors.count, 2)
    }
    func testIdleAndFullRepetition() {
        var motion = SquatMotion()
        XCTAssertEqual(motion.advance(10), 0)
        XCTAssertEqual(motion.frame, 0)
        motion.setRunningCount(1)
        XCTAssertEqual(motion.advance(0.61), 0)
        XCTAssertEqual(motion.frame, 4)
        XCTAssertEqual(motion.advance(0.6), 1)
        XCTAssertEqual(motion.frame, 0)
    }

    func testStoppingDiscardsPartialRepAndRestartsStanding() {
        var motion = SquatMotion()
        motion.setRunningCount(1)
        _ = motion.advance(0.9)
        motion.setRunningCount(0)
        XCTAssertEqual(motion.frame, 0)
        motion.setRunningCount(1)
        XCTAssertEqual(motion.advance(0.9), 0)
    }

    func testMoreTasksIncreaseSpeedWithCapAndPreserveFrame() {
        var motion = SquatMotion()
        motion.setRunningCount(1)
        let slow = motion.frameDuration
        _ = motion.advance(0.5)
        let frame = motion.frame
        motion.setRunningCount(4)
        XCTAssertLessThan(motion.frameDuration, slow)
        XCTAssertEqual(motion.frame, frame)
        motion.setRunningCount(100)
        XCTAssertEqual(motion.frameDuration, 0.045, accuracy: 0.001)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandBarDemoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeManifest(_ object: [String: Any], in packageDirectory: URL) throws {
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try data.write(to: packageDirectory.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        return try XCTUnwrap(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
    }
}
