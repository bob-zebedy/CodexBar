import Combine
import Foundation

/// 菜单栏额度指示偏好
@MainActor
final class MenuBarQuotaSettings: ObservableObject {
    @Published private(set) var selection: MenuBarQuotaSelection

    private let defaults: UserDefaults
    private var pendingSelection: MenuBarQuotaSelection?
    private var publishSelectionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = Self.loadSelection(from: defaults)
    }

    deinit {
        publishSelectionTask?.cancel()
    }

    func refresh() {
        publishSelection(Self.loadSelection(from: defaults))
    }

    func setSelection(_ selection: MenuBarQuotaSelection) {
        guard selection != effectiveSelection else {
            return
        }

        saveSelection(selection)
        publishSelection(selection)
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

    private static let selectionKey = "MenuBarQuota.selection"
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
