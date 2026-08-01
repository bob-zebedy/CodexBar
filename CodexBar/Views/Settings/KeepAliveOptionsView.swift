import SwiftUI

/// 防睡眠子选项面板, 挂在设置窗口右侧, 顶边对齐设置页的防睡眠主开关行
/// 行样式与度量沿用通知子面板, 只有面板宽度按内容收窄
struct KeepAliveOptionsView: View {
    @ObservedObject var keepAliveController: KeepAliveController

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            waitingApprovalRow
            displayAwakeRow
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
                + (Metrics.rowHeight + Metrics.captionRowHeight) * CGFloat(Metrics.maximumRowCount)
                + Metrics.rowSpacing * CGFloat(Metrics.maximumRowCount - 1)
        )
    }

    private var maximumDurationRow: some View {
        pickerRow(
            title: "最长防睡眠时间",
            caption: "防睡眠时长超过阈值后自动恢复系统睡眠",
            selection: Binding(
                get: { keepAliveController.maximumDuration },
                set: { keepAliveController.setMaximumDuration($0) }
            ),
            options: KeepAliveController.MaximumDuration.allCases,
            label: \.title
        )
    }

    /// 只改"哪些任务算数", 没有额外依赖, 所以不置灰也不隐藏
    private var waitingApprovalRow: some View {
        toggleRow(
            title: "等待批准时保持",
            caption: "任务等待批准期间继续防止系统睡眠",
            isOn: Binding(
                get: { keepAliveController.keepsAwakeWhileWaiting },
                set: { keepAliveController.setKeepsAwakeWhileWaiting($0) }
            )
        )
    }

    /// 只在防睡眠真的生效时留住屏幕, 所以和上面那一行一样没有额外依赖
    private var displayAwakeRow: some View {
        toggleRow(
            title: "保持屏幕常亮",
            caption: "同时阻止屏幕保护与自动锁屏",
            isOn: Binding(
                get: { keepAliveController.keepsDisplayAwake },
                set: { keepAliveController.setKeepsDisplayAwake($0) }
            )
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

    private func pickerRow<Option: Hashable>(
        title: String,
        caption: String,
        selection: Binding<Option>,
        options: [Option],
        label: KeyPath<Option, String>
    ) -> some View {
        row(title: title, caption: caption) {
            SettingsOptionsPicker(
                title: title,
                selection: selection,
                options: options,
                label: { $0[keyPath: label] },
                width: Metrics.pickerWidth,
                alignment: .trailing
            )
        }
    }

    /// 开关的修饰链与通知子面板的 optionRow 保持一致, 两个面板才是同一套控件
    private func toggleRow(
        title: String,
        caption: String,
        isOn: Binding<Bool>
    ) -> some View {
        row(title: title, caption: caption) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    /// 面板里每一行都是控件行加一句固定说明, 说明那行与通知子面板的音效子行同一套字号和层级
    private func row(
        title: String,
        caption: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.controlSpacing) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                control()
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
        /// 有内置电池的设备时行数, 无内置电池设备少一行低电量保护
        static let maximumRowCount = 4
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
