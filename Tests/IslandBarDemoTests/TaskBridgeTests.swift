import Foundation
import XCTest
@testable import IslandBarDemo

final class TaskBridgeTests: XCTestCase {
    func testAccountManagementPreservesIdentityAndRejectsWrongLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskBridgeStore(paths: TaskBridgePaths(root: root))
        let original = try await store.registerAccount(email: "a@example.com", planType: "team", codexHome: root, workspaceID: "team-a")[0]
        let renamed = try await store.renameAccount(id: original.id, name: " 工作 ")
        XCTAssertEqual(renamed[0].displayName, "工作")
        do {
            _ = try await store.renameAccount(id: original.id, name: "  ")
            XCTFail("Empty remark accepted")
        } catch {}
        var identity = CodexAccountIdentity(email: "a@example.com", planType: "team", workspaceID: "team-b")
        do {
            _ = try await store.renewAccount(id: original.id, identity: identity, home: root.appendingPathComponent("new"))
            XCTFail("Different workspace accepted")
        } catch {}
        identity.workspaceID = "team-a"
        let renewed = try await store.renewAccount(id: original.id, identity: identity, home: root.appendingPathComponent("new"))
        XCTAssertEqual(renewed[0].id, original.id)
        XCTAssertEqual(renewed[0].displayName, "工作")
        XCTAssertEqual(renewed[0].createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 1)
        let removed = try await store.removeAccount(id: original.id)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
    func testAccountSwitchBlocksRunningUnknownAndStaleState() {
        let now = Date()
        XCTAssertNotNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 1, connected: true, lastUpdated: now, hasError: false, now: now))
        XCTAssertNotNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 0, connected: false, lastUpdated: now, hasError: false, now: now))
        XCTAssertNotNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 0, connected: true, lastUpdated: nil, hasError: false, now: now))
        XCTAssertNotNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 0, connected: true, lastUpdated: now.addingTimeInterval(-6), hasError: false, now: now))
        XCTAssertNotNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 0, connected: true, lastUpdated: now, hasError: true, now: now))
        XCTAssertNil(CodexAccountSwitchPolicy.blockingReason(runningCount: 0, connected: true, lastUpdated: now, hasError: false, now: now))
    }
    func testAccountRegistrationDeduplicatesAndPreservesIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskBridgeStore(paths: TaskBridgePaths(root: root))
        let home = root.appendingPathComponent("codex")
        let first = try await store.registerAccount(email: "a@example.com", planType: "plus", codexHome: home)
        let repeated = try await store.registerAccount(email: "A@example.com", planType: "pro", codexHome: home)
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(first[0].id, repeated[0].id)
        XCTAssertEqual(repeated[0].planType, "pro")
        let second = try await store.registerAccount(email: "b@example.com", planType: "plus", codexHome: home)
        XCTAssertEqual(second.count, 2)
        let loaded = try await store.loadAccountProfiles()
        XCTAssertEqual(loaded.map(\.id), second.map(\.id))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("accounts.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAccountResponseRejectsMissingIdentity() throws {
        XCTAssertThrowsError(try CodexAccountIdentity.parse(["account": NSNull()]))
        XCTAssertThrowsError(try CodexAccountIdentity.parse(["account": ["type": "apiKey"]]))
        XCTAssertThrowsError(try CodexAccountIdentity.parse(["account": ["type": "chatgpt"]]))
        let identity = try CodexAccountIdentity.parse(["account": ["type": "chatgpt", "email": "a@example.com", "planType": "plus"]])
        XCTAssertEqual(identity.email, "a@example.com")
    }

    func testPersonalAndTeamWorkspacesRemainSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskBridgeStore(paths: TaskBridgePaths(root: root))
        _ = try await store.registerAccount(email: "a@example.com", planType: "plus", codexHome: root, workspaceID: "personal")
        _ = try await store.registerAccount(email: "a@example.com", planType: "team", codexHome: root, workspaceID: "team-a")
        let profiles = try await store.registerAccount(email: "a@example.com", planType: "team", codexHome: root, workspaceID: "team-b")
        XCTAssertEqual(profiles.count, 3)
        let repeated = try await store.registerAccount(email: "a@example.com", planType: "team", codexHome: root, workspaceID: "team-a")
        XCTAssertEqual(repeated.map(\.id), profiles.map(\.id))
    }

    func testUsageUsesCodexBucketAndDistinguishesMissingFromZero() {
        let legacy: [String: Any] = ["primary": ["usedPercent": 90]]
        let usage = CodexAccountUsage.parse([
            "rateLimits": legacy,
            "rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 24, "windowDurationMins": 300],
                "secondary": ["usedPercent": 100, "windowDurationMins": 10080]
            ]]
        ])
        XCTAssertEqual(usage.primary?.remainingPercent, 76)
        XCTAssertEqual(usage.primary?.title, "5h")
        XCTAssertEqual(usage.secondary?.remainingPercent, 0)
        XCTAssertEqual(usage.secondary?.title, "7d")
        XCTAssertNil(CodexAccountUsage.parse([:]).primary)
        XCTAssertNil(CodexAccountUsage.parse([
            "rateLimits": legacy, "rateLimitsByLimitId": ["other-model": legacy]
        ]).primary)
    }

    func testQuotaWindowsHideMissingAndSortShortWindowFirst() {
        let weeklyOnly = CodexAccountUsage.parse(["rateLimits": [
            "primary": NSNull(), "secondary": ["usedPercent": 12, "windowDurationMins": 10080]
        ]])
        XCTAssertEqual(weeklyOnly.displayWindows.count, 1)
        XCTAssertEqual(weeklyOnly.displayWindows.first?.minutes, 10080)
        let reversed = CodexAccountUsage.parse(["rateLimits": [
            "primary": ["usedPercent": 12, "windowDurationMins": 10080],
            "secondary": ["usedPercent": 20, "windowDurationMins": 300]
        ]])
        XCTAssertEqual(reversed.displayWindows.compactMap(\.minutes), [300, 10080])
    }

    func testSwitchRequiresExpectedWorkspaceAndEmail() {
        let profile = CodexAccountProfile(
            id: "test", displayName: "A", codexHomePath: URL(fileURLWithPath: "/tmp/example"),
            createdAt: .now, isEnabled: true, email: "a@example.com", planType: "team", workspaceID: "team-a"
        )
        var identity = CodexAccountIdentity(email: "A@example.com", planType: "team")
        XCTAssertFalse(identity.matches(profile), "Missing workspace evidence must not activate an account")
        identity.usage = CodexAccountUsage(accountID: "team-b", primary: nil, secondary: nil)
        XCTAssertFalse(identity.matches(profile))
        identity.usage = CodexAccountUsage(accountID: "team-a", primary: nil, secondary: nil)
        XCTAssertTrue(identity.matches(profile))
        let otherEmail = CodexAccountIdentity(email: "b@example.com", planType: "team", usage: identity.usage)
        XCTAssertFalse(otherEmail.matches(profile))
    }

    func testBackgroundQuotaStateNeverAssignsAnotherAccountsUsage() {
        let profile = CodexAccountProfile(
            id: "a", displayName: "A", codexHomePath: URL(fileURLWithPath: "/tmp/example"),
            createdAt: .now, isEnabled: true, email: "a@example.com", planType: "plus", workspaceID: "a"
        )
        let usage = CodexAccountUsage.parse(["accountId": "a", "rateLimits": [
            "secondary": ["usedPercent": 40, "windowDurationMins": 10080]
        ]])
        let identity = CodexAccountIdentity(email: "a@example.com", planType: "plus", usage: usage)
        let success = CodexAccountQuotaState.resolve(.success(identity), for: profile)
        XCTAssertEqual(success.usage?.secondary?.remainingPercent, 60)
        XCTAssertNil(success.error)
        let different = CodexAccountIdentity(email: "b@example.com", planType: "plus", usage: usage)
        let mismatch = CodexAccountQuotaState.resolve(.success(different), for: profile)
        XCTAssertNil(mismatch.usage)
        XCTAssertNotNil(mismatch.error)
        let failure = CodexAccountQuotaState.resolve(.failure(CocoaError(.fileReadNoPermission)), for: profile)
        XCTAssertNil(failure.usage)
        XCTAssertNotNil(failure.error)
    }

    func testBootstrapCreatesPrivateBridgeDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandBarTaskBridge-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TaskBridgeStore(paths: TaskBridgePaths(root: root))
        try await store.bootstrap()

        for directory in ["tasks", "messages", "leases"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(directory).path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testHandoffPersistsTaskAndReadableMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandBarTaskBridge-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskBridgePaths(root: root)
        let store = TaskBridgeStore(paths: paths)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let projectPath = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let task = TaskBridgeTask(
            id: "task/001",
            projectPath: projectPath,
            branch: "main",
            worktreePath: projectPath,
            status: .pausedQuota,
            activeAccountID: "account-a",
            activeSessionID: "session-a",
            goal: "继续完成任务",
            completed: ["完成基础实现"],
            inProgress: ["账号 B 继续"],
            decisions: ["使用文件交接"],
            filesChanged: ["TaskBridgeStore.swift"],
            tests: ["swift test"],
            lastUserRequest: "继续原任务",
            nextStep: "读取 handoff.md",
            sessions: [],
            latestHandoffID: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await store.saveTask(task)
        let snapshot = try await store.createHandoff(for: task, generatedAt: timestamp)
        let loaded = try await store.loadTask(id: task.id)

        XCTAssertEqual(loaded, task)
        XCTAssertEqual(snapshot.taskID, task.id)
        XCTAssertTrue(snapshot.markdown.contains("继续完成任务"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.handoffMarkdownFile(taskID: task.id, handoffID: snapshot.id).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.handoffJSONFile(taskID: task.id, handoffID: snapshot.id).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.projectHandoffMarkdownFile(
                projectPath: projectPath,
                taskID: task.id,
                handoffID: snapshot.id
            ).path
        ))
    }
}
