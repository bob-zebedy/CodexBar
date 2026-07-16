import AppKit
import SwiftUI

/// Codex CLI/APP 版本区, 同时展示磁盘版本和当前 app-server 运行版本
struct CodexVersionSection: View {
    let snapshot: CodexCLIVersionSnapshot
    let connectionInfo: CodexCLIConnectionInfo?
    @State private var copiedPathResetTasks: [CodexCLIExecutableSource: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "number.circle")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("Codex 版本")

                Spacer()
            }

            LiquidGlassDivider()
                .padding(.leading, Metrics.iconWidth + 10)

            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                codexVersionRow(icon: "terminal", item: snapshot.global)

                codexVersionRow(icon: "app.badge", item: snapshot.bundled)
            }
            .padding(.leading, Metrics.childIndent)
        }
        .onDisappear {
            copiedPathResetTasks.values.forEach { $0.cancel() }
        }
    }

    private func codexVersionRow(icon: String, item: CodexCLIVersionItem) -> some View {
        let row = CodexCLIVersionDisplay(item: item, connection: connectionInfo)
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
                    if row.isCurrent {
                        Text("当前使用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassCapsule(tint: .green)
                            .transition(.opacity)
                    }

                    Text(row.displayVersion)
                        .font(row.hasVersion ? .body.monospacedDigit() : .body)
                        .foregroundStyle(row.hasVersion ? .secondary : .tertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(Metrics.statusAnimation, value: row.displayVersion)
                }
                .animation(Metrics.statusAnimation, value: row.isCurrent)

                if let newerInstalledVersion = row.newerInstalledVersion {
                    Text("已更新至 \(newerInstalledVersion)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                if let path = row.path {
                    CopyablePathText(path: path, isCopied: isPathCopied)
                        .animation(Metrics.statusAnimation, value: isPathCopied)
                        .help(isPathCopied ? "已复制" : "点击复制")
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

            Text("已复制")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(1)
                .opacity(isCopied ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
