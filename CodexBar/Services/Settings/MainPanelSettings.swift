import Combine
import Foundation
import os

/// 主面板内容偏好
@MainActor
final class MainPanelSettings: ObservableObject {
    @Published private(set) var showsTaskCenter: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsTaskCenter = Self.loadShowsTaskCenter(from: defaults)
    }

    func refresh() {
        let showsTaskCenter = Self.loadShowsTaskCenter(from: defaults)
        guard showsTaskCenter != self.showsTaskCenter else {
            return
        }

        self.showsTaskCenter = showsTaskCenter
    }

    func setShowsTaskCenter(_ showsTaskCenter: Bool) {
        guard showsTaskCenter != self.showsTaskCenter else {
            return
        }

        AppLog.settings.notice("主面板任务中心变更: enabled=\(showsTaskCenter ? 1 : 0)")
        defaults.set(showsTaskCenter, forKey: Self.showsTaskCenterKey)
        self.showsTaskCenter = showsTaskCenter
    }

    private static func loadShowsTaskCenter(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: showsTaskCenterKey) != nil else {
            return true
        }

        return defaults.bool(forKey: showsTaskCenterKey)
    }

    private static let showsTaskCenterKey = "MainPanel.showsTaskCenter"
}
