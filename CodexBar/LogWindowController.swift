import AppKit
import SwiftUI

@MainActor
final class LogWindowController: HostingWindowController {
    private let store: RequestLogStore
    
    init(
        store: RequestLogStore = .shared,
        screenProvider: @escaping () -> NSScreen?
    ) {
        self.store = store
        super.init(screenProvider: screenProvider)
    }
    
    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: LogView(store: store))
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexBar 日志"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = Metrics.minimumContentSize
        window.setContentSize(Metrics.defaultContentSize)
        return window
    }
    
    private enum Metrics {
        static let minimumContentSize = NSSize(width: 640, height: 480)
        static let defaultContentSize = NSSize(width: 900, height: 680)
    }
}
