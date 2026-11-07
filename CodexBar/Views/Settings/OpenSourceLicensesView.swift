import AppKit
import SwiftUI

nonisolated enum OpenSourceLicense: String, CaseIterable, Sendable {
    case codexBar = "LICENSE"
    case thirdParty = "ThirdPartyLicenses.txt"

    @concurrent func load(bundle: Bundle = .main) async throws -> String {
        guard let url = bundle.url(forResource: rawValue, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

struct OpenSourceLicensesView: View {
    let bundle: Bundle
    @State private var selectedLicense = OpenSourceLicense.codexBar

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("licenses.category.title", selection: $selectedLicense) {
                Text(verbatim: "CodexBar")
                    .tag(OpenSourceLicense.codexBar)
                Text("licenses.tab.third-party")
                    .tag(OpenSourceLicense.thirdParty)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            LicenseDocumentView(license: selectedLicense, bundle: bundle)
                .id(selectedLicense)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
        .padding(16)
    }
}

private struct LicenseDocumentView: View {
    let license: OpenSourceLicense
    let bundle: Bundle
    @State private var loadResult: Result<String, any Error>?

    var body: some View {
        Group {
            switch loadResult {
            case let .success(text)?:
                LicenseTextView(text: text, license: license)
            case .failure?:
                Text("licenses.load-failed")
                    .foregroundStyle(.secondary)
            case nil:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if case .success? = loadResult {
                return
            }
            do {
                let loaded = try await license.load(bundle: bundle)
                try Task.checkCancellation()
                loadResult = .success(loaded)
            } catch is CancellationError {
            } catch {
                loadResult = .failure(error)
            }
        }
    }
}

final class LicenseTextScrollView: NSScrollView {
    init(text: String, license: OpenSourceLicense = .codexBar) {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor

        let textView = LicenseDocumentTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = LicenseDocumentTextView.bodyFont
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.configure(text: text, license: license)
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        // NSTextView 会向下取整文字原点, 内边距同步取整以保持两侧对称
        let inset = NSSize(width: max(16, floor((contentSize.width - 600) / 2)), height: 16)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
            textView.needsDisplay = true
        }
    }
}

private final class LicenseDocumentTextView: NSTextView {
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let characterWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
    private var separatorRanges: [NSRange] = []

    private static let gplHeading = try? NSRegularExpression(pattern: #"(?m)^( {12,})(\S[^\r\n]*)$"#)

    /// 只识别生成脚本添加的组件头, 上游正文中的标题和分隔符保持原样
    private static let componentHeader = try? NSRegularExpression(
        pattern: #"(?m)^([^\r\n]+)\n(={8,})\n\n(?=Version: [^\r\n]+\nSource: [^\r\n]+\nLicense: [^\r\n]+\n\n)"#
    )

    func configure(text: String, license: OpenSourceLicense) {
        let document = NSMutableAttributedString(string: text, attributes: [
            .font: Self.bodyFont,
            .foregroundColor: NSColor.textColor
        ])
        let source = text as NSString
        if license == .codexBar {
            let headings = Self.gplHeading?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
            for heading in headings {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                document.addAttribute(.paragraphStyle, value: paragraph, range: source.paragraphRange(for: heading.range))
                // 抵消标题前导空格的显示宽度, 原文和复制内容仍保留这些空格
                document.addAttribute(.kern, value: -Self.characterWidth, range: heading.range(at: 1))
            }
        } else {
            let headers = Self.componentHeader?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
            for (index, header) in headers.enumerated() {
                let title = source.paragraphRange(for: header.range(at: 1))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.paragraphSpacingBefore = index == 0 ? 0 : 24
                paragraph.paragraphSpacing = 8
                document.addAttributes([
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .paragraphStyle: paragraph
                ], range: title)
                let separator = header.range(at: 2)
                document.addAttribute(.foregroundColor, value: NSColor.clear, range: separator)
                separatorRanges.append(separator)
            }
        }
        textStorage?.setAttributedString(document)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let scrollView = enclosingScrollView
        let keepsTopEdge = scrollView?.contentView.bounds.minY == 0
        super.setFrameSize(newSize)
        guard keepsTopEdge, let scrollView else { return }
        // 保持顶部边缘, 避免 NSTextView 在宽度变化后把视口移到首行文字处
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        for range in separatorRanges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: origin.x, dy: origin.y)
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: origin.x + padding, y: line.midY))
            divider.line(to: NSPoint(x: origin.x + textContainer.size.width - padding, y: line.midY))
            guard divider.bounds.insetBy(dx: 0, dy: -0.5).intersects(dirtyRect) else { continue }
            divider.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            divider.stroke()
        }
    }
}

private struct LicenseTextView: NSViewRepresentable {
    let text: String
    let license: OpenSourceLicense

    func makeNSView(context _: Context) -> LicenseTextScrollView {
        LicenseTextScrollView(text: text, license: license)
    }

    /// 文本在创建时固定, 切换许可证由外层文档身份重建视图
    func updateNSView(_: LicenseTextScrollView, context _: Context) {}
}
