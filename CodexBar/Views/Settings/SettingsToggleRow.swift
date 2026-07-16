import SwiftUI

/// 设置页行布局共享常量: 各行的图标列宽与行内间距必须一致才能对齐
enum SettingsRowMetrics {
    static let iconWidth: CGFloat = 18
    static let spacing: CGFloat = 10
}

/// 设置页通用开关行, accessory 插入在开关左侧
struct SettingsToggleRow<Accessory: View>: View {
    let icon: String
    let title: String
    let isOn: Binding<Bool>
    let isEnabled: Bool
    private let accessory: Accessory

    init(
        icon: String,
        title: String,
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
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) {
        self.init(icon: icon, title: title, isOn: isOn, isEnabled: isEnabled) {
            EmptyView()
        }
    }
}
