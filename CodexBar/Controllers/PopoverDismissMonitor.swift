import AppKit

@MainActor
final class PopoverDismissMonitor {
    private let popover: NSPopover
    private let statusButtonProvider: () -> NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalMouseEventMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?
    private var popoverWindowResignKeyObserver: NSObjectProtocol?
    private var deferredWindowFocusTask: Task<Void, Never>?
    private var onDismiss: (() -> Void)?
    
    init(
        popover: NSPopover,
        statusButtonProvider: @escaping () -> NSStatusBarButton?
    ) {
        self.popover = popover
        self.statusButtonProvider = statusButtonProvider
    }
    
    func install(onDismiss: @escaping () -> Void) {
        remove()
        self.onDismiss = onDismiss
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] event in
            guard let self else {
                return event
            }
            
            if self.handleKeyEvent(event) {
                return nil
            }
            
            self.dismissIfNeeded(for: event)
            self.restabilizePopoverChromeAfterEvent()
            return event
        }
        
        globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Metrics.mouseDismissEventMask) { [weak self] _ in
            self?.scheduleDismiss()
        }
        
        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDismiss()
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
        
        installPopoverWindowObserverAndFocus()
        deferredWindowFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.popover.isShown else {
                return
            }
            
            self.installPopoverWindowObserverAndFocus()
        }
    }
    
    func remove() {
        onDismiss = nil
        deferredWindowFocusTask?.cancel()
        deferredWindowFocusTask = nil
        removeEventMonitor(&localEventMonitor)
        removeEventMonitor(&globalMouseEventMonitor)
        removeObserver(&appResignActiveObserver)
        removeObserver(&workspaceActivateObserver, center: NSWorkspace.shared.notificationCenter)
        removeObserver(&popoverWindowResignKeyObserver)
    }
    
    private func installPopoverWindowObserverAndFocus() {
        installPopoverWindowObserver()
        focusPopoverWindow()
    }
    
    private func installPopoverWindowObserver() {
        removeObserver(&popoverWindowResignKeyObserver)
        guard let popoverWindow = popover.contentViewController?.view.window else {
            return
        }
        
        popoverWindowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: popoverWindow,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDismiss()
        }
    }
    
    private nonisolated func scheduleDismiss() {
        Task { @MainActor [weak self] in
            self?.dismiss()
        }
    }
    
    private func dismiss() {
        guard popover.isShown else {
            return
        }
        
        onDismiss?()
    }
    
    private func dismissIfDifferentApplication(processIdentifier: pid_t?) {
        if let processIdentifier, processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }
        
        dismiss()
    }
    
    private func focusPopoverWindow() {
        guard popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window else {
            return
        }
        
        NSApplication.shared.activate()
        popoverWindow.makeKey()
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
        guard popover.isShown, event.type == .keyDown else {
            return false
        }
        
        if event.keyCode == Metrics.escapeKeyCode {
            dismiss()
            return true
        }
        
        if isSystemDismissShortcut(event) {
            dismiss()
        }
        
        return false
    }
    
    private func isSystemDismissShortcut(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags.contains(.command) else {
            return false
        }
        
        return event.keyCode == Metrics.tabKeyCode || event.keyCode == Metrics.spaceKeyCode
    }
    
    private func dismissIfNeeded(for event: NSEvent) {
        guard popover.isShown, isMouseDismissEvent(event) else {
            return
        }
        
        if isEventInsidePopover(event) || isEventInsideStatusButton(event) {
            return
        }
        
        dismiss()
    }
    
    private func isMouseDismissEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }
    
    private func restabilizePopoverChromeAfterEvent() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.popover.isShown else {
                return
            }
            
            self.stabilizePopoverChromeAppearance()
        }
    }
    
    private func stabilizePopoverChromeAppearance() {
        guard let rootView = popover.contentViewController?.view.window?.contentView else {
            return
        }
        
        // NSPopover 会在点击后重新强调 NSVisualEffectView, 这里固定为 inactive 避免背景明暗跳变
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
    
    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let contentView = popover.contentViewController?.view,
              event.window == contentView.window else {
            return false
        }
        
        let point = contentView.convert(event.locationInWindow, from: nil)
        return contentView.bounds.contains(point)
    }
    
    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusButtonProvider(),
              let buttonWindow = button.window else {
            return false
        }
        
        let eventScreenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        return buttonScreenRect.contains(eventScreenPoint)
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
    }
}
