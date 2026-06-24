import AppKit
import SwiftUI

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

            Text("Codex app-server 日志")
                .font(.headline)

            Text("\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))

            Spacer()

            Button {
                store.clear()
            } label: {
                Label("清空", systemImage: "trash")
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

            Text("暂无日志")
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
                        payloadBlock(caption: "请求", time: entry.requestedAt, text: request, color: .primary)
                    }

                    if let detail = entry.detail {
                        payloadBlock(
                            caption: detailCaption,
                            time: entry.respondedAt,
                            text: detail,
                            color: entry.kind == .failure ? .red : .primary
                        )
                    } else if entry.kind == .pending {
                        Text("等待响应…")
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
                // 无方法名的记录(信息/进程级错误)直接预览正文, 避免标签后留空
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

    private func payloadBlock(caption: String, time: Date?, text: String, color: Color) -> some View {
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
                        title: "预览",
                        systemImage: "doc.text.magnifyingglass",
                        help: "预览完整\(caption)"
                    ) {
                        fullTextItem = FullLogTextItem(title: caption, text: text)
                    }

                    LogHeaderActionButton(
                        title: "复制",
                        systemImage: "doc.on.doc",
                        help: "复制完整\(caption)"
                    ) {
                        LogClipboard.copy(text)
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

    private var detailCaption: String {
        switch entry.kind {
        case .response, .emptyResponse:
            "响应"
        case .failure:
            "错误"
        default:
            "详情"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct FullLogTextItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct LogHeaderActionButton: View {
    let title: String
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

private enum LogClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

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

                Text("\(item.text.count)")
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
                    LogClipboard.copy(item.text)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LogCodePreviewView(attributedText: preview.attributedText)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

private struct LogCodePreview {
    let attributedText: NSAttributedString
    let language: String?
}

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
        textView.autoresizingMask = [.width]
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
    }
}

private extension RequestLogEntry.Kind {
    var label: String {
        switch self {
        case .pending:
            "进行"
        case .response:
            "完成"
        case .failure:
            "错误"
        case .emptyResponse:
            "请求"
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
