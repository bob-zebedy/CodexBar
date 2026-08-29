import Combine
import Foundation
import os

nonisolated enum MainPanelSection: String, CaseIterable, Identifiable, Sendable {
    case account
    case activity
    case quota
    case usage
    case status

    var id: Self {
        self
    }
}

nonisolated struct MainPanelLayout: Equatable, Sendable {
    let orderedSections: [MainPanelSection]
    let hiddenSections: Set<MainPanelSection>

    init(
        orderedSections: [MainPanelSection],
        hiddenSections: Set<MainPanelSection>
    ) {
        var seenSections = Set<MainPanelSection>()
        var normalizedOrder = orderedSections.filter { seenSections.insert($0).inserted }
        normalizedOrder.append(
            contentsOf: MainPanelSection.allCases.filter { seenSections.insert($0).inserted }
        )

        var normalizedHiddenSections = hiddenSections
        if normalizedHiddenSections.count == normalizedOrder.count,
           let firstSection = normalizedOrder.first {
            normalizedHiddenSections.remove(firstSection)
        }

        self.orderedSections = normalizedOrder
        self.hiddenSections = normalizedHiddenSections
    }

    var visibleSections: [MainPanelSection] {
        orderedSections.filter { !hiddenSections.contains($0) }
    }

    func isVisible(_ section: MainPanelSection) -> Bool {
        !hiddenSections.contains(section)
    }

    func disablingActivitySection() -> MainPanelLayout {
        var hiddenSections = hiddenSections
        hiddenSections.insert(.activity)

        if orderedSections.allSatisfy(hiddenSections.contains) {
            hiddenSections.remove(.account)
        }

        return MainPanelLayout(
            orderedSections: orderedSections,
            hiddenSections: hiddenSections
        )
    }
}

/// 主面板区域布局与动画效果偏好
@MainActor
final class MainPanelSettings: ObservableObject {
    @Published private(set) var layout: MainPanelLayout
    @Published private(set) var areEntranceAnimationsEnabled: Bool

    private let defaults: UserDefaults
    private var isHookEnabled: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = Self.loadLayout(from: defaults)
        areEntranceAnimationsEnabled = Self.loadEntranceAnimationsEnabled(from: defaults)
    }

    func refresh() {
        let loadedEntranceAnimationsEnabled = Self.loadEntranceAnimationsEnabled(from: defaults)
        if loadedEntranceAnimationsEnabled != areEntranceAnimationsEnabled {
            areEntranceAnimationsEnabled = loadedEntranceAnimationsEnabled
        }

        let loadedLayout = Self.loadLayout(from: defaults)
        guard isHookEnabled == false else {
            publish(loadedLayout)
            return
        }

        let updatedLayout = loadedLayout.disablingActivitySection()
        if updatedLayout == loadedLayout {
            publish(updatedLayout)
        } else {
            saveAndPublish(updatedLayout)
        }
    }

    func updateHookEnabled(_ isEnabled: Bool) {
        isHookEnabled = isEnabled
        guard !isEnabled else {
            return
        }

        let updatedLayout = layout.disablingActivitySection()
        guard updatedLayout != layout else {
            return
        }

        AppLog.settings.notice("Hook 关闭已同步主面板任务中心")
        saveAndPublish(updatedLayout)
    }

    func setEntranceAnimationsEnabled(_ enabled: Bool) {
        guard enabled != areEntranceAnimationsEnabled else {
            return
        }

        AppLog.settings.notice("动画效果变更: enabled=\(enabled ? 1 : 0)")
        defaults.set(enabled, forKey: Self.entranceAnimationsEnabledKey)
        areEntranceAnimationsEnabled = enabled
    }

    func setSection(
        _ section: MainPanelSection,
        isVisible: Bool,
        undoManager: UndoManager
    ) {
        guard section != .activity || !isVisible || isHookEnabled == true else {
            return
        }
        guard layout.isVisible(section) != isVisible else {
            return
        }
        guard isVisible || layout.visibleSections.count > 1 else {
            return
        }

        var hiddenSections = layout.hiddenSections
        if isVisible {
            hiddenSections.remove(section)
        } else {
            hiddenSections.insert(section)
        }

        AppLog.settings.notice(
            "主面板区域显隐变更: section=\(section.rawValue, privacy: .public); visible=\(isVisible ? 1 : 0)"
        )
        applyUndoableLayout(
            MainPanelLayout(
                orderedSections: layout.orderedSections,
                hiddenSections: hiddenSections
            ),
            undoManager: undoManager
        )
    }

    func setSectionOrder(
        _ orderedSections: [MainPanelSection],
        undoManager: UndoManager
    ) {
        let updatedLayout = MainPanelLayout(
            orderedSections: orderedSections,
            hiddenSections: layout.hiddenSections
        )
        guard updatedLayout != layout else {
            return
        }

        AppLog.settings.notice(
            "主面板区域顺序变更: order=\(Self.orderLogValue(for: updatedLayout), privacy: .public)"
        )
        applyUndoableLayout(updatedLayout, undoManager: undoManager)
    }

    private func applyUndoableLayout(
        _ requestedLayout: MainPanelLayout,
        undoManager: UndoManager
    ) {
        let updatedLayout = isHookEnabled == false
            ? requestedLayout.disablingActivitySection()
            : requestedLayout
        guard updatedLayout != layout else {
            return
        }

        let previousLayout = layout
        saveAndPublish(updatedLayout)
        undoManager.registerUndo(withTarget: self) { [weak undoManager] settings in
            guard let undoManager else {
                return
            }

            settings.applyUndoableLayout(previousLayout, undoManager: undoManager)
        }
        undoManager.setActionName(String(localized: "settings.main-panel.layout.title"))
    }

    private func saveAndPublish(_ layout: MainPanelLayout) {
        defaults.set(
            layout.orderedSections.map(\.rawValue),
            forKey: Self.sectionOrderKey
        )
        defaults.set(
            layout.hiddenSections.map(\.rawValue).sorted(),
            forKey: Self.hiddenSectionsKey
        )
        publish(layout)
    }

    private func publish(_ layout: MainPanelLayout) {
        guard layout != self.layout else {
            return
        }

        self.layout = layout
    }

    private static func loadLayout(from defaults: UserDefaults) -> MainPanelLayout {
        let orderedSections = defaults.stringArray(forKey: sectionOrderKey)?
            .compactMap(MainPanelSection.init(rawValue:)) ?? MainPanelSection.allCases
        let hiddenSections = Set(
            defaults.stringArray(forKey: hiddenSectionsKey)?
                .compactMap(MainPanelSection.init(rawValue:)) ?? []
        )
        return MainPanelLayout(
            orderedSections: orderedSections,
            hiddenSections: hiddenSections
        )
    }

    private static func loadEntranceAnimationsEnabled(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: entranceAnimationsEnabledKey) != nil else {
            return true
        }

        return defaults.bool(forKey: entranceAnimationsEnabledKey)
    }

    private static func orderLogValue(for layout: MainPanelLayout) -> String {
        layout.orderedSections.map(\.rawValue).joined(separator: ",")
    }

    private static let sectionOrderKey = "MainPanel.sectionOrder"
    private static let hiddenSectionsKey = "MainPanel.hiddenSections"
    private static let entranceAnimationsEnabledKey = "MainPanel.entranceAnimationsEnabled"
}
