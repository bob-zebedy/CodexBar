import AppKit

/// 菜单面板淡入淡出的集中控制, 新动画取消旧的完成任务
@MainActor
final class MenuSurfaceFadeCoordinator {
    private let contentViewProvider: () -> NSView?
    private let closeActiveMenuSurface: () -> Void
    private var completionTask: Task<Void, Never>?

    init(
        contentViewProvider: @escaping () -> NSView?,
        closeActiveMenuSurface: @escaping () -> Void
    ) {
        self.contentViewProvider = contentViewProvider
        self.closeActiveMenuSurface = closeActiveMenuSurface
    }

    func cancel() {
        completionTask?.cancel()
        completionTask = nil
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
        cancel()
        fade(to: 1, duration: duration)

        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled else {
                return
            }

            resetAlpha()
            completionTask = nil
            completion()
        }
    }

    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) -> Bool {
        cancel()
        guard let contentView else {
            return false
        }

        let activeMenuSurfaceWindow = contentView.window
        fade(to: 0, duration: duration)

        completionTask = Task { @MainActor [weak self, weak contentView, weak activeMenuSurfaceWindow] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, !Task.isCancelled else {
                return
            }

            closeActiveMenuSurface()
            contentView?.alphaValue = 1
            activeMenuSurfaceWindow?.alphaValue = 1
            completionTask = nil
            completion()
        }

        return true
    }

    private var contentView: NSView? {
        contentViewProvider()
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
