import SwiftUI

struct CodexServiceStatusRow: View {
    @ObservedObject var monitor: CodexServiceStatusMonitor
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
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
                        .foregroundStyle(statusColor)
                        .id(statusSymbol)
                        .transition(allowsAnimations ? .opacity : .identity)
                }
                .font(.system(size: MenuMetrics.statusIconSize, weight: .medium))
                .frame(width: MenuMetrics.statusIconSize, height: MenuMetrics.statusIconSize)

                Text(statusTitle)
                    .font(MenuMetrics.bodyFont)
                    .foregroundStyle(Color.codexLabel)
                    .numericTransition(value: monitor.state)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if !displayedComponents.isEmpty {
                    Text(verbatim: displayedComponents.map { Self.shortComponentName($0) }.joined(separator: " • "))
                        .font(MenuMetrics.bodyFont)
                        .foregroundStyle(statusColor)
                        .numericTransition(value: displayedComponents)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
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
        case "CLI": "CLI"
        case "VS Code extension": "VS Code"
        case "Codex in ChatGPT Desktop": "Desktop"
        default: name
        }
    }

    private var statusTitle: LocalizedStringResource {
        switch monitor.state {
        case .checking: LocalizedStringResource("service-status.checking")
        case let .available(status): status.level.title
        case .unavailable: LocalizedStringResource("service-status.unknown")
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
    var title: LocalizedStringResource {
        switch self {
        case .operational: LocalizedStringResource("service-status.operational")
        case .degradedPerformance: LocalizedStringResource("service-status.degraded-performance")
        case .partialOutage: LocalizedStringResource("service-status.partial-outage")
        case .fullOutage: LocalizedStringResource("service-status.full-outage")
        case .underMaintenance: LocalizedStringResource("service-status.under-maintenance")
        }
    }

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
        case .degradedPerformance: Color(hex: colorScheme == .dark ? 0xFEF3C7 : 0xC08A00)
        case .partialOutage: .orange
        case .fullOutage: .red
        case .underMaintenance: .blue
        }
    }
}
