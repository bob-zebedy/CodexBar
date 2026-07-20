import SwiftUI

/// 通知子选项面板, 挂在设置窗口「系统通知」行右侧展开
/// 面板尺寸在 Hook 开/关两种状态下保持不变: 行高固定, Picker 行内显隐不改行高
struct NotificationOptionsView: View {
    @ObservedObject var notificationSettings: NotificationSettings
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var codexCLINotificationSettings: CodexCLINotificationSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            lowQuotaRow
            quotaResetRow
            longTaskRow
            taskWaitingRow
            taskHapticRow
            creditExpiryRow
            codexCLINotificationRow
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static var initialPanelSize: CGSize {
        let rowCount = CGFloat(Metrics.optionRowCount)
        return CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + Metrics.rowHeight * rowCount
                + Metrics.rowSpacing * (rowCount - 1)
        )
    }

    private var lowQuotaRow: some View {
        optionRow(
            title: "额度预警通知",
            isOn: Binding(
                get: { notificationSettings.isLowQuotaEnabled },
                set: { notificationSettings.setLowQuotaEnabled($0) }
            )
        ) {
            if notificationSettings.isLowQuotaEnabled {
                optionPicker(
                    title: "低额度阈值",
                    selection: Binding(
                        get: { notificationSettings.lowQuotaThresholdPercent },
                        set: { notificationSettings.setLowQuotaThresholdPercent($0) }
                    ),
                    options: NotificationSettings.lowQuotaThresholdOptions,
                    label: { "\($0)%" }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Metrics.statusAnimation, value: notificationSettings.isLowQuotaEnabled)
    }

    private var quotaResetRow: some View {
        optionRow(
            title: "额度重置通知",
            isOn: Binding(
                get: { notificationSettings.isQuotaResetEnabled },
                set: { notificationSettings.setQuotaResetEnabled($0) }
            )
        )
    }

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 isLongTaskEnabled
    private var longTaskRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && notificationSettings.isLongTaskEnabled

        return optionRow(
            title: "任务完成通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setLongTaskEnabled($0) }
            ),
            isEnabled: codexHookSettings.isEnabled
        ) {
            if isDisplayedOn {
                optionPicker(
                    title: "任务时长",
                    selection: Binding(
                        get: { notificationSettings.longTaskThresholdSeconds },
                        set: { notificationSettings.setLongTaskThresholdSeconds($0) }
                    ),
                    options: NotificationSettings.longTaskThresholdOptions,
                    label: { Self.longTaskOptionLabel($0) }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Metrics.statusAnimation, value: isDisplayedOn)
    }

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 isTaskWaitingEnabled
    private var taskWaitingRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && notificationSettings.isTaskWaitingEnabled

        return optionRow(
            title: "任务等待通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskWaitingEnabled($0) }
            ),
            isEnabled: codexHookSettings.isEnabled
        )
    }

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 isTaskHapticEnabled
    private var taskHapticRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && notificationSettings.isTaskHapticEnabled

        return optionRow(
            title: "任务触觉反馈",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskHapticEnabled($0) }
            ),
            isEnabled: codexHookSettings.isEnabled
        )
    }

    private var creditExpiryRow: some View {
        optionRow(
            title: "重置次数临期通知",
            isOn: Binding(
                get: { notificationSettings.isCreditExpiryEnabled },
                set: { notificationSettings.setCreditExpiryEnabled($0) }
            )
        )
    }

    private var codexCLINotificationRow: some View {
        optionRow(
            title: "Codex TUI 通知",
            isOn: Binding(
                get: { codexCLINotificationSettings.isEnabled },
                set: { codexCLINotificationSettings.setEnabled($0) }
            ),
            isEnabled: !codexCLINotificationSettings.isUpdating
        ) {
            if codexCLINotificationSettings.isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
            } else if let errorMessage = codexCLINotificationSettings.errorMessage {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
                    .help(errorMessage)
            }
        }
    }

    private func optionRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        optionRow(title: title, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }

    private func optionRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            accessory()

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled)
        }
        .frame(height: Metrics.rowHeight)
    }

    private func optionPicker(
        title: String,
        selection: Binding<Int>,
        options: [Int],
        label: @escaping (Int) -> String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: Metrics.pickerWidth)
    }

    private static func longTaskOptionLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 300
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let optionRowCount = 7
        static let rowSpacing: CGFloat = 7
        static let rowHeight: CGFloat = 22
        static let pickerWidth: CGFloat = 72
        static let statusIconSize: CGFloat = 16
        static let cornerRadius: CGFloat = 12
        static let statusAnimation = Animation.codexStatus
    }
}
