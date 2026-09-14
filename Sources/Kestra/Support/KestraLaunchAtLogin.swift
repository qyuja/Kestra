import Combine
import Foundation
import ServiceManagement

@MainActor
final class KestraLaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    var isAvailable: Bool {
        service.status != .notFound
    }

    func refresh() {
        isEnabled = service.status == .enabled
        statusMessage = message(for: service.status)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = "开机自启动设置失败：\(error.localizedDescription)"
        }
    }

    private func message(for status: SMAppService.Status) -> String? {
        switch status {
        case .requiresApproval:
            return "请在系统设置的登录项中允许 Kestra"
        case .notFound:
            return "当前构建不是可注册的 App bundle"
        default:
            return nil
        }
    }
}
