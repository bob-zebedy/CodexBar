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
    @Published private(set) var settingsStatusMessage: String?
    @Published private(set) var panelUpdateMessage: String?
    @Published private(set) var availableUpdateMessage: String?
    @Published private(set) var automaticallyChecksForUpdates = false

    var canConfigureAutomaticChecks: Bool { updaterController != nil }

    private var updaterController: SPUStandardUpdaterController?
    private var clearSettingsStatusMessageTask: Task<Void, Never>?
    private var isManualCheckInProgress = false
    
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
        refreshAutomaticCheckSetting()
    }
    
    func checkForUpdates() {
        guard let updaterController else {
            showSettingsStatusMessage("未配置更新资源")
            return
        }
        
        if let availableUpdateMessage {
            showSettingsStatusMessage(availableUpdateMessage, autoDismissDelay: nil)
            return
        }
        
        isManualCheckInProgress = true
        showSettingsStatusMessage("正在检查更新")
        updaterController.updater.checkForUpdateInformation()
    }
    
    func startUpdate() {
        guard let updaterController else {
            showSettingsStatusMessage("未配置更新资源")
            return
        }
        
        NSApplication.shared.activate()
        updaterController.checkForUpdates(nil)
    }
    
    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        guard let updaterController else {
            automaticallyChecksForUpdates = false
            showSettingsStatusMessage("未配置更新资源")
            return
        }
        
        updaterController.updater.automaticallyChecksForUpdates = isEnabled
        refreshAutomaticCheckSetting()
    }
    
    func refreshAutomaticCheckSetting() {
        automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
    }
    
    private func showSettingsStatusMessage(_ message: String, autoDismissDelay: Duration? = .seconds(3)) {
        clearSettingsStatusMessageTask?.cancel()
        settingsStatusMessage = message
        
        guard let autoDismissDelay else { return }
        
        clearSettingsStatusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.settingsStatusMessage = nil
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
        let message = "发现新版本: v\(item.displayVersionString)"
        availableUpdateMessage = message
        
        if isManualCheckInProgress {
            showSettingsStatusMessage(message, autoDismissDelay: nil)
        } else {
            panelUpdateMessage = message
        }
        
        isManualCheckInProgress = false
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableUpdateMessage = nil
        panelUpdateMessage = nil
        
        if isManualCheckInProgress {
            showSettingsStatusMessage("已是最新版本", autoDismissDelay: .milliseconds(1500))
        }
        
        isManualCheckInProgress = false
    }
}
