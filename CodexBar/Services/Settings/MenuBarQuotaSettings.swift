import Combine
import Foundation

/// 菜单栏额度指示偏好
@MainActor
final class MenuBarQuotaSettings: ObservableObject {
    @Published private(set) var selection: MenuBarQuotaSelection

    /// 关闭指示前最后一次选中的窗口, 重新开启时恢复; 随偏好持久化
    private var lastWindowSelection: MenuBarQuotaSelection
    private let defaults: UserDefaults
    private var pendingSelection: MenuBarQuotaSelection?
    private var publishSelectionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let selection = Self.loadSelection(from: defaults)
        self.selection = selection
        lastWindowSelection = Self.loadLastWindowSelection(from: defaults, current: selection)
    }

    deinit {
        publishSelectionTask?.cancel()
    }

    func refresh() {
        let selection = Self.loadSelection(from: defaults)
        rememberLastWindowSelection(selection)
        publishSelection(selection)
    }

    func setSelection(_ selection: MenuBarQuotaSelection) {
        rememberLastWindowSelection(selection)
        guard selection != effectiveSelection else {
            return
        }

        saveSelection(selection)
        publishSelection(selection)
    }

    func setEnabled(_ enabled: Bool) {
        setSelection(enabled ? lastWindowSelection : .off)
    }

    /// 供设置页 Picker 展示的窗口选择: 关闭时回退到最后一次的非 off 选择
    var activeWindowSelection: MenuBarQuotaSelection {
        selection == .off ? lastWindowSelection : selection
    }

    private func rememberLastWindowSelection(_ selection: MenuBarQuotaSelection) {
        guard selection != .off, selection != lastWindowSelection else {
            return
        }

        lastWindowSelection = selection
        defaults.set(selection.rawValue, forKey: Self.lastWindowSelectionKey)
    }

    private var effectiveSelection: MenuBarQuotaSelection {
        pendingSelection ?? selection
    }

    private func saveSelection(_ selection: MenuBarQuotaSelection) {
        defaults.set(selection.rawValue, forKey: Self.selectionKey)
    }

    private func publishSelection(_ selection: MenuBarQuotaSelection) {
        publishSelectionTask?.cancel()
        publishSelectionTask = nil
        pendingSelection = nil

        guard selection != self.selection else {
            return
        }

        pendingSelection = selection
        publishSelectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else {
                return
            }

            self.selection = selection
            pendingSelection = nil
            publishSelectionTask = nil
        }
    }

    private static func loadSelection(from defaults: UserDefaults) -> MenuBarQuotaSelection {
        guard let rawValue = defaults.string(forKey: selectionKey),
              let selection = MenuBarQuotaSelection(rawValue: rawValue) else {
            return .primary
        }

        return selection
    }

    private static func loadLastWindowSelection(
        from defaults: UserDefaults,
        current: MenuBarQuotaSelection
    ) -> MenuBarQuotaSelection {
        if let rawValue = defaults.string(forKey: lastWindowSelectionKey),
           let selection = MenuBarQuotaSelection(rawValue: rawValue),
           selection != .off {
            return selection
        }

        return current == .off ? .primary : current
    }

    private static let selectionKey = "MenuBarQuota.selection"
    private static let lastWindowSelectionKey = "MenuBarQuota.lastWindowSelection"
}

nonisolated enum MenuBarQuotaSelection: String, CaseIterable, Identifiable {
    case off
    case primary
    case secondary

    var id: String {
        rawValue
    }

    init?(windowId: String) {
        switch windowId {
        case "primary":
            self = .primary
        case "secondary":
            self = .secondary
        default:
            return nil
        }
    }

    var fallbackTitle: String {
        switch self {
        case .off:
            "off"
        case .primary:
            "primary"
        case .secondary:
            "secondary"
        }
    }

    var windowId: String? {
        switch self {
        case .off:
            nil
        case .primary:
            "primary"
        case .secondary:
            "secondary"
        }
    }
}
