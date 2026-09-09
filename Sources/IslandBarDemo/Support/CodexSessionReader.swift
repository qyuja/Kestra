import Foundation

/// Incrementally reads user-authored messages from Codex session JSONL files.
///
/// A session can contain injected context in `response_item` user messages.
/// Codex also records the actual submitted text as `event_msg.user_message`,
/// so that event is preferred whenever the client has written it.
actor CodexSessionReader {
    private struct SessionState {
        var offset: UInt64 = 0
        var pendingLine = Data()
        var firstPreferredMessage: String?
        var latestPreferredMessage: String?
        var firstFallbackMessage: String?
        var latestFallbackMessage: String?
    }

    private enum ParsedMessage {
        case preferred(String)
        case fallback(String)
    }

    private let fileManager = FileManager.default
    private let chunkSize = 64 * 1024
    private let previewLimit = 92
    private var states: [String: SessionState] = [:]
    private var currentMode: CodexTaskPreviewMode?
    private var modelCache: [String: (size: UInt64, model: TaskModelReader.Configuration?)] = [:]

    func models(for records: [CodexThreadRecord]) -> [String: TaskModelReader.Configuration] {
        var result: [String: TaskModelReader.Configuration] = [:]
        for record in records {
            guard let path = record.path,
                  let attributes = try? fileManager.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber else { continue }
            let cached = modelCache[path.path]
            let value = cached?.size == size.uint64Value
                ? cached?.model
                : TaskModelReader.latestConfiguration(at: path) ?? cached?.model
            modelCache[path.path] = (size.uint64Value, value)
            result[record.id] = value
        }
        return result
    }

    func latestMessages(
        for records: [CodexThreadRecord],
        mode: CodexTaskPreviewMode
    ) -> [String: String] {
        if currentMode != mode {
            states.removeAll(keepingCapacity: true)
            currentMode = mode
        }

        return records.reduce(into: [:]) { messages, record in
            guard let path = record.path,
                  let message = message(for: path, mode: mode) else {
                return
            }

            messages[record.id] = message
        }
    }

    private func message(
        for path: URL,
        mode: CodexTaskPreviewMode
    ) -> String? {
        guard fileManager.isReadableFile(atPath: path.path) else {
            return nil
        }

        let state: SessionState
        if mode == .latestUser,
           states[path.path] == nil {
            state = readLatestMessageFromEnd(at: path)
            states[path.path] = state
        } else {
            state = readNewLines(at: path, mode: mode)
        }

        switch mode {
        case .firstUser:
            return state.firstPreferredMessage ?? state.firstFallbackMessage
        case .latestUser:
            return state.latestPreferredMessage ?? state.latestFallbackMessage
        }
    }

    private func readNewLines(
        at path: URL,
        mode: CodexTaskPreviewMode
    ) -> SessionState {
        let pathKey = path.path
        var state = states[pathKey] ?? SessionState()

        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber else {
            states[pathKey] = state
            return state
        }

        let currentSize = fileSize.uint64Value
        if currentSize < state.offset {
            state = SessionState()
        }

        if mode == .firstUser, state.firstPreferredMessage != nil {
            // The first user message cannot change. Mark the current end as
            // consumed so a large historical session is not scanned again.
            state.offset = currentSize
            state.pendingLine.removeAll(keepingCapacity: false)
            states[pathKey] = state
            return state
        }

        guard currentSize > state.offset,
              let handle = try? FileHandle(forReadingFrom: path) else {
            states[pathKey] = state
            return state
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: state.offset)

            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                state.pendingLine.append(chunk)
                state.offset += UInt64(chunk.count)

                while let newlineIndex = state.pendingLine.firstIndex(of: 0x0A) {
                    let line = state.pendingLine.subdata(in: 0..<newlineIndex)
                    state.pendingLine.removeSubrange(0...newlineIndex)
                    record(parseMessage(from: line), in: &state)

                    if mode == .firstUser, state.firstPreferredMessage != nil {
                        state.offset = currentSize
                        state.pendingLine.removeAll(keepingCapacity: false)
                        states[pathKey] = state
                        return state
                    }
                }
            }
        } catch {
            // Keep the offset at the last successfully read byte. The next
            // polling pass can retry without losing a message.
        }

        states[pathKey] = state
        return state
    }

    private func readLatestMessageFromEnd(at path: URL) -> SessionState {
        var state = SessionState()

        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return state
        }

        let currentSize = fileSize.uint64Value
        state.offset = currentSize
        guard currentSize > 0,
              let handle = try? FileHandle(forReadingFrom: path) else {
            return state
        }

        defer {
            try? handle.close()
        }

        var cursor = currentSize
        var reversedLine: [UInt8] = []
        var latestFallback: String?

        while cursor > 0 {
            let readLength = min(UInt64(chunkSize), cursor)
            cursor -= readLength

            do {
                try handle.seek(toOffset: cursor)
                guard let chunk = try handle.read(upToCount: Int(readLength)) else {
                    break
                }
                for byte in chunk.reversed() {
                    if byte == 0x0A {
                        switch parseMessage(fromReversedLine: reversedLine) {
                        case .preferred(let message):
                            state.latestPreferredMessage = message
                            return state
                        case .fallback(let message):
                            latestFallback = latestFallback ?? message
                        case nil:
                            break
                        }
                        reversedLine.removeAll(keepingCapacity: true)
                    } else {
                        reversedLine.append(byte)
                    }
                }
            } catch {
                break
            }
        }

        if let message = parseMessage(fromReversedLine: reversedLine) {
            switch message {
            case .preferred(let message):
                state.latestPreferredMessage = message
            case .fallback(let message):
                latestFallback = latestFallback ?? message
            }
        }

        state.latestFallbackMessage = latestFallback
        return state
    }

    private func parseMessage(fromReversedLine line: [UInt8]) -> ParsedMessage? {
        guard !line.isEmpty else { return nil }
        return parseMessage(from: Data(line.reversed()))
    }

    private func record(_ message: ParsedMessage?, in state: inout SessionState) {
        guard let message else { return }

        switch message {
        case .preferred(let message):
            state.firstPreferredMessage = state.firstPreferredMessage ?? message
            state.latestPreferredMessage = message
        case .fallback(let message):
            state.firstFallbackMessage = state.firstFallbackMessage ?? message
            state.latestFallbackMessage = message
        }
    }

    private func parseMessage(from line: Data) -> ParsedMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        if object["type"] as? String == "event_msg",
           payload["type"] as? String == "user_message",
           let message = payload["message"] as? String,
           let normalized = normalizedMessage(message) {
            return .preferred(normalized)
        }

        guard object["type"] as? String == "response_item",
              payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else {
            return nil
        }

        let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        let contentKinds = metadata?["content_item_kinds"] as? [String]
        let userText = content.enumerated()
            .compactMap { index, item -> String? in
                guard let contentKinds,
                      index < contentKinds.count,
                      contentKinds[index].hasPrefix("user.") else {
                    return nil
                }
                return text(from: item)
            }
            .joined(separator: " ")

        if let normalized = normalizedMessage(userText) {
            return .preferred(normalized)
        }

        let fallbackText = content
            .compactMap(text(from:))
            .joined(separator: " ")
        guard let normalized = normalizedMessage(fallbackText) else {
            return nil
        }
        return .fallback(normalized)
    }

    private func normalizedMessage(_ message: String) -> String? {
        let text = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !text.isEmpty else { return nil }
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit - 1)) + "…"
    }

    private func text(from item: [String: Any]) -> String? {
        (item["text"] as? String) ?? (item["input_text"] as? String)
    }
}
