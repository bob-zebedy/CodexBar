import AppKit
import SwiftUI

/// 分别展示安装版本和 Codex 后台服务运行版本, 只重连当前客户端
struct CodexVersionSection: View {
    @EnvironmentObject private var animationState: SettingsWindowAnimationState
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let snapshot: CodexVersionSnapshot
    let connectionInfo: CodexServerConnectionInfo?
    let isReconnecting: Bool
    let isBusy: Bool
    let onReconnect: () -> Void
    @State private var isExpanded = false
    @State private var copiedPathResetTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "number.circle")
                        .frame(width: Metrics.iconWidth)
                        .foregroundStyle(.tint)

                    Text("settings.codex.version.title")
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleDetails)

                reconnectButton

                Button(action: toggleDetails) {
                    HStack(spacing: Metrics.controlSpacing) {
                        Spacer(minLength: 0)

                        if !isExpanded {
                            if let connectionInfo {
                                Text("settings.codex.daemon.title")
                                Text(connectionInfo.version)
                                    .monospacedDigit()
                            } else {
                                Text("settings.codex.daemon.disconnected")
                            }
                        }

                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            SettingsDrawerLayout(progress: isExpanded ? 1 : 0) {
                VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                    daemonRow

                    ForEach(snapshot.installedItems) { item in
                        codexVersionRow(icon: item.source == .standalone ? "terminal" : "app.badge", item: item)
                    }
                }
                .padding(.leading, Metrics.childIndent)
                .padding(.top, Metrics.rowSpacing)
            }
            .clipped()
            .allowsHitTesting(isExpanded)
        }
        .font(SettingsRowMetrics.bodyFont)
        .onDisappear {
            copiedPathResetTasks.values.forEach { $0.cancel() }
        }
    }

    private func toggleDetails() {
        withAnimation(allowsAnimations ? SettingsOptionsPanelMetrics.contentAnimation : nil) {
            isExpanded.toggle()
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
            .imageScale(.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
        .disabled(!isEnabled)
        .help(label)
    }

    private var daemonRow: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .top, spacing: Metrics.controlSpacing) {
                Image(systemName: "cpu")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)
                Text("settings.codex.daemon.title")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 28)

                if let info = connectionInfo {
                    HStack(spacing: 12) {
                        Text("settings.codex.daemon.in-use")
                            .font(SettingsRowMetrics.badgeFont)
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassCapsule(tint: Color.green)

                        Text(info.version)
                            .monospacedDigit()
                            .foregroundStyle(Color.codexSecondaryLabel)
                            .numericTransition(value: info.version)
                    }
                } else {
                    Text("settings.codex.daemon.disconnected")
                        .foregroundStyle(.secondary)
                }
            }

            if let info = connectionInfo {
                copyablePath(info.socketPath, key: "shared")
            }
        }
    }

    private func codexVersionRow(icon: String, item: CodexVersionItem) -> some View {
        let (text, hasVersion) = switch item.result {
        case let .success(version): (version, true)
        case let .failure(error): (error.message, false)
        }

        return VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .top, spacing: Metrics.controlSpacing) {
                Image(systemName: icon)
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)

                Text(item.source.displayName)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 28)

                Text(text)
                    .font(hasVersion ? SettingsRowMetrics.bodyFont.monospacedDigit() : SettingsRowMetrics.bodyFont)
                    .foregroundStyle(Color(nsColor: hasVersion ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor))
                    .lineLimit(1)
                    .numericTransition(value: text)
            }

            copyablePath(item.path, key: item.source.rawValue)
        }
        .animation(Metrics.statusAnimation, value: item.path)
    }

    private func copyablePath(_ path: String, key: String) -> some View {
        CopyablePathText(path: path, isCopied: copiedPathResetTasks[key] != nil)
            .padding(.leading, Metrics.iconWidth + Metrics.controlSpacing)
            .onTapGesture { copyPathToPasteboard(path, key: key) }
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
        static let controlSpacing: CGFloat = 10
        static let childIndent: CGFloat = 28
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
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(isCopied ? 0 : 1)

            Text("common.status.copied")
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(Color.green)
                .lineLimit(1)
                .opacity(isCopied ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.codexStatus, value: isCopied)
    }
}
