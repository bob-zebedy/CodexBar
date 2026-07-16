import SwiftUI

/// 设置页中与主行标题对齐的缩进辅助行
struct SettingsIndentedRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var iconWidth: CGFloat = SettingsRowMetrics.iconWidth
    var spacing: CGFloat = SettingsRowMetrics.spacing
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            Color.clear
                .frame(width: iconWidth)

            content()
        }
    }
}

struct SettingsCaptionMessageRow: View {
    let message: String
    var color = Color.red

    var body: some View {
        SettingsIndentedRow(alignment: .top) {
            Text(message)
                .font(.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
