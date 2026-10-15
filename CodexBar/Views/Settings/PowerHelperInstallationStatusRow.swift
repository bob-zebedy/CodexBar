import SwiftUI

struct PowerHelperInstallationStatusRow: View {
    let status: KeepAliveController.PowerHelperInstallationStatus

    var body: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "puzzlepiece.extension")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text("settings.about.power-helper.title")

            Spacer()

            Text(statusPresentation.text)
                .foregroundStyle(statusPresentation.color)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.codexStatus, value: status)
        }
    }

    private var statusPresentation: (text: LocalizedStringKey, color: Color) {
        switch status {
        case .notInstalled:
            ("settings.about.power-helper.not-installed", .gray)
        case .authorized:
            ("settings.about.power-helper.authorized", .green)
        case .requiresApproval:
            ("settings.about.power-helper.requires-approval", .orange)
        case .unavailable:
            ("settings.about.power-helper.unavailable", .red)
        }
    }
}
