import SwiftUI

/// 自动使用重置子选项面板, 顶边对齐设置页的自动使用主开关行
struct ResetCreditAutomationOptionsView: View {
    @ObservedObject var settings: ResetCreditAutomationSettings

    var body: some View {
        HStack(spacing: Metrics.controlSpacing) {
            Text("临期时间")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            SettingsOptionsPicker(
                title: "临期时间",
                selection: Binding(
                    get: { settings.leadTime },
                    set: { settings.setLeadTime($0) }
                ),
                options: ResetCreditAutomationLeadTime.allCases,
                label: { $0.title },
                width: Metrics.pickerWidth,
                alignment: .trailing
            )
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
    }

    static var initialPanelSize: CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + Metrics.rowHeight
        )
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 250
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let controlSpacing = SettingsOptionsPanelMetrics.controlSpacing
        static let pickerWidth: CGFloat = 88
        static let cornerRadius = SettingsOptionsPanelMetrics.cornerRadius
    }
}
