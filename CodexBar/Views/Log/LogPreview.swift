import AppKit
import SwiftUI

// MARK: - JSON 预览与高亮

/// 日志预览文本, JSON 时会带基础语法高亮
struct LogCodePreview {
    let attributedText: NSAttributedString
    let language: String?
}

/// 将 JSON 格式化并做轻量 token 高亮, 非 JSON 保持纯文本
enum LogCodePreviewFormatter {
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
struct LogCodePreviewView: NSViewRepresentable {
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
