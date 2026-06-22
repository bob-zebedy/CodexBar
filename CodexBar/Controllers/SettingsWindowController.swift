import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: HostingWindowController {
    private let viewModel: CodexStatusViewModel
    private let appUpdater: AppUpdater
    private let codexHookSettings: CodexHookSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    
    init(
        viewModel: CodexStatusViewModel,
        appUpdater: AppUpdater,
        codexHookSettings: CodexHookSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        screenProvider: @escaping () -> NSScreen?
    ) {
        self.viewModel = viewModel
        self.appUpdater = appUpdater
        self.codexHookSettings = codexHookSettings
        self.globalHotKeySettings = globalHotKeySettings
        super.init(screenProvider: screenProvider)
    }
    
    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView(
                codexHookSettings: codexHookSettings,
                globalHotKeySettings: globalHotKeySettings
            )
            .environmentObject(viewModel)
            .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = Metrics.minimumContentSize
        return window
    }
    
    override func prepareForDisplay(_ window: NSWindow) {
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        
        if let fittingSize = window.contentViewController?.view.fittingSize,
           fittingSize.width > 0,
           fittingSize.height > 0 {
            window.setContentSize(
                NSSize(
                    width: max(Metrics.minimumContentSize.width, fittingSize.width),
                    height: max(Metrics.minimumContentSize.height, fittingSize.height)
                )
            )
        }
        
        super.prepareForDisplay(window)
    }
    
    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
    }
}
