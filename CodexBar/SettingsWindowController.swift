//
//  SettingsWindowController.swift
//  CodexBar
//
//  Created by Bob on 2026-06-14.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let appUpdater: AppUpdater
    private let screenProvider: () -> NSScreen?
    private var window: NSWindow?

    init(appUpdater: AppUpdater, screenProvider: @escaping () -> NSScreen?) {
        self.appUpdater = appUpdater
        self.screenProvider = screenProvider
    }

    func open() {
        if window == nil {
            window = makeWindow()
        }

        guard let window else {
            return
        }

        NSApplication.shared.activate()
        prepareForDisplay(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView()
                .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = Metrics.minimumContentSize
        return window
    }

    private func prepareForDisplay(_ window: NSWindow) {
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

        center(window)
    }

    private func center(_ window: NSWindow) {
        guard let screen = screenProvider() ?? window.screen ?? NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - windowFrame.width / 2,
            y: visibleFrame.midY - windowFrame.height / 2
        )

        window.setFrameOrigin(origin)
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
    }
}
