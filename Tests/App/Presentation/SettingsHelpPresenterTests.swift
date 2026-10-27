import AppKit
import Testing

@MainActor
struct SettingsHelpPresenterTests {
    @Test func showsAndHidesSynchronouslyWithoutTakingFocus() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        let previousKeyWindow = NSApplication.shared.keyWindow

        presenter.show("settings.sync.title.help", anchorProvider: anchor)

        let panel = try #require(window.childWindows?.first as? NSPanel)
        #expect(panel.isVisible)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.ignoresMouseEvents)
        #expect(NSApplication.shared.keyWindow === previousKeyWindow)

        presenter.hide()

        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func repeatedHoverReplacesThePreviousPanel() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }

        presenter.show("settings.sync.title.help", anchorProvider: anchor)
        let previousPanel = try #require(window.childWindows?.first)
        presenter.show("settings.keep-alive.title.help", anchorProvider: anchor)

        #expect(!previousPanel.isVisible)
        #expect(previousPanel.parent == nil)
        #expect(window.childWindows?.count == 1)
        #expect(window.childWindows?.first?.isVisible == true)
    }

    @Test(arguments: [
        NSWindow.willCloseNotification,
        NSWindow.willMiniaturizeNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.willMoveNotification,
        NSWindow.didResizeNotification,
        NSApplication.didResignActiveNotification
    ])
    func dismissesWithTheSettingsWindow(_ notification: Notification.Name) throws {
        let window = makeWindow()
        defer { window.close() }
        let options = makeWindow()
        defer {
            window.removeChildWindow(options)
            options.close()
        }
        window.addChildWindow(options, ordered: .above)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        presenter.show("settings.sync.title.help", anchorProvider: makeAnchor(in: options))
        let panel = try #require(options.childWindows?.first)

        NotificationCenter.default.post(name: notification, object: window)

        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }

    @Test func doesNotShowForHiddenOrDetachedAnchors() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        window.orderOut(nil)

        presenter.show("settings.sync.title.help", anchorProvider: anchor)
        #expect(window.childWindows?.isEmpty != false)

        presenter.show("settings.sync.title.help", anchorProvider: ScreenFrameProvider())
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func keepsInitialLayoutReportAndDismissesWhenAnchorMoves() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        presenter.show("settings.sync.title.help", anchorProvider: anchor)
        let panel = try #require(window.childWindows?.first)
        let frame = try #require(anchor.currentScreenFrame(in: window))

        presenter.updateAnchorFrame(frame)
        #expect(panel.isVisible)

        presenter.updateAnchorFrame(frame.offsetBy(dx: 0, dy: 20))
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }

    @Test func hidingTheOwnerRemovesTheTooltipBeforeReopening() throws {
        let window = makeWindow()
        defer { window.close() }
        let presenter = SettingsHelpPresenter()
        defer { presenter.hide() }
        presenter.show("settings.sync.title.help", anchorProvider: makeAnchor(in: window))
        let panel = try #require(window.childWindows?.first)

        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.orderFront(nil)

        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
        #expect(window.childWindows?.isEmpty != false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 470, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
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
