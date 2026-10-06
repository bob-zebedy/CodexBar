import AppKit
import SwiftUI

/// 日志窗口控制器, 日志持续写入本地, 仅在窗口打开时读取显示内容
@MainActor
final class LogWindowController: HostingWindowController {
    private var closeObserver: (any NSObjectProtocol)?
    private let store: AppServerLogViewModel

    init(
        store: AppServerLogViewModel = .shared,
        screenProvider: @escaping () -> NSScreen?
    ) {
        self.store = store
        super.init(screenProvider: screenProvider)
    }

    override func open() {
        super.open()
        store.start()
    }

    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: LogView(store: store))

        let window = AuxiliaryHostingWindow(contentViewController: hostingController)
        window.title = String(localized: "log.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = Metrics.minimumContentSize
        window.setContentSize(Metrics.defaultContentSize)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.stop() }
        }
        return window
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 640, height: 480)
        static let defaultContentSize = NSSize(width: 900, height: 680)
    }
}
