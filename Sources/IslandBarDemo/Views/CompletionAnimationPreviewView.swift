import SwiftUI

struct CompletionAnimationPreviewView: View {
    let plugin: any CompletionAnimationPlugin
    let configuration: CompletionAnimationConfiguration

    private let previewSize = CGSize(width: 368, height: 72)

    @State private var offset: CGSize = .zero
    @State private var opacity = 0.0

    var body: some View {
        previewCard
            .frame(width: previewSize.width, height: previewSize.height)
            .offset(offset)
            .opacity(opacity)
            .task(id: plugin.identifier) {
                await playPreview()
            }
            .clipped()
    }

    private var previewCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 32, height: 32)

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
            }

            Text("Codex 已完成")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Spacer(minLength: 6)

            Text(plugin.displayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(width: previewSize.width, height: previewSize.height)
        .background(
            RoundedRectangle(cornerRadius: configuration.cardCornerRadius, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: configuration.cardCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
    }

    @MainActor
    private func playPreview() async {
        let transition = plugin.transition
        let entryOffset = swiftUIOffset(for: transition.entryOffset(for: previewSize))
        let exitOffset = swiftUIOffset(for: transition.exitOffset(for: previewSize))
        let durationScale = configuration.durationScale

        offset = entryOffset
        opacity = 0
        await Task.yield()

        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: transition.entryDuration * durationScale)) {
            offset = .zero
            opacity = 1
        }

        let visibleDuration = max(0.35, configuration.dwellDuration * 0.18)
        let nanoseconds = UInt64(visibleDuration * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)

        guard !Task.isCancelled else { return }

        withAnimation(.easeIn(duration: transition.exitDuration * durationScale)) {
            offset = exitOffset
            opacity = 0
        }
    }

    private func swiftUIOffset(for appKitOffset: CGSize) -> CGSize {
        CGSize(width: appKitOffset.width, height: -appKitOffset.height)
    }
}
