import SwiftUI

struct BridgeSettingsRow: View {
    var host: BridgeHost = .shared
    let open: () -> Void
    @AppStorage(BridgeRuntime.enabledKey) private var enabled = false
    @State private var changing = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsRowWithCaption(errorMessage) {
            HStack(spacing: 0) {
                Button(action: open) {
                    HStack(spacing: SettingsRowMetrics.spacing) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .frame(width: SettingsRowMetrics.iconWidth)
                            .foregroundStyle(.tint)
                        SettingsHelpLabel(title: "settings.bridge.title", help: "settings.bridge.title.help")
                            .font(SettingsRowMetrics.bodyFont)
                        Spacer()
                    }
                    .frame(minHeight: SettingsRowMetrics.optionsButtonSize)
                    .padding(.trailing, SettingsRowMetrics.spacing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("settings.bridge.title", isOn: Binding(get: { enabled }, set: setEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(changing)
            }
        } caption: { message, _ in
            SettingsCaptionMessageRow(message: message)
        }
    }

    private func setEnabled(_ value: Bool) {
        guard !changing else { return }
        changing = true
        errorMessage = nil
        Task {
            defer { changing = false }
            do { try await host.setEnabled(value) } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
