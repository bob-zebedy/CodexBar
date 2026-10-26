import AppKit
import SwiftUI

enum LogTypography {
    static let titleFont = Font.body.weight(.semibold)
    static let bodyFont = Font.body.weight(.regular)
    static let sectionTitleFont = Font.caption.weight(.semibold)
    static let captionFont = Font.caption.weight(.regular)
    static let badgeFont = Font.caption.weight(.medium)
    static let controlFont = Font.system(size: NSFont.smallSystemFontSize, weight: .regular)

    nonisolated static var fullTextFont: NSFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}

/// app-server 交互日志窗口根视图
struct LogView: View {
    @ObservedObject var store: AppServerLogViewModel
    let mainPanelSettings: MainPanelSettings
    @State private var preview = LogPreviewPresentation()
    @State private var scrollPosition = ScrollPosition(idType: UUID.self, edge: .top)

    var body: some View {
        // 每轮渲染只取一次发布快照复用
        let entries = store.entries
        VStack(spacing: 0) {
            header
            Divider()

            if let error = store.errorMessage {
                Text(error)
                    .font(LogTypography.captionFont)
                    .foregroundStyle(.red)
                    .padding(8)
            }

            if entries.isEmpty, store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else {
                logList(entries: entries)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: preview.request?.id) {
            if let request = preview.request {
                await preview.prepare(request)
            }
        }
        .sheet(item: $preview.item) { item in
            FullLogTextView(item: item)
                .onDisappear { preview.dismiss(item) }
        }
        .onDisappear { preview.cancel() }
        .contentAnimations(settings: mainPanelSettings)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)

            Text("log.app-server.window.title")
                .font(LogTypography.titleFont)

            Text(verbatim: "\(store.totalCount)")
                .font(LogTypography.badgeFont.monospacedDigit())
                .foregroundStyle(Color.codexSecondaryLabel)
                .numericTransition(value: store.totalCount, comparison: Double(store.totalCount))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(.quaternary)
                }

            Spacer()

            Button {
                Task { await store.clear() }
            } label: {
                Label("common.action.clear", systemImage: "trash")
            }
            .controlSize(.small)
            .font(LogTypography.controlFont)
            .disabled(store.totalCount == 0 || store.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)

            Text("log.empty.no-entries")
                .font(LogTypography.bodyFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logList(entries: [AppServerLogEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    VStack(spacing: 0) {
                        LogRow(entry: entry, preview: preview)
                        Divider()
                    }
                }
                if store.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .task(id: entries.last?.id) { await store.loadMore() }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition, anchor: .top)
        .onScrollPhaseChange { _, phase, context in
            // 浏览时按日志身份保持位置, 回到顶部后才重新跟随新日志
            if phase == .idle, context.geometry.contentOffset.y + context.geometry.contentInsets.top <= 1 {
                scrollPosition.scrollTo(edge: .top)
            }
        }
        .onDisappear { scrollPosition = ScrollPosition(idType: UUID.self, edge: .top) }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 单条日志行

/// 单条日志行, 摘要行可展开查看请求和响应预览
private struct LogRow: View {
    let entry: AppServerLogEntry
    @State private var isExpanded = false
    let preview: LogPreviewPresentation
    @State private var inlinePreview: LogInlinePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                summary
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let request = entry.request {
                        payloadBlock(
                            caption: "log.payload.request",
                            time: entry.requestedAt,
                            text: request,
                            inline: currentInlinePreview?.request,
                            color: .primary
                        )
                    }

                    if let detail = entry.detail {
                        payloadBlock(
                            caption: detailCaption,
                            time: entry.respondedAt,
                            text: detail,
                            inline: currentInlinePreview?.detail,
                            color: entry.status == .failure ? .red : .primary
                        )
                    } else if entry.status == .pending {
                        Text("log.status.waiting-response")
                            .font(LogTypography.captionFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .task(id: inlineInput) {
            let input = inlineInput
            guard inlinePreview?.input != input else { return }
            do {
                let result = try await LogPreviewPreparer.shared.inlinePreview(for: input)
                try Task.checkCancellation()
                inlinePreview = result
            } catch is CancellationError {
                // 行离开列表或正文更新后, 由下一次任务生成摘要
            } catch {
                assertionFailure("Unexpected inline preview error: \(error)")
            }
        }
        .onDisappear { preview.cancel(for: entry.id) }
    }

    private var inlineInput: LogInlinePreviewInput {
        LogInlinePreviewInput(request: entry.request, detail: entry.detail, needsSummary: entry.method == nil)
    }

    private var currentInlinePreview: LogInlinePreview? {
        inlinePreview?.input == inlineInput ? inlinePreview : nil
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            Text(Self.timeFormatter.string(from: entry.requestedAt))
                .font(LogTypography.captionFont.monospaced())
                .foregroundStyle(.secondary)

            Text(entry.source.label)
                .font(LogTypography.badgeFont)
                .foregroundStyle(entry.status.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.status.tint.opacity(0.14))
                }

            if let method = entry.method {
                Text(method)
                    .font(LogTypography.sectionTitleFont.monospaced())
                    .foregroundStyle(.primary)
            } else if entry.detail != nil {
                // 无方法名的记录 (信息/进程级错误) 直接预览正文
                // 避免标签后留空
                Text(verbatim: currentInlinePreview?.summary ?? "")
                    .font(LogTypography.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func payloadBlock(
        caption: LocalizedStringResource,
        time: Date?,
        text: String,
        inline: LogInlinePreview.Payload?,
        color: Color
    ) -> some View {
        let caption = String(localized: caption)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(LogTypography.sectionTitleFont)
                    .foregroundStyle(.tertiary)

                if let time {
                    Text(Self.timeFormatter.string(from: time))
                        .font(LogTypography.captionFont.monospaced())
                        .foregroundStyle(.tertiary)
                }

                if inline?.hasText == true {
                    Button {
                        preview.show(entryID: entry.id, title: caption, text: text)
                    } label: {
                        Label("common.action.preview", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        PasteboardWriter.copy(text)
                    } label: {
                        Label("common.action.copy", systemImage: "doc.on.doc")
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(LogTypography.controlFont)

            Text(verbatim: inline?.text ?? "")
                .font(LogTypography.captionFont.monospaced())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailCaption: LocalizedStringResource {
        if entry.isConnectionEvent {
            return "log.payload.details"
        }
        if entry.isReceived {
            return "log.payload.received"
        }
        if entry.status == .failure {
            return "log.label.error"
        }
        return entry.source == .request ? "log.payload.response" : "log.payload.details"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - 全文查看

/// 完整请求/响应预览弹窗
private struct FullLogTextView: View {
    let item: LogPreviewPresentation.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(item.request.title)
                    .font(LogTypography.titleFont)

                Text(verbatim: "\(item.document.characterCount)")
                    .font(LogTypography.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let language = item.document.language {
                    Text(language)
                        .font(LogTypography.badgeFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary)
                        }
                }

                Spacer()

                Button {
                    PasteboardWriter.copy(item.request.text)
                } label: {
                    Label("common.action.copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .font(LogTypography.controlFont)

                Button {
                    dismiss()
                } label: {
                    Label("common.action.close", systemImage: "xmark")
                }
                .controlSize(.small)
                .font(LogTypography.controlFont)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LogCodePreviewView(document: item.document)
                .id(item.id)
                .frame(minWidth: 860, minHeight: 600)
        }
    }
}

private extension AppServerLogEntry.Source {
    var label: LocalizedStringResource {
        switch self {
        case .request: "log.payload.request"
        case .sent: "log.label.sent"
        case .received: "log.label.received"
        case .connection: "log.label.connection-event"
        case .local: "log.label.local"
        }
    }
}

private extension AppServerLogEntry.Status {
    var tint: Color {
        switch self {
        case .pending: .orange
        case .success: .green
        case .failure: .red
        case .information: .blue
        }
    }
}
