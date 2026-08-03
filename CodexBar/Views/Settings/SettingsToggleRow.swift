import SwiftUI

/// 设置页行布局共享常量: 各行的图标列宽与行内间距必须一致才能对齐
enum SettingsRowMetrics {
    static let iconWidth: CGFloat = 18
    static let spacing: CGFloat = 10
}

/// 设置窗口右侧两个子选项面板共用的度量
/// 两个面板要看起来是同一套控件, 所以除了面板宽度和 picker 宽度以外都从这里取
enum SettingsOptionsPanelMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 5
    static let rowHeight: CGFloat = 22
    /// 第二行的高度, 通知面板用于音效子行, 防睡眠面板用于固定说明
    static let secondaryRowHeight: CGFloat = 18
    static let controlSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 12
}

/// 两个子选项面板共用的下拉选择器
/// 只有宽度和对齐各自定义, 其余样式必须同源, 否则两个面板看起来就不是同一套控件
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
        .frame(width: width, alignment: alignment)
    }
}

/// 设置页通用开关行, accessory 插入在开关左侧
struct SettingsToggleRow<Accessory: View>: View {
    let icon: String
    let title: LocalizedStringResource
    let isOn: Binding<Bool>
    let isEnabled: Bool
    private let accessory: Accessory

    init(
        icon: String,
        title: LocalizedStringResource,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: icon)
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text(title)

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
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) {
        self.init(icon: icon, title: title, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }
}
