import AppKit

@MainActor
final class MenuSurfaceFadeCoordinator {
    private let contentViewProvider: () -> NSView?
    private let closeActiveMenuSurface: () -> Void
    private var fadeInCompletionTask: Task<Void, Never>?
    private var fadeOutCompletionTask: Task<Void, Never>?
    private var fadeGeneration = 0

    init(
        contentViewProvider: @escaping () -> NSView?,
        closeActiveMenuSurface: @escaping () -> Void
    ) {
        self.contentViewProvider = contentViewProvider
        self.closeActiveMenuSurface = closeActiveMenuSurface
    }

    func cancel() {
        fadeInCompletionTask?.cancel()
        fadeInCompletionTask = nil
        fadeOutCompletionTask?.cancel()
        fadeOutCompletionTask = nil
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

        fadeInCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled, fadeGeneration == operationGeneration else {
                return
            }

            resetAlpha()
            fadeInCompletionTask = nil
            completion()
        }
    }

    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) -> Bool {
        guard let contentView else {
            return false
        }

        let operationGeneration = nextGeneration()
        let activeMenuSurfaceWindow = contentView.window
        fade(to: 0, duration: duration)

        fadeOutCompletionTask = Task { @MainActor [weak self, weak contentView, weak activeMenuSurfaceWindow] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled, fadeGeneration == operationGeneration else {
                return
            }

            closeActiveMenuSurface()
            contentView?.alphaValue = 1
            activeMenuSurfaceWindow?.alphaValue = 1
            fadeOutCompletionTask = nil
            completion()
        }

        return true
    }

    private var contentView: NSView? {
        contentViewProvider()
    }

    private func nextGeneration() -> Int {
        fadeGeneration += 1
        return fadeGeneration
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        guard let contentView else {
            return
        }

        let activeMenuSurfaceWindow = contentView.window
        if alpha == 1 {
            activeMenuSurfaceWindow?.alphaValue = 0
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            activeMenuSurfaceWindow?.animator().alphaValue = alpha
            contentView.animator().alphaValue = alpha
        }
    }
}
