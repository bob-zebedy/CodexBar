import SwiftUI

struct BridgeConfigurationList: View {
    private static let actionsWidth: CGFloat = 72
    let configurations: [BridgeConfiguration]
    let showDetails: (BridgeConfiguration) -> Void
    let editConfiguration: (BridgeConfiguration) -> Void
    let requestDeletion: (BridgeConfiguration) -> Void

    var body: some View {
        if configurations.isEmpty {
            ContentUnavailableView {
                Text("bridge.configuration.list.empty")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let nameWidth: CGFloat? = geometry.size.width >= 580 ? geometry.size.width * 0.28 : nil
                ScrollView {
                    VStack(spacing: 0) {
                        if let nameWidth {
                            columns(nameWidth: nameWidth) {
                                columnTitle("bridge.configuration.name")
                                columnTitle("bridge.permissions.file.title")
                                columnTitle("bridge.permissions.network.title")
                                columnTitle("bridge.permissions.additional.title")
                                columnTitle("bridge.configuration.usage-count")
                            }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                            .padding(.trailing, Self.actionsWidth)
                            .padding(.vertical, 8)
                            .background(.background.secondary)
                            Divider()
                        }
                        ForEach(configurations.reversed()) { configuration in
                            row(configuration, nameWidth: nameWidth)
                            if configuration.id != configurations.first?.id {
                                Divider()
                            }
                        }
                    }
                    .multilineTextAlignment(.center)
                    .bridgeSettingsGroup()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func row(_ configuration: BridgeConfiguration, nameWidth: CGFloat?) -> some View {
        let compact = nameWidth == nil
        return Button { showDetails(configuration) } label: {
            VStack(spacing: 8) {
                if compact {
                    name(configuration)
                }
                columns(nameWidth: nameWidth) {
                    if !compact {
                        name(configuration)
                    }
                    cell("bridge.permissions.file.title", compact: compact) {
                        Text(BridgePermissions.fileAccessTitle(writable: configuration.permissions.writable))
                    }
                    cell("bridge.permissions.network.title", compact: compact) {
                        Text(configuration.permissions.network.title)
                    }
                    cell("bridge.permissions.additional.title", compact: compact) {
                        Text(configuration.permissions.approval.title)
                    }
                    cell("bridge.configuration.usage-count", compact: compact) {
                        TokenCountText(tokens: Int(configuration.usageCount), font: .subheadline.monospacedDigit())
                            .minimumScaleFactor(0.8)
                            .help(Text(configuration.usageCount, format: .number))
                    }
                }
            }
            .font(.subheadline)
            .padding(.leading, 14)
            .padding(.trailing, compact ? 40 : Self.actionsWidth)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            let layout = compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 4))
            layout {
                rowAction("square.and.pencil") { editConfiguration(configuration) }
                rowAction("trash", role: .destructive) { requestDeletion(configuration) }
            }
            .frame(width: compact ? 40 : Self.actionsWidth)
        }
    }

    private func rowAction(_ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(role == .destructive ? Color.red : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func columns(nameWidth: CGFloat?, @ViewBuilder content: () -> some View) -> some View {
        var columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: nameWidth == nil ? 2 : 3)
        if let nameWidth {
            columns.insert(GridItem(.fixed(nameWidth), spacing: 8), at: 0)
            columns.append(GridItem(.fixed(68)))
        }
        return LazyVGrid(columns: columns, spacing: nameWidth == nil ? 8 : 0, content: content)
            .frame(maxWidth: .infinity)
    }

    private func name(_ configuration: BridgeConfiguration) -> some View {
        Text(verbatim: configuration.name)
            .lineLimit(2)
    }

    private func cell(_ title: LocalizedStringResource, compact: Bool, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 2) {
            if compact {
                columnTitle(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .foregroundStyle(.secondary)
            }
            value()
        }
    }

    private func columnTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }
}
