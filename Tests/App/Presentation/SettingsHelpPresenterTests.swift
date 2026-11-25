import AppKit
import Testing

@MainActor
struct SettingsHelpPresenterTests {
    @Test func doesNotShowForAnAnchorInAHiddenWindow() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        #expect(!window.isVisible)

        presenter.show("settings.sync.title.help", anchorProvider: anchor)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func readingAnchorCoordinatesDoesNotRequestAnotherLayout() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = LayoutCountingView(frame: CGRect(x: 12, y: 20, width: 18, height: 18))
        window.contentView?.addSubview(anchor)
        let provider = ScreenFrameProvider()
        provider.bind(to: anchor)
        let expected = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let layouts = anchor.layoutRequests
        #expect(provider.currentScreenFrame(in: window) == expected)
        #expect(anchor.layoutRequests == layouts)
    }

    private final class LayoutCountingView: NSView {
        private(set) var layoutRequests = 0

        override func layoutSubtreeIfNeeded() {
            layoutRequests += 1
            super.layoutSubtreeIfNeeded()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 470, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeAnchor(in window: NSWindow) -> ScreenFrameProvider {
        let view = NSView(frame: NSRect(x: 40, y: 240, width: 18, height: 18))
        window.contentView?.addSubview(view)
        let provider = ScreenFrameProvider()
        provider.bind(to: view)
        return provider
    }
}
