import Foundation

struct CodexTaskCompletionEvent: Hashable, Sendable {
    let threadID: String
    let turnID: String

    var id: String {
        "\(threadID):\(turnID)"
    }
}

struct CodexActivitySnapshot: Sendable {
    let activeThreadIDs: Set<String>
    let completedTasks: [CodexTaskCompletionEvent]
    var startedAt: [String: Date] = [:]
    var endedAt: [String: Date] = [:]
    var unknownThreadIDs: Set<String> = []
}

/// Reads the lifecycle events Codex writes to its session JSONL files.
///
/// Writer locks describe an open thread, not an executing turn, so they stay
/// around while a thread is merely open in the Codex UI. The task_started and
/// task_complete events are the useful boundary for the status bar monitor.
actor CodexSessionActivityReader {
    private struct SessionState {
        var offset: UInt64 = 0
        var pendingLine = Data()
        var isRunning = false
        var startedAt: Date?
        var endedAt: Date?
        var hasLifecycle = false
        var isReliable = true
    }

    private enum LifecycleEvent {
        case started(Date?)
        case completed(turnID: String, date: Date?)
        case aborted(Date?)
    }

    private let chunkSize = 64 * 1024
    private static let lifecycleMarkers = [
        Data("\"task_started\"".utf8),
        Data("\"task_complete\"".utf8),
        Data("\"task_aborted\"".utf8),
        Data("\"turn_aborted\"".utf8),
        Data("\"task_cancelled\"".utf8),
        Data("\"turn_cancelled\"".utf8)
    ]
    private static let reversedLifecyclePrefixes = [
        Data(Array("\"task_".utf8.reversed())),
        Data(Array("\"turn_".utf8.reversed()))
    ]
    private var states: [String: SessionState] = [:]
    private var hasBootstrapped = false

    func snapshot(records: [CodexThreadRecord]) -> CodexActivitySnapshot {
        var activeThreadIDs = Set<String>()
        var completedTasks: [CodexTaskCompletionEvent] = []
        var seenPaths = Set<String>()
        var startedAt: [String: Date] = [:]
        var endedAt: [String: Date] = [:]

        var unknownThreadIDs = Set<String>()
        for record in records {
            guard let path = record.path else { unknownThreadIDs.insert(record.id); continue }
            let pathKey = path.path
            let isNewFile = states[pathKey] == nil
            let shouldEmitCompletions = hasBootstrapped && !isNewFile
            let events: (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent])
            if isNewFile {
                events = readInitialState(at: path)
            } else {
                events = readEvents(
                    at: path,
                    threadID: record.id,
                    emitCompletions: shouldEmitCompletions
                )
            }

            seenPaths.insert(pathKey)
            if states[pathKey]?.hasLifecycle != true || states[pathKey]?.isReliable != true {
                unknownThreadIDs.insert(record.id)
            }
            if events.isRunning {
                activeThreadIDs.insert(record.id)
            }
            completedTasks.append(contentsOf: events.completedTasks)
            startedAt[record.id] = states[pathKey]?.startedAt
            endedAt[record.id] = states[pathKey]?.endedAt
        }

        states = states.filter { seenPaths.contains($0.key) }
        hasBootstrapped = true

        return CodexActivitySnapshot(
            activeThreadIDs: activeThreadIDs,
            completedTasks: completedTasks,
            startedAt: startedAt,
            endedAt: endedAt,
            unknownThreadIDs: unknownThreadIDs
        )
    }

    private func readEvents(
        at path: URL,
        threadID: String,
        emitCompletions: Bool
    ) -> (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent]) {
        let pathKey = path.path
        var state = states[pathKey] ?? SessionState()
        var completedTasks: [CodexTaskCompletionEvent] = []

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber else {
            states[pathKey] = state
            return (state.isRunning, completedTasks)
        }

        let currentSize = fileSize.uint64Value
        if currentSize < state.offset {
            state = SessionState()
        }

        guard currentSize > state.offset,
              let handle = try? FileHandle(forReadingFrom: path) else {
            states[pathKey] = state
            return (state.isRunning, completedTasks)
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

                    guard let event = lifecycleEvent(from: line) else { continue }
                    switch event {
                    case .started:
                        state.isRunning = true
                    case .completed(let turnID, _):
                        if emitCompletions, state.isRunning {
                            completedTasks.append(
                                CodexTaskCompletionEvent(
                                    threadID: threadID,
                                    turnID: turnID
                                )
                            )
                        }
                        state.isRunning = false
                    case .aborted:
                        state.isRunning = false
                    }
                    apply(event, to: &state)
                }
            }
        } catch {
            // Keep the last coherent state. The next polling pass retries the
            // unread bytes from the same offset.
            states[pathKey] = state
            return (state.isRunning, completedTasks)
        }

        states[pathKey] = state
        return (state.isRunning, completedTasks)
    }

    private func readInitialState(
        at path: URL
    ) -> (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent]) {
        let pathKey = path.path
        var state = SessionState()

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: path) else {
            states[pathKey] = state
            return (state.isRunning, [])
        }

        let currentSize = fileSize.uint64Value
        state.offset = currentSize
        guard currentSize > 0 else {
            states[pathKey] = state
            try? handle.close()
            return (state.isRunning, [])
        }

        defer {
            try? handle.close()
        }

        var cursor = currentSize
        var reversedLine: [UInt8] = []

        while cursor > 0 {
            let readLength = min(UInt64(chunkSize), cursor)
            cursor -= readLength

            do {
                try handle.seek(toOffset: cursor)
                guard let chunk = try handle.read(upToCount: Int(readLength)) else {
                    state.isReliable = false
                    break
                }
                if cursor + readLength == currentSize, chunk.last != 0x0A {
                    state.isReliable = false
                }

                for byte in chunk.reversed() {
                    if byte == 0x0A {
                        if let event = lifecycleEvent(fromReversedLine: reversedLine) {
                            apply(event, to: &state)
                            states[pathKey] = state
                            return (state.isRunning, [])
                        }
                        reversedLine.removeAll(keepingCapacity: true)
                    } else {
                        reversedLine.append(byte)
                    }
                }
            } catch {
                state.isReliable = false
                break
            }
        }

        if let event = lifecycleEvent(fromReversedLine: reversedLine) {
            apply(event, to: &state)
        }

        states[pathKey] = state
        return (state.isRunning, [])
    }

    private func apply(_ event: LifecycleEvent, to state: inout SessionState) {
        state.hasLifecycle = true
        switch event {
        case .started(let date):
            state.isRunning = true
            state.startedAt = date ?? .now
            state.endedAt = nil
        case .completed(_, let date):
            state.isRunning = false
            state.endedAt = date ?? .now
        case .aborted(let date):
            state.isRunning = false
            state.endedAt = date ?? .now
        }
    }

    private func lifecycleEvent(from line: Data) -> LifecycleEvent? {
        guard Self.lifecycleMarkers.contains(where: { line.range(of: $0) != nil }) else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        let timestamp = object["timestamp"] as? String ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        switch type {
        case "task_started":
            return .started(date)
        case "task_complete":
            guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else {
                return nil
            }
            return .completed(turnID: turnID, date: date)
        case "task_aborted", "turn_aborted", "task_cancelled", "turn_cancelled":
            return .aborted(date)
        default:
            return nil
        }
    }

    private func lifecycleEvent(fromReversedLine line: [UInt8]) -> LifecycleEvent? {
        guard !line.isEmpty else {
            return nil
        }

        let data = Data(line)
        guard Self.reversedLifecyclePrefixes.contains(where: { data.range(of: $0) != nil }) else {
            return nil
        }

        return lifecycleEvent(from: Data(line.reversed()))
    }
}
