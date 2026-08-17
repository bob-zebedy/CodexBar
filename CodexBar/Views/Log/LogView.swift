import AppKit
import SwiftUI

/// app-server 交互日志窗口根视图
struct LogView: View {
    @ObservedObject var store: RequestLogStore

    var body: some View {
        // 每轮渲染只取一次发布快照复用
        let entries = store.entries
        VStack(spacing: 0) {
            header(entries: entries)
            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                logList(entries: entries)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func header(entries: [RequestLogEntry]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)

            Text("log.window.app-server-title")
                .font(.headline)

            Text(verbatim: "\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))

            Spacer()

            Button {
                store.clear()
            } label: {
                Label("common.action.clear", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(entries.isEmpty)
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

    private func logList(entries: [RequestLogEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    LogRow(entry: entry)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 单条日志行

/// 单条日志行, 摘要行可展开查看请求和响应预览
private struct LogRow: View {
    let entry: RequestLogEntry
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
                            color: entry.kind == .failure ? .red : .primary
                        )
                    } else if entry.kind == .pending {
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

            Text(entry.kind.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.kind.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.kind.tint.opacity(0.14))
                )

            if let method = entry.method {
                Text(method)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.primary)
            } else if let detail = entry.detail {
                // 无方法名的记录 (信息/进程级错误) 直接预览正文
                // 避免标签后留空
                Text(RequestLogEntry.singleLinePreview(detail, limit: RequestLogEntry.summaryPreviewLength))
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
        let displayText = RequestLogEntry.singleLinePreview(
            text,
            limit: RequestLogEntry.expandedInlinePreviewLength
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
                    LogHeaderActionButton(
                        title: "common.action.preview",
                        systemImage: "doc.text.magnifyingglass",
                        help: String(localized: "log.action.preview-full", defaultValue: "\(caption)")
                    ) {
                        fullTextItem = FullLogTextItem(title: caption, text: text)
                    }

                    LogHeaderActionButton(
                        title: "common.action.copy",
                        systemImage: "doc.on.doc",
                        help: String(localized: "log.action.copy-full", defaultValue: "\(caption)")
                    ) {
                        PasteboardWriter.copy(text)
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
        switch entry.kind {
        case .response, .emptyResponse:
            "log.payload.response"
        case .failure:
            "log.label.error"
        default:
            "log.payload.details"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
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

/// 复制/预览按钮的统一样式入口
private struct LogHeaderActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(help)
    }
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

// MARK: - JSON 预览与高亮

/// 日志预览文本, JSON 时会带基础语法高亮
private struct LogCodePreview {
    let attributedText: NSAttributedString
    let language: String?
}

/// 将 JSON 格式化并做轻量 token 高亮, 非 JSON 保持纯文本
private enum LogCodePreviewFormatter {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static let jsonReadingOptions: JSONSerialization.ReadingOptions = [.fragmentsAllowed]
    private static let jsonWritingOptions: JSONSerialization.WritingOptions = [
        .fragmentsAllowed,
        .prettyPrinted,
        .sortedKeys,
        .withoutEscapingSlashes
    ]
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|\b(?:true|false|null)\b|[{}\[\]:,]"#
    )

    static func preview(for text: String) -> LogCodePreview {
        if let formattedJSON = formattedJSON(text) {
            return LogCodePreview(
                attributedText: highlightedJSON(formattedJSON),
                language: "JSON"
            )
        }

        return LogCodePreview(
            attributedText: attributedPlainText(text),
            language: nil
        )
    }

    private static func formattedJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: jsonReadingOptions),
              let output = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: jsonWritingOptions
              ) else {
            return nil
        }

        return String(bytes: output, encoding: .utf8)
    }

    private static func attributedPlainText(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: baseAttributes
        )
    }

    private static func highlightedJSON(_ text: String) -> NSAttributedString {
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )

        guard let tokenRegex else {
            return attributedText
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        tokenRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let range = match?.range else {
                return
            }

            let token = nsText.substring(with: range)
            attributedText.addAttribute(
                .foregroundColor,
                value: color(for: token, in: nsText, range: range),
                range: range
            )
        }

        return attributedText
    }

    private static func color(for token: String, in text: NSString, range: NSRange) -> NSColor {
        if token.hasPrefix("\"") {
            return isJSONKey(in: text, after: range) ? .systemBlue : .systemGreen
        }

        if token == "true" || token == "false" {
            return .systemOrange
        }

        if token == "null" {
            return .secondaryLabelColor
        }

        if token.first?.isNumber == true || token.hasPrefix("-") {
            return .systemPurple
        }

        return .tertiaryLabelColor
    }

    private static func isJSONKey(in text: NSString, after range: NSRange) -> Bool {
        var cursor = range.location + range.length
        while cursor < text.length {
            guard let scalar = UnicodeScalar(Int(text.character(at: cursor))),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            cursor += 1
        }

        guard cursor < text.length else {
            return false
        }

        return text.character(at: cursor) == 58
    }
}

/// AppKit 文本视图承载完整日志, 支持横向滚动
private struct LogCodePreviewView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        textView.textStorage?.setAttributedString(attributedText)
        updateDocumentSize(for: textView, in: scrollView)
    }

    private func updateDocumentSize(for textView: NSTextView, in scrollView: NSScrollView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        let minimumSize = scrollView.contentSize
        let fittedSize = NSSize(
            width: max(ceil(usedRect.maxX + inset.width * 2), minimumSize.width),
            height: max(ceil(usedRect.maxY + inset.height * 2), minimumSize.height)
        )

        textView.setFrameSize(fittedSize)
    }
}

private extension RequestLogEntry.Kind {
    var label: LocalizedStringResource {
        switch self {
        case .pending:
            "log.status.in-progress"
        case .response:
            "common.status.completed"
        case .failure:
            "log.label.error"
        case .emptyResponse:
            "log.payload.request"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            .orange
        case .response:
            .green
        case .failure:
            .red
        case .emptyResponse:
            .blue
        }
    }
}
