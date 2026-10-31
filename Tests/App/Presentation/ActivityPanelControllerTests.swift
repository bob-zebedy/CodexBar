import AppKit
import Testing

@MainActor
struct ActivityPanelControllerTests {
    @Test func anchorIgnoresTransientViewFramesAndRejectsOtherHosts() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = makeAnchor(in: window)
        let top = try #require(anchor.screenFrame(in: window)).maxY
        let view = try #require(window.contentView?.subviews.first)

        for offset in [-8.0, 4.0, -2.0, 0.0] {
            view.setFrameOrigin(NSPoint(x: 0, y: offset))
            #expect(anchor.screenFrame(in: window)?.maxY == top)
        }
        anchor.updateTopOffset(150)
        #expect(anchor.screenFrame(in: window)?.maxY == top - 30)
        let other = makeWindow()
        defer { other.close() }
        #expect(anchor.screenFrame(in: other) == nil)
        anchor.updateTopOffset(.nan)
        #expect(anchor.screenFrame(in: window) == nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 467, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        #expect(!window.isVisible)
        return window
    }

    private func makeAnchor(in window: NSWindow) -> ActivityCenterPanelAnchor {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 467, height: 100))
        window.contentView?.addSubview(view)
        let anchor = ActivityCenterPanelAnchor()
        anchor.bind(to: view)
        anchor.updateTopOffset(120)
        return anchor
    }
}
