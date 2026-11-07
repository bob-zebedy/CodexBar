import SwiftUI

/// 自动重置子选项面板, 顶边对齐设置页的自动重置主开关行
struct AutoResetOptionsView: View {
    @ObservedObject var settings: AutoResetSettings

    var body: some View {
        HStack(spacing: Metrics.controlSpacing) {
            SettingsHelpLabel(title: "auto-reset.lead-time.title", help: "auto-reset.lead-time.title.help")
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            SettingsOptionsPicker(
                title: "auto-reset.lead-time.title",
                selection: Binding(
                    get: { settings.leadTime },
                    set: { settings.setLeadTime($0) }
                ),
                options: AutoResetLeadTime.allCases,
                label: { $0.title }
            )
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(
            minWidth: SettingsOptionsPanelMetrics.minimumWidth,
            maxWidth: SettingsOptionsPanelMetrics.maximumWidth,
            alignment: .topLeading
        )
        .fixedSize(horizontal: true, vertical: true)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
    }

    private enum Metrics {
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let controlSpacing = SettingsOptionsPanelMetrics.controlSpacing

        static let cornerRadius = SettingsOptionsPanelMetrics.cornerRadius
    }
}
