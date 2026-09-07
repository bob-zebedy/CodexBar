import SwiftUI

struct ProxySettingsRow: View {
    @EnvironmentObject private var statusViewModel: CodexStatusViewModel
    @ObservedObject var settings: CodexProxySettings
    let action: () -> Void
    @State private var showsSaveError = false

    var body: some View {
        Group {
            if settings.configuration == nil {
                Button(action: action) {
                    HStack(spacing: SettingsRowMetrics.spacing) {
                        rowLabel
                        Toggle("proxy.enabled", isOn: .constant(false))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 0) {
                    Button(action: action) {
                        rowLabel
                            .padding(.trailing, SettingsRowMetrics.spacing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    enabledToggle
                }
            }
        }
        .disabled(settings.isSaving)
        .alert("proxy.feedback.save-failed", isPresented: $showsSaveError) {
            Button("common.action.close", role: .cancel) {}
        }
    }

    private var rowLabel: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "personalhotspot")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)
            Text("proxy.title")
            Spacer()
        }
        .frame(minHeight: SettingsRowMetrics.optionsButtonSize)
    }

    private var enabledToggle: some View {
        Toggle("proxy.enabled", isOn: Binding(
            get: { settings.configuration?.isEnabled == true },
            set: { enabled in
                settings.setEnabled(enabled) { succeeded in
                    if succeeded {
                        statusViewModel.refreshAfterCurrent(trigger: .settings)
                    } else if settings.showsValidationErrors {
                        action()
                    } else {
                        showsSaveError = true
                    }
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct ProxySettingsView: View {
    let source: CodexCLISourceSelection
    @ObservedObject var settings: CodexProxySettings
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showsPassword = false
    @State private var serverFieldHeight: CGFloat = 24
    @State private var isPasswordFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 14) {
                configurationHeader
                LiquidGlassDivider()
                configurationFields
                LiquidGlassDivider()
                authenticationFields
            }
            .disabled(settings.isSaving)

            actions
        }
        .padding(20)
        .frame(width: 550)
        .liquidGlassSurface(cornerRadius: 16, isOuterSurface: true)
        .onAppear {
            showsPassword = false
            settings.loadDraft(showValidationErrors: settings.showsValidationErrors)
        }
        .onChange(of: settings.draft.usesAuthentication) { _, enabled in
            if !enabled {
                showsPassword = false
            }
        }
        .onDisappear {
            showsPassword = false
            settings.closeDraft()
        }
        .interactiveDismissDisabled(settings.isSaving)
    }

    private var configurationHeader: some View {
        HStack {
            Text("proxy.configuration.title")
                .font(.headline)
            Spacer()
            if settings.hasStoredConfiguration {
                Menu {
                    Button(role: .destructive) {
                        Task {
                            if await settings.save(clear: true) {
                                showsPassword = false
                                dismiss()
                                onApplied()
                            }
                        }
                    } label: {
                        Label("proxy.action.clear-configuration", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: SettingsRowMetrics.optionsButtonSize, height: SettingsRowMetrics.optionsButtonSize)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<CodexProxyConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { settings.draft[keyPath: keyPath] },
            set: {
                settings.draftChanged()
                settings.draft[keyPath: keyPath] = $0
            }
        )
    }

    private var configurationFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("proxy.server")
                    .fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    SettingsDropdownPicker(
                        selection: settings.draft.transport,
                        options: CodexProxyConfiguration.Transport.allCases,
                        isEnabled: !settings.isSaving,
                        title: settings.draft.transport.rawValue,
                        height: serverFieldHeight,
                        optionTitle: { $0.rawValue },
                        onSelect: { transport in
                            draftBinding(\.transport).wrappedValue = transport
                        }
                    )
                    Text(verbatim: "://")
                        .foregroundStyle(.secondary)
                    TextField(text: draftBinding(\.host)) {
                        Text(verbatim: "127.0.0.1")
                    }
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { serverFieldHeight = $0 }
                    .overlay { validationBorder(for: .host) }
                    Text(verbatim: ":")
                        .foregroundStyle(.secondary)
                    TextField(text: draftBinding(\.port)) {
                        Text(verbatim: "2048")
                    }
                    .frame(width: 64, alignment: .leading)
                    .overlay { validationBorder(for: .port) }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var authenticationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("proxy.authentication")
                Spacer()
                Toggle("proxy.authentication", isOn: draftBinding(\.usesAuthentication))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            LiquidGlassDivider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("proxy.username")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("proxy.username", text: draftBinding(\.username))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .overlay { validationBorder(for: .username) }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("proxy.password")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    passwordField
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!settings.draft.usesAuthentication)
            .opacity(settings.draft.usesAuthentication ? 1 : 0.5)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var passwordField: some View {
        ProxyPasswordField(
            text: passwordBinding,
            isFocused: $isPasswordFocused,
            isRevealed: showsPassword && controlActiveState != .inactive
        )
        .frame(height: max(18, serverFieldHeight - 6))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { showsPassword = $0 }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if isPasswordFocused {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
    }

    private func validationBorder(for field: CodexProxyConfiguration.InputField) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(settings.invalidFields.contains(field) ? Color.red : Color.clear, lineWidth: 1)
            .allowsHitTesting(false)
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { settings.password },
            set: {
                settings.draftChanged()
                settings.password = $0
            }
        )
    }

    private var testStatus: some View {
        HStack(spacing: 8) {
            Button(settings.isTesting ? "proxy.action.cancel-test" : "proxy.action.test-connection") {
                if settings.isTesting {
                    settings.cancelTest()
                } else {
                    settings.testConnection(source: source)
                }
            }
            .fixedSize()
            if settings.isTesting || settings.isSaving {
                ProgressView()
                    .controlSize(.small)
            } else if let result = settings.feedback {
                HStack(spacing: 6) {
                    Image(systemName: result == .success ? "checkmark" : "xmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(result == .success ? Color.green : Color.red)
                        .frame(width: 14)
                    Text(result.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            testStatus
            Spacer(minLength: 16)
            actionButtons
        }
        .disabled(settings.isSaving)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("common.action.cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("proxy.action.save") { apply() }
                .keyboardShortcut(.defaultAction)
        }
        .fixedSize()
    }

    private func apply() {
        Task {
            if await settings.save() {
                onApplied()
                dismiss()
            }
        }
    }
}
