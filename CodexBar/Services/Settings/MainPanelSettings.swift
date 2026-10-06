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
}

/// 主面板区域布局与动画效果偏好
@MainActor
final class MainPanelSettings: ObservableObject {
    @Published private(set) var layout: MainPanelLayout
    @Published private(set) var areAnimationsEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = Self.loadLayout(from: defaults)
        areAnimationsEnabled = Self.loadAnimationsEnabled(from: defaults)
    }

    func refresh() {
        let loadedAnimationsEnabled = Self.loadAnimationsEnabled(from: defaults)
        if loadedAnimationsEnabled != areAnimationsEnabled {
            areAnimationsEnabled = loadedAnimationsEnabled
        }

        publish(Self.loadLayout(from: defaults))
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        guard enabled != areAnimationsEnabled else {
            return
        }

        AppLog.settings.notice("动画效果变更: enabled=\(enabled ? 1 : 0)")
        defaults.set(enabled, forKey: Self.animationsEnabledKey)
        areAnimationsEnabled = enabled
    }

    func setSection(
        _ section: MainPanelSection,
        isVisible: Bool,
        undoManager: UndoManager
    ) {
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
        let updatedLayout = requestedLayout
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

    private static func loadAnimationsEnabled(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: animationsEnabledKey) != nil else {
            return true
        }

        return defaults.bool(forKey: animationsEnabledKey)
    }

    private static func orderLogValue(for layout: MainPanelLayout) -> String {
        layout.orderedSections.map(\.rawValue).joined(separator: ",")
    }

    private static let sectionOrderKey = "MainPanel.sectionOrder"
    private static let hiddenSectionsKey = "MainPanel.hiddenSections"
    private static let animationsEnabledKey = "MainPanel.entranceAnimationsEnabled"
}
