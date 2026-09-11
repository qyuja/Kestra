import Foundation
import SwiftUI

enum StatusPopoverStyle {
    static let selectionColor = Color(red: 0.35, green: 0.86, blue: 0.38)
    static let surface = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let tile = Color(red: 0.06, green: 0.065, blue: 0.07)
    static let selectedTile = Color(red: 0.02, green: 0.20, blue: 0.09)
    static let divider = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.56)
}

struct StatusPopoverView: View {
    private enum Section {
        case tasks
        case settings
    }

    @ObservedObject var store: CodexTaskStore
    @ObservedObject var squatRunner: SquatRunner
    @ObservedObject var providerSelection: AIProviderSelectionStore
    @ObservedObject var previewSettings: CodexTaskPreviewSettingsStore
    @ObservedObject var updater: KestraUpdater
    let animationPlugins: CompletionAnimationRegistry
    @ObservedObject var animationSettings: CompletionAnimationSettingsStore
    let onPreviewAnimation: (CompletionPreviewRequest?) -> Void
    let onDirectionMenuPresented: (Bool) -> Void

    let onHover: (Bool) -> Void
    let onOpenTask: (CodexTask) -> Void
    let onOpenCodex: () -> Void
    let onOpenClaude: () -> Void
    let onQuit: () -> Void

    @State private var section: Section = .tasks
    // Consume the published value itself: @Published emits before store.tasks
    // is assigned. Tabs and cards must render the same current snapshot.
    @State private var displayedTasks: [CodexTask] = []
    @State private var activeProvider: AIProvider = .codex
    @State private var isRunningSectionExpanded = true
    @State private var isRecentSectionExpanded = true
    @State private var showsAdditionalProviders = false
    @State private var showsFadeDirections = false
    @State private var showsAccounts = false
    @State private var showsClaudeAccounts = false
    @State private var showsQuickClaudeAccounts = false
    @State private var showsQuickAccounts = false
    @State private var editingAccount: CodexAccountProfile?
    @State private var deletingAccount: CodexAccountProfile?
    @State private var accountRemark = ""
    @State private var hoveredExitDirection: AnimateCSSAnimationPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)

            if section == .tasks {
                taskSection
            } else {
                settingsSection
            }
        }
        .padding(16)
        .frame(width: 420, height: 560, alignment: .topLeading)
        .background(StatusPopoverStyle.surface)
        .onHover(perform: onHover)
        .onAppear(perform: syncActiveProvider)
        .onReceive(store.$tasks) { displayedTasks = $0 }
        .onDisappear { onPreviewAnimation(nil) }
        .onChange(of: section) { _, _ in onPreviewAnimation(nil) }
        .onChange(of: showsFadeDirections) { _, shown in onDirectionMenuPresented(shown) }
        .onChange(of: showsQuickAccounts) { _, shown in onDirectionMenuPresented(shown) }
        .onChange(of: showsQuickClaudeAccounts) { _, shown in onDirectionMenuPresented(shown) }
        .onChange(of: editingAccount != nil || deletingAccount != nil) { _, shown in onDirectionMenuPresented(shown) }
        .alert("修改备注", isPresented: Binding(get: { editingAccount != nil }, set: { if !$0 { editingAccount = nil } })) {
            TextField("备注", text: $accountRemark)
            Button("取消", role: .cancel) { editingAccount = nil }
            Button("保存") {
                if let profile = editingAccount { store.renameAccount(profile, name: accountRemark) }
                editingAccount = nil
            }
            .disabled(accountRemark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("删除账号登记？", isPresented: Binding(get: { deletingAccount != nil }, set: { if !$0 { deletingAccount = nil } })) {
            Button("取消", role: .cancel) { deletingAccount = nil }
            Button("删除", role: .destructive) {
                if let profile = deletingAccount { store.removeAccount(profile) }
                deletingAccount = nil
            }
        } message: { Text("仅从列表移除，不删除登录缓存、项目或对话历史。") }
        .onChange(of: store.switchingAccountID) { previous, current in
            guard previous != nil, current == nil else { return }
            if store.accountSwitchError == nil { showsQuickAccounts = false }
        }
        .alert("账号切换未完成", isPresented: Binding(
            get: { store.accountSwitchError != nil }, set: { if !$0 { store.dismissAccountSwitchError() } }
        )) {
            Button("好", role: .cancel) { store.dismissAccountSwitchError() }
        } message: { Text(store.accountSwitchError ?? "") }
        .onChange(of: providerSelection.selectedProviders) { _, _ in
            syncActiveProvider()
        }
        .onChange(of: previewSettings.mode) { _, _ in
            store.refreshNow()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 32, height: 32)

                AppBrandIcon(size: 14, weight: .bold)
                    .foregroundStyle(.green)
            }

            Text("Kestra")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StatusPopoverStyle.primaryText)

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    section = section == .tasks ? .settings : .tasks
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        section == .settings
                            ? StatusPopoverStyle.selectionColor
                            : .white.opacity(0.58)
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        section == .settings
                            ? StatusPopoverStyle.selectedTile
                            : .white.opacity(0.08),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help(section == .tasks ? "设置" : "返回任务")
            .accessibilityLabel(section == .tasks ? "设置" : "返回任务")

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("退出 Kestra")
            .disabled(store.switchingAccountID != nil)
            .accessibilityLabel("退出 Kestra")
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerTabs

            Divider()
                .overlay(.white.opacity(0.10))

            if activeProvider.isImplemented {
                codexTaskList
            } else {
                providerPlaceholder
            }

            taskFooter
        }
    }

    private var providerTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providerSelection.selectedProviders) { provider in
                    HStack(spacing: 3) {
                        Button {
                            activeProvider = provider
                        } label: {
                            HStack(spacing: 6) {
                                AIProviderIcon(provider: provider, size: 11)
                                Text(provider.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Text("\(displayedTasks.filter { $0.provider == provider && $0.isRunning }.count)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                            .foregroundStyle(
                                activeProvider == provider
                                    ? StatusPopoverStyle.selectionColor
                                    : .white.opacity(0.48)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                activeProvider == provider
                                    ? .clear
                                    : .white.opacity(0.05),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)

                        if activeProvider == provider && provider == .claude {
                            Button { showsQuickClaudeAccounts.toggle() } label: {
                                Image(systemName: "arrow.triangle.swap").font(.system(size: 10, weight: .semibold))
                                    .frame(width: 22, height: 22).background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("切换 Claude Code 账号")
                            .popover(isPresented: $showsQuickClaudeAccounts, arrowEdge: .bottom) {
                                ClaudeAccountsView(accounts: store.claudeAccounts, hasRunningTasks: store.runningTaskCount(for: .claude) > 0, management: false)
                                    .padding(10).frame(width: 320).preferredColorScheme(.dark)
                            }
                            Button(action: onOpenClaude) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(ApplicationLauncher.isClaudeDesktopInstalled ? 0.42 : 0.18))
                                    .frame(width: 22, height: 22)
                                    .background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!ApplicationLauncher.isClaudeDesktopInstalled)
                            .help(ApplicationLauncher.isClaudeDesktopInstalled ? "打开 Claude Desktop" : "未安装 Claude Desktop")
                            .accessibilityLabel("打开 Claude Desktop")
                        }
                        if activeProvider == provider && provider == .codex {
                            quickAccountButton
                            Button(action: onOpenCodex) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.42))
                                    .frame(width: 22, height: 22)
                                    .background(.white.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("打开 \(provider.name)")
                            .accessibilityLabel("打开 \(provider.name)")
                        }
                    }
                }
            }
        }
        .frame(height: 31)
    }

    private var codexTaskList: some View {
        let providerTasks = displayedTasks.filter { $0.provider == activeProvider }
        let runningTasks = providerTasks.filter(\.isRunning)
        let recentTasks = providerTasks.filter { !$0.isRunning }
            .sorted { ($0.endedAt ?? $0.updatedAt) > ($1.endedAt ?? $1.updatedAt) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !runningTasks.isEmpty {
                    taskGroupTitle(
                        "正在运行",
                        count: runningTasks.count,
                        tint: .green,
                        isExpanded: $isRunningSectionExpanded
                    )
                    if isRunningSectionExpanded {
                        ForEach(runningTasks.prefix(8)) { task in
                            TaskRow(task: task, onOpen: onOpenTask)
                        }
                    }
                }

                if !recentTasks.isEmpty {
                    taskGroupTitle(
                        "最近任务",
                        count: recentTasks.count,
                        tint: .white.opacity(0.42),
                        isExpanded: $isRecentSectionExpanded
                    )
                        .padding(.top, runningTasks.isEmpty ? 0 : 4)
                    if isRecentSectionExpanded {
                        ForEach(recentTasks.prefix(6)) { task in
                            TaskRow(task: task, onOpen: onOpenTask)
                        }
                    }
                }

                if runningTasks.isEmpty && recentTasks.isEmpty {
                    emptyTaskState
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func taskGroupTitle(
        _ title: String,
        count: Int,
        tint: Color,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: Capsule())

                Spacer(minLength: 8)

                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 个任务")
        .accessibilityHint(isExpanded.wrappedValue ? "点击收起" : "点击展开")
    }

    private var emptyTaskState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.green.opacity(0.8))
            Text(activeProvider == .claude ? store.claudeStatus : store.cliStatuses[activeProvider] ?? "当前没任务")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
            if activeProvider == .claude && !ClaudeHookMonitor.isConfigured && ClaudeHookMonitor.executable != nil {
                Button("连接 Claude Code", action: store.connectClaude)
                    .buttonStyle(.bordered)
            }
            if activeProvider == .claude {
                Text("Cowork 尚未接入").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if AIProvider.hookProviders.contains(activeProvider),
               CLIHookIntegration(provider: activeProvider).installed,
               !CLIHookIntegration(provider: activeProvider).configured {
                Button("连接 \(activeProvider.name)") { store.connectCLI(activeProvider) }
                    .buttonStyle(.bordered)
                    .help(activeProvider == .pi ? "安装扩展后，在 Pi 中执行 /reload 或重启 Pi；需要支持 agent_settled 的版本" : activeProvider.integrationStatus)
            }
            if activeProvider == .pi, CLIHookIntegration(provider: .pi).configured {
                Text("连接后在 Pi 执行 /reload 或重启 Pi")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if activeProvider == .workbuddy {
                Text("实验性接入 · 连接后需重启 WorkBuddy")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var providerPlaceholder: some View {
        VStack(spacing: 10) {
            AIProviderIcon(provider: activeProvider, size: 26, weight: .medium)
                .foregroundStyle(activeProvider.tint.opacity(0.75))
            Text("暂未接入 \(activeProvider.name)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
            Text(activeProvider.integrationStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var taskFooter: some View {
        HStack(spacing: 10) {
            Text("深蹲 \(squatRunner.total) 次")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                .help("累计播放的完整深蹲次数；中途停止不计数，重启后保留")
            Button(action: store.refreshNow) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Spacer()

            if let lastUpdated = store.lastUpdated {
                Text(lastUpdated, style: .time)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.52))
    }

    private var settingsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                providerVisibilitySection
                MenuBarIconSettingsView(squatRunner: squatRunner)

                taskPreviewRow
                displayPositionSection
                completionAnimationSection
                timingSection
                updateSection

                if let lastError = store.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var quickAccountButton: some View {
        Button {
            showsQuickAccounts.toggle()
        } label: {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("切换账号")
        .popover(isPresented: $showsQuickAccounts, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button {
                        showsQuickAccounts = false
                        section = .settings
                        showsAccounts = true
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("添加账号")
                    .accessibilityLabel("添加账号")
                }
                accountRows
            }
            .padding(8)
            .frame(width: 320)
            .preferredColorScheme(.dark)
        }
    }

    private var currentAccount: CodexAccountProfile? {
        store.accountProfiles.first { $0.id == store.currentAccountID }
    }

    private func accountAvatar(_ profile: CodexAccountProfile?) -> some View {
        Text(profile.map { String($0.displayName.prefix(1)).uppercased() } ?? "+")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(profile == nil ? Color.gray.opacity(0.3) : Color.purple.opacity(0.55), in: Circle())
            .overlay(Circle().strokeBorder(profile?.id == store.currentAccountID && profile != nil ? StatusPopoverStyle.selectionColor : .clear, lineWidth: 1))
            .accessibilityLabel(profile?.displayName ?? "添加账号")
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已登记账号").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(action: store.addAccount) {
                    Text(store.isAddingAccount ? "等待登录…" : "添加账号")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StatusPopoverStyle.selectionColor)
                .disabled(store.isAddingAccount || store.switchingAccountID != nil)
                if store.isAddingAccount {
                    Button("取消", action: store.cancelAccountLogin)
                        .buttonStyle(.plain).font(.system(size: 11))
                }
            }
            accountRows
            if let message = store.accountMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(StatusPopoverStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountRows: some View {
        VStack(spacing: 4) {
            ForEach(store.accountProfiles) { profile in
                HStack(spacing: 4) {
                    accountRow(profile)
                    if section == .settings && !showsQuickAccounts {
                        Menu {
                            Button("修改备注") {
                                accountRemark = profile.displayName
                                editingAccount = profile
                            }
                            Button("重新登录") { store.reloginAccount(profile) }
                                .disabled(profile.id == store.currentAccountID)
                            Button("删除账号", role: .destructive) { deletingAccount = profile }
                                .disabled(profile.id == store.currentAccountID)
                        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 28) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(store.isAddingAccount || store.switchingAccountID != nil || store.isRegisteringAccount)
                        .help("账号管理；当前账号请在 Codex 中重新登录，切换后可删除")
                    }
                }
            }
        }
    }

    private func accountRow(_ profile: CodexAccountProfile) -> some View {
        let isCurrent = profile.id == store.currentAccountID
        let quota = store.accountQuotas[profile.id]
        let usage = quota?.usage
        let blocked = !isCurrent && store.accountSwitchBlockedReason != nil
        return Button {
            store.switchAccount(profile)
        } label: {
        HStack(spacing: 8) {
            accountAvatar(profile)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(profile.isTeam ? "Team" : (profile.planType?.capitalized ?? "个人"))
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusPopoverStyle.selectionColor)
                    } else {
                        Text("已登记")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if store.switchingAccountID == profile.id {
                ProgressView().controlSize(.small)
            }
            if let usage {
                ForEach(Array(usage.displayWindows.enumerated()), id: \.offset) { _, window in
                    quotaRing(window, fallback: "额度", error: nil)
                }
            } else {
                quotaRing(nil, fallback: "额度", error: quota?.error)
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 8))
        .opacity(blocked ? 0.5 : 1)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || blocked || store.isAddingAccount || store.switchingAccountID != nil || store.isRegisteringAccount)
        .help(isCurrent ? "当前使用中" : store.accountSwitchBlockedReason ?? "切换账号")
    }

    private func quotaRing(_ window: CodexAccountUsage.Window?, fallback: String, error: String?) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.10), lineWidth: 3)
                if let window {
                    Circle().trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                        .stroke(window.remainingPercent <= 10 ? Color.orange : StatusPopoverStyle.selectionColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(window.map { String($0.remainingPercent) } ?? "—")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 29, height: 29)
        }
        .frame(width: 34)
        .help(error ?? window.map { "\($0.title) 剩余 \($0.remainingPercent)%" } ?? "额度未获取")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "\($0.title) 剩余百分之 \($0.remainingPercent)" } ?? "\(fallback)额度未获取")
    }

    private var providerVisibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsGroupTitle("客户端")

            VStack(spacing: 1) {
                ForEach(AIProvider.primaryProviders + (showsAdditionalProviders ? AIProvider.additionalProviders : [])) { provider in
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            AIProviderIcon(provider: provider, size: 16)
                                .saturation(providerSelection.isSelected(provider) ? 1 : 0)
                                .opacity(providerSelection.isSelected(provider) ? 1 : 0.35)
                            Text(provider.name).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(providerSelection.isSelected(provider) ? 0.88 : 0.30))
                            if !provider.isImplemented {
                                Text("未接入").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if provider == .codex {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) { showsAccounts.toggle() }
                                } label: {
                                    HStack(spacing: 4) {
                                        accountAvatar(currentAccount)
                                        Text(currentAccount?.displayName.components(separatedBy: "@").first ?? "账号")
                                            .lineLimit(1).frame(maxWidth: 75)
                                        Image(systemName: showsAccounts ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.system(size: 10))
                                    .padding(4)
                                    .background(StatusPopoverStyle.selectedTile, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                                    .disabled(!providerSelection.isSelected(provider))
                                    .opacity(providerSelection.isSelected(provider) ? 1 : 0.35)
                            }
                            if provider == .claude {
                                Button("账号") { showsClaudeAccounts.toggle() }
                                    .buttonStyle(.plain).font(.system(size: 10))
                                    .disabled(!providerSelection.isSelected(provider))
                            }
                            Toggle("显示 \(provider.name)", isOn: Binding(
                                get: { providerSelection.isSelected(provider) },
                                set: { value in
                                    if value != providerSelection.isSelected(provider) { providerSelection.toggle(provider) }
                                }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .tint(StatusPopoverStyle.selectionColor)
                            .disabled(providerSelection.isSelected(provider) && providerSelection.selectedProviders.count == 1)
                        }
                        .padding(10)
                        if provider == .codex && showsAccounts && providerSelection.isSelected(provider) {
                            Divider()
                            accountSection.padding(10)
                        }
                        if provider == .claude && showsClaudeAccounts && providerSelection.isSelected(provider) {
                            Divider()
                            ClaudeAccountsView(accounts: store.claudeAccounts, hasRunningTasks: store.runningTaskCount(for: .claude) > 0, onInteraction: onDirectionMenuPresented).padding(10)
                        }
                    }
                    .background(StatusPopoverStyle.tile)
                }
            }
            .background(StatusPopoverStyle.divider)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !AIProvider.additionalProviders.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showsAdditionalProviders.toggle() }
                } label: {
                    Label(showsAdditionalProviders ? "收起客户端" : "更多客户端（\(AIProvider.additionalProviders.count)）",
                          systemImage: showsAdditionalProviders ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var taskPreviewRow: some View {
        HStack(spacing: 10) {
            Text("任务预览")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.86))

            Spacer(minLength: 8)

            Picker(
                "任务预览",
                selection: Binding(
                    get: { previewSettings.mode },
                    set: { previewSettings.setMode($0) }
                )
            ) {
                ForEach(CodexTaskPreviewMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .tint(StatusPopoverStyle.primaryText)
            .frame(width: 142, height: 28)
            .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 10))
    }

    private var displayPositionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsGroupTitle("显示位置")
            ScreenPositionPicker(position: animationSettings.displayPosition, onSelect: { position in
                animationSettings.setDisplayPosition(position)
            })
        }
    }

    private var completionAnimationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsGroupTitle("完成动画")

            HStack(spacing: 8) {
                Text(selectedAnimationDisplayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.86))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    onPreviewAnimation(.full)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StatusPopoverStyle.selectionColor)
                        .frame(width: 24, height: 24)
                        .background(StatusPopoverStyle.selectedTile, in: Circle())
                }
                .buttonStyle(.plain)
                .help("预览当前动画")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("In").font(.system(size: 11, weight: .semibold))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6),
                    count: 3
                ),
                spacing: 6
            ) {
                ForEach(animationPlugins.plugins.filter { plugin in
                    plugin.identifier == "fadeIn" || animationSettings.displayPosition.allowedAnimations.contains { $0.rawValue == plugin.identifier }
                }, id: \.identifier) { plugin in
                    AnimationSelectionRow(
                        title: animationPresetName(for: plugin),
                        isSelected: animationSettings.selectedAnimationIdentifier == plugin.identifier,
                        onSelect: {
                            animationSettings.selectAnimation(identifier: plugin.identifier)
                        },
                        onHover: { _ in }
                    )
                }
            }

            Text("Out").font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(CompletionExitEffect.allCases) { effect in
                    AnimationSelectionRow(title: effect.title,
                        isSelected: animationSettings.exitEffect == effect,
                        onSelect: { animationSettings.setExitEffect(effect) },
                        onHover: { hovering in
                            guard hovering else { return }
                            if effect == .fade { showsFadeDirections = true }
                        })
                    .popover(isPresented: Binding(
                        get: { effect == .fade && showsFadeDirections },
                        set: { if !$0 { showsFadeDirections = false } }
                    ), arrowEdge: .trailing) {
                        fadeDirectionOptions
                    }
                }
            }

        }
    }

    private var fadeDirectionOptions: some View {
        VStack(spacing: 2) {
            ForEach(AnimateCSSAnimationPreset.allCases) { direction in
                Button {
                    animationSettings.setExitEffect(.fade)
                    animationSettings.setExitDirection(direction)
                    showsFadeDirections = false
                } label: {
                    HStack {
                        Text(direction == .fadeIn ? "无方向" : direction.directionName)
                        Spacer()
                        Image(systemName: "checkmark")
                            .opacity(animationSettings.exitDirection == direction ? 1 : 0)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .frame(width: 144, height: 28)
                    .background(hoveredExitDirection == direction ? StatusPopoverStyle.selectedTile : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(hoveredExitDirection == direction ? StatusPopoverStyle.selectionColor : .white.opacity(0.8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hoveredExitDirection = direction
                    } else if hoveredExitDirection == direction {
                        hoveredExitDirection = nil
                    }
                }
            }
        }
        .padding(6)
        .preferredColorScheme(.dark)
        .onDisappear { hoveredExitDirection = nil }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsGroupTitle("时间")

            NumericSliderRow(
                title: "动画速度",
                value: Binding(
                    get: { animationSettings.speed },
                    set: { animationSettings.setSpeed($0) }
                ),
                range: 0.5...2,
                step: 0.05,
                fractionDigits: 2,
                suffix: "x"
            )

            NumericSliderRow(
                title: "停留时长",
                value: Binding(
                    get: { animationSettings.dwellDuration },
                    set: { animationSettings.setDwellDuration($0) }
                ),
                range: 1...30,
                step: 0.5,
                fractionDigits: 1,
                suffix: "s"
            )

            HStack(spacing: 10) {
                Text("当前 AI 应用在前台时不提醒")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.68))

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { animationSettings.suppressWhenProviderActive },
                        set: { animationSettings.setSuppressWhenProviderActive($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .frame(height: 30)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsGroupTitle("更新")

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StatusPopoverStyle.selectionColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("自动更新")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StatusPopoverStyle.primaryText)
                    Text(updater.isConfigured ? "后台自动检查，安装前会确认" : "当前构建未配置更新源")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StatusPopoverStyle.secondaryText)
                }

                Spacer(minLength: 8)

                Button("检查更新") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
            }
            .padding(10)
            .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(StatusPopoverStyle.divider)
            .frame(height: 1)
    }

    private var selectedAnimationDisplayName: String {
        let direction = AnimateCSSAnimationPreset(rawValue: animationSettings.selectedAnimationIdentifier)?.directionName ?? "Top"
        return "In: \(direction) → Out: \(animationSettings.exitEffect.title)"
    }

    private func animationPresetName(for plugin: any CompletionAnimationPlugin) -> String {
        AnimateCSSAnimationPreset(rawValue: plugin.identifier).map { $0 == .fadeIn ? "fadeIn" : "In \($0.directionName)" } ?? plugin.identifier
    }

    private func settingsGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(StatusPopoverStyle.secondaryText)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func syncActiveProvider() {
        guard let firstProvider = providerSelection.selectedProviders.first else {
            activeProvider = .codex
            return
        }

        if !providerSelection.selectedProviders.contains(activeProvider) {
            activeProvider = firstProvider
        }
    }
}

private struct ProviderSelectionRow: View {
    let provider: AIProvider
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                AIProviderIcon(provider: provider, size: 12)
                    .foregroundStyle(provider.tint.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(
                        provider.tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            StatusPopoverStyle.primaryText.opacity(isSelected ? 1 : 0.62)
                        )
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? StatusPopoverStyle.selectionColor
                            : StatusPopoverStyle.primaryText.opacity(0.23)
                    )
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(StatusPopoverStyle.tile)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AnimationSelectionRow: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        isSelected
                            ? StatusPopoverStyle.selectionColor
                            : StatusPopoverStyle.selectionColor.opacity(0.35)
                    )
                    .frame(width: 5, height: 5)

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? StatusPopoverStyle.primaryText
                            : StatusPopoverStyle.primaryText.opacity(0.58)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                isSelected
                    ? StatusPopoverStyle.selectedTile
                    : StatusPopoverStyle.tile,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }
}

private struct RunningTaskIndicator: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 7, height: 7)
            .foregroundStyle(.green)
            .symbolEffect(.breathe.pulse.wholeSymbol, options: .repeat(.continuous).speed(2))
            .accessibilityLabel("运行中")
    }
}

private struct NumericSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let suffix: String

    @FocusState private var isEditingValue: Bool
    @State private var draftValue: String

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int,
        suffix: String
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.fractionDigits = fractionDigits
        self.suffix = suffix
        self._draftValue = State(
            initialValue: Self.formatted(value.wrappedValue, fractionDigits: fractionDigits)
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.68))
                .frame(width: 60, alignment: .leading)

            Slider(value: Binding(
                get: { value },
                set: { value = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
            ), in: range)
                .tint(StatusPopoverStyle.selectionColor)

            HStack(spacing: 2) {
                TextField("", text: $draftValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 38)
                    .focused($isEditingValue)
                    .onSubmit(commitDraft)
                    .onChange(of: isEditingValue) { _, isEditing in
                        if !isEditing {
                            commitDraft()
                        }
                    }

                Text(suffix)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(StatusPopoverStyle.primaryText.opacity(0.82))
            .frame(width: 55, height: 24)
            .padding(.horizontal, 6)
            .background(StatusPopoverStyle.tile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(height: 30)
        .onChange(of: value) { _, newValue in
            guard !isEditingValue else { return }
            draftValue = Self.formatted(newValue, fractionDigits: fractionDigits)
        }
    }

    private func commitDraft() {
        guard let parsedValue = Double(draftValue), parsedValue.isFinite else {
            draftValue = Self.formatted(value, fractionDigits: fractionDigits)
            return
        }

        value = min(max(parsedValue, range.lowerBound), range.upperBound)
        draftValue = Self.formatted(value, fractionDigits: fractionDigits)
    }

    private static func formatted(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.*f", fractionDigits, value)
    }
}

private struct TaskRow: View {
    let task: CodexTask
    let onOpen: (CodexTask) -> Void

    var body: some View {
        Button {
            onOpen(task)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if task.isRunning {
                        RunningTaskIndicator()
                    } else {
                        Circle()
                            .fill(.white.opacity(0.28))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 13, height: 13)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.threadName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        TimelineView(.periodic(from: .now, by: task.isRunning ? 1 : 60)) { context in
                            Text(task.timeText(at: context.date))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.34))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }

                    Text(task.latestMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        if task.provider == .claude, let mode = task.claudeMode {
                            Text(mode.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange.opacity(0.85))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                        }
                        Text(task.modelText)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
