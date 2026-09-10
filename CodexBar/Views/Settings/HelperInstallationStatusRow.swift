import SwiftUI

struct HelperInstallationStatusRow: View {
    let status: KeepAliveController.HelperInstallationStatus

    var body: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "puzzlepiece.extension")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text("settings.about.helper.title")

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
            ("settings.about.helper.not-installed", .gray)
        case .authorized:
            ("settings.about.helper.authorized", .green)
        case .requiresApproval:
            ("settings.about.helper.requires-approval", .orange)
        case .unavailable:
            ("settings.about.helper.unavailable", .red)
        }
    }
}
