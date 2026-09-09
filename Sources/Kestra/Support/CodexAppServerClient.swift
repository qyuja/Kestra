import Foundation

@MainActor
final class CodexAppServerClient {
    typealias ThreadListCompletion = @MainActor (Result<[CodexThreadRecord], Error>) -> Void

    private enum PendingRequest {
        case initialize
        case threadList
        case account
        case accountLimits
        case login
    }

    private let fileManager = FileManager.default
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var isInitialized = false
    private var accountCompletion: ((Result<CodexAccountIdentity, Error>) -> Void)?
    private var accountTimeout: Task<Void, Never>?
    private var pendingAccountIdentity: CodexAccountIdentity?
    private var includeAccountUsage = true
    private(set) var codexHome: URL
    var onInitialized: (() -> Void)?
    var onLoginURL: ((URL) -> Void)?
    var onLoginCompleted: ((Bool, String?) -> Void)?
    private var loginID: String?

    static var defaultCodexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    init(codexHome: URL = CodexAppServerClient.defaultCodexHome) {
        self.codexHome = codexHome.standardizedFileURL.resolvingSymlinksInPath()
    }

    func setCodexHome(_ home: URL) {
        precondition(!isRunning)
        codexHome = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    func beginLogin() {
        guard isInitialized else { reportError("登录服务尚未就绪"); return }
        let id = allocateRequestID()
        pendingRequests[id] = .login
        send(["jsonrpc": "2.0", "id": id, "method": "account/login/start", "params": ["type": "chatgpt"]])
    }

    func requestAccount(includeUsage: Bool = true, completion: @escaping (Result<CodexAccountIdentity, Error>) -> Void) {
        guard isRunning else { completion(.failure(CodexAppServerError.notRunning)); return }
        guard accountCompletion == nil else {
            completion(.failure(CodexAppServerError.server("正在读取账号，请稍后重试")))
            return
        }
        accountCompletion = completion
        includeAccountUsage = includeUsage
        accountTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.finishAccountFailure(CodexAppServerError.server("读取账号或额度超时，请重试"))
        }
        if isInitialized { sendAccountRequest() }
    }

    private func sendAccountRequest() {
        let id = allocateRequestID()
        pendingRequests[id] = .account
        send(["jsonrpc": "2.0", "id": id, "method": "account/read", "params": ["refreshToken": false]])
    }

    private func finishAccount(_ result: Result<CodexAccountIdentity, Error>) {
        accountTimeout?.cancel()
        accountTimeout = nil
        let completion = accountCompletion
        accountCompletion = nil
        pendingAccountIdentity = nil
        pendingRequests = pendingRequests.filter {
            switch $0.value { case .account, .accountLimits: return false; default: return true }
        }
        completion?(result)
    }

    private func finishAccountFailure(_ error: Error) {
        if var identity = pendingAccountIdentity {
            identity.usageError = error.localizedDescription
            finishAccount(.success(identity))
        } else {
            finishAccount(.failure(error))
        }
    }
    private var queuedThreadListCompletion: ThreadListCompletion?
    private var activeThreadListCompletion: ThreadListCompletion?
    private var threadListAccumulator: [CodexThreadRecord] = []

    var onConnectionChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onActivityChanged: (() -> Void)?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() {
        guard process == nil else { return }

        guard let executableURL = Self.codexExecutableURL(fileManager: fileManager) else {
            reportError("找不到 Codex CLI，无法连接本地 app-server")
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            reportError("启动 Codex app-server 失败：\(error.localizedDescription)")
            return
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        isInitialized = false
        onConnectionChanged?(true)

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }

        // Codex can write startup diagnostics to stderr. Drain the pipe so a
        // noisy configuration cannot block the JSON-RPC process.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        sendInitialize()
    }

    func stop() {
        if let loginID {
            send(["jsonrpc": "2.0", "id": allocateRequestID(), "method": "account/login/cancel", "params": ["loginId": loginID]])
        }
        loginID = nil
        finishAccount(.failure(CodexAppServerError.notRunning))
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        pendingRequests.removeAll()
        queuedThreadListCompletion = nil
        activeThreadListCompletion = nil
        isInitialized = false
        onConnectionChanged?(false)
    }

    func requestThreadList(completion: @escaping ThreadListCompletion) {
        guard process?.isRunning == true else {
            completion(.failure(CodexAppServerError.notRunning))
            return
        }

        guard isInitialized else {
            queuedThreadListCompletion = completion
            return
        }

        guard activeThreadListCompletion == nil else {
            queuedThreadListCompletion = completion
            return
        }

        beginThreadList(completion: completion)
    }

    private func sendInitialize() {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "island-bar-demo",
                "version": "0.1.0"
            ],
            "capabilities": [
                "experimentalApi": true
            ]
        ]

        let requestID = allocateRequestID()
        pendingRequests[requestID] = .initialize
        send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "initialize",
            "params": params
        ])
    }

    private func beginThreadList(completion: @escaping ThreadListCompletion) {
        activeThreadListCompletion = completion
        threadListAccumulator.removeAll(keepingCapacity: true)
        sendThreadListPage(cursor: nil)
    }

    private func sendThreadListPage(cursor: String?) {
        var params: [String: Any] = [
            "archived": false,
            "limit": 100,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "useStateDbOnly": true
        ]

        if let cursor, !cursor.isEmpty {
            params["cursor"] = cursor
        }

        let requestID = allocateRequestID()
        pendingRequests[requestID] = .threadList
        send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "thread/list",
            "params": params
        ])
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func send(_ object: [String: Any]) {
        guard let inputPipe else {
            reportError("Codex app-server 输入管道不可用")
            return
        }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            reportError("发送 Codex app-server 请求失败：\(error.localizedDescription)")
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.subdata(in: 0..<newlineIndex)
            outputBuffer.removeSubrange(0...newlineIndex)

            guard !line.isEmpty else { continue }
            handleMessage(line)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            reportError("无法解析 Codex app-server 响应")
            return
        }

        // Notifications are useful as a low-latency hint, while the monitor
        // still polls thread/list so it also recovers after a missed event.
        if let method = object["method"] as? String {
            if method == "account/login/completed", let params = object["params"] as? [String: Any],
               let completedID = params["loginId"] as? String, completedID == loginID {
                loginID = nil
                onLoginCompleted?(params["success"] as? Bool == true, params["error"] as? String)
            }
            if method.hasPrefix("thread/") || method.hasPrefix("turn/") {
                onActivityChanged?()

                if let queuedThreadListCompletion,
                   activeThreadListCompletion == nil,
                   isInitialized {
                    self.queuedThreadListCompletion = nil
                    beginThreadList(completion: queuedThreadListCompletion)
                }
            }
            return
        }

        guard let rawID = object["id"] as? NSNumber else { return }
        let requestID = rawID.intValue
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else {
            return
        }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "未知错误"
            finish(pendingRequest, with: .failure(CodexAppServerError.server(message)))
            return
        }

        guard let result = object["result"] as? [String: Any] else {
            finish(pendingRequest, with: .failure(CodexAppServerError.invalidResponse))
            return
        }

        switch pendingRequest {
        case .initialize:
            isInitialized = true
            send([
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:]
            ])

            if accountCompletion != nil { sendAccountRequest() }
            onInitialized?()
            if let queuedThreadListCompletion {
                self.queuedThreadListCompletion = nil
                beginThreadList(completion: queuedThreadListCompletion)
            }

        case .threadList:
            handleThreadListPage(result)
        case .account:
            do {
                let identity = try CodexAccountIdentity.parse(result)
                guard includeAccountUsage else {
                    finishAccount(.success(identity))
                    return
                }
                pendingAccountIdentity = identity
                let id = allocateRequestID()
                pendingRequests[id] = .accountLimits
                send(["jsonrpc": "2.0", "id": id, "method": "account/rateLimits/read", "params": [:]])
            } catch {
                finishAccount(.failure(error))
            }
        case .accountLimits:
            guard var identity = pendingAccountIdentity else { return }
            identity.usage = CodexAccountUsage.parse(result)
            finishAccount(.success(identity))
        case .login:
            guard let id = result["loginId"] as? String,
                  let rawURL = result["authUrl"] as? String,
                  let url = URL(string: rawURL), url.scheme == "https",
                  ["auth.openai.com", "auth.chatgpt.com", "chatgpt.com"].contains(url.host ?? "") else {
                reportError("登录服务返回了无效的登录地址")
                return
            }
            loginID = id
            onLoginURL?(url)
        }
    }

    private func handleThreadListPage(_ result: [String: Any]) {
        if let rawThreads = result["data"] as? [[String: Any]] {
            threadListAccumulator.append(contentsOf: rawThreads.compactMap(parseThread))
        }

        if let nextCursor = result["nextCursor"] as? String, !nextCursor.isEmpty {
            sendThreadListPage(cursor: nextCursor)
            return
        }

        let completion = activeThreadListCompletion
        activeThreadListCompletion = nil
        completion?(.success(threadListAccumulator))

        if let queuedThreadListCompletion {
            self.queuedThreadListCompletion = nil
            beginThreadList(completion: queuedThreadListCompletion)
        }
    }

    private func parseThread(_ rawThread: [String: Any]) -> CodexThreadRecord? {
        guard let id = rawThread["id"] as? String, !id.isEmpty else {
            return nil
        }

        let preview = normalizedText(rawThread["preview"] as? String, limit: 92)
        let title = normalizedText(
            (rawThread["name"] as? String) ?? (rawThread["title"] as? String),
            limit: 56,
            fallback: preview.isEmpty ? "未命名 Codex 任务" : preview
        )
        let summary = preview.isEmpty ? "Codex 任务" : preview
        let updatedAt = date(from: rawThread["updatedAt"])
        let path = (rawThread["path"] as? String).map(URL.init(fileURLWithPath:))

        return CodexThreadRecord(
            id: id,
            title: title,
            summary: summary,
            updatedAt: updatedAt,
            path: path
        )
    }

    private func normalizedText(
        _ value: String?,
        limit: Int,
        fallback: String = ""
    ) -> String {
        let compact = value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") ?? ""
        let text = compact.isEmpty ? fallback : compact

        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 1))) + "…"
    }

    private func date(from value: Any?) -> Date {
        guard let number = value as? NSNumber else { return .distantPast }
        let timestamp = number.doubleValue
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private func finish(
        _ request: PendingRequest,
        with result: Result<[CodexThreadRecord], Error>
    ) {
        switch request {
        case .initialize:
            finishAccount(.failure(CodexAppServerError.server(result.errorDescription)))
            reportError(result.errorDescription)
        case .account:
            finishAccount(.failure(CodexAppServerError.server(result.errorDescription)))
        case .accountLimits:
            finishAccountFailure(CodexAppServerError.server(result.errorDescription))
        case .login:
            reportError(result.errorDescription)
        case .threadList:
            let completion = activeThreadListCompletion
            activeThreadListCompletion = nil
            completion?(result)
        }
    }

    private func handleTermination(status: Int32) {
        guard process != nil else { return }
        finishAccount(.failure(CodexAppServerError.notRunning))

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        isInitialized = false
        pendingRequests.removeAll()
        activeThreadListCompletion = nil
        onConnectionChanged?(false)

        if status != 0 {
            reportError("Codex app-server 已退出（\(status)）")
        }
    }

    private func reportError(_ message: String) {
        onError?(message)
    }

    private static func codexExecutableURL(fileManager: FileManager) -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}

private enum CodexAppServerError: LocalizedError {
    case notRunning
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Codex app-server 尚未运行"
        case .invalidResponse:
            "Codex app-server 返回了无法识别的响应"
        case .server(let message):
            "Codex app-server：\(message)"
        }
    }
}

private extension Result where Failure == Error {
    var errorDescription: String {
        guard case .failure(let error) = self else { return "Codex app-server 初始化失败" }
        return error.localizedDescription
    }
}
