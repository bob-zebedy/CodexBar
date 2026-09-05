import AppKit
import SwiftUI

/// Codex CLI/APP 版本区, 同时展示磁盘版本和当前 app-server 运行版本
struct CodexVersionSection: View {
    let snapshot: CodexCLIVersionSnapshot
    let connectionInfo: CodexCLIConnectionInfo?
    let sourceSelection: CodexCLISourceSelection
    let isReconnecting: Bool
    let isBusy: Bool
    let errorMessage: String?
    let unavailableSource: CodexCLIExecutableSource?
    let onReconnect: (CodexCLISourceSelection?) -> Void
    @State private var copiedPathResetTasks: [CodexCLIExecutableSource: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "number.circle")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("settings.codex-version.title")

                Spacer()

                sourceSelectionControls
            }

            if !displayedItems.isEmpty {
                LiquidGlassDivider()
                    .padding(.leading, Metrics.iconWidth + 10)

                VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                    ForEach(displayedItems) { item in
                        codexVersionRow(icon: item.source == .global ? "terminal" : "app.badge", item: item)
                    }
                }
                .padding(.leading, Metrics.childIndent)
            }

            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Metrics.childIndent)
            }
        }
        .onDisappear {
            copiedPathResetTasks.values.forEach { $0.cancel() }
        }
    }

    private var sourceSelectionControls: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Picker(
                "settings.codex-version.source.title",
                selection: Binding(
                    get: { availableSelections.contains(sourceSelection) ? sourceSelection : nil },
                    set: { selection in
                        guard let selection, selection != sourceSelection else { return }
                        onReconnect(selection)
                    }
                )
            ) {
                if !availableSelections.contains(sourceSelection) {
                    Text("settings.codex-version.source.select")
                        .tag(CodexCLISourceSelection?.none)
                        .disabled(true)
                }

                ForEach(availableSelections) { selection in
                    Text(selection.title)
                        .tag(Optional(selection))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: Metrics.sourcePickerWidth, alignment: .trailing)
            .disabled(isBusy)

            reconnectButton
        }
        .frame(minHeight: SettingsRowMetrics.optionsButtonSize)
    }

    private var reconnectButton: some View {
        let isEnabled = !isBusy && !isReconnecting && isSourceInstalled(sourceSelection)
        let label: LocalizedStringKey = isReconnecting
            ? "settings.codex-version.reconnecting"
            : "settings.codex-version.reconnect"

        return Button {
            onReconnect(nil)
        } label: {
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate.byLayer, options: .repeat(.periodic(delay: 0.0)), isActive: isReconnecting)
                .frame(width: SettingsRowMetrics.optionsButtonSize, height: SettingsRowMetrics.optionsButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
        .disabled(!isEnabled)
        .help(label)
    }

    private var installedItems: [CodexCLIVersionItem] {
        [snapshot.global, snapshot.bundled].filter { $0.path != nil }
    }

    private var displayedItems: [CodexCLIVersionItem] {
        [snapshot.global, snapshot.bundled].filter {
            $0.path != nil || $0.source == connectionInfo?.source
                || (snapshot.refreshedAt != .distantPast
                    && ($0.source == sourceSelection.source || $0.source == unavailableSource))
        }
    }

    private var availableSelections: [CodexCLISourceSelection] {
        CodexCLISourceSelection.allCases.filter { $0 == .automatic || isSourceInstalled($0) }
    }

    private func isSourceInstalled(_ selection: CodexCLISourceSelection) -> Bool {
        guard let source = selection.source else { return !installedItems.isEmpty }
        return installedItems.contains { $0.source == source }
    }

    private func codexVersionRow(icon: String, item: CodexCLIVersionItem) -> some View {
        let row = CodexCLIVersionDisplay(item: item, connection: connectionInfo)
        let isUnavailable = snapshot.refreshedAt != .distantPast && item.path == nil
        let statusColor: Color = isUnavailable ? .orange : .green
        let isPathCopied = copiedPathResetTasks[item.source] != nil

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tint)

            Text(item.source.displayName)
                .foregroundStyle(.secondary)

            Spacer(minLength: 28)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 12) {
                    if row.isCurrent || isUnavailable {
                        Text(isUnavailable ? "settings.codex-version.unavailable" : "settings.codex-version.in-use")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassCapsule(tint: statusColor)
                            .transition(.opacity)
                    }

                    if row.hasVersion || !isUnavailable {
                        Text(row.displayVersion)
                            .font(row.hasVersion ? .body.monospacedDigit() : .body)
                            .foregroundStyle(row.hasVersion ? .secondary : .tertiary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .animation(Metrics.statusAnimation, value: row.displayVersion)
                    }
                }
                .animation(Metrics.statusAnimation, value: row.isCurrent)
                .animation(Metrics.statusAnimation, value: isUnavailable)

                if let newerInstalledVersion = row.newerInstalledVersion {
                    Text(LocalizedStringResource("settings.codex-version.updated-to", defaultValue: "\(newerInstalledVersion)"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                if let path = row.path {
                    CopyablePathText(path: path, isCopied: isPathCopied)
                        .animation(Metrics.statusAnimation, value: isPathCopied)
                        .help(
                            isPathCopied
                                ? "common.status.copied"
                                : "common.action.click-to-copy"
                        )
                        .onTapGesture {
                            copyPathToPasteboard(path, source: item.source)
                        }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: Metrics.versionColumnWidth, alignment: .trailing)
            .animation(Metrics.statusAnimation, value: row.newerInstalledVersion)
            .animation(Metrics.statusAnimation, value: row.path)
        }
    }

    private func copyPathToPasteboard(_ path: String, source: CodexCLIExecutableSource) {
        PasteboardWriter.copy(path)

        copiedPathResetTasks[source]?.cancel()
        copiedPathResetTasks[source] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            copiedPathResetTasks[source] = nil
        }
    }

    private enum Metrics {
        static let rowSpacing: CGFloat = 14
        static let iconWidth = SettingsRowMetrics.iconWidth
        static let childIndent: CGFloat = 28
        static let sourcePickerWidth: CGFloat = 140
        static let versionColumnWidth: CGFloat = 270
        static let statusAnimation = Animation.codexStatus
    }
}

/// 路径复制后保持同一布局宽度, 避免 `已复制` 状态造成跳动
private struct CopyablePathText: View {
    let path: String
    let isCopied: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(isCopied ? 0 : 1)

            Text("common.status.copied")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(1)
                .opacity(isCopied ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
