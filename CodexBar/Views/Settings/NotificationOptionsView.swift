import AppKit
import SwiftUI

/// 通知子选项面板, 挂在设置窗口右侧并与设置内容区底边对齐
/// 通知开启时展开音效子行, 关闭时连同占位一起收起
struct NotificationOptionsView: View {
    @ObservedObject var notificationSettings: NotificationSettings
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var codexCLINotificationSettings: CodexCLINotificationSettings
    @State private var previewSound: NSSound?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            longTaskRow
            taskWaitingRow
            lowQuotaRow
            quotaResetRow
            creditExpiryRow
            taskHapticRow
            codexCLINotificationRow
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
        .onDisappear(perform: stopPreview)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static var initialPanelSize: CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: Metrics.verticalPadding * 2
                + Metrics.notificationRowHeight * CGFloat(Metrics.notificationRowCount)
                + Metrics.rowHeight * CGFloat(Metrics.standardRowCount)
                + Metrics.rowSpacing * CGFloat(Metrics.totalRowCount - 1)
        )
    }

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
                label: { "\($0)%" }
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

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 isLongTaskEnabled
    private var longTaskRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && notificationSettings.isLongTaskEnabled

        return notificationOptionRow(
            title: "任务完成通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setLongTaskEnabled($0) }
            ),
            isEnabled: codexHookSettings.isEnabled,
            sound: Binding(
                get: { notificationSettings.longTaskSound },
                set: { notificationSettings.setLongTaskSound($0) }
            )
        ) {
            optionPicker(
                title: "任务时长",
                selection: Binding(
                    get: { notificationSettings.longTaskThresholdSeconds },
                    set: { notificationSettings.setLongTaskThresholdSeconds($0) }
                ),
                options: NotificationSettings.longTaskThresholdOptions,
                label: { Self.longTaskOptionLabel($0) }
            )
        }
    }

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 isTaskWaitingEnabled
    private var taskWaitingRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && notificationSettings.isTaskWaitingEnabled

        return notificationOptionRow(
            title: "任务等待通知",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskWaitingEnabled($0) }
            ),
            isEnabled: codexHookSettings.isEnabled,
            sound: Binding(
                get: { notificationSettings.taskWaitingSound },
                set: { notificationSettings.setTaskWaitingSound($0) }
            )
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
                    .controlSize(.mini)
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

    /// Swift 6.3.3 在 -O 下会让这两个行构建器中的原生 mini Switch 漏绘 thumb
    @_optimize(none)
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

    private func notificationOptionRow(
        title: String,
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

    @_optimize(none)
    private func notificationOptionRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        sound: Binding<NotificationSoundOption>,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        let showsSoundControls = isEnabled && isOn.wrappedValue
        let canPreviewSound = sound.wrappedValue != .silent

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

    private func soundMenu(selection: Binding<NotificationSoundOption>) -> some View {
        Menu {
            soundMenuButton(.systemDefault, selection: selection)
            soundMenuButton(.silent, selection: selection)

            Divider()

            Menu("经典提示音") {
                ForEach(NotificationSoundOption.classicSounds) { sound in
                    soundMenuButton(sound, selection: selection)
                }
            }

            Menu("现代提示音") {
                ForEach(NotificationSoundOption.modernSounds) { sound in
                    soundMenuButton(sound, selection: selection)
                }
            }
        } label: {
            Text(selection.wrappedValue.title)
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
                Label(sound.title, systemImage: "checkmark")
            } else {
                Text(sound.title)
            }
        }
    }

    private func playPreview(for sound: NotificationSoundOption) {
        stopPreview()

        switch sound {
        case .silent:
            return
        case .systemDefault:
            NSSound.beep()
        default:
            previewSound = sound.makePreviewSound()
                ?? NSSound(named: NSSound.Name(sound.title))
            previewSound?.play()
        }
    }

    private func stopPreview() {
        previewSound?.stop()
        previewSound = nil
    }

    private static func longTaskOptionLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 320
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let notificationRowCount = 5
        static let standardRowCount = 2
        static let totalRowCount = notificationRowCount + standardRowCount
        static let rowSpacing: CGFloat = 5
        static let rowHeight: CGFloat = 22
        static let soundRowHeight: CGFloat = 18
        static let notificationRowHeight = rowHeight + soundRowHeight
        static let notificationControlSpacing: CGFloat = 6
        static let pickerWidth: CGFloat = 68
        static let soundMenuWidth: CGFloat = 160
        static let soundPreviewButtonSize: CGFloat = 18
        static let soundPreviewIconSize: CGFloat = 13
        static let statusIconSize: CGFloat = 16
        static let cornerRadius: CGFloat = 12
    }
}
