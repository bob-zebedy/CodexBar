//
//  AppUpdater.swift
//  CodexBar
//
//  Created by Bob on 2026-06-11.
//

import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var statusMessage: String?
    
    private var updaterController: SPUStandardUpdaterController?
    private var clearStatusMessageTask: Task<Void, Never>?
    
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
        
        showStatusMessage("正在检查更新")
        updaterController.checkForUpdates(nil)
    }
    
    private func showStatusMessage(_ message: String) {
        clearStatusMessageTask?.cancel()
        statusMessage = message
        
        clearStatusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
    
    private static func hasUsableSparkleConfiguration(in bundle: Bundle) -> Bool {
        guard
            let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feedURLString),
            ["https", "http"].contains(feedURL.scheme?.lowercased()),
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.isEmpty
        else {
            return false
        }

        return true
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        showStatusMessage("发现新版本 v\(item.displayVersionString)")
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        showStatusMessage("已是最新版本")
    }
}
