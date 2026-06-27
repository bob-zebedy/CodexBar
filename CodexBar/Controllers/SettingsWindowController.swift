import AppKit
import SwiftUI

/// 设置窗口控制器, 打开前刷新设置状态并按内容自适应高度
@MainActor
final class SettingsWindowController: HostingWindowController {
    private let viewModel: CodexStatusViewModel
    private let appUpdater: AppUpdater
    private let codexHookSettings: CodexHookSettings
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let onSyncChanged: (Bool) -> Void

    init(
        viewModel: CodexStatusViewModel,
        appUpdater: AppUpdater,
        codexHookSettings: CodexHookSettings,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        screenProvider: @escaping () -> NSScreen?,
        onSyncChanged: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.appUpdater = appUpdater
        self.codexHookSettings = codexHookSettings
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.onSyncChanged = onSyncChanged
        super.init(screenProvider: screenProvider)
    }

    override func open() {
        refreshSettingsState()
        super.open()
    }

    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView(
                codexHookSettings: codexHookSettings,
                syncSettings: syncSettings,
                globalHotKeySettings: globalHotKeySettings,
                onSyncChanged: onSyncChanged
            )
            .environmentObject(viewModel)
            .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = AuxiliaryHostingWindow(contentViewController: hostingController)
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

    private func refreshSettingsState() {
        codexHookSettings.refresh()
        codexHookSettings.verifyInstalledHooks()
        syncSettings.refresh()
    }
}
