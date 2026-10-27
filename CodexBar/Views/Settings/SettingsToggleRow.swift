import AppKit
import SwiftUI

/// 设置页共享字体和布局, 按内容角色区分层级并保持各行对齐
enum SettingsRowMetrics {
    static let tabFont = Font.subheadline.weight(.semibold)
    static let titleFont = Font.body.weight(.semibold)
    static let bodyFont = Font.body.weight(.regular)
    static let captionFont = Font.caption.weight(.regular)
    static let controlFont = Font.system(size: NSFont.smallSystemFontSize, weight: .regular)
    static let badgeFont = Font.caption.weight(.medium)

    static let iconWidth: CGFloat = 18
    static let spacing: CGFloat = 10
    static let optionsButtonSize: CGFloat = 22
}

/// 设置窗口子面板入口共用的滑杆按钮
struct SettingsOptionsButton: View {
    let isAvailable: Bool
    let action: () -> Void

    init(isAvailable: Bool = true, action: @escaping () -> Void) {
        self.isAvailable = isAvailable
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(.tint)
        .frame(
            width: SettingsRowMetrics.optionsButtonSize,
            height: SettingsRowMetrics.optionsButtonSize
        )
        .opacity(isAvailable ? 1 : 0)
        .disabled(!isAvailable)
        .animation(.codexStatus, value: isAvailable)
    }
}

/// 设置窗口右侧子选项面板共用的度量
/// 各面板要看起来是同一套控件, 所以除了面板宽度和 picker 宽度以外都从这里取
enum SettingsOptionsPanelMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 5
    static let rowHeight: CGFloat = 22
    /// 通知面板音效子行的高度
    static let secondaryRowHeight: CGFloat = 18
    static let controlSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 12
}

/// 子选项面板共用的下拉选择器
/// 只有宽度和对齐各自定义, 其余样式必须同源, 否则各面板看起来就不是同一套控件
struct SettingsOptionsPicker<Option: Hashable>: View {
    let title: LocalizedStringResource
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    let width: CGFloat
    var alignment: Alignment = .center

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(SettingsRowMetrics.controlFont.monospacedDigit())
        .frame(width: width, alignment: alignment)
    }
}

/// 设置页通用开关行, accessory 插入在开关左侧
struct SettingsToggleRow<Accessory: View>: View {
    let icon: String
    let title: LocalizedStringResource
    let help: LocalizedStringResource
    let isOn: Binding<Bool>
    let isEnabled: Bool
    private let accessory: Accessory

    init(
        icon: String,
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.help = help
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: icon)
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            SettingsHelpLabel(title: title, help: help)
                .font(SettingsRowMetrics.bodyFont)

            Spacer()

            accessory

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
}

extension SettingsToggleRow where Accessory == EmptyView {
    init(
        icon: String,
        title: LocalizedStringResource,
        help: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) {
        self.init(icon: icon, title: title, help: help, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }
}
