import AppKit
import Testing

struct LogPreviewTests {
    @Test func jsonFormattingAndHighlightingPreserveUnicodeAndOriginalText() async throws {
        let raw = #"{"z":null,"🙂":"é 汉字","a":true,"n":-1.25,"url":"https://example.com"}"#
        let presentation = LogPreviewPresentation()
        presentation.show(entryID: UUID(), title: "Response", text: raw)
        let request = try #require(presentation.request)
        await presentation.prepare(request)
        let item = try #require(presentation.item)
        let document = item.document
        let formatted = document.storage.string as NSString

        #expect(item.request.text == raw)
        #expect(document.characterCount == raw.count)
        #expect(document.language == "JSON")
        #expect(formatted.range(of: "\"a\"").location < formatted.range(of: "\"z\"").location)
        #expect(formatted.contains("\n"))
        #expect(formatted.contains("https://example.com"))
        for (token, color) in [
            ("\"🙂\"", NSColor.systemBlue),
            ("\"é 汉字\"", .systemGreen),
            ("true", .systemOrange),
            ("null", .secondaryLabelColor),
            ("-1.25", .systemPurple)
        ] {
            let range = formatted.range(of: token)
            #expect(range.location != NSNotFound)
            #expect(document.storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == color)
        }
    }

    @Test(arguments: ["", "🙂 汉字 é\nsecond line", "{invalid JSON}", "{\"partial\":\n[Truncated, original: 200000 bytes]"])
    func plainInvalidAndTruncatedContentRemainUnchanged(raw: String) async throws {
        let document = try await LogPreviewPreparer.shared.document(for: raw)
        #expect(document.language == nil)
        #expect(document.storage.string == raw)
        #expect(document.characterCount == raw.count)
    }

    @Test(arguments: ["true", "null", "42", "\"🙂\""])
    func jsonFragmentsRemainSupported(raw: String) async throws {
        let document = try await LogPreviewPreparer.shared.document(for: raw)
        #expect(document.language == "JSON")
        #expect(document.storage.string == raw)
    }

    @Test func inlinePreviewUpdatesWhenResponseArrivesWithoutChangingEntryIdentity() async throws {
        let pending = LogInlinePreviewInput(request: #"{"b":2,"a":1}"#, detail: nil, needsSummary: true)
        let first = try await LogPreviewPreparer.shared.inlinePreview(for: pending)
        #expect(first.request?.text == #"{"a":1,"b":2}"#)
        #expect(first.request?.hasText == true)
        #expect(first.detail == nil)
        let response = LogInlinePreviewInput(request: pending.request, detail: "received\nsecond line", needsSummary: true)
        let updated = try await LogPreviewPreparer.shared.inlinePreview(for: response)
        #expect(updated.input != first.input)
        #expect(updated.request?.text == first.request?.text)
        #expect(updated.detail?.text == "received...")
        #expect(updated.summary == "received...")
        let blank = LogInlinePreviewInput(request: " \n\t ", detail: nil, needsSummary: false)
        #expect(try await LogPreviewPreparer.shared.inlinePreview(for: blank).request?.hasText == false)
    }

    @Test func inlinePreviewBoundsTextAtCharacterBoundaries() async throws {
        let input = LogInlinePreviewInput(request: nil, detail: String(repeating: "🙂", count: 300), needsSummary: true)
        let preview = try await LogPreviewPreparer.shared.inlinePreview(for: input)
        #expect(preview.summary == String(repeating: "🙂", count: 160) + "...")
        #expect(preview.detail?.text == String(repeating: "🙂", count: 260) + "...")
    }

    @Test func cancelledPreparationDoesNotPublishAPreview() async throws {
        let presentation = LogPreviewPresentation()
        presentation.show(entryID: UUID(), title: "Cancelled", text: "{}")
        let request = try #require(presentation.request)
        let task = Task { await presentation.prepare(request) }
        task.cancel()
        await task.value
        #expect(presentation.item == nil)
    }

    @Test func closingAndReplacingRequestsRejectLateResults() async throws {
        let presentation = LogPreviewPresentation()
        let entryID = UUID()
        presentation.show(entryID: entryID, title: "Old", text: Self.denseJSON)
        let old = try #require(presentation.request)
        let oldTask = Task { await presentation.prepare(old) }
        await Task.yield()
        presentation.show(entryID: UUID(), title: "New", text: "new response")
        let current = try #require(presentation.request)
        presentation.cancel(for: entryID)
        #expect(presentation.request?.id == current.id)
        await presentation.prepare(current)
        await oldTask.value
        #expect(presentation.item?.id == current.id)
        #expect(presentation.item?.document.storage.string == "new response")

        presentation.show(entryID: entryID, title: "Closing", text: Self.denseJSON)
        let closing = try #require(presentation.request)
        let closingTask = Task { await presentation.prepare(closing) }
        await Task.yield()
        presentation.cancel(for: entryID)
        await closingTask.value
        #expect(presentation.request == nil)
        #expect(presentation.item == nil)
    }

    @Test func previousSheetDismissalDoesNotCancelNewRequest() async throws {
        let presentation = LogPreviewPresentation()
        presentation.show(entryID: UUID(), title: "First", text: "first")
        try await presentation.prepare(#require(presentation.request))
        let previous = try #require(presentation.item)
        presentation.show(entryID: UUID(), title: "Next", text: "next")
        let current = try #require(presentation.request)
        presentation.dismiss(previous)
        #expect(presentation.request?.id == current.id)
        await presentation.prepare(current)
        let item = try #require(presentation.item)
        #expect(item.document.storage.string == "next")
        presentation.dismiss(item)
        #expect(presentation.request == nil)
        #expect(presentation.item == nil)
    }

    @Test func repeatedLayoutAndResizeKeepSelectionScrollAndLayout() async throws {
        let document = try await LogPreviewPreparer.shared.document(for: Self.denseJSON)
        let scrollView = LogPreviewScrollView(document: document)
        scrollView.setFrameSize(NSSize(width: 860, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? NSTextView)
        let manager = try #require(textView.layoutManager)
        #expect(textView.textStorage === document.storage)
        #expect(textView.textContainer === document.container)
        #expect(manager.firstUnlaidCharacterIndex() == document.storage.length)
        let selection = NSRange(location: document.storage.length - 10, length: 10)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        let visibleOrigin = scrollView.contentView.bounds.origin
        #expect(visibleOrigin.y > 0)
        for _ in 0 ..< 3 {
            scrollView.needsLayout = true
            scrollView.layoutSubtreeIfNeeded()
        }
        #expect(scrollView.documentView === textView)
        #expect(textView.selectedRange() == selection)
        #expect(scrollView.contentView.bounds.origin == visibleOrigin)

        scrollView.setFrameSize(NSSize(width: 1100, height: 800))
        scrollView.layoutSubtreeIfNeeded()
        #expect(textView.frame.width >= scrollView.contentSize.width)
        #expect(textView.frame.height >= document.contentSize.height)
        #expect(textView.selectedRange() == selection)
        #expect(manager.firstUnlaidCharacterIndex() == document.storage.length)
        textView.scrollRangeToVisible(selection)
        let selectedRect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil), in: document.container)
        #expect(scrollView.contentView.bounds.maxY >= selectedRect.maxY)
    }

    @Test func longLinesScrollHorizontallyAndShortTextFillsViewport() async throws {
        let document = try await LogPreviewPreparer.shared.document(for: String(repeating: "a", count: 131000))
        let scrollView = LogPreviewScrollView(document: document)
        scrollView.setFrameSize(NSSize(width: 860, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.scrollRangeToVisible(NSRange(location: document.storage.length - 1, length: 1))
        #expect(scrollView.contentView.bounds.origin.x > 0)
        #expect(scrollView.contentView.bounds.maxX >= document.contentSize.width)

        let short = try await LogPreviewPreparer.shared.document(for: "🙂 汉字 é")
        let shortScrollView = LogPreviewScrollView(document: short)
        shortScrollView.setFrameSize(NSSize(width: 860, height: 600))
        shortScrollView.layoutSubtreeIfNeeded()
        let shortTextView = try #require(shortScrollView.documentView as? NSTextView)
        #expect(shortTextView.string == "🙂 汉字 é")
        #expect(shortTextView.frame.width >= shortScrollView.contentSize.width)
        #expect(shortTextView.frame.height >= shortScrollView.contentSize.height)
        shortTextView.setSelectedRange(NSRange(location: 0, length: short.storage.length))
        #expect(shortTextView.selectedRange().length == short.storage.length)
        #expect(shortScrollView.contentView.bounds.origin.x == 0)
    }

    private static var denseJSON: String {
        "[" + Array(repeating: "0", count: 65500).joined(separator: ",") + "]"
    }
}
