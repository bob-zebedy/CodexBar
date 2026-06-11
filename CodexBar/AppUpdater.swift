//
//  AppUpdater.swift
//  CodexBar
//
//  Created by Bob on 2026-06-11.
//

import Combine
import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var statusMessage: String?
    
    private var updaterController: SPUStandardUpdaterController?
    private var clearStatusMessageTask: Task<Void, Never>?
    private var hasAvailableUpdate = false
    
    init(bundle: Bundle = .main) {
        super.init()
        
        guard Self.hasUsableSparkleConfiguration(in: bundle) else {
            return
        }
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }
    
    func checkForUpdates() {
        guard let updaterController else {
            showStatusMessage("未配置更新资源")
            return
        }
        
        if hasAvailableUpdate {
            NSApplication.shared.activate()
            updaterController.checkForUpdates(nil)
            return
        }
        
        showStatusMessage("正在检查更新")
        updaterController.updater.checkForUpdateInformation()
    }
    
    private func showStatusMessage(_ message: String, autoDismiss: Bool = true) {
        clearStatusMessageTask?.cancel()
        statusMessage = message

        guard autoDismiss else { return }

        clearStatusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private static func hasUsableSparkleConfiguration(in bundle: Bundle) -> Bool {
        guard
            let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let scheme = URL(string: feedURLString)?.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !publicKey.isEmpty
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        hasAvailableUpdate = true
        showStatusMessage("发现新版本 v\(item.displayVersionString)", autoDismiss: false)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        hasAvailableUpdate = false
        showStatusMessage("已是最新版本")
    }
}
