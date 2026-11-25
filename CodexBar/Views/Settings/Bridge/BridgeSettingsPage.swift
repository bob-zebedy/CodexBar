import SwiftUI

extension EnvironmentValues {
    @Entry var bridgeListening = false
}

struct BridgeSettingsPage<Content: View, Actions: View>: View {
    @Environment(\.bridgeListening) private var listening
    @AppStorage(BridgeRuntime.enabledKey) private var enabled = false
    let errorMessage: String?
    let content: Content
    let actions: Actions

    init(errorMessage: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.errorMessage = errorMessage
        self.content = content()
        self.actions = actions()
    }

    private var statusTitle: LocalizedStringKey {
        if listening {
            return "bridge.status.enabled"
        }
        return enabled ? "bridge.status.not-running" : "bridge.status.disabled"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                content
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(listening ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                actions
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }
}

extension View {
    func bridgeSettingsGroup() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return background(Color(nsColor: .controlBackgroundColor))
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5).allowsHitTesting(false) }
    }
}
