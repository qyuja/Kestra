import SwiftUI

struct StatusHoverView: View {
  @ObservedObject var store: CodexTaskStore
  @ObservedObject var providers: AIProviderSelectionStore
  @ObservedObject var theme: KestraThemeStore
  let width: CGFloat
  let maxHeight: CGFloat
  let onHeightChange: (CGFloat) -> Void
  let onHover: (Bool) -> Void
  let onOpenTask: (CodexTask) -> Void
  @State private var contentHeight: CGFloat = 160

  private var runningTasks: [CodexTask] {
    store.tasks.filter { $0.isRunning && providers.selectedProviders.contains($0.provider) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(Bundle.main.bundleIdentifier == "com.kiannest.kestra.dev" ? "剩余额度 · Dev" : "剩余额度")
            .font(.headline)
          Spacer()
          Text("\(runningTasks.count) 个任务运行中")
            .font(.caption).foregroundStyle(.secondary)
        }
        quotaContent
        Divider()
        if runningTasks.isEmpty {
          Text("当前没有运行中的任务")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        } else {
          HoverTaskFlowLayout(spacing: 8) {
            ForEach(runningTasks) { task in
              Button {
                onOpenTask(task)
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack(spacing: 6) {
                    AIProviderIcon(provider: task.provider, size: 14)
                    Text(task.threadName)
                      .font(.system(size: 12, weight: .semibold))
                      .lineLimit(1)
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
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(width: 130, alignment: .topLeading)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help("打开 \(task.threadName)")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(12)
      .frame(width: width)
      .onGeometryChange(for: CGFloat.self) { geometry in
        ceil(geometry.size.height)
      } action: { height in
        contentHeight = height
        onHeightChange(min(height, maxHeight))
      }
    }
    .frame(width: width, height: min(contentHeight, maxHeight))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    .preferredColorScheme(theme.mode == .dark ? .dark : .light)
    .onHover(perform: onHover)
  }

  @ViewBuilder
  private var quotaContent: some View {
    if providers.selectedProviders.contains(.codex) {
      if let accountID = store.currentAccountID,
        let usage = store.accountQuotas[accountID]?.usage,
        !usage.displayWindows.isEmpty
      {
        HStack(spacing: 10) {
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
                .tint(
                  Color(
                    nsColor: QuotaProgressColor.forRemainingPercent(window.remainingPercent).nsColor
                  ))
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

// Preserve fixed card widths while wrapping rows without stretching the cards.
private struct HoverTaskFlowLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrangement(width: bounds.width, subviews: subviews)
    for (index, subview) in subviews.enumerated() {
      let frame = result.frames[index]
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: usedWidth, height: y + rowHeight), frames)
  }
}
