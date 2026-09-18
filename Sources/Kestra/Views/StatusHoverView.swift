import SwiftUI

struct StatusHoverView: View {
    @ObservedObject var store: CodexTaskStore
    @ObservedObject var providers: AIProviderSelectionStore
    @ObservedObject var theme: KestraThemeStore
    let width: CGFloat
    let height: CGFloat
    let onHover: (Bool) -> Void
    let onOpenTask: (CodexTask) -> Void

    private var runningTasks: [CodexTask] {
        store.tasks.filter { $0.isRunning && providers.selectedProviders.contains($0.provider) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Bundle.main.bundleIdentifier == "com.kiannest.kestra.dev" ? "剩余额度 · Dev" : "剩余额度").font(.headline)
                Spacer()
                Text("\(runningTasks.count) 个任务运行中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            quotaContent
            Divider()
            if runningTasks.isEmpty {
                Text("当前没有运行中的任务")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(runningTasks) { task in
                            Button { onOpenTask(task) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        AIProviderIcon(provider: task.provider, size: 14)
                                        Text(task.threadName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Text(task.modelText)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Label(task.timeText(at: context.date), systemImage: "clock")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                                .padding(12)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("打开 \(task.threadName)")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: width, height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .preferredColorScheme(theme.mode == .dark ? .dark : .light)
        .onHover(perform: onHover)
    }

    @ViewBuilder
    private var quotaContent: some View {
        if providers.selectedProviders.contains(.codex) {
            if let accountID = store.currentAccountID,
               let usage = store.accountQuotas[accountID]?.usage,
               !usage.displayWindows.isEmpty {
                HStack(spacing: 16) {
                    AIProviderIcon(provider: .codex, size: 18)
                    ForEach(Array(usage.displayWindows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(window.title)
                                Spacer()
                                Text("\(window.remainingPercent)%").monospacedDigit()
                            }
                            .font(.caption)
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                                .tint(Color(nsColor: QuotaProgressColor.forRemainingPercent(window.remainingPercent).nsColor))
                        }
                    }
                }
                .accessibilityLabel("ChatGPT 剩余额度")
            } else {
                Text("ChatGPT 额度暂未获取").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("当前客户端暂无额度数据").font(.caption).foregroundStyle(.secondary)
        }
    }
}
