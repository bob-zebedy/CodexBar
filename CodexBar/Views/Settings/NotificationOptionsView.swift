import AppKit
import SwiftUI

/// 通知子选项面板, 挂在设置窗口右侧, 顶边对齐设置页的通知主开关行
/// 通知开启时展开音效子行, 关闭时连同占位一起收起
struct NotificationOptionsView: View {
    @ObservedObject var notificationSettings: NotificationSettings
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var codexCLINotificationSettings: CodexCLINotificationSettings
    @ObservedObject var keepAliveController: KeepAliveController
    @State private var previewSound: NSSound?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            taskCompletionRow
            taskWaitingRow
            lowQuotaRow
            quotaResetRow
            creditExpiryRow
            lowBatteryRow
            keepAliveLimitRow
            taskHapticRow
            codexCLINotificationRow
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
        .onDisappear(perform: stopPreview)
    }

    static var initialPanelSize: CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + Metrics.notificationRowHeight * CGFloat(Metrics.notificationRowCount)
                + Metrics.captionedRowHeight * CGFloat(Metrics.captionedRowCount)
                + Metrics.rowSpacing * CGFloat(Metrics.totalRowCount - 1)
        )
    }

    // MARK: - 各通知行

    private var lowQuotaRow: some View {
        notificationOptionRow(
            title: "额度预警通知",
            isOn: Binding(
                get: { notificationSettings.isLowQuotaEnabled },
                set: { notificationSettings.setLowQuotaEnabled($0) }
            ),
            sound: Binding(
                get: { notificationSettings.lowQuotaSound },
                set: { notificationSettings.setLowQuotaSound($0) }
            )
        ) {
            optionPicker(
                title: "低额度阈值",
                selection: Binding(
                    get: { notificationSettings.lowQuotaThresholdPercent },
                    set: { notificationSettings.setLowQuotaThresholdPercent($0) }
                ),
                options: NotificationSettings.lowQuotaThresholdOptions,
                label: { CodexPercentageFormat.string(from: $0) }
            )
        }
    }

    private var quotaResetRow: some View {
        notificationOptionRow(
            title: "额度重置通知",
            isOn: Binding(
                get: { notificationSettings.isQuotaResetEnabled },
                set: { notificationSettings.setQuotaResetEnabled($0) }
            ),
            sound: Binding(
                get: { notificationSettings.quotaResetSound },
                set: { notificationSettings.setQuotaResetSound($0) }
            )
        )
    }

    /// Hook 未开启或链路校验不通时显示为关闭并置灰, 不修改持久化的 isTaskCompletionEnabled
    private var taskCompletionRow: some View {
        let isDisplayedOn = codexHookSettings.isOperable && notificationSettings.isTaskCompletionEnabled

        return notificationOptionRow(
            title: "任务完成通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskCompletionEnabled($0) }
            ),
            isEnabled: codexHookSettings.isOperable,
            sound: Binding(
                get: { notificationSettings.taskCompletionSound },
                set: { notificationSettings.setTaskCompletionSound($0) }
            )
        ) {
            optionPicker(
                title: "任务时长",
                selection: Binding(
                    get: { notificationSettings.taskCompletionMinimumDurationSeconds },
                    set: { notificationSettings.setTaskCompletionMinimumDurationSeconds($0) }
                ),
                options: NotificationSettings.taskCompletionDurationOptions,
                label: { Self.taskCompletionDurationLabel($0) }
            )
        }
    }

    /// Hook 未开启或链路校验不通时显示为关闭并置灰, 不修改持久化的 isTaskWaitingEnabled
    private var taskWaitingRow: some View {
        let isDisplayedOn = codexHookSettings.isOperable && notificationSettings.isTaskWaitingEnabled

        return notificationOptionRow(
            title: "任务等待通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskWaitingEnabled($0) }
            ),
            isEnabled: codexHookSettings.isOperable,
            sound: Binding(
                get: { notificationSettings.taskWaitingSound },
                set: { notificationSettings.setTaskWaitingSound($0) }
            )
        )
    }

    /// Hook 未开启或链路校验不通时显示为关闭并置灰, 不修改持久化的 isTaskHapticEnabled
    private var taskHapticRow: some View {
        let isDisplayedOn = codexHookSettings.isOperable && notificationSettings.isTaskHapticEnabled

        return VStack(spacing: 0) {
            optionRow(
                title: "任务触觉反馈",
                isOn: Binding(
                    get: { isDisplayedOn },
                    set: { notificationSettings.setTaskHapticEnabled($0) }
                ),
                isEnabled: codexHookSettings.isOperable
            )

            captionRow("任务完成或等待批准时触发触摸板震动")
        }
    }

    private var creditExpiryRow: some View {
        notificationOptionRow(
            title: "重置临期通知",
            isOn: Binding(
                get: { notificationSettings.isCreditExpiryEnabled },
                set: { notificationSettings.setCreditExpiryEnabled($0) }
            ),
            sound: Binding(
                get: { notificationSettings.creditExpirySound },
                set: { notificationSettings.setCreditExpirySound($0) }
            )
        )
    }

    /// 防睡眠关着或低电量保护关着时显示为关闭并置灰, 不修改持久化的 isLowBatteryEnabled
    /// 保护默认就是关的, 不置灰会让这一行在任何默认安装上都亮着, 而对应通知永远发不出来
    /// "保护是不是真的在起作用"由 KeepAliveController 判定, 这里只读结论
    /// 它同时覆盖了台式机: 那时防睡眠面板整行隐藏低电量保护, 而阈值可能是从笔记本迁移过来的非 off 值
    private var lowBatteryRow: some View {
        let isProtectionOn = keepAliveController.isLowBatteryProtectionEnabled
        let isDisplayedOn = isProtectionOn && notificationSettings.isLowBatteryEnabled

        return notificationOptionRow(
            title: "低电量保护通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setLowBatteryEnabled($0) }
            ),
            isEnabled: isProtectionOn,
            sound: Binding(
                get: { notificationSettings.lowBatterySound },
                set: { notificationSettings.setLowBatterySound($0) }
            )
        )
    }

    /// 防睡眠关着或选了无限制时显示为关闭并置灰, 不修改持久化的 isKeepAliveLimitEnabled
    /// 与低电量那一行同一个做法, "上限会不会到点"由 KeepAliveController 判定, 这里只读结论
    private var keepAliveLimitRow: some View {
        let hasLimit = keepAliveController.isMaximumDurationEnabled
        let isDisplayedOn = hasLimit && notificationSettings.isKeepAliveLimitEnabled

        return notificationOptionRow(
            title: "防睡眠上限通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setKeepAliveLimitEnabled($0) }
            ),
            isEnabled: hasLimit,
            sound: Binding(
                get: { notificationSettings.keepAliveLimitSound },
                set: { notificationSettings.setKeepAliveLimitSound($0) }
            )
        )
    }

    private var codexCLINotificationRow: some View {
        VStack(spacing: 0) {
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
                        .controlSize(.mini)
                        .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
                } else if let errorMessage = codexCLINotificationSettings.errorMessage {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
                        .help(errorMessage)
                }
            }

            captionRow("Codex TUI 通知, 独立于 CodexBar 通知")
        }
    }

    // MARK: - 行构建器

    private func optionRow(
        title: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        optionRow(title: title, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }

    private func optionRow(
        title: LocalizedStringResource,
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

    private func captionRow(_ caption: LocalizedStringResource) -> some View {
        HStack(spacing: 0) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .frame(height: Metrics.secondaryRowHeight)
    }

    private func notificationOptionRow(
        title: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        sound: Binding<NotificationSoundOption>
    ) -> some View {
        notificationOptionRow(
            title: title,
            isOn: isOn,
            isEnabled: isEnabled,
            sound: sound
        ) {
            EmptyView()
        }
    }

    private func notificationOptionRow(
        title: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        sound: Binding<NotificationSoundOption>,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        let showsSoundControls = isEnabled && isOn.wrappedValue
        let canPreviewSound = sound.wrappedValue.isPreviewable

        return VStack(spacing: 0) {
            HStack(spacing: Metrics.notificationControlSpacing) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if showsSoundControls {
                    accessory()
                }

                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!isEnabled)
            }
            .frame(height: Metrics.rowHeight)

            if showsSoundControls {
                HStack(spacing: Metrics.notificationControlSpacing) {
                    Text("通知音效")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    soundMenu(selection: sound)

                    Button {
                        playPreview(for: sound.wrappedValue)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: Metrics.soundPreviewIconSize))
                            .frame(
                                width: Metrics.soundPreviewButtonSize,
                                height: Metrics.soundPreviewButtonSize
                            )
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(canPreviewSound ? .secondary : .tertiary)
                    .disabled(!canPreviewSound)
                }
                .frame(height: Metrics.soundRowHeight)
            }
        }
    }

    private func optionPicker(
        title: LocalizedStringResource,
        selection: Binding<Int>,
        options: [Int],
        label: @escaping (Int) -> String
    ) -> some View {
        SettingsOptionsPicker(
            title: title,
            selection: selection,
            options: options,
            label: label,
            width: Metrics.pickerWidth
        )
    }

    // MARK: - 音效选择与试听

    private func soundMenu(selection: Binding<NotificationSoundOption>) -> some View {
        Menu {
            soundMenuButton(.systemDefault, selection: selection)
            soundMenuButton(.silent, selection: selection)

            Divider()

            ForEach(NotificationSoundOption.categories) { category in
                Menu(category.title) {
                    ForEach(category.sounds) { sound in
                        soundMenuButton(sound, selection: selection)
                    }
                }
            }
        } label: {
            Text(selection.wrappedValue.localizedTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .frame(width: Metrics.soundMenuWidth, alignment: .trailing)
    }

    private func soundMenuButton(
        _ sound: NotificationSoundOption,
        selection: Binding<NotificationSoundOption>
    ) -> some View {
        Button {
            selection.wrappedValue = sound
            playPreview(for: sound)
        } label: {
            if sound == selection.wrappedValue {
                Label(sound.localizedTitle, systemImage: "checkmark")
            } else {
                Text(sound.localizedTitle)
            }
        }
    }

    private func playPreview(for sound: NotificationSoundOption) {
        stopPreview()

        guard sound.isPreviewable else {
            return
        }

        previewSound = sound.makePreviewSound()
        previewSound?.play()
    }

    private func stopPreview() {
        previewSound?.stop()
        previewSound = nil
    }

    private static func taskCompletionDurationLabel(_ seconds: Int) -> String {
        seconds < 60
            ? String(localized: "\(seconds) 秒")
            : String(localized: "\(seconds / 60) 分钟")
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 320
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let notificationRowCount = 7
        static let captionedRowCount = 2
        static let totalRowCount = notificationRowCount + captionedRowCount
        static let rowSpacing = SettingsOptionsPanelMetrics.rowSpacing
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let secondaryRowHeight = SettingsOptionsPanelMetrics.secondaryRowHeight
        static let soundRowHeight = secondaryRowHeight
        static let notificationRowHeight = rowHeight + soundRowHeight
        static let captionedRowHeight = rowHeight + secondaryRowHeight
        static let notificationControlSpacing = SettingsOptionsPanelMetrics.controlSpacing
        static let pickerWidth: CGFloat = 68
        static let soundMenuWidth: CGFloat = 160
        static let soundPreviewButtonSize: CGFloat = 18
        static let soundPreviewIconSize: CGFloat = 13
        static let statusIconSize: CGFloat = 16
        static let cornerRadius = SettingsOptionsPanelMetrics.cornerRadius
    }
}
