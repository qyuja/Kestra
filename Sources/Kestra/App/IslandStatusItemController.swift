import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let store: CodexTaskStore
    private let providerSelection: AIProviderSelectionStore
    private let previewSettings: CodexTaskPreviewSettingsStore
    private let onOpenTask: (CodexTask) -> Void
    private let onOpenCodex: () -> Void
    private let onOpenClaude: () -> Void
    private let onQuit: () -> Void
    private let animationPlugins: CompletionAnimationRegistry
    private let animationSettings: CompletionAnimationSettingsStore
    private lazy var previewController = CodexCompletionPanelController(
        onOpenTask: { _ in }, animationRegistry: animationPlugins, animationSettings: animationSettings
    )

    private var trackingArea: NSTrackingArea?
    private var popover: NSPopover?
    private var closeWorkItem: DispatchWorkItem?
    private var isDirectionMenuPresented = false
    private var holdsPopoverAfterMenu = false
    private var isButtonHovering = false
    private var storeObservation: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private let squatRunner = SquatRunner()

    init(
        store: CodexTaskStore,
        providerSelection: AIProviderSelectionStore,
        previewSettings: CodexTaskPreviewSettingsStore,
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
        self.onOpenTask = onOpenTask
        self.onOpenCodex = onOpenCodex
        self.onOpenClaude = onOpenClaude
        self.onQuit = onQuit
        self.animationPlugins = animationPlugins
        self.animationSettings = animationSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        squatRunner.onFrame = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = self.makeStatusImage()
            self.statusItem.button?.toolTip = self.makeToolTip()
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
    }

    func show() {
        configureButton()
        statusItem.isVisible = true
    }

    func hide() {
        squatRunner.update(runningCount: 0)
        closePopover()
        statusItem.isVisible = false
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        squatRunner.update(runningCount: providerSelection.selectedProviders.reduce(0) { $0 + store.runningTaskCount(for: $1) })

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

    private func makeStatusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 18))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        if let runnerImage = squatRunner.image {
            let size = runnerImage.size
            let scale = min(19 / max(1, size.width), 18 / max(1, size.height))
            let width = size.width * scale
            let height = size.height * scale
            drawImage(runnerImage, in: NSRect(x: (19 - width) / 2, y: (18 - height) / 2, width: width, height: height))
        } else {
            drawSystemSymbol("figure.strengthtraining.traditional", in: NSRect(x: 0, y: 0, width: 18, height: 18))
        }

        image.unlockFocus()
        image.isTemplate = true
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
            pointSize: 11,
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

    private func makeToolTip() -> String {
        let runningProviders = providerSelection.selectedProviders.filter {
            store.runningTaskCount(for: $0) > 0
        }
        guard !runningProviders.isEmpty else {
            return "Kestra；当前没有运行中的任务；累计深蹲 \(squatRunner.total) 次"
        }

        let counts = runningProviders
            .map { "\($0.name) \(store.runningTaskCount(for: $0))" }
            .joined(separator: "，")
        return "运行中：\(counts)；累计深蹲 \(squatRunner.total) 次"
    }

    private func makeAccessibilityLabel() -> String {
        let runningProviders = providerSelection.selectedProviders.filter {
            store.runningTaskCount(for: $0) > 0
        }
        guard !runningProviders.isEmpty else {
            return "Kestra，没有运行中的任务"
        }

        return runningProviders
            .map { "\($0.name)，\(store.runningTaskCount(for: $0)) 个运行中" }
            .joined(separator: "；")
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
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.contentSize = NSSize(width: 420, height: 560)
            popover.contentViewController = NSHostingController(
                rootView: StatusPopoverView(
                    store: store,
                    squatRunner: squatRunner,
                    providerSelection: providerSelection,
                    previewSettings: previewSettings,
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
