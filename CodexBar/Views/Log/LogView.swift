import AppKit
import SwiftUI

/// app-server 交互日志窗口根视图
struct LogView: View {
    @ObservedObject var store: AppServerLogViewModel

    var body: some View {
        // 每轮渲染只取一次发布快照复用
        let entries = store.entries
        VStack(spacing: 0) {
            header
            Divider()

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)

            Text("log.app-server.window.title")
                .font(.headline)

            Text(verbatim: "\(store.totalCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.codexSecondaryLabel)
                .numericTransition(value: store.totalCount, comparison: Double(store.totalCount))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))

            Spacer()

            Button {
                Task { await store.clear() }
            } label: {
                Label("common.action.clear", systemImage: "trash")
            }
            .controlSize(.small)
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
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logList(entries: [AppServerLogEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    LogRow(entry: entry)
                    Divider()
                }
                if store.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .task(id: entries.last?.id) { await store.loadMore() }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 单条日志行

/// 单条日志行, 摘要行可展开查看请求和响应预览
private struct LogRow: View {
    let entry: AppServerLogEntry
    @State private var isExpanded = false
    @State private var fullTextItem: FullLogTextItem?

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
                            color: .primary
                        )
                    }

                    if let detail = entry.detail {
                        payloadBlock(
                            caption: detailCaption,
                            time: entry.respondedAt,
                            text: detail,
                            color: entry.status == .failure ? .red : .primary
                        )
                    } else if entry.status == .pending {
                        Text("log.status.waiting-response")
                            .font(.caption.monospaced())
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
        .sheet(item: $fullTextItem) { item in
            FullLogTextView(item: item)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            Text(Self.timeFormatter.string(from: entry.requestedAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(entry.source.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.status.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.status.tint.opacity(0.14))
                )

            if let method = entry.method {
                Text(method)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.primary)
            } else if let detail = entry.detail {
                // 无方法名的记录 (信息/进程级错误) 直接预览正文
                // 避免标签后留空
                Text(AppServerLogEntry.singleLinePreview(detail, limit: AppServerLogEntry.summaryPreviewLength))
                    .font(.caption)
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
        color: Color
    ) -> some View {
        let caption = String(localized: caption)
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let displayText = AppServerLogEntry.singleLinePreview(
            text,
            limit: AppServerLogEntry.expandedInlinePreviewLength
        )

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                if let time {
                    Text(Self.timeFormatter.string(from: time))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                if hasText {
                    Button {
                        fullTextItem = FullLogTextItem(title: caption, text: text)
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
            .font(.caption)

            Text(verbatim: displayText)
                .font(.caption.monospaced())
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

/// 预览弹窗数据源
private struct FullLogTextItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// 完整请求/响应预览弹窗
private struct FullLogTextView: View {
    let item: FullLogTextItem
    @Environment(\.dismiss) private var dismiss
    private let preview: LogCodePreview

    init(item: FullLogTextItem) {
        self.item = item
        preview = LogCodePreviewFormatter.preview(for: item.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(item.title)
                    .font(.headline)

                Text(verbatim: "\(item.text.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let language = preview.language {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary)
                        )
                }

                Spacer()

                Button {
                    PasteboardWriter.copy(item.text)
                } label: {
                    Label("common.action.copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    dismiss()
                } label: {
                    Label("common.action.close", systemImage: "xmark")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LogCodePreviewView(attributedText: preview.attributedText)
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
