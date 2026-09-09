import SwiftUI

struct HelperInstallationStatusRow: View {
    let status: KeepAliveController.HelperStatus

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
        case .notRegistered:
            ("settings.about.helper.not-installed", .gray)
        case .enabled:
            ("settings.about.helper.authorized", .green)
        case .requiresApproval:
            ("settings.about.helper.requires-approval", .orange)
        case .notFound:
            ("settings.about.helper.unavailable", .red)
        }
    }
}
