import AppKit
import Testing

struct WindowAnimationTests {
    @Test func disabledDrawerAnimationClearsOldTransformAndCompletesImmediately() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        let animationKey = "test.drawer"
        let animator = SidePanelDrawerAnimator(
            contentViewProvider: { view }, animationKey: animationKey,
            overscan: 0, areAnimationsEnabled: { false }
        )
        animator.setTranslation(100)
        view.layer?.add(CABasicAnimation(keyPath: "transform"), forKey: animationKey)
        var completions = 0
        animator.animateTranslation(to: 0, duration: 1, timing: .easeOut) { completions += 1 }
        #expect(completions == 1)
        #expect(view.layer?.animation(forKey: animationKey) == nil)
        #expect(view.layer?.transform.m41 == 0)
        #expect(view.window == nil)
    }

    @Test func immediateFadeInCancelsOldOpeningAndClosingCompletions() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var closes = 0
        var oldCompletions = 0
        var completions = 0
        let coordinator = MenuSurfaceFadeCoordinator(contentViewProvider: { view }, closeActiveMenuSurface: { closes += 1 })
        coordinator.fadeIn(duration: 0.01) { oldCompletions += 1 }
        coordinator.fadeIn(duration: 0) { completions += 1 }
        #expect(view.alphaValue == 1)
        #expect(completions == 1)
        #expect(coordinator.fadeOut(duration: 0.01) { oldCompletions += 1 })
        coordinator.fadeIn(duration: 0) { completions += 1 }
        #expect(completions == 2)
        try await Task.sleep(for: .milliseconds(30))
        #expect(oldCompletions == 0)
        #expect(closes == 0)
        #expect(view.alphaValue == 1)
        #expect(view.window == nil)
    }
}
