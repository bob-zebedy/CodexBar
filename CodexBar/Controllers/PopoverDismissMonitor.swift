import AppKit

@MainActor
final class PopoverDismissMonitor {
    private let popover: NSPopover
    private let statusButtonProvider: () -> NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalMouseEventMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var popoverWindowResignKeyObserver: NSObjectProtocol?

    init(
        popover: NSPopover,
        statusButtonProvider: @escaping () -> NSStatusBarButton?
    ) {
        self.popover = popover
        self.statusButtonProvider = statusButtonProvider
    }

    func install(onDismiss: @escaping () -> Void) {
        remove()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] event in
            guard let self else {
                return event
            }

            if self.dismissesKeyEvent(event, onDismiss: onDismiss) {
                return nil
            }

            self.dismissIfNeeded(for: event, onDismiss: onDismiss)
            self.restabilizePopoverChromeAfterEvent()
            return event
        }

        globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Metrics.mouseDismissEventMask) { _ in
            Task { @MainActor in
                onDismiss()
            }
        }

        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { _ in
            onDismiss()
        }

        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: popoverWindow,
                queue: .main
            ) { _ in
                onDismiss()
            }
        }
    }

    func remove() {
        removeEventMonitor(&localEventMonitor)
        removeEventMonitor(&globalMouseEventMonitor)
        removeObserver(&appResignActiveObserver)
        removeObserver(&popoverWindowResignKeyObserver)
    }

    private func removeEventMonitor(_ monitor: inout Any?) {
        if let currentMonitor = monitor {
            NSEvent.removeMonitor(currentMonitor)
            monitor = nil
        }
    }

    private func removeObserver(_ observer: inout NSObjectProtocol?) {
        if let currentObserver = observer {
            NotificationCenter.default.removeObserver(currentObserver)
            observer = nil
        }
    }

    private func dismissesKeyEvent(_ event: NSEvent, onDismiss: () -> Void) -> Bool {
        guard popover.isShown, event.type == .keyDown, event.keyCode == Metrics.escapeKeyCode else {
            return false
        }

        onDismiss()
        return true
    }

    private func dismissIfNeeded(for event: NSEvent, onDismiss: () -> Void) {
        guard popover.isShown else {
            return
        }

        if isEventInsidePopover(event) || isEventInsideStatusButton(event) {
            return
        }

        onDismiss()
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
    }
}
