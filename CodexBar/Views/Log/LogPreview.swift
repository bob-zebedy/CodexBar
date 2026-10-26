import AppKit
import Observation
import SwiftUI

// MARK: - JSON 预览与高亮

/// 日志预览文本, JSON 时会带基础语法高亮
private nonisolated struct LogCodePreview {
    let attributedText: NSAttributedString
    let language: String?
}

/// 将 JSON 格式化并做轻量 token 高亮, 非 JSON 保持纯文本
private nonisolated enum LogCodePreviewFormatter {
    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: LogTypography.fullTextFont,
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

    static func preview(for text: String) throws -> LogCodePreview {
        try Task.checkCancellation()
        if let formattedJSON = formattedJSON(text) {
            return try LogCodePreview(
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

    private static func highlightedJSON(_ text: String) throws -> NSAttributedString {
        try Task.checkCancellation()
        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )

        guard let tokenRegex else {
            return attributedText
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        tokenRegex.enumerateMatches(in: text, range: fullRange) { match, _, stop in
            guard !Task.isCancelled else {
                stop.pointee = true
                return
            }
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

        try Task.checkCancellation()
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

// MARK: - 后台预处理

/// 排版期间仅由后台 actor 使用, 完成后整体转交主 actor
nonisolated struct LogPreviewDocument {
    let storage: NSTextStorage
    let container: NSTextContainer
    let contentSize: NSSize
    let language: String?
    let characterCount: Int
}

nonisolated struct LogInlinePreviewInput: Equatable, Sendable {
    let request: String?
    let detail: String?
    let needsSummary: Bool
}

nonisolated struct LogInlinePreview: Sendable {
    struct Payload: Sendable {
        let text: String
        let hasText: Bool
    }

    let input: LogInlinePreviewInput
    let request: Payload?
    let detail: Payload?
    let summary: String?
}

actor LogPreviewPreparer {
    static let shared = LogPreviewPreparer()

    func document(for text: String) throws -> sending LogPreviewDocument {
        try Task.checkCancellation()
        let preview = try LogCodePreviewFormatter.preview(for: text)
        try Task.checkCancellation()

        let storage = NSTextStorage(attributedString: preview.attributedText)
        let manager = NSLayoutManager()
        // 排版图不连接视图, 禁止 AppKit 自行调度后台排版
        manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(containerSize: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        try Task.checkCancellation()
        manager.ensureLayout(for: container)
        let usedRect = manager.usedRect(for: container)
        try Task.checkCancellation()
        return LogPreviewDocument(
            storage: storage,
            container: container,
            contentSize: NSSize(width: ceil(usedRect.maxX), height: ceil(usedRect.maxY)),
            language: preview.language,
            characterCount: text.count
        )
    }

    func inlinePreview(for input: LogInlinePreviewInput) throws -> LogInlinePreview {
        try Task.checkCancellation()
        let request = input.request.map(inlinePayload)
        try Task.checkCancellation()
        let detail = input.detail.map(inlinePayload)
        let summary = input.needsSummary ? input.detail.map {
            AppServerLogEntry.singleLinePreview($0, limit: AppServerLogEntry.summaryPreviewLength)
        } : nil
        try Task.checkCancellation()
        return LogInlinePreview(input: input, request: request, detail: detail, summary: summary)
    }

    private func inlinePayload(_ text: String) -> LogInlinePreview.Payload {
        LogInlinePreview.Payload(
            text: AppServerLogEntry.singleLinePreview(text, limit: AppServerLogEntry.expandedInlinePreviewLength),
            hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}

// MARK: - 预览生命周期

@Observable
final class LogPreviewPresentation {
    struct Request: Identifiable {
        let id = UUID()
        let entryID: UUID
        let title: String
        let text: String
    }

    struct Item: Identifiable {
        let request: Request
        let document: LogPreviewDocument
        var id: UUID {
            request.id
        }
    }

    private(set) var request: Request?
    var item: Item?

    func show(entryID: UUID, title: String, text: String) {
        request = Request(entryID: entryID, title: title, text: text)
        item = nil
    }

    func prepare(_ request: Request) async {
        guard self.request?.id == request.id else { return }
        do {
            let document = try await LogPreviewPreparer.shared.document(for: request.text)
            try Task.checkCancellation()
            guard self.request?.id == request.id else { return }
            item = Item(request: request, document: document)
        } catch is CancellationError {
            // 关闭窗口或选择其他日志后, 丢弃尚未展示的结果
        } catch {
            assertionFailure("Unexpected log preview error: \(error)")
        }
    }

    func dismiss(_ item: Item) {
        guard request?.id == item.id else { return }
        cancel()
    }

    func cancel(for entryID: UUID) {
        guard request?.entryID == entryID else { return }
        cancel()
    }

    func cancel() {
        request = nil
        item = nil
    }
}

// MARK: - 原生文本视图

/// 保留后台生成的文本存储和排版缓存, 窗口缩放只调整可滚动区域
final class LogPreviewScrollView: NSScrollView {
    private let previewDocument: LogPreviewDocument
    private static let textInset = NSSize(width: 12, height: 12)

    init(document: LogPreviewDocument) {
        previewDocument = document
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        let textView = NSTextView(frame: NSRect(origin: .zero, size: fittedSize), textContainer: document.container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = Self.textInset
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        guard let documentView else { return }
        let size = fittedSize
        if documentView.frame.size != size {
            documentView.setFrameSize(size)
        }
    }

    private var fittedSize: NSSize {
        NSSize(
            width: max(previewDocument.contentSize.width + Self.textInset.width * 2, contentSize.width),
            height: max(previewDocument.contentSize.height + Self.textInset.height * 2, contentSize.height)
        )
    }
}

struct LogCodePreviewView: NSViewRepresentable {
    let document: LogPreviewDocument

    func makeNSView(context _: Context) -> LogPreviewScrollView {
        LogPreviewScrollView(document: document)
    }

    /// 每次预览由 item.id 创建独立视图, 文档在视图生命周期内保持不变
    func updateNSView(_: LogPreviewScrollView, context _: Context) {}
}
