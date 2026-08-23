import Foundation
import SwiftUI

/// 通用设置页中的主面板布局入口, 自己持有定位锚点
struct MainPanelLayoutSettingsRow: View {
    let onOptionsTap: (ScreenFrameProvider) -> Void
    @State private var anchorProvider = ScreenFrameProvider()

    var body: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "rectangle.3.group")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text("settings.main-panel.layout.title")

            Spacer()

            SettingsOptionsButton {
                onOptionsTap(anchorProvider)
            }
        }
        .background {
            ScreenFrameReader(provider: anchorProvider)
        }
    }
}

/// 主面板布局子选项, 拖放调整区域顺序并控制显隐
struct MainPanelOptionsView: View {
    @ObservedObject var settings: MainPanelSettings
    @ObservedObject var codexHookSettings: CodexHookSettings
    let undoManager: UndoManager
    @State private var dragState: SectionDragState?
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(displayedSections.enumerated()), id: \.element) { index, section in
                    if index > 0 {
                        LiquidGlassDivider()
                    }

                    sectionRow(section)
                        .opacity(dragState?.section == section ? 0 : 1)
                }
            }
            .animation(Metrics.reorderAnimation, value: displayedSections)

            if let dragState {
                sectionRow(dragState.section)
                    .frame(maxWidth: .infinity)
                    .liquidGlassSurface(cornerRadius: Metrics.draggedCornerRadius)
                    .shadow(
                        color: .black.opacity(Metrics.draggedShadowOpacity),
                        radius: Metrics.draggedShadowRadius,
                        y: Metrics.draggedShadowY
                    )
                    .offset(
                        y: CGFloat(dragState.originIndex) * Metrics.rowStride
                            + dragTranslation
                    )
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
        .onDisappear {
            dragState = nil
            dragTranslation = 0
        }
    }

    static var initialPanelSize: CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + Metrics.rowHeight * CGFloat(MainPanelSection.allCases.count)
                + Metrics.dividerHeight * CGFloat(MainPanelSection.allCases.count - 1)
        )
    }

    private func sectionRow(_ section: MainPanelSection) -> some View {
        let isAvailable = section != .activity || codexHookSettings.isEnabled
        let isVisible = isAvailable && settings.layout.isVisible(section)
        let visibleSectionCount = settings.layout.visibleSections.filter { visibleSection in
            visibleSection != .activity || codexHookSettings.isEnabled
        }.count
        let canToggle = isAvailable && (!isVisible || visibleSectionCount > 1)

        return HStack(spacing: Metrics.controlSpacing) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: Metrics.dragHandleWidth, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .gesture(sectionDragGesture(for: section))

            Image(systemName: section.symbolName)
                .foregroundStyle(.tint)
                .frame(width: Metrics.sectionIconWidth)

            Text(section.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Toggle(
                section.title,
                isOn: Binding(
                    get: {
                        (section != .activity || codexHookSettings.isEnabled)
                            && settings.layout.isVisible(section)
                    },
                    set: {
                        settings.setSection(
                            section,
                            isVisible: $0,
                            undoManager: undoManager
                        )
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!canToggle)
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Metrics.rowHorizontalPadding)
    }

    private var displayedSections: [MainPanelSection] {
        dragState?.displayedSections ?? settings.layout.orderedSections
    }

    private func sectionDragGesture(for section: MainPanelSection) -> some Gesture {
        DragGesture(
            minimumDistance: Metrics.dragMinimumDistance,
            coordinateSpace: .global
        )
        .onChanged { value in
            updateDrag(section: section, translation: value.translation.height)
        }
        .onEnded { _ in
            finishDrag(section: section)
        }
    }

    private func updateDrag(section: MainPanelSection, translation: CGFloat) {
        if dragState?.section != section || dragState?.isSettling == true {
            beginDrag(section)
        }
        guard var dragState, dragState.section == section else {
            return
        }

        dragTranslation = translation
        let indexOffset = Int((translation / Metrics.rowStride).rounded())
        let targetIndex = min(
            max(dragState.originIndex + indexOffset, 0),
            dragState.initialSections.count - 1
        )
        guard targetIndex != dragState.targetIndex else {
            return
        }

        dragState.targetIndex = targetIndex
        self.dragState = dragState
    }

    private func beginDrag(_ section: MainPanelSection) {
        let initialSections = settings.layout.orderedSections
        guard let originIndex = initialSections.firstIndex(of: section) else {
            return
        }

        dragTranslation = 0
        dragState = SectionDragState(
            section: section,
            originIndex: originIndex,
            targetIndex: originIndex,
            initialSections: initialSections
        )
    }

    private func finishDrag(section: MainPanelSection) {
        guard var dragState, dragState.section == section else {
            return
        }

        settings.setSectionOrder(
            dragState.displayedSections,
            undoManager: undoManager
        )
        dragState.isSettling = true
        self.dragState = dragState
        let dragID = dragState.id
        withAnimation(
            Metrics.settleAnimation,
            completionCriteria: .logicallyComplete
        ) {
            dragTranslation = CGFloat(dragState.targetIndex - dragState.originIndex)
                * Metrics.rowStride
        } completion: {
            guard self.dragState?.id == dragID else {
                return
            }

            self.dragState = nil
            dragTranslation = 0
        }
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 270
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowHeight: CGFloat = 28
        static let dividerHeight: CGFloat = 1
        static let rowStride = rowHeight + dividerHeight
        static let controlSpacing = SettingsOptionsPanelMetrics.controlSpacing
        static let dragHandleWidth: CGFloat = 16
        static let sectionIconWidth: CGFloat = 18
        static let rowHorizontalPadding: CGFloat = 2
        static let dragMinimumDistance: CGFloat = 2
        static let draggedCornerRadius: CGFloat = 7
        static let draggedShadowOpacity = 0.24
        static let draggedShadowRadius: CGFloat = 7
        static let draggedShadowY: CGFloat = 3
        static let reorderAnimation = Animation.smooth(duration: 0.18)
        static let settleAnimation = Animation.smooth(duration: 0.14)
        static let cornerRadius = SettingsOptionsPanelMetrics.cornerRadius
    }
}

private struct SectionDragState {
    let id = UUID()
    let section: MainPanelSection
    let originIndex: Int
    var targetIndex: Int
    let initialSections: [MainPanelSection]
    var isSettling = false

    var displayedSections: [MainPanelSection] {
        var sections = initialSections
        sections.remove(at: originIndex)
        sections.insert(section, at: targetIndex)
        return sections
    }
}

private extension MainPanelSection {
    var title: LocalizedStringResource {
        switch self {
        case .account:
            "settings.main-panel.section.account"
        case .activity:
            "settings.main-panel.section.activity"
        case .quota:
            "settings.main-panel.section.quota"
        case .usage:
            "settings.main-panel.section.usage"
        case .status:
            "settings.main-panel.section.status"
        }
    }

    var symbolName: String {
        switch self {
        case .account:
            "person.fill"
        case .activity:
            "list.bullet.rectangle"
        case .quota:
            "gauge.with.dots.needle.50percent"
        case .usage:
            "chart.bar.xaxis"
        case .status:
            "clock"
        }
    }
}
