import Foundation

/// Reads model metadata only, never configuration credentials or response text.
enum TaskModelReader {
    struct Configuration: Sendable, Equatable {
        let model: String
        let effort: String?
    }

    static func configuration(in object: [String: Any]) -> Configuration? {
        guard let name = model(in: object) else { return nil }
        let metadata = object["type"] as? String == "turn_context"
            ? object["payload"] as? [String: Any] ?? [:] : object
        let collaboration = metadata["collaboration_mode"] as? [String: Any]
        let settings = collaboration?["settings"] as? [String: Any]
        let value = (metadata["effort"] as? String)
            ?? (metadata["reasoning_effort"] as? String)
            ?? (settings?["reasoning_effort"] as? String)
        let effort = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Configuration(model: name, effort: effort?.isEmpty == false ? effort : nil)
    }
    static func model(in object: [String: Any]) -> String? {
        if let value = object["model"] as? String, !value.isEmpty { return value }
        if let value = object["modelID"] as? String, !value.isEmpty { return value }
        if let model = object["model"] as? [String: Any],
           let value = model["modelID"] as? String { return value }
        if object["type"] as? String == "turn_context",
           let payload = object["payload"] as? [String: Any] {
            return model(in: payload)
        }
        if let message = object["message"] as? [String: Any] {
            return model(in: message)
        }
        return nil
    }

    /// A bounded tail scan keeps a large transcript off the UI hot path.
    static func latestModel(at path: URL) -> String? {
        latestConfiguration(at: path)?.model
    }

    static func latestConfiguration(at path: URL) -> Configuration? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 1_048_576 ? end - 1_048_576 : 0)
            guard let data = try handle.read(upToCount: 1_048_576) else { return nil }
            for line in data.split(separator: 0x0A).reversed() {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let value = configuration(in: object) { return value }
            }
        } catch { return nil }
        return nil
    }
}
