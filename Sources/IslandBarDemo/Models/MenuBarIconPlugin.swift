import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MenuBarIconOption: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

struct MenuBarIconPlugin {
    let option: MenuBarIconOption
    let frames: [NSImage]
    let systemSymbolName: String?
    let idleFrame: Int
    let cycleDuration: Double
    let countsTowardSquat: Bool

    var isAnimated: Bool {
        frames.count > 1
    }

    func image(at frame: Int) -> NSImage? {
        if let systemSymbolName {
            return NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: option.name)
        }

        guard !frames.isEmpty else { return nil }
        return frames[min(max(0, frame), frames.count - 1)]
    }
}

struct MenuBarIconPluginLoadResult {
    let plugins: [MenuBarIconPlugin]
    let errors: [String]
}

enum MenuBarIconPluginLimits {
    static let maxManifestBytes = 64 * 1024
    static let maxFrameCount = 32
    static let maxFrameBytes = 1 * 1024 * 1024
    static let maxImageDimension = 512
    static let minCycleDuration = 0.1
    static let maxCycleDuration = 60.0
}

enum MenuBarIconPluginCatalog {
    static let squatID = "barbell-squat"
    static let sparklesID = "sparkles"

    static func builtIns() -> (plugins: [MenuBarIconPlugin], errors: [String]) {
        var plugins: [MenuBarIconPlugin] = []
        var errors: [String] = []

        let squatFrames = (0..<8).compactMap { frame in
            Bundle.module.url(
                forResource: "barbell-squat-frame-\(frame)",
                withExtension: "png"
            ).flatMap(NSImage.init(contentsOf:))
        }

        if squatFrames.count == 8 {
            plugins.append(
                MenuBarIconPlugin(
                    option: MenuBarIconOption(id: squatID, name: "深蹲"),
                    frames: squatFrames,
                    systemSymbolName: nil,
                    idleFrame: 0,
                    cycleDuration: 1.2,
                    countsTowardSquat: true
                )
            )
        } else {
            errors.append("内置深蹲图标资源不完整")
        }

        if NSImage(systemSymbolName: "sparkles", accessibilityDescription: "星芒") != nil {
            plugins.append(
                MenuBarIconPlugin(
                    option: MenuBarIconOption(id: sparklesID, name: "星芒"),
                    frames: [],
                    systemSymbolName: "sparkles",
                    idleFrame: 0,
                    cycleDuration: 1.2,
                    countsTowardSquat: false
                )
            )
        } else {
            errors.append("内置星芒系统图标不可用")
        }

        return (plugins, errors)
    }
}

enum MenuBarIconPluginLoader {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let id: String
        let name: String
        let frames: [String]?
        let systemSymbol: String?
        let idleFrame: Int?
        let cycleDuration: Double?
    }

    private struct ValidationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func load(
        from directory: URL,
        builtIns: [MenuBarIconPlugin]
    ) -> MenuBarIconPluginLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return MenuBarIconPluginLoadResult(plugins: builtIns, errors: [])
        }

        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(resolvedDirectory) else {
            return MenuBarIconPluginLoadResult(
                plugins: builtIns,
                errors: ["图标插件目录不是文件夹：\(directory.path)"]
            )
        }

        var plugins = builtIns
        var errors: [String] = []
        var usedIDs = Set(builtIns.map { $0.option.id })

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return MenuBarIconPluginLoadResult(
                plugins: builtIns,
                errors: ["读取图标插件目录失败：\(error.localizedDescription)"]
            )
        }

        for child in children {
            guard isDirectory(child) else { continue }
            do {
                let packageRoot = child.resolvingSymlinksInPath().standardizedFileURL
                guard packageRoot == child.standardizedFileURL else {
                    throw ValidationError(message: "插件目录不能是符号链接")
                }
                guard isContained(packageRoot, in: resolvedDirectory) else {
                    throw ValidationError(message: "插件目录超出插件根目录")
                }

                let manifestURL = try packagePath("manifest.json", in: packageRoot)
                guard try fileType(manifestURL) == .typeRegular else {
                    throw ValidationError(message: "manifest.json 不是普通文件")
                }

                let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
                guard manifestData.count <= MenuBarIconPluginLimits.maxManifestBytes else {
                    throw ValidationError(message: "manifest.json 超过大小限制")
                }

                let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
                guard manifest.schemaVersion == 1 else {
                    throw ValidationError(message: "不支持的 schemaVersion")
                }

                let id = try validatedIdentifier(manifest.id, label: "id")
                guard !usedIDs.contains(id) else {
                    throw ValidationError(message: "id 重复或与内置图标冲突：\(id)")
                }
                let name = try validatedName(manifest.name)
                let hasFrames = manifest.frames != nil
                let hasSystemSymbol = manifest.systemSymbol != nil
                guard hasFrames != hasSystemSymbol else {
                    throw ValidationError(message: "frames 与 systemSymbol 必须二选一")
                }

                let cycleDuration = manifest.cycleDuration ?? 1.2
                guard cycleDuration.isFinite,
                      cycleDuration >= MenuBarIconPluginLimits.minCycleDuration,
                      cycleDuration <= MenuBarIconPluginLimits.maxCycleDuration else {
                    throw ValidationError(message: "cycleDuration 超出允许范围")
                }

                let plugin: MenuBarIconPlugin
                if let framePaths = manifest.frames {
                    guard !framePaths.isEmpty,
                          framePaths.count <= MenuBarIconPluginLimits.maxFrameCount else {
                        throw ValidationError(message: "PNG 帧数量超出限制")
                    }

                    let idleFrame = manifest.idleFrame ?? 0
                    guard framePaths.indices.contains(idleFrame) else {
                        throw ValidationError(message: "idleFrame 超出帧范围")
                    }

                    var loadedFrames: [NSImage] = []
                    var resolvedFramePaths = Set<String>()
                    for framePath in framePaths {
                        guard framePath.lowercased().hasSuffix(".png") else {
                            throw ValidationError(message: "帧文件必须是 PNG：\(framePath)")
                        }
                        let frameURL = try packagePath(framePath, in: packageRoot)
                        guard resolvedFramePaths.insert(frameURL.path).inserted else {
                            throw ValidationError(message: "帧文件路径重复：\(framePath)")
                        }
                        guard try fileType(frameURL) == .typeRegular else {
                            throw ValidationError(message: "帧文件不是普通文件：\(framePath)")
                        }

                        let data = try Data(contentsOf: frameURL, options: [.mappedIfSafe])
                        guard data.count <= MenuBarIconPluginLimits.maxFrameBytes else {
                            throw ValidationError(message: "帧文件超过大小限制：\(framePath)")
                        }
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let imageType = CGImageSourceGetType(source),
                              let uniformType = UTType(imageType as String),
                              uniformType.conforms(to: .png),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                            throw ValidationError(message: "无法读取 PNG 帧：\(framePath)")
                        }
                        guard pixelWidth > 0,
                              pixelHeight > 0,
                              pixelWidth <= MenuBarIconPluginLimits.maxImageDimension,
                              pixelHeight <= MenuBarIconPluginLimits.maxImageDimension else {
                            throw ValidationError(message: "PNG 帧尺寸超出限制：\(framePath)")
                        }
                        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                            throw ValidationError(message: "无法解码 PNG 帧：\(framePath)")
                        }
                        guard let image = NSImage(data: data) else {
                            throw ValidationError(message: "无法创建 PNG 图像：\(framePath)")
                        }
                        loadedFrames.append(image)
                    }

                    plugin = MenuBarIconPlugin(
                        option: MenuBarIconOption(id: id, name: name),
                        frames: loadedFrames,
                        systemSymbolName: nil,
                        idleFrame: idleFrame,
                        cycleDuration: cycleDuration,
                        countsTowardSquat: false
                    )
                } else if let systemSymbol = manifest.systemSymbol {
                    let symbolName = try validatedSystemSymbol(systemSymbol)
                    if let idleFrame = manifest.idleFrame, idleFrame != 0 {
                        throw ValidationError(message: "systemSymbol 插件的 idleFrame 必须为 0")
                    }
                    guard NSImage(systemSymbolName: symbolName, accessibilityDescription: name) != nil else {
                        throw ValidationError(message: "找不到系统图标：\(symbolName)")
                    }

                    plugin = MenuBarIconPlugin(
                        option: MenuBarIconOption(id: id, name: name),
                        frames: [],
                        systemSymbolName: symbolName,
                        idleFrame: 0,
                        cycleDuration: cycleDuration,
                        countsTowardSquat: false
                    )
                } else {
                    throw ValidationError(message: "插件没有可用资源")
                }

                plugins.append(plugin)
                usedIDs.insert(id)
            } catch {
                errors.append("图标插件“\(child.lastPathComponent)”无效：\(error.localizedDescription)")
            }
        }

        return MenuBarIconPluginLoadResult(plugins: plugins, errors: errors)
    }

    private static func validatedIdentifier(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, trimmed.count <= 80 else {
            throw ValidationError(message: "\(label) 为空、带首尾空白或过长")
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ValidationError(message: "\(label) 含非法字符")
        }
        return trimmed
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw ValidationError(message: "name 为空或过长")
        }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ValidationError(message: "name 含非法字符")
        }
        return name
    }

    private static func validatedSystemSymbol(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name == value, name.count <= 128 else {
            throw ValidationError(message: "systemSymbol 为空、带首尾空白或过长")
        }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ValidationError(message: "systemSymbol 含非法字符")
        }
        return name
    }

    private static func packagePath(_ relativePath: String, in packageRoot: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            throw ValidationError(message: "资源路径必须是包内相对路径")
        }

        let candidate = URL(fileURLWithPath: relativePath, relativeTo: packageRoot).standardizedFileURL
        guard isContained(candidate, in: packageRoot) else {
            throw ValidationError(message: "资源路径超出插件目录：\(relativePath)")
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved, in: packageRoot) else {
            throw ValidationError(message: "资源符号链接指向包外：\(relativePath)")
        }
        return resolved
    }

    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let rootComponents = directory.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? fileType(url)) == .typeDirectory
    }

    private static func fileType(_ url: URL) throws -> FileAttributeType {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw ValidationError(message: "无法读取文件类型")
        }
        return type
    }
}
