import SwiftUI

struct MenuBarIndicatorSettingsRow: View {
    @ObservedObject var settings: MenuBarIndicatorSettings
    let onOptionsAction: (SettingsOptionsPanelAction) -> Void
    @State private var anchorProvider = ScreenFrameProvider()

    var body: some View {
        SettingsToggleRow(
            icon: "gauge.with.dots.needle.50percent",
            title: "settings.menu-bar-indicator.title",
            help: "settings.menu-bar-indicator.title.help",
            isOn: Binding(
                get: { settings.configuration.isEnabled },
                set: { settings.setEnabled($0) }
            )
        ) {
            SettingsOptionsButton(isAvailable: settings.configuration.isEnabled) {
                onOptionsAction(.toggle(panel: .menuBarIndicator, anchorProvider: anchorProvider))
            }
        }
        .background {
            ScreenFrameReader(provider: anchorProvider)
        }
        .onChange(of: settings.configuration.isEnabled) { _, isEnabled in
            if !isEnabled {
                onOptionsAction(.close(panel: .menuBarIndicator))
            }
        }
    }
}

struct MenuBarIndicatorOptionsView: View {
    @ObservedObject var settings: MenuBarIndicatorSettings
    @ObservedObject var statusViewModel: CodexStatusViewModel
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations

    var body: some View {
        let windows = statusViewModel.snapshot?.codexLimit?.windows ?? []
        let metrics = Array(settings.configuration.metrics(in: windows).enumerated())

        HStack(alignment: .top, spacing: SettingsOptionsPanelMetrics.controlSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHelpLabel(
                    title: "menu-bar-indicator.layout.title",
                    help: "menu-bar-indicator.layout.title.help"
                )
                .frame(height: SettingsOptionsPanelMetrics.rowHeight)

                ForEach(metrics, id: \.offset) { index, _ in
                    SettingsHelpLabel(
                        title: indicatorTitle(at: index),
                        help: indicatorHelp(at: index)
                    )
                    .contentTransition(.opacity)
                    .settingsOptionsReveal(
                        isExpanded: index < settings.configuration.count.rawValue,
                        height: SettingsOptionsPanelMetrics.rowHeight,
                        spacing: SettingsOptionsPanelMetrics.rowSpacing
                    )
                }
            }
            .font(SettingsRowMetrics.captionFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 0) {
                SettingsOptionsPicker(
                    title: "menu-bar-indicator.layout.title",
                    selection: Binding(
                        get: { settings.configuration.count },
                        set: { settings.setCount($0) }
                    ),
                    options: MenuBarIndicatorCount.allCases,
                    label: { $0.title }
                )
                .frame(height: SettingsOptionsPanelMetrics.rowHeight)

                Grid(
                    alignment: .trailing,
                    horizontalSpacing: SettingsOptionsPanelMetrics.controlSpacing,
                    verticalSpacing: 0
                ) {
                    ForEach(metrics, id: \.offset) { index, metric in
                        indicatorControls(index: index, metric: metric)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SettingsOptionsPanelMetrics.horizontalPadding)
        .padding(.vertical, SettingsOptionsPanelMetrics.verticalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            minWidth: SettingsOptionsPanelMetrics.minimumWidth,
            maxWidth: SettingsOptionsPanelMetrics.maximumWidth,
            alignment: .topLeading
        )
        .fixedSize(horizontal: true, vertical: true)
        .settingsOptionsPanel(height: panelHeight)
        .animation(
            allowsAnimations ? SettingsOptionsPanelMetrics.contentAnimation : nil,
            value: settings.configuration.count
        )
    }

    private var panelHeight: CGFloat {
        SettingsOptionsPanelMetrics.height(rowCount: settings.configuration.count.rawValue + 1)
    }

    private func indicatorTitle(at index: Int) -> LocalizedStringResource {
        index == 0
            ? (settings.configuration.count == .one ? "menu-bar-indicator.single" : "menu-bar-indicator.left")
            : "menu-bar-indicator.right"
    }

    private func indicatorHelp(at index: Int) -> LocalizedStringResource {
        index == 0
            ? (settings.configuration.count == .one ? "menu-bar-indicator.single.help" : "menu-bar-indicator.left.help")
            : "menu-bar-indicator.right.help"
    }

    private func indicatorControls(index: Int, metric: MenuBarIndicatorMetric) -> some View {
        let windows = statusViewModel.snapshot?.codexLimit?.windows ?? []
        var windowKinds = windows.map(\.kind)
        if !windowKinds.contains(metric.windowKind) {
            windowKinds.append(metric.windowKind)
        }

        return GridRow {
            SettingsOptionsPicker(
                title: "menu-bar-indicator.metric.title",
                selection: Binding(
                    get: { metric.isResetTime },
                    set: { settings.setMetric(isResetTime: $0, at: index, windows: windows) }
                ),
                options: [false, true],
                label: { $0 ? String(localized: "menu-bar-indicator.metric.time") : String(localized: "menu-bar-indicator.metric.quota") }
            )
            .settingsOptionsReveal(
                isExpanded: index < settings.configuration.count.rawValue,
                height: SettingsOptionsPanelMetrics.rowHeight,
                spacing: SettingsOptionsPanelMetrics.rowSpacing
            )
            Picker(indicatorTitle(at: index), selection: Binding(
                get: { metric.windowKind },
                set: { settings.setMetric(windowKind: $0, at: index, windows: windows) }
            )) {
                ForEach(windowKinds, id: \.self) { kind in
                    let window = windows.first { $0.kind == kind }
                    Text(window?.label ?? (kind == .primary ? "5 Hours" : "Weekly"))
                        .tag(kind)
                        .disabled(window == nil)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(SettingsRowMetrics.controlFont.monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
            .settingsOptionsReveal(
                isExpanded: index < settings.configuration.count.rawValue,
                height: SettingsOptionsPanelMetrics.rowHeight,
                spacing: SettingsOptionsPanelMetrics.rowSpacing
            )
            .gridColumnAlignment(.trailing)
        }
    }
}
