import AppKit
import Testing

@MainActor
struct SettingsHelpPresenterTests {
    @Test func doesNotShowForHiddenOrDetachedAnchors() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        #expect(!window.isVisible)

        presenter.show("settings.sync.title.help", anchorProvider: anchor)
        #expect(window.childWindows?.isEmpty != false)

        presenter.show("settings.sync.title.help", anchorProvider: ScreenFrameProvider())
        #expect(window.childWindows?.isEmpty != false)
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
