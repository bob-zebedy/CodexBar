import SwiftUI

/// 防休眠子选项面板, 挂在设置窗口右侧, 顶边对齐设置页的防休眠主开关行
/// 行样式与度量沿用通知子面板, 只有面板宽度按内容收窄
struct KeepAliveOptionsView: View {
    @ObservedObject var keepAliveController: KeepAliveController

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            maximumDurationRow

            // 台式机读不到电池, 这一行整个收起而不是置灰
            if keepAliveController.hasBattery {
                lowBatteryRow
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
    }

    /// 按有电池时的最大内容给初始值, 实际高度在展开前由 fitting size 覆盖
    static var initialPanelSize: CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + (Metrics.rowHeight + Metrics.captionRowHeight) * 2
                + Metrics.rowSpacing
        )
    }

    private var maximumDurationRow: some View {
        pickerRow(
            title: "最长防休眠时间",
            caption: "防休眠时长超过阈值后自动恢复系统休眠",
            selection: Binding(
                get: { keepAliveController.maximumDuration },
                set: { keepAliveController.setMaximumDuration($0) }
            ),
            options: KeepAliveController.MaximumDuration.allCases,
            label: \.title
        )
    }

    private var lowBatteryRow: some View {
        pickerRow(
            title: "低电量保护",
            caption: "仅在使用电池供电时生效, 充电时自动恢复",
            selection: Binding(
                get: { keepAliveController.lowBatteryThreshold },
                set: { keepAliveController.setLowBatteryThreshold($0) }
            ),
            options: KeepAliveController.LowBatteryThreshold.allCases,
            label: \.title
        )
    }

    /// 第二行的固定说明与通知子面板的音效子行同一套字号和层级
    private func pickerRow<Option: Hashable>(
        title: String,
        caption: String,
        selection: Binding<Option>,
        options: [Option],
        label: KeyPath<Option, String>
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.controlSpacing) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                SettingsOptionsPicker(
                    title: title,
                    selection: selection,
                    options: options,
                    label: { $0[keyPath: label] },
                    width: Metrics.pickerWidth,
                    alignment: .trailing
                )
            }
            .frame(height: Metrics.rowHeight)

            HStack(spacing: 0) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
            .frame(height: Metrics.captionRowHeight)
        }
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 250
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowSpacing = SettingsOptionsPanelMetrics.rowSpacing
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let captionRowHeight = SettingsOptionsPanelMetrics.secondaryRowHeight
        static let controlSpacing = SettingsOptionsPanelMetrics.controlSpacing
        static let pickerWidth: CGFloat = 88
        static let cornerRadius = SettingsOptionsPanelMetrics.cornerRadius
    }
}
