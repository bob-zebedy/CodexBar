import AppKit
import SwiftUI

@MainActor
final class LicensesWindowController: HostingWindowController {
    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: OpenSourceLicensesView())
        let window = AuxiliaryHostingWindow(contentViewController: hostingController)
        window.title = String(localized: "settings.about.open-source-licenses")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.setContentSize(NSSize(width: 660, height: 640))
        return window
    }
}
