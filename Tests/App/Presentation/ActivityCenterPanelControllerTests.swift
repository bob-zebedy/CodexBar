import AppKit
import Combine
import Testing

@MainActor
struct ActivityCenterPanelControllerTests {
    @Test func resizeRealignsChildBeforeTheNextFrame() async throws {
        let host = makeWindow()
        let child = makeWindow()
        defer {
            host.removeChildWindow(child)
            child.close()
            host.close()
        }
        let anchor = makeAnchor(in: host)
        let original = host.frame
        let top = try #require(anchor.screenFrame(in: host)).maxY
        child.setFrame(NSRect(x: 600, y: top - 180, width: 200, height: 180), display: false)
        host.addChildWindow(child, ordered: .above)
        let subscription = anchor.layoutChanges(in: host).sink {
            if let target = anchor.screenFrame(in: host), child.frame.maxY != target.maxY {
                child.setFrameTopLeftPoint(NSPoint(x: child.frame.minX, y: target.maxY))
            }
        }
        defer { subscription.cancel() }

        for offset: CGFloat in [-8, 8, -1, 1] {
            // 移动父窗口的原点会带动子窗口, 随后调整父窗口高度让顶边回到原位
            let y = host.frame.minY + offset
            host.setFrameOrigin(NSPoint(x: original.minX, y: y))
            #expect(child.frame.maxY == top + offset)
            host.setFrame(NSRect(x: original.minX, y: y, width: original.width, height: original.maxY - y), display: false)
            #expect(child.frame.maxY == top)
        }

        host.setFrameOrigin(NSPoint(x: original.minX, y: original.minY + 24))
        #expect(child.frame.maxY == top + 24)
        anchor.updateTopOffset(150)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(child.frame.maxY == top + 24 - 30)
        #expect(!host.isVisible && !child.isVisible)
    }

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
