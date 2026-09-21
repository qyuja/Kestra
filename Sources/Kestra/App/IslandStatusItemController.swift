import AppKit
import Combine
import QuartzCore
import SwiftUI

struct MenuBarAppearanceRedrawGate {
    private(set) var lastIsDark: Bool?

    mutating func shouldRedraw(for isDark: Bool) -> Bool {
        guard lastIsDark != isDark else { return false }
        lastIsDark = isDark
        return true
    }

    mutating func record(_ isDark: Bool) {
        lastIsDark = isDark
    }
}

@MainActor
final class IslandStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let store: CodexTaskStore
    private let providerSelection: AIProviderSelectionStore
    private let previewSettings: CodexTaskPreviewSettingsStore
    private let updater: KestraUpdater
    private let launchAtLogin: KestraLaunchAtLogin
    private let limitRefreshSettings: CodexLimitRefreshSettingsStore
    private let themeStore: KestraThemeStore
    private let menuBarIconLayoutSettings: MenuBarIconLayoutSettingsStore
    private let onOpenTask: (CodexTask) -> Void
    private let onOpenCodex: () -> Void
    private let onOpenClaude: () -> Void
    private let onQuit: () -> Void
    private let animationPlugins: CompletionAnimationRegistry
    private let animationSettings: CompletionAnimationSettingsStore
    private lazy var previewController = CodexCompletionPanelController(
        onOpenTask: { _ in },
        animationRegistry: animationPlugins,
        animationSettings: animationSettings,
        themeStore: themeStore
    )

    private var trackingArea: NSTrackingArea?
    private var popover: NSPopover?
    private var hoverPanel: NSPanel?
    private var isHoverPanelHovering = false
    private var isPopoverHovering = false
    private var closeWorkItem: DispatchWorkItem?
    private var hoverShowWorkItem: DispatchWorkItem?
    private var isDirectionMenuPresented = false
    private var holdsPopoverAfterMenu = false
    private var isButtonHovering = false
    private var storeObservation: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var menuBarAppearanceObservation: NSKeyValueObservation?
    private var menuBarAppearanceRedrawGate = MenuBarAppearanceRedrawGate()
    private let logoRotationDurationForSingleTask: CGFloat = 3
    private let logoRotationSpeedCap: CGFloat = 4
    private let logoRotationAnimationKey = "kestra.logoRotation"
    private let menuBarLogoLayer = CALayer()
    // NSStatusItem snapshots its replicant on every image assignment. Keep
    // frame-based runner plugins below display refresh rate; the status icon
    // uses Core Animation and does not redraw an NSImage every frame.
    private let animatedStatusImageRefreshInterval: TimeInterval = 1.0 / 4.0
    private var lastAnimatedStatusImageRefreshUptime: TimeInterval?
    private let squatRunner = SquatRunner()

    init(
        store: CodexTaskStore,
        providerSelection: AIProviderSelectionStore,
        previewSettings: CodexTaskPreviewSettingsStore,
        updater: KestraUpdater,
        launchAtLogin: KestraLaunchAtLogin,
        limitRefreshSettings: CodexLimitRefreshSettingsStore,
        themeStore: KestraThemeStore,
        menuBarIconLayoutSettings: MenuBarIconLayoutSettingsStore,
        onOpenTask: @escaping (CodexTask) -> Void,
        onOpenCodex: @escaping () -> Void,
        onOpenClaude: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        animationPlugins: CompletionAnimationRegistry,
        animationSettings: CompletionAnimationSettingsStore
    ) {
        self.store = store
        self.providerSelection = providerSelection
        self.previewSettings = previewSettings
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        self.limitRefreshSettings = limitRefreshSettings
        self.themeStore = themeStore
        self.menuBarIconLayoutSettings = menuBarIconLayoutSettings
        self.onOpenTask = onOpenTask
        self.onOpenCodex = onOpenCodex
        self.onOpenClaude = onOpenClaude
        self.onQuit = onQuit
        self.animationPlugins = animationPlugins
        self.animationSettings = animationSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        squatRunner.onFrame = { [weak self] in
            self?.refreshStatusItemImage(isAnimationFrame: true)
        }

        statusItem.autosaveName = KestraAppIdentity.bundleIdentifier + ".statusItem"
        statusItem.menu = nil
        configureButton()

        storeObservation = store.$tasks.sink { [weak self] _ in
            // @Published emits before the property is assigned. Render after
            // assignment because configureButton reads the store's properties.
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }

        providerSelection.$selectedProviders.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }.store(in: &cancellables)

        store.$accountQuotas.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }.store(in: &cancellables)

        store.$currentAccountID.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }.store(in: &cancellables)

        themeStore.$mode.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePopoverAppearance()
                self?.configureButton()
            }
        }.store(in: &cancellables)

        squatRunner.$selectedIconID.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }.store(in: &cancellables)
    }

    func show() {
        configureButton()
        statusItem.isVisible = true
    }

    func hide() {
        squatRunner.update(runningCount: 0)
        stopLogoRotation()
        closePopover()
        statusItem.isVisible = false
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        observeMenuBarAppearance(on: button)

        let runningCount = selectedRunningTaskCount
        squatRunner.update(runningCount: runningCount)

        menuBarAppearanceRedrawGate.record(menuBarUsesDarkAppearance)
        button.image = makeStatusImage()
        updateMenuBarLogoLayer(on: button)
        updateLogoRotation(
            isRunning: runningCount > 0
                && squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID
        )
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(statusItemClicked)
        button.toolTip = Bundle.main.bundleIdentifier == "com.kiannest.kestra.dev"
            ? "Kestra Dev · 开发版（设置独立）\n" + makeToolTip()
            : makeToolTip()
        button.setAccessibilityLabel(
            makeAccessibilityLabel()
        )
        button.setAccessibilityHelp("悬停或点击查看已选 AI 服务商的任务")
        statusItem.length = NSStatusItem.variableLength
        installTrackingArea(on: button)
    }

    private func observeMenuBarAppearance(on button: NSStatusBarButton) {
        guard menuBarAppearanceObservation == nil else { return }
        menuBarAppearanceObservation = button.observe(\NSStatusBarButton.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.menuBarAppearanceRedrawGate.shouldRedraw(
                    for: self.menuBarUsesDarkAppearance
                ) else { return }
                self.refreshStatusItemImage()
            }
        }
    }

    private func makeStatusImage() -> NSImage {
        guard squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID else {
            return makeRunnerImage()
        }

        return MenubarStatusIconRenderer.makeRingImage(
            usage: currentUsage,
            isDark: menuBarUsesDarkAppearance
        )
    }

    private var menuBarUsesDarkAppearance: Bool {
        guard let button = statusItem.button else { return false }
        return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func makeRunnerImage() -> NSImage {
        let imageSize = NSSize(width: 22, height: 21)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        if let runnerImage = squatRunner.image {
            let size = runnerImage.size
            let scale = min(
                imageSize.width / max(1, size.width),
                imageSize.height / max(1, size.height)
            )
            let width = size.width * scale
            let height = size.height * scale
            drawImage(
                runnerImage,
                in: NSRect(
                    x: (imageSize.width - width) / 2,
                    y: (imageSize.height - height) / 2,
                    width: width,
                    height: height
                )
            )
        } else {
            drawSystemSymbol(
                "figure.strengthtraining.traditional",
                in: NSRect(origin: .zero, size: imageSize)
            )
        }

        image.unlockFocus()
        // Kestra's branded asset is a full-color icon. Runner and symbol
        // plugins remain template images so macOS can adapt their tint.
        image.isTemplate = squatRunner.selectedIconID != MenuBarIconPluginCatalog.kestraLogoID
        return image
    }

    private func drawSystemSymbol(_ symbolName: String, in rect: NSRect) {
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else {
            return
        }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: min(rect.width, rect.height) * 0.72,
            weight: .semibold
        )
        let configuredImage = image.withSymbolConfiguration(configuration) ?? image
        drawImage(configuredImage, in: rect)
    }

    private func drawImage(_ image: NSImage, in rect: NSRect) {
        let configuredImage = image.copy() as? NSImage ?? image
        configuredImage.isTemplate = false
        configuredImage.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func refreshStatusItemImage(isAnimationFrame: Bool = false) {
        if isAnimationFrame {
            let now = ProcessInfo.processInfo.systemUptime
            if let lastAnimatedStatusImageRefreshUptime,
               now - lastAnimatedStatusImageRefreshUptime < animatedStatusImageRefreshInterval {
                return
            }
            lastAnimatedStatusImageRefreshUptime = now
        } else {
            lastAnimatedStatusImageRefreshUptime = ProcessInfo.processInfo.systemUptime
        }

        menuBarAppearanceRedrawGate.record(menuBarUsesDarkAppearance)
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage()
        updateMenuBarLogoLayer(on: button)
        if !isAnimationFrame {
            button.toolTip = makeToolTip()
        }
    }

    private var selectedRunningTaskCount: Int {
        providerSelection.selectedProviders.reduce(0) {
            $0 + store.runningTaskCount(for: $1)
        }
    }

    private var runningProvider: AIProvider? {
        var selected: (provider: AIProvider, count: Int)?
        for provider in providerSelection.selectedProviders {
            let count = store.runningTaskCount(for: provider)
            guard count > 0 else { continue }
            if selected == nil || count > selected!.count {
                selected = (provider, count)
            }
        }
        return selected?.provider
    }

    private var displayedProvider: AIProvider? {
        runningProvider ?? providerSelection.selectedProviders.first
    }

    private var currentUsage: CodexAccountUsage? {
        // The current quota reader is Codex-specific. Do not place a ChatGPT
        // quota ring beside another client's logo and imply that it belongs to
        // that client.
        guard displayedProvider == .codex else { return nil }
        guard let accountID = store.currentAccountID else { return nil }
        return store.accountQuotas[accountID]?.usage
    }

    private func updateLogoRotation(isRunning: Bool) {
        guard squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID else {
            stopLogoRotation()
            return
        }
        let layer = menuBarLogoLayer

        if !isRunning {
            stopLogoRotation()
            return
        }

        let taskSpeed = min(
            logoRotationSpeedCap,
            CGFloat(sqrt(Double(max(1, selectedRunningTaskCount))))
        )
        let duration = Double(logoRotationDurationForSingleTask / taskSpeed)
        if let animation = layer.animation(forKey: logoRotationAnimationKey) as? CABasicAnimation,
           abs(animation.duration - duration) < 0.001 {
            return
        }

        layer.removeAnimation(forKey: logoRotationAnimationKey)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: logoRotationAnimationKey)
    }

    private func stopLogoRotation() {
        menuBarLogoLayer.removeAnimation(forKey: logoRotationAnimationKey)
        menuBarLogoLayer.setAffineTransform(.identity)
    }

    private func updateMenuBarLogoLayer(on button: NSStatusBarButton) {
        guard squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID else {
            menuBarLogoLayer.removeFromSuperlayer()
            stopLogoRotation()
            return
        }

        button.wantsLayer = true
        guard let buttonLayer = button.layer,
              let logoImage = MenubarStatusIconRenderer.makeLogoImage(
                  provider: displayedProvider,
                  usage: currentUsage,
                  isDark: menuBarUsesDarkAppearance
              ) else {
            menuBarLogoLayer.removeFromSuperlayer()
            stopLogoRotation()
            return
        }

        if menuBarLogoLayer.superlayer !== buttonLayer {
            menuBarLogoLayer.removeFromSuperlayer()
            buttonLayer.addSublayer(menuBarLogoLayer)
        }

        let imageRect = button.cell?.imageRect(forBounds: button.bounds)
            ?? NSRect(
                x: (button.bounds.width - MenubarStatusIconRenderer.imageSize.width) / 2,
                y: (button.bounds.height - MenubarStatusIconRenderer.imageSize.height) / 2,
                width: MenubarStatusIconRenderer.imageSize.width,
                height: MenubarStatusIconRenderer.imageSize.height
            )
        let logoFrame = MenubarStatusIconRenderer.logoFrame(for: currentUsage)
        let scaleX = imageRect.width / MenubarStatusIconRenderer.imageSize.width
        let scaleY = imageRect.height / MenubarStatusIconRenderer.imageSize.height
        let frame = NSRect(
            x: imageRect.minX + logoFrame.minX * scaleX,
            y: imageRect.minY + logoFrame.minY * scaleY,
            width: logoFrame.width * scaleX,
            height: logoFrame.height * scaleY
        )
        var proposedRect = NSRect(origin: .zero, size: logoImage.size)
        guard let cgImage = logoImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            menuBarLogoLayer.contents = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        menuBarLogoLayer.frame = frame
        menuBarLogoLayer.contents = cgImage
        menuBarLogoLayer.contentsGravity = .resizeAspect
        menuBarLogoLayer.contentsScale = button.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        menuBarLogoLayer.isHidden = false
        CATransaction.commit()
    }

    private func makeToolTip() -> String {
        let runningProviders = providerSelection.selectedProviders.filter {
            store.runningTaskCount(for: $0) > 0
        }
        guard !runningProviders.isEmpty else {
            return "Kestra；当前没有运行中的任务\(quotaTooltipSuffix)"
        }

        let counts = runningProviders
            .map { "\($0.name) \(store.runningTaskCount(for: $0))" }
            .joined(separator: "，")
        return "运行中：\(counts)\(quotaTooltipSuffix)"
    }

    private var quotaTooltipSuffix: String {
        guard let currentUsage, !currentUsage.displayWindows.isEmpty else { return "" }
        let values = currentUsage.displayWindows
            .map { "\($0.title) \($0.remainingPercent)%" }
            .joined(separator: "，")
        return "；额度：\(values)"
    }

    private func makeAccessibilityLabel() -> String {
        let runningProviders = providerSelection.selectedProviders.filter {
            store.runningTaskCount(for: $0) > 0
        }
        guard !runningProviders.isEmpty else {
            return "Kestra，没有运行中的任务\(quotaAccessibilitySuffix)"
        }

        let label = runningProviders
            .map { "\($0.name)，\(store.runningTaskCount(for: $0)) 个运行中" }
            .joined(separator: "；")
        return "\(label)\(quotaAccessibilitySuffix)"
    }

    private var quotaAccessibilitySuffix: String {
        guard let currentUsage, !currentUsage.displayWindows.isEmpty else { return "" }
        let values = currentUsage.displayWindows
            .map { "\($0.title)剩余百分之\($0.remainingPercent)" }
            .joined(separator: "，")
        return "；\(values)"
    }

    private func installTrackingArea(on button: NSStatusBarButton) {
        // inVisibleRect follows button resizing. Reinstalling on every task
        // refresh can lose the pointer's existing enter/exit state.
        guard trackingArea == nil else { return }

        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    // NSObject does not inherit NSResponder's Objective-C selector mapping.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        isButtonHovering = true
        closeWorkItem?.cancel()
        hoverShowWorkItem?.cancel()
        guard hoverPanel == nil, popover?.isShown != true else { return }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isButtonHovering, self.statusItem.isVisible else { return }
                self.hoverShowWorkItem = nil
                self.showHoverPanel()
            }
        }
        hoverShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        isButtonHovering = false
        hoverShowWorkItem?.cancel()
        hoverShowWorkItem = nil
        schedulePopoverClose()
    }

    @objc private func statusItemClicked() {
        closeHoverPanel()
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopoverIfNeeded()
        }
    }

    private func showPopoverIfNeeded() {
        guard let button = statusItem.button else { return }

        closeWorkItem?.cancel()

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.appearance = themeAppearance
            popover.contentSize = NSSize(width: 420, height: 560)
            popover.contentViewController = NSHostingController(
                rootView: StatusPopoverView(
                    store: store,
                    squatRunner: squatRunner,
                    providerSelection: providerSelection,
                    previewSettings: previewSettings,
                    themeStore: themeStore,
                    menuBarIconLayoutSettings: menuBarIconLayoutSettings,
                    updater: updater,
                    launchAtLogin: launchAtLogin,
                    limitRefreshSettings: limitRefreshSettings,
                    animationPlugins: animationPlugins,
                    animationSettings: animationSettings,
                    onPreviewAnimation: { [weak self] identifier in
                        if let identifier { self?.previewController.preview(request: identifier) }
                        else { self?.previewController.cancelPreview() }
                    },
                    onDirectionMenuPresented: { [weak self] shown in
                        self?.isDirectionMenuPresented = shown
                        if shown {
                            self?.holdsPopoverAfterMenu = true
                            self?.closeWorkItem?.cancel()
                        }
                    },
                    onHover: { [weak self] isHovered in
                        self?.setPopoverHovering(isHovered)
                    },
                    onOpenTask: { [weak self] task in
                        self?.launchTask(task)
                    },
                    onOpenCodex: { [weak self] in
                        self?.closePopover()
                        self?.onOpenCodex()
                    },
                    onOpenClaude: { [weak self] in
                        self?.closePopover()
                        self?.onOpenClaude()
                    },
                    onQuit: { [weak self] in
                        self?.onQuit()
                    }
                )
            )
            self.popover = popover
        }

        guard let popover, !popover.isShown else { return }
        store.refreshNow()
        configureButton()
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private var themeAppearance: NSAppearance? {
        NSAppearance(named: themeStore.mode == .dark ? .darkAqua : .aqua)
    }

    private func updatePopoverAppearance() {
        popover?.appearance = themeAppearance
        hoverPanel?.appearance = themeAppearance
    }

    private func setPopoverHovering(_ isHovered: Bool) {
        isPopoverHovering = isHovered
        if isHovered {
            closeWorkItem?.cancel()
            if !isDirectionMenuPresented { holdsPopoverAfterMenu = false }
        } else if !isButtonHovering {
            schedulePopoverClose()
        }
    }

    private func schedulePopoverClose() {
        closeWorkItem?.cancel()
        guard !isButtonHovering, !isHoverPanelHovering, !isPopoverHovering,
              !isDirectionMenuPresented, !holdsPopoverAfterMenu else { return }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
        closeWorkItem = workItem
        // The corner panel can be farther from the status item; allow pointer travel.
        let delay = hoverPanel == nil ? 0.28 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func closePopover() {
        closeWorkItem?.cancel()
        closeHoverPanel()
        isPopoverHovering = false
        isDirectionMenuPresented = false
        holdsPopoverAfterMenu = false
        popover?.performClose(nil)
    }

    private func showHoverPanel() {
        guard popover?.isShown != true, hoverPanel == nil,
              let button = statusItem.button, let window = button.window,
              let screen = window.screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        // Two 130pt cards, an 8pt gap, and 12pt padding on either side.
        let size = NSSize(width: min(292, visible.width), height: min(160, visible.height))
        let origin = NSPoint(
            x: visible.maxX - size.width,
            y: visible.maxY - size.height
        )
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = themeAppearance
        panel.contentViewController = NSHostingController(rootView: StatusHoverView(
            store: store, providers: providerSelection, theme: themeStore,
            width: size.width, maxHeight: visible.height,
            onHeightChange: { [weak self, weak panel] height in
                guard let panel, self?.hoverPanel === panel else { return }
                let frame = NSRect(x: visible.maxX - size.width, y: visible.maxY - height,
                                   width: size.width, height: height)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            },
            onHover: { [weak self] inside in
                guard let self else { return }
                self.isHoverPanelHovering = inside
                if inside { self.closeWorkItem?.cancel() }
                else { self.schedulePopoverClose() }
            },
            onOpenTask: { [weak self] task in self?.launchTask(task) }
        ))
        hoverPanel = panel
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
    }

    private func closeHoverPanel() {
        hoverShowWorkItem?.cancel()
        hoverShowWorkItem = nil
        hoverPanel?.orderOut(nil)
        hoverPanel = nil
        isHoverPanelHovering = false
    }

    private func launchTask(_ task: CodexTask) {
        closePopover()
        onOpenTask(task)
    }

}
