import AppKit
import SwiftUI

/// 分别展示安装版本和 Codex 后台服务运行版本, 只重连当前客户端
struct CodexVersionSection: View {
    @EnvironmentObject private var animationState: SettingsWindowAnimationState
    let snapshot: CodexVersionSnapshot
    let connectionInfo: CodexServerConnectionInfo?
    let isReconnecting: Bool
    let isBusy: Bool
    let errorMessage: String?
    let onReconnect: () -> Void
    @State private var copiedPathResetTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "number.circle")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("settings.codex.version.title")

                reconnectButton

                Spacer()
            }

            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                daemonRow

                ForEach(displayedItems) { item in
                    codexVersionRow(icon: item.source == .global ? "terminal" : "app.badge", item: item)
                }
            }
            .padding(.leading, Metrics.childIndent)

            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            copiedPathResetTasks.values.forEach { $0.cancel() }
        }
    }

    private var reconnectButton: some View {
        let isWorking = isBusy || isReconnecting
        let isEnabled = !isWorking
        let label: LocalizedStringKey = isReconnecting
            ? "settings.codex.connection.status.reconnecting"
            : "settings.codex.connection.action.reconnect"

        return Button {
            onReconnect()
        } label: {
            let icon = Image(systemName: "cable.coaxial")
            Group {
                if !animationState.allowsAnimations || !isWorking {
                    // 隐藏时移除动画分支, 同时停止 phaseAnimator 和持续符号效果
                    icon
                } else if #available(macOS 26.0, *) {
                    // DrawOn 保持激活会停在隐藏状态, 交替阶段才能持续重复绘制
                    icon.phaseAnimator([true, false]) { content, isHidden in
                        content.symbolEffect(.drawOn.byLayer, options: .repeat(.continuous), isActive: isHidden)
                    } animation: { _ in
                        .linear(duration: 0.5)
                    }
                } else {
                    icon.symbolEffect(.wiggle.clockwise.byLayer, options: .repeat(.continuous))
                }
            }
            .frame(width: SettingsRowMetrics.optionsButtonSize, height: SettingsRowMetrics.optionsButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
        .disabled(!isEnabled)
        .help(label)
    }

    private var displayedItems: [CodexVersionItem] {
        [snapshot.global, snapshot.bundled].filter { $0.path != nil }
    }

    private var daemonRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu")
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tint)
            Text("settings.codex.daemon.title")
                .foregroundStyle(.secondary)
            Spacer(minLength: 28)
            VStack(alignment: .trailing, spacing: 3) {
                if let info = connectionInfo {
                    HStack(spacing: 12) {
                        Text("settings.codex.daemon.in-use")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassCapsule(tint: .green)

                        Text(info.version ?? String(localized: "codex.version.unknown"))
                            .monospacedDigit()
                            .foregroundStyle(Color.codexSecondaryLabel)
                            .numericTransition(value: info.version, enabled: animationState.allowsAnimations)
                    }
                    CopyablePathText(path: info.socketPath, isCopied: copiedPathResetTasks["shared"] != nil)
                        .onTapGesture { copyPathToPasteboard(info.socketPath, key: "shared") }
                } else {
                    Text("settings.codex.daemon.disconnected")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: Metrics.versionColumnWidth, alignment: .trailing)
        }
    }

    private func codexVersionRow(icon: String, item: CodexVersionItem) -> some View {
        let hasVersion = item.version != nil
        let isPathCopied = copiedPathResetTasks[item.source.rawValue] != nil

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tint)

            Text(item.source.displayName)
                .foregroundStyle(.secondary)

            Spacer(minLength: 28)

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.displayVersion)
                    .font(hasVersion ? .body.monospacedDigit() : .body)
                    .foregroundStyle(Color(nsColor: hasVersion ? .secondaryLabelColor : .tertiaryLabelColor))
                    .lineLimit(1)
                    .numericTransition(value: item.displayVersion, enabled: animationState.allowsAnimations)

                if let path = item.path {
                    CopyablePathText(path: path, isCopied: isPathCopied)
                        .animation(Metrics.statusAnimation, value: isPathCopied)
                        .help(
                            isPathCopied
                                ? "common.status.copied"
                                : "common.action.click-to-copy"
                        )
                        .onTapGesture {
                            copyPathToPasteboard(path, key: item.source.rawValue)
                        }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: Metrics.versionColumnWidth, alignment: .trailing)
            .animation(Metrics.statusAnimation, value: item.path)
        }
    }

    private func copyPathToPasteboard(_ path: String, key: String) {
        PasteboardWriter.copy(path)

        copiedPathResetTasks[key]?.cancel()
        copiedPathResetTasks[key] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            copiedPathResetTasks[key] = nil
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

            Text("common.status.copied")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(1)
                .opacity(isCopied ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
