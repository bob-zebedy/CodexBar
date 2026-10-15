import SwiftUI

struct CodexServiceStatusRow: View {
    @ObservedObject var monitor: CodexServiceStatusMonitor
    @Environment(\.mainPanelAnimationsEnabled) private var allowsAnimations
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Link(destination: CodexServiceStatusService.statusPageURL) {
            HStack(spacing: MenuMetrics.statusIconSpacing) {
                ZStack {
                    Image(systemName: statusSymbol)
                        .resizable()
                        .scaledToFit()
                        .frame(width: MenuMetrics.statusIconSize, height: MenuMetrics.statusIconSize)
                        .id(statusSymbol)
                        .transition(allowsAnimations ? .opacity : .identity)
                }
                .font(.system(size: MenuMetrics.statusIconSize, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: MenuMetrics.statusIconSize, height: MenuMetrics.statusIconSize)

                Text("service-status.title")
                    .font(.caption)
                    .foregroundStyle(Color.codexLabel)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if !displayedComponents.isEmpty {
                    Text(verbatim: displayedComponents.map { Self.shortComponentName($0) }.joined(separator: " • "))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                        .contentTransition(allowsAnimations ? .opacity : .identity)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                        .help(Text(verbatim: displayedComponents.joined(separator: "\n")))
                        .transition(allowsAnimations ? .opacity : .identity)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, MenuMetrics.panelPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: MenuMetrics.panelCornerRadius)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .animation(allowsAnimations ? .codexStatus : nil, value: isHovered)
        .animation(allowsAnimations ? .codexStatus : nil, value: monitor.state)
    }

    private var displayedComponents: [String] {
        guard case let .available(status) = monitor.state else { return [] }
        return status.componentNames
    }

    private static func shortComponentName(_ name: String) -> String {
        switch name {
        case "Codex Web": "Web"
        case "Codex API": "API"
        case "VS Code extension": "VS Code"
        case "Codex in ChatGPT Desktop": "Desktop"
        default: name
        }
    }

    private var statusSymbol: String {
        switch monitor.state {
        case .checking: "ellipsis.circle"
        case let .available(status): status.level.symbolName
        case .unavailable: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch monitor.state {
        case let .available(status): status.level.tint(for: colorScheme)
        case .checking, .unavailable: .secondary
        }
    }
}

private extension CodexServiceStatus.Level {
    var symbolName: String {
        switch self {
        case .operational: "checkmark.circle.fill"
        case .degradedPerformance: "exclamationmark.circle.fill"
        case .partialOutage: "exclamationmark.triangle.fill"
        case .fullOutage: "xmark.octagon.fill"
        case .underMaintenance: "wrench.fill"
        }
    }

    func tint(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .operational: .green
        case .degradedPerformance: Color(hex: colorScheme == .dark ? 0xE4C66A : 0xBE9B38)
        case .partialOutage: .orange
        case .fullOutage: .red
        case .underMaintenance: .blue
        }
    }
}
