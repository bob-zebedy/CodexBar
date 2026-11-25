import AppKit
import Combine
import SwiftUI

@MainActor
final class BridgeSettingsWindowController: HostingWindowController {
    private static let defaultContentSize = NSSize(width: 726, height: 550)
    private var closeObserver: AnyCancellable?

    override func makeWindow() -> NSWindow {
        let window = AuxiliaryHostingWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = String(localized: "settings.bridge.title")
        window.contentMinSize = NSSize(width: 470, height: 340)
        closeObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak window] _ in window?.contentViewController = nil }
        return window
    }

    override func prepareForDisplay(_ window: NSWindow) {
        guard window.contentViewController == nil else { return }
        let controller = NSHostingController(rootView: BridgeSettingsView())
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(Self.defaultContentSize)
        super.prepareForDisplay(window)
    }
}
