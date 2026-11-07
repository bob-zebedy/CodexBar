import AppKit
import SwiftUI

/// 通知子选项面板, 挂在设置窗口右侧, 顶边对齐设置页的通知主开关行
/// 通知开启时展开音效子行, 关闭时连同占位一起收起
struct NotificationOptionsView: View {
    @ObservedObject var notificationSettings: NotificationSettings
    @ObservedObject var tuiNotificationSettings: TUINotificationSettings
    @ObservedObject var autoResetSettings: AutoResetSettings
    @ObservedObject var keepAliveController: KeepAliveController
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    @State private var previewSound: NSSound?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            taskCompletionRow
            taskWaitingRow
            lowQuotaRow
            quotaResetRow
            creditExpiryRow
            autoResetNotificationRow
            lowBatteryRow
            keepAliveLimitRow
            taskHapticRow
            tuiNotificationRow
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
        .settingsOptionsPanel(height: SettingsOptionsPanelMetrics.height(
            rowCount: soundRowVisibility.count + 2,
            secondaryRowCount: soundRowVisibility.filter(\.self).count
        ))
        .animation(
            allowsAnimations ? SettingsOptionsPanelMetrics.contentAnimation : nil,
            value: soundRowVisibility
        )
        .onDisappear(perform: stopPreview)
    }

    // MARK: - 各通知行

    private var soundRowVisibility: [Bool] {
        [
            notificationSettings.isTaskCompletionEnabled,
            notificationSettings.isTaskWaitingEnabled,
            notificationSettings.isLowQuotaEnabled,
            notificationSettings.isQuotaResetEnabled,
            notificationSettings.isCreditExpiryEnabled,
            autoResetSettings.isEnabled && notificationSettings.isAutoResetEnabled,
            keepAliveController.isLowBatteryProtectionEnabled && notificationSettings.isLowBatteryEnabled,
            keepAliveController.isMaximumDurationEnabled && notificationSettings.isKeepAliveLimitEnabled
        ]
    }

    private var lowQuotaRow: some View {
        notificationOptionRow(
            title: "settings.notifications.low-quota.title",
            help: "settings.notifications.low-quota.title.help",
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
                title: "settings.notifications.low-quota.threshold",
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
            title: "settings.notifications.quota-reset.title",
            help: "settings.notifications.quota-reset.title.help",
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

    private var taskCompletionRow: some View {
        let isDisplayedOn = notificationSettings.isTaskCompletionEnabled

        return notificationOptionRow(
            title: "settings.notifications.task-completion.title",
            help: "settings.notifications.task-completion.title.help",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskCompletionEnabled($0) }
            ),
            sound: Binding(
                get: { notificationSettings.taskCompletionSound },
                set: { notificationSettings.setTaskCompletionSound($0) }
            )
        ) {
            optionPicker(
                title: "settings.notifications.task-completion.minimum-duration",
                selection: Binding(
                    get: { notificationSettings.taskCompletionMinimumDurationSeconds },
                    set: { notificationSettings.setTaskCompletionMinimumDurationSeconds($0) }
                ),
                options: NotificationSettings.taskCompletionDurationOptions,
                label: { Self.taskCompletionDurationLabel($0) }
            )
        }
    }

    private var taskWaitingRow: some View {
        let isDisplayedOn = notificationSettings.isTaskWaitingEnabled

        return notificationOptionRow(
            title: "settings.notifications.task-waiting.title",
            help: "settings.notifications.task-waiting.title.help",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskWaitingEnabled($0) }
            ),
            sound: Binding(
                get: { notificationSettings.taskWaitingSound },
                set: { notificationSettings.setTaskWaitingSound($0) }
            )
        )
    }

    private var taskHapticRow: some View {
        let isDisplayedOn = notificationSettings.isTaskHapticEnabled

        return optionRow(
            title: "settings.notifications.task-haptics.title",
            help: "settings.notifications.task-haptics.title.help",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setTaskHapticEnabled($0) }
            )
        )
    }

    private var creditExpiryRow: some View {
        notificationOptionRow(
            title: "settings.notifications.banked-reset-expiry.title",
            help: "settings.notifications.banked-reset-expiry.title.help",
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

    /// 自动重置关闭时, 通知开关显示为关闭并置灰, 不修改持久化的 isAutoResetEnabled
    private var autoResetNotificationRow: some View {
        let isFeatureEnabled = autoResetSettings.isEnabled
        let isDisplayedOn = isFeatureEnabled && notificationSettings.isAutoResetEnabled

        return notificationOptionRow(
            title: "settings.notifications.auto-reset.title",
            help: "settings.notifications.auto-reset.title.help",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { notificationSettings.setAutoResetEnabled($0) }
            ),
            isEnabled: isFeatureEnabled,
            sound: Binding(
                get: { notificationSettings.autoResetSound },
                set: { notificationSettings.setAutoResetSound($0) }
            )
        )
    }

    /// 可用性由 KeepAliveController 统一判定, 不可用时将通知开关显示为关闭并禁用交互
    /// 仅调整展示状态, 保留持久化的 isLowBatteryEnabled
    private var lowBatteryRow: some View {
        let isProtectionOn = keepAliveController.isLowBatteryProtectionEnabled
        let isDisplayedOn = isProtectionOn && notificationSettings.isLowBatteryEnabled

        return notificationOptionRow(
            title: "settings.notifications.low-battery.title",
            help: "settings.notifications.low-battery.title.help",
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

    /// 防睡眠关闭或时长设为无限制时, 通知开关显示为关闭并置灰, 不修改持久化的 isKeepAliveLimitEnabled
    /// 与低电量通知一样, 可用性由 KeepAliveController 判定
    private var keepAliveLimitRow: some View {
        let hasLimit = keepAliveController.isMaximumDurationEnabled
        let isDisplayedOn = hasLimit && notificationSettings.isKeepAliveLimitEnabled

        return notificationOptionRow(
            title: "settings.notifications.keep-alive-limit.title",
            help: "settings.notifications.keep-alive-limit.title.help",
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

    private var tuiNotificationRow: some View {
        optionRow(
            title: "settings.notifications.codex-tui.title",
            help: "settings.notifications.codex-tui.title.help",
            isOn: Binding(
                get: { tuiNotificationSettings.isEnabled ?? false },
                set: { tuiNotificationSettings.setEnabled($0) }
            ),
            isEnabled: tuiNotificationSettings.isAvailable && !tuiNotificationSettings.isUpdating
        ) {
            if tuiNotificationSettings.isUpdating {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
            } else if let errorMessage = tuiNotificationSettings.errorMessage {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.orange)
                    .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
                    .help(errorMessage)
            }
        }
    }

    // MARK: - 行构建器

    private func optionRow(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        optionRow(title: title, help: help, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }

    private func optionRow(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            SettingsHelpLabel(title: title, help: help)
                .font(SettingsRowMetrics.captionFont)
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
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        sound: Binding<NotificationSoundOption>
    ) -> some View {
        notificationOptionRow(
            title: title,
            help: help,
            isOn: isOn,
            isEnabled: isEnabled,
            sound: sound
        ) {
            EmptyView()
        }
    }

    private func notificationOptionRow(
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        sound: Binding<NotificationSoundOption>,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        let showsSoundControls = isEnabled && isOn.wrappedValue
        let canPreviewSound = sound.wrappedValue.isPreviewable

        return VStack(spacing: 0) {
            HStack(spacing: Metrics.notificationControlSpacing) {
                SettingsHelpLabel(title: title, help: help)
                    .font(SettingsRowMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                accessory()
                    .opacity(showsSoundControls ? 1 : 0)
                    .disabled(!showsSoundControls)
                    .allowsHitTesting(showsSoundControls)

                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!isEnabled)
            }
            .frame(height: Metrics.rowHeight)

            HStack(spacing: Metrics.notificationControlSpacing) {
                Text("settings.notifications.sound.title")
                    .font(SettingsRowMetrics.captionFont)
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
            .settingsOptionsReveal(isExpanded: showsSoundControls, height: Metrics.soundRowHeight)
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
            label: label
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
            Text(Self.soundMenuSizingTitle)
                .font(SettingsRowMetrics.captionFont)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(selection.wrappedValue.localizedTitle)
                        .font(SettingsRowMetrics.captionFont)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private static let soundMenuSizingTitle: String = {
        let sounds = [NotificationSoundOption.systemDefault, .silent]
            + NotificationSoundOption.categories.flatMap(\.sounds)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return sounds.map(\.localizedTitle).max {
            ($0 as NSString).size(withAttributes: [.font: font]).width
                < ($1 as NSString).size(withAttributes: [.font: font]).width
        } ?? ""
    }()

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
            ? String(localized: "duration.seconds", defaultValue: "\(seconds, specifier: "%lld")")
            : String(localized: "duration.minutes", defaultValue: "\(seconds / 60, specifier: "%lld")")
    }

    private enum Metrics {
        static let horizontalPadding = SettingsOptionsPanelMetrics.horizontalPadding
        static let verticalPadding = SettingsOptionsPanelMetrics.verticalPadding
        static let rowSpacing = SettingsOptionsPanelMetrics.rowSpacing
        static let rowHeight = SettingsOptionsPanelMetrics.rowHeight
        static let soundRowHeight = SettingsOptionsPanelMetrics.secondaryRowHeight
        static let notificationControlSpacing = SettingsOptionsPanelMetrics.controlSpacing
        static let soundPreviewButtonSize: CGFloat = 18
        static let soundPreviewIconSize: CGFloat = 13
        static let statusIconSize: CGFloat = 16
    }
}

struct NotificationAuthorizationRow: View {
    let settings: NotificationSettings
    let message: String

    var body: some View {
        SettingsIndentedRow {
            Text(message)
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if settings.needsAuthorization {
                Button("common.action.open-system-settings") {
                    settings.openSystemNotificationSettings()
                }
                .controlSize(.small)
                .font(SettingsRowMetrics.controlFont)
                .fixedSize()
            }
        }
    }
}
