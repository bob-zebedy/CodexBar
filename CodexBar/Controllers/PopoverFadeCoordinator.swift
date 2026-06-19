import AppKit

@MainActor
final class PopoverFadeCoordinator {
    private let popover: NSPopover
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var generation = 0
    
    init(popover: NSPopover) {
        self.popover = popover
    }
    
    func cancel() {
        openTask?.cancel()
        openTask = nil
        closeTask?.cancel()
        closeTask = nil
    }
    
    func prepareForFadeIn() {
        contentView?.alphaValue = 0
        contentView?.window?.alphaValue = 0
    }
    
    func resetAlpha() {
        contentView?.alphaValue = 1
        contentView?.window?.alphaValue = 1
    }
    
    func fadeIn(duration: TimeInterval, completion: @escaping () -> Void) {
        let operationGeneration = nextGeneration()
        fade(to: 1, duration: duration)
        
        openTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled, self.generation == operationGeneration else {
                return
            }
            
            self.resetAlpha()
            self.openTask = nil
            completion()
        }
    }
    
    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) -> Bool {
        guard let contentView else {
            return false
        }
        
        let operationGeneration = nextGeneration()
        let popoverWindow = contentView.window
        fade(to: 0, duration: duration)
        
        closeTask = Task { @MainActor [weak self, weak contentView, weak popoverWindow] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled, self.generation == operationGeneration else {
                return
            }
            
            self.popover.performClose(nil)
            contentView?.alphaValue = 1
            popoverWindow?.alphaValue = 1
            self.closeTask = nil
            completion()
        }
        
        return true
    }
    
    private var contentView: NSView? {
        popover.contentViewController?.view
    }
    
    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }
    
    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        guard let contentView else {
            return
        }
        
        let popoverWindow = contentView.window
        if alpha == 1 {
            popoverWindow?.alphaValue = 0
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            popoverWindow?.animator().alphaValue = alpha
            contentView.animator().alphaValue = alpha
        }
    }
}
