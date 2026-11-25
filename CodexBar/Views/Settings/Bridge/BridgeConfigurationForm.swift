import SwiftUI

struct BridgeConfigurationForm: View {
    let configuration: BridgeConfiguration?
    let errorMessage: String?
    let save: (String, BridgePermissions) -> Void
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var permissions: BridgePermissions

    init(configuration: BridgeConfiguration? = nil, errorMessage: String? = nil, save: @escaping (String, BridgePermissions) -> Void) {
        self.configuration = configuration
        self.errorMessage = errorMessage
        self.save = save
        _name = State(initialValue: configuration?.name ?? "")
        _permissions = State(initialValue: configuration?.permissions ?? .init())
    }

    var body: some View {
        BridgeSettingsPage(errorMessage: errorMessage) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("bridge.configuration.name")
                        TextField(text: $name) { EmptyView() }
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onChange(of: name, initial: true) { _, value in
                                if value.count > BridgeConfiguration.maximumNameLength {
                                    name = String(value.prefix(BridgeConfiguration.maximumNameLength))
                                }
                            }
                            .onSubmit(submit)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("bridge.permissions.title")
                        VStack(spacing: 0) {
                            permission("bridge.permissions.file.title", hint: "bridge.permissions.file.description", selection: $permissions.writable) {
                                ForEach([false, true], id: \.self) { writable in
                                    Text(BridgePermissions.fileAccessTitle(writable: writable)).tag(writable)
                                }
                            }
                            Divider()
                            permission("bridge.permissions.network.title", hint: "bridge.permissions.network.description", selection: $permissions.network) {
                                ForEach(BridgePermissions.Network.allCases, id: \.self) { network in
                                    if network != .ask || permissions.approval == .ask {
                                        Text(network.title).tag(network)
                                    }
                                }
                            }
                            Divider()
                            permission("bridge.permissions.additional.title", hint: "bridge.permissions.additional.description", selection: approvalSelection) {
                                ForEach(BridgePermissions.Approval.allCases, id: \.self) { approval in
                                    Text(approval.title).tag(approval)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .bridgeSettingsGroup()
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize)
        } actions: {
            Button(action: submit) {
                if configuration == nil {
                    Text("common.action.create")
                } else {
                    Text("common.action.save")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .onAppear { nameFocused = true }
    }

    private func permission(
        _ title: LocalizedStringResource, hint: LocalizedStringResource, selection: Binding<some Hashable>,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Picker(selection: selection, content: options) { Text(title) }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var approvalSelection: Binding<BridgePermissions.Approval> {
        Binding(get: { permissions.approval }, set: { approval in
            var next = permissions
            next.approval = approval
            if !next.isValid {
                next.network = .deny
            }
            permissions = next
        })
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (configuration?.name != trimmedName || configuration?.permissions != permissions)
    }

    private func submit() {
        guard canSave else { return }
        save(trimmedName, permissions)
    }
}

extension BridgePermissions {
    static func fileAccessTitle(writable: Bool) -> LocalizedStringResource {
        writable ? "bridge.permissions.file.read-write" : "bridge.permissions.file.read-only"
    }
}

extension BridgePermissions.Network {
    var title: LocalizedStringResource {
        switch self {
        case .deny: "bridge.permissions.network.deny"
        case .ask: "bridge.permissions.network.ask"
        case .allow: "bridge.permissions.network.allow"
        }
    }
}

extension BridgePermissions.Approval {
    var title: LocalizedStringResource {
        switch self {
        case .ask: "bridge.permissions.additional.ask"
        case .deny: "bridge.permissions.additional.deny"
        }
    }
}
