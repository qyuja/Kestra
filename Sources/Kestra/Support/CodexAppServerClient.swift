import Foundation

@MainActor
final class CodexAppServerClient {
    typealias ThreadListCompletion = @MainActor (Result<[CodexThreadRecord], Error>) -> Void
    typealias GreetingCompletion = @MainActor (Result<Void, Error>) -> Void

    private enum PendingRequest {
        case initialize
        case threadList
        case account
        case accountLimits
        case login
        case greetingMCPServerStatus
        case greetingThreadStart
        case greetingTurnStart
    }

    private let fileManager = FileManager.default
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
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
    var canContinueGreeting: (() -> Bool)?
    private var loginID: String?
    private var greetingCompletion: GreetingCompletion?
    private var greetingTimeout: Task<Void, Never>?
    private var pendingGreetingMessage: String?
    private var greetingThreadID: String?
    private var greetingTurnID: String?
    private var greetingWorkingDirectory: URL?
    private var greetingMCPServerNames = [String]()
    private var greetingMCPServerCursor: String?

    private static let activityNotificationMethods: Set<String> = [
        "thread/archived",
        "thread/closed",
        "thread/compacted",
        "thread/deleted",
        "thread/goal/cleared",
        "thread/goal/updated",
        "thread/started",
        "thread/name/updated",
        "thread/project/updated",
        "thread/queue/changed",
        "thread/reverted",
        "thread/settings/updated",
        "thread/status/changed",
        "thread/unarchived",
        "turn/started",
        "turn/completed",
    ]

    private static let greetingInstructions = "这是一次自动额度唤醒请求。不要调用任何工具，不要读取或修改文件，不要访问网络，也不要执行任何操作，只回复一句简短问候。"

    private var greetingConfig: [String: Any] {
        var disabledServers: [String: Any] = [:]
        for name in greetingMCPServerNames where !name.isEmpty {
            disabledServers[name] = ["enabled": false]
        }

        return [
            "features": ["plugins": false],
            "mcp_servers": disabledServers
        ]
    }

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

    /// Sends one isolated greeting through the app-server. The completion is
    /// delivered only after the corresponding `turn/completed` notification.
    func sendGreeting(
        message: String,
        completion: @escaping GreetingCompletion
    ) {
        guard isRunning else {
            completion(.failure(CodexAppServerError.notRunning))
            return
        }
        guard greetingCompletion == nil else {
            completion(.failure(CodexAppServerError.server("正在发送问候，请稍后重试")))
            return
        }
        guard let workingDirectory = createGreetingWorkingDirectory() else {
            completion(.failure(CodexAppServerError.server("无法创建问候临时目录")))
            return
        }

        greetingCompletion = completion
        greetingWorkingDirectory = workingDirectory
        greetingMCPServerNames.removeAll(keepingCapacity: true)
        greetingMCPServerCursor = nil
        pendingGreetingMessage = message
        greetingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.finishGreeting(.failure(CodexAppServerError.server("发送问候超时")))
        }
        if isInitialized {
            beginGreetingMCPServerStatus()
        }
    }

    private func beginGreeting() {
        guard isInitialized, greetingCompletion != nil,
              greetingThreadID == nil, greetingTurnID == nil else { return }
        guard pendingGreetingMessage != nil else {
            finishGreeting(.failure(CodexAppServerError.server("问候消息未准备好")))
            return
        }
        guard let workingDirectory = greetingWorkingDirectory else {
            finishGreeting(.failure(CodexAppServerError.server("问候临时目录未准备好")))
            return
        }
        let requestID = allocateRequestID()
        pendingRequests[requestID] = .greetingThreadStart
        send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "thread/start",
            "params": [
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "cwd": workingDirectory.path,
                "baseInstructions": Self.greetingInstructions,
                "developerInstructions": Self.greetingInstructions,
                "config": greetingConfig
            ]
        ])
    }

    private func beginGreetingTurn(threadID: String) {
        guard let message = pendingGreetingMessage else {
            finishGreeting(.failure(CodexAppServerError.server("问候线程未准备好")))
            return
        }
        guard let workingDirectory = greetingWorkingDirectory else {
            finishGreeting(.failure(CodexAppServerError.server("问候临时目录未准备好")))
            return
        }
        guard canContinueGreeting?() ?? true else {
            finishGreeting(.failure(CodexAppServerError.server("检测到运行中任务，问候已暂存")))
            return
        }

        greetingThreadID = threadID
        let requestID = allocateRequestID()
        pendingRequests[requestID] = .greetingTurnStart
        send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "turn/start",
            "params": [
                "threadId": threadID,
                "input": [
                    [
                        "type": "text",
                        "text": message
                    ]
                ],
                "approvalPolicy": "never",
                "cwd": workingDirectory.path,
                "sandboxPolicy": [
                    "type": "readOnly",
                    "networkAccess": false
                ]
            ]
        ])
    }

    private func finishGreeting(_ result: Result<Void, Error>) {
        greetingTimeout?.cancel()
        greetingTimeout = nil
        pendingGreetingMessage = nil
        greetingThreadID = nil
        greetingTurnID = nil
        greetingMCPServerNames.removeAll(keepingCapacity: false)
        greetingMCPServerCursor = nil
        if let greetingWorkingDirectory {
            try? fileManager.removeItem(at: greetingWorkingDirectory)
        }
        greetingWorkingDirectory = nil
        pendingRequests = pendingRequests.filter {
            switch $0.value {
            case .greetingMCPServerStatus, .greetingThreadStart, .greetingTurnStart:
                return false
            default:
                return true
            }
        }
        let completion = greetingCompletion
        greetingCompletion = nil
        completion?(result)
    }

    /// Resolve the configured MCP servers before starting the isolated thread.
    /// Passing every server back as `enabled: false` prevents a user's normal
    /// MCP configuration from becoming an implicit side effect of this request.
    private func beginGreetingMCPServerStatus() {
        guard isInitialized, greetingCompletion != nil,
              greetingThreadID == nil, greetingTurnID == nil else { return }
        guard !pendingRequests.values.contains(where: {
            if case .greetingMCPServerStatus = $0 { return true }
            return false
        }) else { return }

        var params: [String: Any] = [
            "detail": "toolsAndAuthOnly",
            "limit": 100
        ]
        if let cursor = greetingMCPServerCursor, !cursor.isEmpty {
            params["cursor"] = cursor
        }

        let requestID = allocateRequestID()
        pendingRequests[requestID] = .greetingMCPServerStatus
        send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "mcpServerStatus/list",
            "params": params
        ])
    }

    private func handleGreetingMCPServerStatus(_ result: [String: Any]) {
        guard let rawServers = result["data"] as? [[String: Any]] else {
            finishGreeting(.failure(CodexAppServerError.invalidResponse))
            return
        }

        for rawServer in rawServers {
            guard let name = rawServer["name"] as? String, !name.isEmpty,
                  !greetingMCPServerNames.contains(name) else { continue }
            greetingMCPServerNames.append(name)
        }

        if let nextCursor = result["nextCursor"] as? String, !nextCursor.isEmpty {
            greetingMCPServerCursor = nextCursor
            beginGreetingMCPServerStatus()
        } else {
            greetingMCPServerCursor = nil
            beginGreeting()
        }
    }

    private func createGreetingWorkingDirectory() -> URL? {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("KestraLimitRefresh-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            reportError("创建额度问候临时目录失败：\(error.localizedDescription)")
            return nil
        }
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
    private var queuedThreadListIncludesHistory = false
    private var activeThreadListCompletion: ThreadListCompletion?
    private var activeThreadListIncludesHistory = false
    private var threadListAccumulator: [CodexThreadRecord] = []
    // Kestra shows active tasks and a short recent list. Fetching every
    // historical page on each poll makes the app-server and JSON parser scale
    // with the lifetime of the account rather than the visible UI.
    private let visibleThreadListLimit = 100

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
        self.errorPipe = errorPipe
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
            let data = handle.availableData
            if data.isEmpty {
                // EOF remains readable. Removing the handler here prevents
                // FileHandle from repeatedly waking a monitoring queue after
                // the app-server has exited.
                handle.readabilityHandler = nil
            }
        }

        sendInitialize()
    }

    func stop() {
        if let loginID {
            send(["jsonrpc": "2.0", "id": allocateRequestID(), "method": "account/login/cancel", "params": ["loginId": loginID]])
        }
        loginID = nil
        finishAccount(.failure(CodexAppServerError.notRunning))
        finishGreeting(.failure(CodexAppServerError.notRunning))
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        pendingRequests.removeAll()
        queuedThreadListCompletion = nil
        queuedThreadListIncludesHistory = false
        activeThreadListCompletion = nil
        activeThreadListIncludesHistory = false
        isInitialized = false
        onConnectionChanged?(false)
    }

    func requestThreadList(
        includeHistory: Bool = true,
        completion: @escaping ThreadListCompletion
    ) {
        guard process?.isRunning == true else {
            completion(.failure(CodexAppServerError.notRunning))
            return
        }

        guard isInitialized else {
            queuedThreadListCompletion = completion
            queuedThreadListIncludesHistory = includeHistory
            return
        }

        guard activeThreadListCompletion == nil else {
            queuedThreadListCompletion = completion
            queuedThreadListIncludesHistory = queuedThreadListIncludesHistory || includeHistory
            return
        }

        beginThreadList(includeHistory: includeHistory, completion: completion)
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

    private func beginThreadList(
        includeHistory: Bool,
        completion: @escaping ThreadListCompletion
    ) {
        activeThreadListCompletion = completion
        activeThreadListIncludesHistory = includeHistory
        threadListAccumulator.removeAll(keepingCapacity: true)
        sendThreadListPage(cursor: nil)
    }

    private func sendThreadListPage(cursor: String?) {
        var params: [String: Any] = [
            "archived": false,
            "limit": visibleThreadListLimit,
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
            if method == "turn/completed",
               let params = object["params"] as? [String: Any],
               let threadID = params["threadId"] as? String,
               threadID == greetingThreadID,
               let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String,
               turnID == greetingTurnID {
                let status = turn["status"] as? String
                if status == "completed" {
                    finishGreeting(.success(()))
                } else {
                    let message = (turn["error"] as? [String: Any])?["message"] as? String
                        ?? "问候任务未完成（\(status ?? "未知状态")）"
                    finishGreeting(.failure(CodexAppServerError.server(message)))
                }
            }
            if Self.activityNotificationMethods.contains(method) {
                onActivityChanged?()

                if let queuedThreadListCompletion,
                   activeThreadListCompletion == nil,
                   isInitialized {
                    self.queuedThreadListCompletion = nil
                    let includeHistory = self.queuedThreadListIncludesHistory
                    self.queuedThreadListIncludesHistory = false
                    beginThreadList(
                        includeHistory: includeHistory,
                        completion: queuedThreadListCompletion
                    )
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
            if pendingGreetingMessage != nil {
                beginGreetingMCPServerStatus()
            }
            if let queuedThreadListCompletion {
                self.queuedThreadListCompletion = nil
                let includeHistory = self.queuedThreadListIncludesHistory
                self.queuedThreadListIncludesHistory = false
                beginThreadList(
                    includeHistory: includeHistory,
                    completion: queuedThreadListCompletion
                )
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
        case .greetingMCPServerStatus:
            handleGreetingMCPServerStatus(result)
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
        case .greetingThreadStart:
            guard let thread = result["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String,
                  !threadID.isEmpty else {
                finishGreeting(.failure(CodexAppServerError.invalidResponse))
                return
            }
            beginGreetingTurn(threadID: threadID)
        case .greetingTurnStart:
            guard let turn = result["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  !turnID.isEmpty else {
                finishGreeting(.failure(CodexAppServerError.invalidResponse))
                return
            }
            greetingTurnID = turnID
        }
    }

    private func handleThreadListPage(_ result: [String: Any]) {
        if let rawThreads = result["data"] as? [[String: Any]] {
            threadListAccumulator.append(contentsOf: rawThreads.compactMap(parseThread))
        }

        if activeThreadListIncludesHistory,
           let nextCursor = result["nextCursor"] as? String,
           !nextCursor.isEmpty {
            sendThreadListPage(cursor: nextCursor)
            return
        }

        // Normal monitoring only needs the first page. A periodic full scan
        // is requested by CodexTaskStore so old but still-running threads are
        // eventually rediscovered without parsing the whole history every 2s.
        let completion = activeThreadListCompletion
        activeThreadListCompletion = nil
        activeThreadListIncludesHistory = false
        completion?(.success(threadListAccumulator))

        if let queuedThreadListCompletion {
            self.queuedThreadListCompletion = nil
            let includeHistory = queuedThreadListIncludesHistory
            queuedThreadListIncludesHistory = false
            beginThreadList(
                includeHistory: includeHistory,
                completion: queuedThreadListCompletion
            )
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
            activeThreadListIncludesHistory = false
            completion?(result)
        case .greetingMCPServerStatus, .greetingThreadStart, .greetingTurnStart:
            finishGreeting(.failure(CodexAppServerError.server(result.errorDescription)))
        }
    }

    private func handleTermination(status: Int32) {
        guard process != nil else { return }
        finishAccount(.failure(CodexAppServerError.notRunning))
        finishGreeting(.failure(CodexAppServerError.notRunning))

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        isInitialized = false
        pendingRequests.removeAll()
        activeThreadListCompletion = nil
        activeThreadListIncludesHistory = false
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
