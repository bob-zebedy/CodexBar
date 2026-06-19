import SwiftUI

struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let isOn: Binding<Bool>
    var isEnabled = true
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tint)
            
            Text(title)
            
            Spacer()
            
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
    
    private enum Metrics {
        static let iconWidth: CGFloat = 18
    }
}
