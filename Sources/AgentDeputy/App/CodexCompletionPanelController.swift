import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexCompletionPanelController: NSObject {
    private struct Notice {
        let task: CodexTask
        let attention: CodexAttentionEvent?
    }

    private let onOpenTask: (CodexTask) -> Void
    private let onPermissionDecision: (CodexAttentionEvent, CodexPermissionDecision) -> Bool
    private let animationRegistry: CompletionAnimationRegistry
    private let animationSettings: CompletionAnimationSettingsStore
    private let themeStore: AgentDeputyThemeStore
    private var panelSize: NSSize {
        currentAttention?.permission == nil
            ? NSSize(width: 368, height: 86)
            : NSSize(width: 432, height: 248)
    }

    private var panel: NSPanel?
    private var pendingTasks: [Notice] = []
    private var currentTask: CodexTask?
    private var currentAttention: CodexAttentionEvent?
    private var dismissTask: Task<Void, Never>?
    private var permissionExpiryTask: Task<Void, Never>?
    private var isHovering = false
    private var isDismissing = false
    private var activeTransition: CompletionAnimationTransition?
    private var previewIdentifier: String?
    private var generation = UUID()
    private var previewRequest: CompletionPreviewRequest?
    private var activeExitEffect = CompletionExitEffect.fade
    private var activeExitDirection = AnimateCSSAnimationPreset.fadeIn
    private var fragmentPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    func preview(request: CompletionPreviewRequest) {
        cancelPreview()
        previewRequest = request
        if case .entrance(let identifier) = request { previewIdentifier = identifier }
        else { previewIdentifier = animationSettings.selectedAnimationIdentifier }
        enqueue(CodexTask(id: "preview", title: "任务完成提醒预览", summary: "这是当前显示位置和动画效果", updatedAt: Date(), path: nil, isRunning: false))
        panel?.ignoresMouseEvents = true
    }

    func cancelPreview() {
        generation = UUID()
        dismissTask?.cancel()
        permissionExpiryTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        currentTask = nil
        currentAttention = nil
        pendingTasks.removeAll()
        isDismissing = false
        isHovering = false
        previewIdentifier = nil
        previewRequest = nil
        fragmentPanel?.orderOut(nil)
        fragmentPanel = nil
    }

    init(
        onOpenTask: @escaping (CodexTask) -> Void,
        onPermissionDecision: @escaping (CodexAttentionEvent, CodexPermissionDecision) -> Bool,
        animationRegistry: CompletionAnimationRegistry,
        animationSettings: CompletionAnimationSettingsStore,
        themeStore: AgentDeputyThemeStore
    ) {
        self.onOpenTask = onOpenTask
        self.onPermissionDecision = onPermissionDecision
        self.animationRegistry = animationRegistry
        self.animationSettings = animationSettings
        self.themeStore = themeStore
        super.init()

        themeStore.$mode.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePanelAppearance()
            }
        }.store(in: &cancellables)
    }

    func enqueue(_ task: CodexTask) {
        pendingTasks.append(Notice(task: task, attention: nil))
        showNextIfNeeded()
    }

    func enqueueAttention(_ task: CodexTask, event: CodexAttentionEvent) {
        let notice = Notice(task: task, attention: event)
        if event.permission != nil {
            pendingTasks.insert(notice, at: 0)
            if currentAttention?.permission == nil, currentTask != nil {
                dismissCurrent(animated: false)
            }
        } else {
            pendingTasks.append(notice)
        }
        showNextIfNeeded()
    }

    private var selectedAnimation: any CompletionAnimationPlugin {
        animationRegistry.plugin(for: previewIdentifier ?? animationSettings.selectedAnimationIdentifier)
            ?? AnimateCSSAnimationPlugin()
    }

    private func showNextIfNeeded() {
        pendingTasks.removeAll { $0.attention?.permission.map { $0.expiresAt <= .now } ?? false }
        guard currentTask == nil, !isDismissing, let notice = pendingTasks.first else {
            return
        }

        pendingTasks.removeFirst()

        if notice.attention == nil && shouldSuppressCompletion(for: notice.task) {
            showNextIfNeeded()
            return
        }

        currentTask = notice.task
        currentAttention = notice.attention
        let panel = makePanelIfNeeded()
        let configuration = animationSettings.configuration
        let animation = selectedAnimation
        let transition = transition(for: animation.transition)
        activeTransition = transition
        activeExitEffect = animationSettings.exitEffect
        activeExitDirection = animationSettings.exitDirection
        if case .exit(let effect) = previewRequest { activeExitEffect = effect }
        if case .fadeExit(let direction) = previewRequest {
            activeExitEffect = .fade
            activeExitDirection = direction
        }
        let finalFrame = frameForPanel()
        let entryOffset = transition.entryOffset(for: panelSize)
        let initialFrame = finalFrame.offsetBy(
            dx: entryOffset.width,
            dy: entryOffset.height
        )

        panel.contentViewController = NSHostingController(
            rootView: CodexCompletionView(
                task: notice.task,
                attention: notice.attention,
                animationPlugin: animation,
                animationConfiguration: configuration,
                themeStore: themeStore,
                onHover: { [weak self] hovering in
                    self?.setHovering(hovering)
                },
                onOpen: { [weak self] in
                    self?.openCurrentTask()
                },
                onDecision: { [weak self] decision in
                    self?.resolvePermission(decision)
                }
            )
        )
        panel.setFrame(initialFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let request = notice.attention?.permission {
            // Approval is time-sensitive; an off-screen entrance must never
            // make the only actionable UI invisible while Codex is waiting.
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            schedulePermissionExpiry(for: request)
            return
        }

        if isExitPreview {
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            scheduleDismiss()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = transition.entryDuration * configuration.durationScale
            context.timingFunction = entryTimingFunction(for: transition)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        scheduleDismiss()
    }

    private func schedulePermissionExpiry(for request: CodexPermissionRequest) {
        permissionExpiryTask?.cancel()
        permissionExpiryTask = Task { @MainActor [weak self] in
            let remaining = max(0, request.expiresAt.addingTimeInterval(-1).timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, self?.currentAttention?.permission?.id == request.id else { return }
            self?.dismissCurrent(animated: false)
        }
    }

    private func shouldSuppressCompletion(for task: CodexTask) -> Bool {
        previewIdentifier == nil && animationSettings.suppressWhenProviderActive
            && ProviderActivityDetector.isFrontmost(task.provider)
    }

    private func transition(
        for baseTransition: CompletionAnimationTransition
    ) -> CompletionAnimationTransition {
        guard animationSettings.entryMode != .automatic else {
            return baseTransition
        }

        let entryVector = CompletionEntryVectorResolver.resolve(
            position: animationSettings.displayPosition,
            mode: animationSettings.entryMode
        )
        let exitVector = CompletionEntryVectorResolver.exitVector(
            position: animationSettings.displayPosition,
            mode: animationSettings.entryMode
        )
        return baseTransition.replacing(
            entryVector: entryVector,
            exitVector: exitVector
        )
    }

    private func entryTimingFunction(
        for transition: CompletionAnimationTransition
    ) -> CAMediaTimingFunction {
        transition.entryVector == .zero
            ? CAMediaTimingFunction(name: .easeInEaseOut)
            : CAMediaTimingFunction(name: .easeOut)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = themeAppearance
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false

        self.panel = panel
        return panel
    }

    private var themeAppearance: NSAppearance? {
        switch themeStore.mode {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func updatePanelAppearance() {
        panel?.appearance = themeAppearance
    }

    private func frameForPanel() -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.frame ?? .zero
        let margin: CGFloat = 12
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - panelSize.width - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - panelSize.height - margin

        let originX: CGFloat
        let originY: CGFloat
        switch animationSettings.displayPosition {
        case .topLeading, .centerLeading, .bottomLeading:
            originX = minX
        case .topCenter, .center, .bottomCenter:
            originX = visibleFrame.midX - panelSize.width / 2
        case .topTrailing, .centerTrailing, .bottomTrailing:
            originX = maxX
        }

        switch animationSettings.displayPosition {
        case .topLeading, .topCenter, .topTrailing:
            originY = maxY
        case .centerLeading, .center, .centerTrailing:
            originY = visibleFrame.midY - panelSize.height / 2
        case .bottomLeading, .bottomCenter, .bottomTrailing:
            originY = minY
        }

        return NSRect(
            x: min(max(originX, minX), maxX),
            y: min(max(originY, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private func setHovering(_ hovering: Bool) {
        isHovering = hovering
        guard currentAttention?.permission == nil else { return }
        if hovering {
            dismissTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    private var isExitPreview: Bool {
        switch previewRequest {
        case .exit, .fadeExit: return true
        default: return false
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard currentAttention?.permission == nil else { return }
        guard !isHovering, !isDismissing else { return }

        let dwellDuration: Double
        if isExitPreview { dwellDuration = 0.6 }
        else { dwellDuration = animationSettings.dwellDuration + (activeTransition?.entryDuration ?? 0) * animationSettings.configuration.durationScale }
        dismissTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(dwellDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
        }
    }

    private func openCurrentTask() {
        guard let task = currentTask else { return }
        if let attention = currentAttention, attention.permission != nil {
            _ = onPermissionDecision(attention, .openInCodex)
        }
        dismissCurrent(animated: false)
        onOpenTask(task)
    }

    private func resolvePermission(_ decision: CodexPermissionDecision) {
        guard let attention = currentAttention, attention.permission != nil else { return }
        guard onPermissionDecision(attention, decision) else {
            NSSound.beep()
            return
        }
        dismissCurrent(animated: false)
    }

    private func dismissCurrent(animated: Bool = true) {
        dismissTask?.cancel()
        dismissTask = nil
        permissionExpiryTask?.cancel()
        permissionExpiryTask = nil
        isHovering = false

        guard currentTask != nil, !isDismissing else { return }
        if case .entrance = previewRequest {
            panel?.orderOut(nil)
            finishDismissal()
            return
        }

        guard animated, let panel else {
            panel?.orderOut(nil)
            finishDismissal()
            return
        }

        isDismissing = true
        if activeExitEffect == .fragments, animateFragments(panel) { return }
        let configuration = animationSettings.configuration
        let transition = activeExitDirection.transition
        let exitOffset = transition.exitOffset(for: panelSize)
        let exitFrame = activeExitEffect == .shrink ? panel.frame.insetBy(dx: panel.frame.width * 0.45, dy: panel.frame.height * 0.45) : panel.frame.offsetBy(
            dx: exitOffset.width,
            dy: exitOffset.height
        )
        let dismissalGeneration = generation

        NSAnimationContext.runAnimationGroup { context in
            context.duration = transition.exitDuration * configuration.durationScale
            context.timingFunction = transition.exitVector == .zero
                ? CAMediaTimingFunction(name: .easeInEaseOut)
                : CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(exitFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                guard self?.generation == dismissalGeneration else { return }
                self?.finishDismissal()
            }
        }
    }

    private func animateFragments(_ source: NSPanel) -> Bool {
        guard let view = source.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }

        // Extra transparent space allows fragments to travel beyond the original card.
        let inset: CGFloat = 100
        let overlay = NSPanel(contentRect: source.frame.insetBy(dx: -inset, dy: -inset),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = source.level
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let container = NSView(frame: NSRect(origin: .zero, size: overlay.frame.size))
        container.wantsLayer = true
        overlay.contentView = container
        guard let root = container.layer else { return false }
        fragmentPanel = overlay
        let duration = 1.1 * animationSettings.configuration.durationScale
        // Roughly 3-point grains share one snapshot instead of allocating an image per grain.
        let columns = 123
        let rows = 29
        let width = source.frame.width / CGFloat(columns)
        let height = source.frame.height / CGFloat(rows)
        let token = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, overlay] in
            MainActor.assumeIsolated {
                overlay.orderOut(nil)
                guard self?.generation == token else { return }
                self?.fragmentPanel = nil
                self?.finishDismissal()
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let piece = CALayer()
                piece.frame = CGRect(x: inset + CGFloat(column) * width, y: inset + CGFloat(row) * height, width: width, height: height)
                piece.contents = image
                piece.contentsRect = CGRect(x: Double(column) / Double(columns), y: Double(rows - 1 - row) / Double(rows), width: 1.0 / Double(columns), height: 1.0 / Double(rows))
                root.addSublayer(piece)
                let driftX = CGFloat.random(in: -65...65)
                let driftY = CGFloat.random(in: -28...74)
                let movement = CAKeyframeAnimation(keyPath: "position")
                movement.values = [NSValue(point: piece.position),
                    NSValue(point: CGPoint(x: piece.position.x + driftX * 0.35, y: piece.position.y + driftY * 0.2)),
                    NSValue(point: CGPoint(x: piece.position.x + driftX, y: piece.position.y + driftY))]
                movement.keyTimes = [0, 0.35, 1]
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0
                rotation.toValue = Double.random(in: -Double.pi...Double.pi)
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.08
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 0.8, 0]
                fade.keyTimes = [0, 0.35, 1]
                let group = CAAnimationGroup()
                group.animations = [movement, rotation, shrink, fade]
                group.duration = duration * Double.random(in: 0.65...1)
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                piece.opacity = 0
                piece.add(group, forKey: "fragmentExit")
            }
        }
        overlay.orderFrontRegardless()
        source.orderOut(nil)
        CATransaction.commit()
        return true
    }

    private func finishDismissal() {
        isDismissing = false
        currentTask = nil
        currentAttention = nil
        activeTransition = nil

        guard !pendingTasks.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showNextIfNeeded()
        }
    }
}

private struct CodexCompletionView: View {
    let task: CodexTask
    let attention: CodexAttentionEvent?
    let animationPlugin: any CompletionAnimationPlugin
    let animationConfiguration: CompletionAnimationConfiguration
    @ObservedObject var themeStore: AgentDeputyThemeStore
    let onHover: (Bool) -> Void
    let onOpen: () -> Void
    let onDecision: (CodexPermissionDecision) -> Void

    var body: some View {
        Group {
            if let request = attention?.permission {
                permissionCard(request)
            } else {
                animationPlugin.makeView(
                    content: AnyView(
                        Button(action: onOpen) {
                            cardContent
                        }
                        .buttonStyle(.plain)
                    ),
                    configuration: animationConfiguration
                )
            }
        }
        .onHover(perform: onHover)
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch themeStore.mode {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AgentDeputyPalette.accent.opacity(0.18))
                    .frame(width: 38, height: 38)

                Image(systemName: attention?.kind.symbolName ?? "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AgentDeputyPalette.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(attention.map { "\(task.provider.name) \($0.kind.title)" } ?? "\(task.provider.name) 已完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.64))

                    Circle()
                        .fill(.primary.opacity(0.25))
                        .frame(width: 3, height: 3)

                    Text(task.shortIdentifier)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.34))
                }

                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(attention == nil ? task.summary : "点击打开 Codex 回答")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.44))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.48))
        }
        .padding(.horizontal, 14)
        .frame(width: 368, height: 86)
    }

    private func permissionCard(_ request: CodexPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AgentDeputyPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(AgentDeputyPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(task.provider.name) 需要授权")
                        .font(.system(size: 13, weight: .semibold))
                    Text(task.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(request.toolName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(2)
            }

            ScrollView {
                Text(request.input)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(request.canApprove ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: request.reason == nil ? 105 : 79)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("未操作则由 Codex 接管")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button("拒绝") { onDecision(.deny) }
                    .foregroundStyle(.red)
                Button("打开 Codex", action: onOpen)
                Button("同意一次") { onDecision(.allow) }
                    .disabled(!request.canApprove)
                    .accessibilityHint("只批准当前这一次请求")
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 432, height: 248, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: animationConfiguration.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: animationConfiguration.cardCornerRadius, style: .continuous))
    }
}
