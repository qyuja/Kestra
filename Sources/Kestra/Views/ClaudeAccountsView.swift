import SwiftUI

struct ClaudeAccountsView: View {
    @ObservedObject var accounts: ClaudeAccountStore
    let hasRunningTasks: Bool
    var management = true
    var onInteraction: (Bool) -> Void = { _ in }
    @State private var editing: ClaudeAccountProfile?
    @State private var deleting: ClaudeAccountProfile?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if accounts.busy { ProgressView().controlSize(.mini) }
                Button("刷新") { accounts.refresh() }
                Button { accounts.login() } label: { Image(systemName: "plus") }
                    .help("添加 Claude 账号")
                    .disabled(hasRunningTasks || accounts.needsRecovery)
            }
            .buttonStyle(.plain)
            .disabled(accounts.busy)
            if accounts.loggingIn { Button("取消登录") { accounts.cancelLogin() }.buttonStyle(.plain) }
            ForEach(accounts.profiles) { profile in
                HStack {
                    Button {
                        accounts.switchAccount(profile, hasRunningTasks: hasRunningTasks)
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.fill").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).lineLimit(1)
                                Text(profile.identity.subscriptionType ?? "Claude 订阅").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if accounts.currentID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(accounts.busy || hasRunningTasks || accounts.needsRecovery || accounts.currentID == profile.id)
                    if management {
                        Menu {
                            Button("修改备注") { editing = profile; name = profile.name }
                            Button("重新登录") { accounts.login(replacing: profile) }.disabled(hasRunningTasks)
                            Button("删除登记", role: .destructive) { deleting = profile }.disabled(accounts.currentID == profile.id)
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(accounts.busy || accounts.needsRecovery)
                    }
                }.padding(8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if accounts.needsRecovery { Button("恢复原账号") { accounts.recover() }.disabled(accounts.busy || hasRunningTasks) }
            if let message = accounts.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if hasRunningTasks { Text("Claude 有运行中任务，不能切换").font(.caption).foregroundStyle(.orange) }
        }
        .font(.system(size: 11))
        .onAppear { accounts.loadIfNeeded() }
        .onChange(of: editing != nil || deleting != nil) { _, shown in onInteraction(shown) }
        .alert("修改备注", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("备注", text: $name)
            Button("保存") { if let editing { accounts.rename(editing, name: name) }; editing = nil }
            Button("取消", role: .cancel) { editing = nil }
        }
        .alert("删除账号登记？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { accounts.remove(deleting) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("保留钥匙串缓存、项目和会话历史。") }
    }
}
