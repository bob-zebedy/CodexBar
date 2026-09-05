import AppKit
import QuartzCore
import SwiftUI

/// 开合和悬停状态留在选择器内部, 避免交互时重新计算整个版本区
struct CodexSourcePicker: View {
    let selection: CodexCLISourceSelection
    let options: [CodexCLISourceSelection]
    let isEnabled: Bool
    let onSelect: (CodexCLISourceSelection) -> Void
    @State private var isHovered = false
    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        options.contains(selection) ? selection.title : String(localized: "settings.codex-version.source.select")
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    ForEach(options) { option in
                        Text(option.title).hidden()
                    }
                    Text(title)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .animation(reduceMotion ? nil : .codexStatus, value: isPresented)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsRowMetrics.optionsButtonSize)
            .background {
                Capsule(style: .continuous)
                    .fill(.primary.opacity((isHovered || isPresented) && isEnabled ? 0.06 : 0))
                    .animation(reduceMotion ? nil : .codexStatus, value: isHovered || isPresented)
            }
            .liquidGlassCapsule(tint: isEnabled ? .accentColor : .secondary)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityValue(Text(title))
        .background {
            CodexSourceDropdown(
                isPresented: $isPresented,
                selection: selection,
                options: options,
                isEnabled: isEnabled,
                animates: !reduceMotion,
                onSelect: onSelect
            )
        }
        .onDisappear {
            isPresented = false
        }
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled {
                isPresented = false
            }
        }
        .onChange(of: options) { _, _ in
            isPresented = false
        }
    }
}

/// 浮层开合由同一处处理, 快速点击从当前呈现位置反向动画
private struct CodexSourceDropdown: NSViewRepresentable {
    @Binding var isPresented: Bool
    let selection: CodexCLISourceSelection
    let options: [CodexCLISourceSelection]
    let isEnabled: Bool
    let animates: Bool
    let onSelect: (CodexCLISourceSelection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.anchorView = view
        view.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleReconcile()
        }
        return view
    }

    func updateNSView(_: AnchorView, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.scheduleReconcile()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.dispose()
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var configuration: CodexSourceDropdown
        weak var anchorView: AnchorView?
        private let popover = NSPopover()
        private weak var observedWindow: NSWindow?
        private var targetIsVisible = false
        private var presentedOrigin = NSPoint.zero
        private var animationGeneration = 0
        private var reconcileTask: Task<Void, Never>?
        private var localMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var isAnchorPressInProgress = false
        private var isDisposed = false

        init(configuration: CodexSourceDropdown) {
            self.configuration = configuration
            super.init()
            popover.delegate = self
            popover.behavior = .applicationDefined
            popover.animates = false
        }

        func scheduleReconcile() {
            guard reconcileTask == nil else { return }
            reconcileTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                reconcileTask = nil
                reconcile()
            }
        }

        private func setPresented(_ isPresented: Bool) {
            configuration.isPresented = isPresented && configuration.isEnabled
            reconcile()
        }

        private func reconcile() {
            guard !isDisposed else { return }
            guard let anchorView, let window = anchorView.window, window.isVisible else {
                configuration.isPresented = false
                closeImmediately()
                removeMonitors()
                return
            }
            installMonitors(for: window)
            let wantsPresentation = configuration.isPresented && configuration.isEnabled
            guard wantsPresentation != targetIsVisible else { return }
            if wantsPresentation, !popover.isShown {
                guard !anchorView.visibleRect.isEmpty, show(relativeTo: anchorView) else {
                    configuration.isPresented = false
                    return
                }
            }
            targetIsVisible = wantsPresentation
            if wantsPresentation {
                popover.contentViewController?.view.window?.makeKey()
            }
            animateVisibility(wantsPresentation)
        }

        private func show(relativeTo anchor: NSView) -> Bool {
            let content = CodexSourceOptions(
                selection: configuration.selection,
                options: configuration.options,
                onSelect: { [weak self] selection in
                    guard let self else { return }
                    setPresented(false)
                    configuration.onSelect(selection)
                }
            )
            let host = NSHostingController(rootView: content)
            host.sizingOptions = [.preferredContentSize]
            guard let size = host.view.validFittingSize else { return false }
            popover.contentViewController = host
            popover.contentSize = size
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            guard popover.isShown, let window = popover.contentViewController?.view.window else {
                popover.close()
                return false
            }
            presentedOrigin = window.frame.origin
            window.alphaValue = 0
            window.setFrameOrigin(NSPoint(x: presentedOrigin.x, y: presentedOrigin.y + 8))
            return true
        }

        private func animateVisibility(_ isVisible: Bool) {
            guard let window = popover.contentViewController?.view.window else {
                closeImmediately()
                return
            }
            animationGeneration += 1
            let generation = animationGeneration
            let targetOpacity: CGFloat = isVisible ? 1 : 0
            let targetFrame = NSRect(
                origin: NSPoint(x: presentedOrigin.x, y: presentedOrigin.y + (isVisible ? 0 : 8)),
                size: window.frame.size
            )
            // 整个窗口一起移动和淡入淡出, 避免系统边框和材质与内部图层变换不同步
            // animator 会从当前值转向新目标, 连续点击无需等待上一次动画结束
            NSAnimationContext.runAnimationGroup { context in
                context.duration = configuration.animates ? 0.18 * abs(targetOpacity - window.alphaValue) : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = targetOpacity
                window.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishAnimation(generation: generation)
                }
            }
        }

        private func finishAnimation(generation: Int) {
            guard !isDisposed, animationGeneration == generation, !targetIsVisible else { return }
            popover.close()
        }

        private func closeImmediately() {
            animationGeneration += 1
            if let window = popover.contentViewController?.view.window {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    window.animator().alphaValue = window.alphaValue
                    window.animator().setFrame(window.frame, display: true)
                }
            }
            targetIsVisible = false
            popover.close()
        }

        func popoverWillClose(_: Notification) {
            animationGeneration += 1
            targetIsVisible = false
            configuration.isPresented = false
        }

        private func installMonitors(for window: NSWindow) {
            guard observedWindow !== window || localMonitor == nil else { return }
            removeMonitors()
            observedWindow = window
            // 锚点的按下和抬起始终走同一条路径, 不随浮层开关切换回 SwiftUI 按钮的鼠标追踪
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .keyDown
            ]) { [weak self] event in
                guard let self else { return event }
                return handleEvent(event)
            }
            for (name, object) in [
                (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject),
                (NSWindow.willCloseNotification, window as AnyObject),
                (NSWindow.willMiniaturizeNotification, window as AnyObject)
            ] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == NSWindow.willCloseNotification {
                            self.configuration.isPresented = false
                            self.closeImmediately()
                            self.removeMonitors()
                        } else {
                            self.setPresented(false)
                        }
                    }
                })
            }
        }

        private func handleEvent(_ event: NSEvent) -> NSEvent? {
            if isAnchorPressInProgress, event.type == .leftMouseUp || event.type == .leftMouseDragged {
                if event.type == .leftMouseUp {
                    isAnchorPressInProgress = false
                }
                return nil
            }
            if event.type == .leftMouseDown, configuration.isEnabled,
               let anchorView, !anchorView.isHiddenOrHasHiddenAncestor,
               event.window === anchorView.window,
               anchorView.bounds.intersection(anchorView.visibleRect).contains(anchorView.convert(event.locationInWindow, from: nil)) {
                isAnchorPressInProgress = true
                setPresented(!configuration.isPresented)
                return nil
            }
            guard popover.isShown else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                setPresented(false)
                return nil
            }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
               event.window !== popover.contentViewController?.view.window {
                setPresented(false)
            }
            return event
        }

        private func removeMonitors() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = nil
            isAnchorPressInProgress = false
        }

        func dispose() {
            isDisposed = true
            reconcileTask?.cancel()
            popover.delegate = nil
            closeImmediately()
            removeMonitors()
        }
    }
}

private struct CodexSourceOptions: View {
    let selection: CodexCLISourceSelection
    let options: [CodexCLISourceSelection]
    let onSelect: (CodexCLISourceSelection) -> Void
    @State private var highlightedSelection: CodexCLISourceSelection?

    var body: some View {
        VStack(spacing: 3) {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tint)
                            .opacity(option == selection ? 1 : 0)
                            .frame(width: 12)
                            .accessibilityHidden(true)

                        Text(option.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(width: 12, height: 10)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.primary.opacity(highlightedSelection == option ? 0.08 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isHovered in
                    if isHovered {
                        highlightedSelection = option
                    }
                }
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(6)
        .fixedSize(horizontal: true, vertical: false)
        // 列表接收方向键, 展开时不自动聚焦或高亮某个选项
        .focusable()
        .focusEffectDisabled()
        // 经过行间空隙时保留高亮, 离开列表才清除, 避免闪回键盘焦点所在行
        .onHover { isHovered in
            if !isHovered {
                highlightedSelection = nil
            }
        }
        .onKeyPress(.upArrow) {
            moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            if let selected = highlightedSelection {
                onSelect(selected)
            }
            return .handled
        }
    }

    private func moveFocus(by offset: Int) {
        guard !options.isEmpty else { return }
        if let index = highlightedSelection.flatMap({ options.firstIndex(of: $0) }) {
            highlightedSelection = options[(index + offset + options.count) % options.count]
        } else {
            highlightedSelection = offset > 0 ? options.first : options.last
        }
    }
}
