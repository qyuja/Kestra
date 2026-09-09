import Foundation
import XCTest
@testable import IslandBarDemo

final class ClaudeAccountTests: XCTestCase {
    func testSubscriptionIdentityRejectsOtherAuthMethods() throws {
        let good = Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com","orgId":"org-a","subscriptionType":"max"}"#.utf8)
        let identity = try ClaudeAccountIdentity.parse(good)
        XCTAssertEqual(identity.subscriptionType, "max")
        XCTAssertTrue(identity.matches(.init(email: "A@example.com", orgId: "org-a", subscriptionType: "pro")))
        XCTAssertFalse(identity.matches(.init(email: "a@example.com", orgId: "org-b", subscriptionType: "max")))
        XCTAssertThrowsError(try ClaudeAccountIdentity.parse(Data(#"{"loggedIn":false}"#.utf8)))
        XCTAssertThrowsError(try ClaudeAccountIdentity.parse(Data(#"{"loggedIn":true,"authMethod":"api_key","email":"a@example.com","orgId":"org-a"}"#.utf8)))
    }

    func testConfigReplacementPreservesProjectsSettingsAndUnknownFields() throws {
        let original = Data(#"{"projects":{"/repo":{"history":[1,2]}},"hasCompletedOnboarding":true,"custom":"keep","oauthAccount":{"emailAddress":"old"}}"#.utf8)
        let updated = try ClaudeLoginSnapshot.replacingAccount(in: original, account: Data(#"{"emailAddress":"new"}"#.utf8))
        let before = try JSONSerialization.jsonObject(with: original) as! [String: NSObject]
        let after = try JSONSerialization.jsonObject(with: updated) as! [String: NSObject]
        for key in ["projects", "hasCompletedOnboarding", "custom"] { XCTAssertEqual(before[key], after[key]) }
        XCTAssertNotEqual(before["oauthAccount"], after["oauthAccount"])
        XCTAssertThrowsError(try ClaudeLoginSnapshot.replacingAccount(in: Data("[]".utf8), account: Data("{}".utf8)))
    }

    func testTargetValidationRejectsExpiredOrWrongWorkspace() throws {
        let credentials = Data(#"{"claudeAiOauth":{"accessToken":"test-only","refreshToken":"test-only","expiresAt":2000000}}"#.utf8)
        let snapshot = ClaudeLoginSnapshot(credentials: credentials, account: Data(#"{"emailAddress":"a@example.com","organizationUuid":"org-a"}"#.utf8))
        let expected = ClaudeAccountIdentity(email: "a@example.com", orgId: "org-a", subscriptionType: nil)
        XCTAssertNoThrow(try snapshot.validateTarget(expected, now: Date(timeIntervalSince1970: 1000)))
        XCTAssertThrowsError(try snapshot.validateTarget(expected, now: Date(timeIntervalSince1970: 3000)))
        XCTAssertThrowsError(try snapshot.validateTarget(.init(email: "a@example.com", orgId: "org-b", subscriptionType: nil), now: Date(timeIntervalSince1970: 1000)))
    }

    func testProcessGuardRecognizesNativeAndSupervisor() {
        XCTAssertTrue(ClaudeAccountBackend.containsClaudeProcess("/some path/bin/claude.exe\n/bin/zsh"))
        XCTAssertTrue(ClaudeAccountBackend.containsClaudeProcess("claude\n"))
        XCTAssertTrue(ClaudeAccountBackend.containsClaudeProcess("/bin/claude-supervisor"))
        XCTAssertFalse(ClaudeAccountBackend.containsClaudeProcess("/bin/zsh\n/Applications/IslandBarDemo.app/Contents/MacOS/IslandBarDemo"))
    }

    func testProcessRunnerAndCancellation() async throws {
        let data = try await ClaudeAccountBackend.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["hello"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
        let task = Task { try await ClaudeAccountBackend.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should fail") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
