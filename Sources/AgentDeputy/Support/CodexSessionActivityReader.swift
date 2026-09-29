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
    var attentionEvents: [CodexAttentionEvent] = []
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
        var currentTurnID: String?
        var startedAt: Date?
        var endedAt: Date?
        var hasLifecycle = false
        var isReliable = true
        var hasSessionMetadata = false
        var hasOnlySetupRecords = true

        var hasKnownActivity: Bool {
            isReliable && pendingLine.isEmpty
                && (hasLifecycle || (hasSessionMetadata && hasOnlySetupRecords))
        }
    }

    private enum LifecycleEvent {
        case started(turnID: String?, date: Date?)
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
    private static let userInputMarkers = [
        Data("\"request_user_input\"".utf8),
        Data("\"request_user_input_async\"".utf8)
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
        var attentionEvents: [CodexAttentionEvent] = []
        var seenPaths = Set<String>()
        var startedAt: [String: Date] = [:]
        var endedAt: [String: Date] = [:]

        var unknownThreadIDs = Set<String>()
        for record in records {
            guard let path = record.path else { unknownThreadIDs.insert(record.id); continue }
            let pathKey = path.path
            let isNewFile = states[pathKey] == nil
            let shouldEmitCompletions = hasBootstrapped && !isNewFile
            let events: (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent], attentionEvents: [CodexAttentionEvent])
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
            if states[pathKey]?.hasKnownActivity != true {
                unknownThreadIDs.insert(record.id)
            }
            if events.isRunning {
                activeThreadIDs.insert(record.id)
            }
            completedTasks.append(contentsOf: events.completedTasks)
            attentionEvents.append(contentsOf: events.attentionEvents)
            startedAt[record.id] = states[pathKey]?.startedAt
            endedAt[record.id] = states[pathKey]?.endedAt
        }

        states = states.filter { seenPaths.contains($0.key) }
        hasBootstrapped = true

        return CodexActivitySnapshot(
            activeThreadIDs: activeThreadIDs,
            completedTasks: completedTasks,
            attentionEvents: attentionEvents,
            startedAt: startedAt,
            endedAt: endedAt,
            unknownThreadIDs: unknownThreadIDs
        )
    }

    private func readEvents(
        at path: URL,
        threadID: String,
        emitCompletions: Bool
    ) -> (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent], attentionEvents: [CodexAttentionEvent]) {
        let pathKey = path.path
        var state = states[pathKey] ?? SessionState()
        var completedTasks: [CodexTaskCompletionEvent] = []
        var attentionEvents: [CodexAttentionEvent] = []

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber else {
            states[pathKey] = state
            return (state.isRunning, completedTasks, attentionEvents)
        }

        let currentSize = fileSize.uint64Value
        if currentSize < state.offset {
            state = SessionState()
        }

        guard currentSize > state.offset,
              let handle = try? FileHandle(forReadingFrom: path) else {
            states[pathKey] = state
            return (state.isRunning, completedTasks, attentionEvents)
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

                    if let event = lifecycleEvent(from: line) {
                        if case .completed(let turnID, _) = event, emitCompletions, state.isRunning {
                            completedTasks.append(CodexTaskCompletionEvent(threadID: threadID, turnID: turnID))
                        }
                        apply(event, to: &state)
                    } else {
                        inspectSetupRecord(from: line, to: &state)
                    }
                    if let attention = userInputEvent(
                        from: line,
                        threadID: threadID,
                        turnID: state.currentTurnID
                    ) {
                        attentionEvents.append(attention)
                    }
                }
            }
        } catch {
            // Keep the last coherent state. The next polling pass retries the
            // unread bytes from the same offset.
            states[pathKey] = state
            return (state.isRunning, completedTasks, attentionEvents)
        }

        states[pathKey] = state
        return (state.isRunning, completedTasks, attentionEvents)
    }

    private func readInitialState(
        at path: URL
    ) -> (isRunning: Bool, completedTasks: [CodexTaskCompletionEvent], attentionEvents: [CodexAttentionEvent]) {
        let pathKey = path.path
        var state = SessionState()

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: path) else {
            states[pathKey] = state
            return (state.isRunning, [], [])
        }

        let currentSize = fileSize.uint64Value
        state.offset = currentSize
        guard currentSize > 0 else {
            states[pathKey] = state
            try? handle.close()
            return (state.isRunning, [], [])
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
                            return (state.isRunning, [], [])
                        }
                        if state.hasOnlySetupRecords {
                            inspectSetupRecord(from: Data(reversedLine.reversed()), to: &state)
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
        } else {
            inspectSetupRecord(from: Data(reversedLine.reversed()), to: &state)
        }

        states[pathKey] = state
        return (state.isRunning, [], [])
    }

    private func inspectSetupRecord(from line: Data, to state: inout SessionState) {
        guard !state.hasLifecycle, state.hasOnlySetupRecords, !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            state.hasOnlySetupRecords = false
            return
        }

        // A created but never-started thread has no lifecycle events. Only
        // positively identified setup records can establish that it is idle.
        switch object["type"] as? String {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String, !id.isEmpty else {
                state.hasOnlySetupRecords = false
                return
            }
            state.hasSessionMetadata = true
        case "event_msg":
            let payload = object["payload"] as? [String: Any]
            state.hasOnlySetupRecords = payload?["type"] as? String == "thread_settings_applied"
        default:
            state.hasOnlySetupRecords = false
        }
    }

    private func apply(_ event: LifecycleEvent, to state: inout SessionState) {
        state.hasLifecycle = true
        switch event {
        case .started(let turnID, let date):
            state.isRunning = true
            state.currentTurnID = turnID
            state.startedAt = date ?? .now
            state.endedAt = nil
        case .completed(_, let date):
            state.isRunning = false
            state.currentTurnID = nil
            state.endedAt = date ?? .now
        case .aborted(let date):
            state.isRunning = false
            state.currentTurnID = nil
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
            return .started(turnID: payload["turn_id"] as? String, date: date)
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

    private func userInputEvent(
        from line: Data,
        threadID: String,
        turnID: String?
    ) -> CodexAttentionEvent? {
        guard Self.userInputMarkers.contains(where: { line.range(of: $0) != nil }),
              let turnID,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "function_call",
              let name = payload["name"] as? String,
              name == "request_user_input" || name == "request_user_input_async",
              let callID = payload["call_id"] as? String, !callID.isEmpty else { return nil }
        return CodexAttentionEvent(
            sessionID: threadID,
            turnID: turnID,
            requestID: callID,
            kind: .userInput,
            timestamp: .now
        )
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
