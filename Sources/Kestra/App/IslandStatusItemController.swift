import AppKit
import Combine
import SwiftUI

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
    private var closeWorkItem: DispatchWorkItem?
    private var isDirectionMenuPresented = false
    private var holdsPopoverAfterMenu = false
    private var isButtonHovering = false
    private var storeObservation: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var menuBarAppearanceObservation: NSKeyValueObservation?
    private var logoRotationTimer: Timer?
    private var logoRotationAngle: CGFloat = 0
    private let logoRotationFramesPerSecond: CGFloat = 30
    private let logoRotationDurationForSingleTask: CGFloat = 3
    private let logoRotationSpeedCap: CGFloat = 4
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
            self?.refreshStatusItemImage()
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
        updateLogoRotation(
            isRunning: runningCount > 0
                && squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID
        )

        button.image = makeStatusImage()
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(statusItemClicked)
        button.toolTip = makeToolTip()
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
                self?.refreshStatusItemImage()
            }
        }
    }

    private func makeStatusImage() -> NSImage {
        guard squatRunner.selectedIconID == MenuBarIconPluginCatalog.statusIconID else {
            return makeRunnerImage()
        }

        return MenubarStatusIconRenderer.makeImage(
            provider: displayedProvider,
            usage: currentUsage,
            isRunning: selectedRunningTaskCount > 0,
            rotationAngle: logoRotationAngle,
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

    private func refreshStatusItemImage() {
        statusItem.button?.image = makeStatusImage()
        statusItem.button?.toolTip = makeToolTip()
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
        if isRunning {
            guard logoRotationTimer == nil else { return }
            logoRotationAngle = 0
            let timer = Timer(timeInterval: 1.0 / Double(logoRotationFramesPerSecond), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceLogoRotation() }
            }
            RunLoop.main.add(timer, forMode: .common)
            logoRotationTimer = timer
        } else {
            stopLogoRotation()
        }
    }

    private func advanceLogoRotation() {
        guard selectedRunningTaskCount > 0 else {
            stopLogoRotation()
            refreshStatusItemImage()
            return
        }

        let taskSpeed = min(
            logoRotationSpeedCap,
            CGFloat(sqrt(Double(max(1, selectedRunningTaskCount))))
        )
        let radiansPerFrame = (2 * CGFloat.pi / logoRotationDurationForSingleTask)
            * taskSpeed
            / logoRotationFramesPerSecond
        logoRotationAngle = (logoRotationAngle + radiansPerFrame)
            .truncatingRemainder(dividingBy: 2 * CGFloat.pi)
        refreshStatusItemImage()
    }

    private func stopLogoRotation() {
        logoRotationTimer?.invalidate()
        logoRotationTimer = nil
        logoRotationAngle = 0
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
        if let trackingArea {
            button.removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    func mouseEntered(with event: NSEvent) {
        isButtonHovering = true
        closeWorkItem?.cancel()
        showPopoverIfNeeded()
    }

    func mouseExited(with event: NSEvent) {
        isButtonHovering = false
        schedulePopoverClose()
    }

    @objc private func statusItemClicked() {
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
    }

    private func setPopoverHovering(_ isHovered: Bool) {
        if isHovered {
            closeWorkItem?.cancel()
            if !isDirectionMenuPresented { holdsPopoverAfterMenu = false }
        } else if !isButtonHovering {
            schedulePopoverClose()
        }
    }

    private func schedulePopoverClose() {
        closeWorkItem?.cancel()
        guard !isButtonHovering, !isDirectionMenuPresented, !holdsPopoverAfterMenu else { return }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func closePopover() {
        closeWorkItem?.cancel()
        isDirectionMenuPresented = false
        holdsPopoverAfterMenu = false
        popover?.performClose(nil)
    }

    private func launchTask(_ task: CodexTask) {
        closePopover()
        onOpenTask(task)
    }

}
