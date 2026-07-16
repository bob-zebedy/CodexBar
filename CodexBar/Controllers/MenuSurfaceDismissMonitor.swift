import AppKit

/// 菜单面板关闭监听器, 汇总本地/全局鼠标, 键盘和应用激活变化
@MainActor
final class MenuSurfaceDismissMonitor {
    private let isPresented: () -> Bool
    private let windowProvider: () -> NSWindow?
    private let statusButtonProvider: () -> NSStatusBarButton?
    private let isPointInExtraSurface: (NSPoint) -> Bool
    private var localEventMonitor: Any?
    private var globalMouseEventMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?
    private var activeMenuSurfaceWindowResignKeyObserver: NSObjectProtocol?
    private var deferredWindowFocusTask: Task<Void, Never>?
    private var suppressActivationDismissTask: Task<Void, Never>?
    private var suppressesActivationDismiss = false
    private var onDismiss: (() -> Void)?
    private var onLogShortcut: (() -> Void)?

    init(
        isPresented: @escaping () -> Bool,
        windowProvider: @escaping () -> NSWindow?,
        statusButtonProvider: @escaping () -> NSStatusBarButton?,
        isPointInExtraSurface: @escaping (NSPoint) -> Bool = { _ in false }
    ) {
        self.isPresented = isPresented
        self.windowProvider = windowProvider
        self.statusButtonProvider = statusButtonProvider
        self.isPointInExtraSurface = isPointInExtraSurface
    }

    func install(
        onDismiss: @escaping () -> Void,
        onLogShortcut: (() -> Void)? = nil
    ) {
        remove()
        self.onDismiss = onDismiss
        self.onLogShortcut = onLogShortcut

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] event in
            guard let self else {
                return event
            }

            if handleKeyEvent(event) {
                return nil
            }

            dismissIfNeeded(for: event)
            restabilizeActiveMenuSurfaceChromeAfterEvent()
            return event
        }

        globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Metrics.mouseDismissEventMask) { [weak self] _ in
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self, screenPoint] in
                self?.dismissIfNeeded(at: screenPoint)
            }
        }

        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDismissForActivationChange()
            }
        }

        workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedProcessIdentifier = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.processIdentifier

            Task { @MainActor [weak self, activatedProcessIdentifier] in
                self?.dismissIfDifferentApplication(processIdentifier: activatedProcessIdentifier)
            }
        }

        installActiveMenuSurfaceWindowObserverAndFocus()
        deferredWindowFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, isPresented() else {
                return
            }

            installActiveMenuSurfaceWindowObserverAndFocus()
        }
    }

    func remove() {
        onDismiss = nil
        onLogShortcut = nil
        deferredWindowFocusTask?.cancel()
        deferredWindowFocusTask = nil
        suppressActivationDismissTask?.cancel()
        suppressActivationDismissTask = nil
        suppressesActivationDismiss = false
        removeEventMonitor(&localEventMonitor)
        removeEventMonitor(&globalMouseEventMonitor)
        removeObserver(&appResignActiveObserver)
        removeObserver(&workspaceActivateObserver, center: NSWorkspace.shared.notificationCenter)
        removeObserver(&activeMenuSurfaceWindowResignKeyObserver)
    }

    private func installActiveMenuSurfaceWindowObserverAndFocus() {
        installActiveMenuSurfaceWindowObserver()
        focusActiveMenuSurfaceWindow()
    }

    private func installActiveMenuSurfaceWindowObserver() {
        removeObserver(&activeMenuSurfaceWindowResignKeyObserver)
        guard let activeMenuSurfaceWindow = windowProvider() else {
            return
        }

        activeMenuSurfaceWindowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: activeMenuSurfaceWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDismissForActivationChange()
            }
        }
    }

    private nonisolated func scheduleDismiss() {
        Task { @MainActor [weak self] in
            self?.dismiss()
        }
    }

    private func scheduleDismissForActivationChange() {
        guard !suppressesActivationDismiss else {
            return
        }

        scheduleDismiss()
    }

    private func dismiss() {
        guard isPresented() else {
            return
        }

        onDismiss?()
    }

    private func dismissIfDifferentApplication(processIdentifier: pid_t?) {
        guard !suppressesActivationDismiss else {
            return
        }

        if let processIdentifier, processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }

        dismiss()
    }

    private func focusActiveMenuSurfaceWindow() {
        guard isPresented(),
              let activeMenuSurfaceWindow = windowProvider() else {
            return
        }

        activeMenuSurfaceWindow.bringToFrontActivatingApp()
    }

    private func removeEventMonitor(_ monitor: inout Any?) {
        if let currentMonitor = monitor {
            NSEvent.removeMonitor(currentMonitor)
            monitor = nil
        }
    }

    private func removeObserver(
        _ observer: inout NSObjectProtocol?,
        center: NotificationCenter = .default
    ) {
        if let currentObserver = observer {
            center.removeObserver(currentObserver)
            observer = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isPresented(), event.type == .keyDown else {
            return false
        }

        if event.keyCode == Metrics.escapeKeyCode {
            dismiss()
            return true
        }

        if isExactCommandShortcut(event, keyCode: Metrics.logKeyCode) {
            onLogShortcut?()
            return true
        }

        if isCommandShortcut(event, keyCode: Metrics.tabKeyCode) {
            dismiss()
        } else if isCommandShortcut(event, keyCode: Metrics.spaceKeyCode) {
            suppressNextActivationDismiss()
        }

        return false
    }

    private func isCommandShortcut(_ event: NSEvent, keyCode: UInt16) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifierFlags.contains(.command) && event.keyCode == keyCode
    }

    private func isExactCommandShortcut(_ event: NSEvent, keyCode: UInt16) -> Bool {
        let shortcutModifiers = event.modifierFlags.intersection(Metrics.shortcutModifierMask)
        return shortcutModifiers == .command && event.keyCode == keyCode
    }

    private func suppressNextActivationDismiss() {
        // Command-Space 会切换系统搜索焦点
        // 需要短暂抑制失活关闭避免误关面板
        suppressActivationDismissTask?.cancel()
        suppressesActivationDismiss = true
        suppressActivationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Metrics.activationDismissSuppressionMilliseconds))
            guard let self, !Task.isCancelled else {
                return
            }

            suppressesActivationDismiss = false
            suppressActivationDismissTask = nil
        }
    }

    private func dismissIfNeeded(for event: NSEvent) {
        guard isPresented(), isMouseDismissEvent(event) else {
            return
        }

        dismissIfNeeded(at: screenPoint(for: event))
    }

    private func dismissIfNeeded(at screenPoint: NSPoint) {
        guard isPresented() else {
            return
        }

        if isPointAllowed(screenPoint) {
            return
        }

        // 只有真正点到菜单和状态按钮之外才关闭
        dismiss()
    }

    private func isPointAllowed(_ screenPoint: NSPoint) -> Bool {
        isPointInMenuSurface(screenPoint)
            || isPointInStatusButton(screenPoint)
            || isPointInExtraSurface(screenPoint)
    }

    private func isMouseDismissEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            true
        default:
            false
        }
    }

    private func restabilizeActiveMenuSurfaceChromeAfterEvent() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, isPresented() else {
                return
            }

            stabilizeActiveMenuSurfaceChromeAppearance()
        }
    }

    private func stabilizeActiveMenuSurfaceChromeAppearance() {
        guard let rootView = windowProvider()?.contentView else {
            return
        }

        // AppKit 会在点击后重新强调 NSVisualEffectView
        // 这里固定为 inactive 避免背景明暗跳变
        stabilizeVisualEffectViews(in: rootView)
    }

    private func stabilizeVisualEffectViews(in view: NSView) {
        if let visualEffectView = view as? NSVisualEffectView {
            visualEffectView.state = .inactive
            visualEffectView.isEmphasized = false
        }

        for subview in view.subviews {
            stabilizeVisualEffectViews(in: subview)
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func isPointInMenuSurface(_ screenPoint: NSPoint) -> Bool {
        guard let activeMenuSurfaceWindow = windowProvider() else {
            return false
        }

        return activeMenuSurfaceWindow.frame.contains(screenPoint)
    }

    private func isPointInStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusButtonProvider(),
              let buttonWindow = button.window else {
            return false
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        return buttonScreenRect.contains(screenPoint)
    }

    private enum Metrics {
        static let mouseDismissEventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        static let dismissEventMask: NSEvent.EventTypeMask = mouseDismissEventMask.union(.keyDown)
        static let escapeKeyCode: UInt16 = 53
        static let tabKeyCode: UInt16 = 48
        static let spaceKeyCode: UInt16 = 49
        static let logKeyCode: UInt16 = 37
        static let shortcutModifierMask: NSEvent.ModifierFlags = [
            .command,
            .control,
            .option,
            .shift
        ]
        static let activationDismissSuppressionMilliseconds: UInt64 = 600
    }
}
