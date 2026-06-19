import AppKit

@MainActor
final class PopoverDismissMonitor {
    private let popover: NSPopover
    private let statusButtonProvider: () -> NSStatusBarButton?
    private var localMouseEventMonitor: Any?
    private var globalMouseEventMonitor: Any?
    
    init(
        popover: NSPopover,
        statusButtonProvider: @escaping () -> NSStatusBarButton?
    ) {
        self.popover = popover
        self.statusButtonProvider = statusButtonProvider
    }
    
    func install(onDismiss: @escaping () -> Void) {
        remove()
        
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Metrics.dismissEventMask) { [weak self] event in
            self?.dismissIfNeeded(for: event, onDismiss: onDismiss)
            self?.restabilizePopoverChromeAfterEvent()
            return event
        }
        
        globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Metrics.dismissEventMask) { _ in
            onDismiss()
        }
    }
    
    func remove() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
        
        if let globalMouseEventMonitor {
            NSEvent.removeMonitor(globalMouseEventMonitor)
            self.globalMouseEventMonitor = nil
        }
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
        static let dismissEventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
    }
}
