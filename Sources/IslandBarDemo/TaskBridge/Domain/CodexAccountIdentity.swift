import Foundation

struct CodexAccountIdentity {
    let email: String
    let planType: String?
    var usage: CodexAccountUsage? = nil
    var usageError: String? = nil
    var workspaceID: String? = nil

    func matches(_ profile: CodexAccountProfile) -> Bool {
        guard email.lowercased() == profile.email?.lowercased() else { return false }
        if let workspaceID = profile.workspaceID { return workspaceID == (self.workspaceID ?? usage?.accountID) }
        return profile.planType == planType
    }

    static func parse(_ response: [String: Any]) throws -> Self {
        guard let account = response["account"] as? [String: Any] else {
            throw IdentityError.unavailable("当前 Codex 尚未登录，请先在 Codex 中登录")
        }
        guard account["type"] as? String == "chatgpt" else {
            throw IdentityError.unavailable("当前使用的不是 ChatGPT 账号登录")
        }
        guard let email = account["email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IdentityError.unavailable("Codex 未返回账号邮箱，暂时无法识别当前账号")
        }
        return Self(email: email, planType: account["planType"] as? String)
    }

    private enum IdentityError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): return message }
        }
    }
}
