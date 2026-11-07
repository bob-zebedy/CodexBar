import SwiftUI

/// 防睡眠子选项面板, 挂在设置窗口右侧, 顶边对齐设置页的防睡眠主开关行
struct KeepAliveOptionsView: View {
    @ObservedObject var keepAliveController: KeepAliveController
    @ObservedObject var protectionSettings: ProtectionSettings
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            waitingApprovalRow
            displayAwakeRow
                .padding(.top, Metrics.rowSpacing)
            maximumDurationRow
                .padding(.top, Metrics.rowSpacing)
            protectionRow
                .padding(.top, Metrics.rowSpacing)

            // 无内置电池时隐藏低电量保护行
            lowBatteryRow
                .settingsOptionsReveal(
                    isExpanded: keepAliveController.hasBattery,
                    height: Metrics.rowHeight,
                    spacing: Metrics.rowSpacing
                )
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            minWidth: SettingsOptionsPanelMetrics.minimumWidth,
            maxWidth: SettingsOptionsPanelMetrics.maximumWidth,
            alignment: .topLeading
        )
        .fixedSize(horizontal: true, vertical: true)
        .settingsOptionsPanel(height: SettingsOptionsPanelMetrics.height(rowCount: keepAliveController.hasBattery ? 5 : 4))
        .animation(
            allowsAnimations ? SettingsOptionsPanelMetrics.contentAnimation : nil,
            value: keepAliveController.hasBattery
        )
    }

    private var maximumDurationRow: some View {
        pickerRow(
            title: "keep-alive.duration-limit.title",
            help: "keep-alive.duration-limit.title.help",
            selection: Binding(
                get: { keepAliveController.maximumDuration },
                set: { keepAliveController.setMaximumDuration($0) }
            ),
            options: KeepAliveController.MaximumDuration.allCases,
            label: \.title
        )
    }

    private var protectionRow: some View {
        pickerRow(
            title: "protection.title",
            help: "protection.title.help",
            selection: Binding(
                get: { protectionSettings.inactivityDuration },
                set: { protectionSettings.setInactivityDuration($0) }
            ),
            options: ProtectionSettings.InactivityDuration.allCases,
            label: \.title
        )
    }

    /// 仅决定等待任务是否计入防睡眠, 无额外依赖, 始终可用
    private var waitingApprovalRow: some View {
        toggleRow(
            title: "keep-alive.waiting.title",
            help: "keep-alive.waiting.title.help",
            isOn: Binding(
                get: { keepAliveController.keepsAwakeWhileWaiting },
                set: { keepAliveController.setKeepsAwakeWhileWaiting($0) }
            )
        )
    }

    /// 屏幕常亮随防睡眠生效, 此选项无额外依赖, 始终可用
    private var displayAwakeRow: some View {
        toggleRow(
            title: "keep-alive.display.title",
            help: "keep-alive.display.title.help",
            isOn: Binding(
                get: { keepAliveController.keepsDisplayAwake },
                set: { keepAliveController.setKeepsDisplayAwake($0) }
            )
        )
    }

    private var lowBatteryRow: some View {
        pickerRow(
            title: "keep-alive.low-battery.title",
            help: "keep-alive.low-battery.title.help",
            selection: Binding(
                get: { keepAliveController.lowBatteryThreshold },
                set: { keepAliveController.setLowBatteryThreshold($0) }
            ),
            options: KeepAliveController.LowBatteryThreshold.allCases,
            label: \.title
        )
    }

    private func pickerRow<Option: Hashable>(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        selection: Binding<Option>,
        options: [Option],
        label: KeyPath<Option, String>
    ) -> some View {
        row(title: title, help: help) {
            SettingsOptionsPicker(
                title: title,
                selection: selection,
                options: options,
                label: { $0[keyPath: label] }
            )
        }
    }

    private func toggleRow(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>
    ) -> some View {
        row(title: title, help: help) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func row(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: Metrics.controlSpacing) {
            SettingsHelpLabel(title: title, help: help)
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            control()
        }
        .frame(height: Metrics.rowHeight)
    }

    private enum Metrics {
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowSpacing = SettingsOptionsPanelMetrics.rowSpacing
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let controlSpacing = SettingsOptionsPanelMetrics.controlSpacing
    }
}
