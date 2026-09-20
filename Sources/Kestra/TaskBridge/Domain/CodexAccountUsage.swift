import Foundation

struct CodexAccountUsage: Sendable {
    struct Window: Sendable {
        let remainingPercent: Int
        let minutes: Int?
        let resetsAt: Date?

        var title: String {
            guard let minutes else { return "额度" }
            if minutes.isMultiple(of: 1440) { return "\(minutes / 1440)d" }
            if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }

        /// The API returns Unix time; render it in the user's local timezone.
        var resetTimeText: String? {
            guard let resetsAt else { return nil }
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: resetsAt
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let hour = components.hour,
                  let minute = components.minute else { return nil }
            return String(format: "%02d-%02d %02d:%02d", month, day, hour, minute)
        }

        var resetLabel: String? {
            resetTimeText.map { "reset at : \($0)" }
        }

        /// The hover panel uses the same compact time format as the account panel.
        var hoverResetTimeText: String? {
            resetTimeText
        }
    }

    let accountID: String?
    let primary: Window?
    let secondary: Window?

    var displayWindows: [Window] {
        [primary, secondary].compactMap { $0 }
            .sorted { ($0.minutes ?? Int.max) < ($1.minutes ?? Int.max) }
    }

    static func parse(_ response: [String: Any]) -> Self {
        // Metering buckets are not personal/team workspaces.
        let buckets = response["rateLimitsByLimitId"] as? [String: [String: Any]]
        let snapshot = buckets?["codex"] ?? (buckets == nil || buckets?.isEmpty == true
            ? response["rateLimits"] as? [String: Any] : nil)
        func window(_ key: String) -> Window? {
            guard let raw = snapshot?[key] as? [String: Any], let used = raw["usedPercent"] as? Int else { return nil }
            return Window(
                remainingPercent: max(0, min(100, 100 - used)),
                minutes: raw["windowDurationMins"] as? Int,
                resetsAt: (raw["resetsAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
            )
        }
        return Self(accountID: response["accountId"] as? String, primary: window("primary"), secondary: window("secondary"))
    }
}
