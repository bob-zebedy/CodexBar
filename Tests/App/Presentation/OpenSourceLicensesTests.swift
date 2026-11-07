import AppKit
import SwiftUI
import Testing

struct OpenSourceLicensesTests {
    @Test(.tags(.integration), arguments: OpenSourceLicense.allCases)
    @concurrent nonisolated func bundledLicensesMatchCompleteSourceFiles(license: OpenSourceLicense) async throws {
        let text = try await license.load(bundle: Bundle(for: LicenseBundleAnchor.self))
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePath = license == .codexBar ? "LICENSE" : "CodexBar/Resources/ThirdPartyLicenses.txt"
        let source = try Data(contentsOf: projectURL.appendingPathComponent(relativePath))
        #expect(!source.isEmpty)
        #expect(Data(text.utf8) == source)
    }

    @Test func readOnlyTextSupportsSelectionCopyScrollingAndResize() throws {
        let text = String(repeating: "License text with Unicode: 汉字 🙂 é and a long line that wraps inside the reading area.\n", count: 300)
        let scrollView = LicenseTextScrollView(text: text)
        scrollView.setFrameSize(NSSize(width: 700, height: 420))
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(scrollView.window == nil)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.string == text)
        #expect(textView.frame.width == scrollView.contentSize.width)

        let ending = NSRange(location: (text as NSString).length - 5, length: 5)
        textView.setSelectedRange(ending)
        textView.scrollRangeToVisible(ending)
        #expect(scrollView.contentView.bounds.origin.y > 0)

        scrollView.setFrameSize(NSSize(width: 560, height: 400))
        scrollView.layoutSubtreeIfNeeded()
        #expect(textView.frame.width == scrollView.contentSize.width)
        #expect(textView.selectedRange() == ending)
        #expect(textView.string == text)

        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: (text as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test func readingColumnsHaveMatchingMarginsWhenResizing() throws {
        let text = String(repeating: "License paragraph\n", count: 100)
        let scrollView = LicenseTextScrollView(text: text, license: .codexBar)
        let thirdPartyScrollView = LicenseTextScrollView(text: text, license: .thirdParty)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let thirdPartyTextView = try #require(thirdPartyScrollView.documentView as? NSTextView)
        let container = try #require(textView.textContainer)
        let thirdPartyContainer = try #require(thirdPartyTextView.textContainer)
        let selection = NSRange(location: 8, length: 9)
        textView.setSelectedRange(selection)
        for width in [1100.0, 622, 420, 900] {
            scrollView.setFrameSize(NSSize(width: width, height: 400))
            scrollView.layoutSubtreeIfNeeded()
            thirdPartyScrollView.setFrameSize(NSSize(width: width, height: 400))
            thirdPartyScrollView.layoutSubtreeIfNeeded()
            let left = textView.textContainerOrigin.x
            let right = scrollView.contentSize.width - left - container.size.width
            #expect(abs(left - right) < 1)
            #expect(left >= 16)
            #expect(container.size.width <= 600)
            #expect(textView.textContainerOrigin == thirdPartyTextView.textContainerOrigin)
            #expect(container.size.width == thirdPartyContainer.size.width)
            #expect(textView.selectedRange() == selection)
        }
        #expect(scrollView.window == nil)
        #expect(thirdPartyScrollView.window == nil)
    }

    @Test(arguments: OpenSourceLicense.allCases, [false, true])
    func initialLayoutStartsAtTopAndKeepsReadingPosition(license: OpenSourceLicense, stagesEmptyLayout: Bool) throws {
        let text = """
        Example Library
        ===============

        Version: 1.0
        Source: https://example.com/library
        License: https://example.com/library/LICENSE
        """ + "\n\n" + String(repeating: "License paragraph with a fixed line width.\n", count: 300)
        let scrollView = LicenseTextScrollView(text: text, license: license)
        if stagesEmptyLayout {
            scrollView.layoutSubtreeIfNeeded()
            scrollView.setFrameSize(NSSize(width: 622, height: 0))
            scrollView.layoutSubtreeIfNeeded()
        }
        scrollView.setFrameSize(NSSize(width: 622, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.contentView.bounds.origin == .zero)

        scrollView.setFrameSize(NSSize(width: 900, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.contentView.bounds.origin == .zero)

        let textView = try #require(scrollView.documentView as? NSTextView)
        let selection = NSRange(location: (text as NSString).length / 2, length: 10)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        let readingPosition = scrollView.contentView.bounds.origin
        #expect(readingPosition.y > 0)
        for _ in 0 ..< 3 {
            scrollView.needsLayout = true
            scrollView.layoutSubtreeIfNeeded()
            #expect(scrollView.contentView.bounds.origin == readingPosition)
        }
        scrollView.setFrameSize(NSSize(width: 622, height: 500))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.contentView.bounds.origin.y > 0)
        #expect(textView.selectedRange() == selection)
        #expect(scrollView.window == nil)
    }

    @Test(.tags(.integration)) func gplHeadingsStayCenteredWithoutChangingLicenseText() async throws {
        let text = try await OpenSourceLicense.codexBar.load(bundle: Bundle(for: LicenseBundleAnchor.self))
        let scrollView = LicenseTextScrollView(text: text, license: .codexBar)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let source = text as NSString
        let titles = [
            "GNU GENERAL PUBLIC LICENSE",
            "Version 3, 29 June 2007",
            "Preamble",
            "TERMS AND CONDITIONS",
            "END OF TERMS AND CONDITIONS",
            "How to Apply These Terms to Your New Programs"
        ]
        for width in [622.0, 900, 522] {
            scrollView.setFrameSize(NSSize(width: width, height: 600))
            scrollView.layoutSubtreeIfNeeded()
            manager.ensureLayout(for: container)
            for title in titles {
                let range = source.range(of: title)
                try #require(range.location != NSNotFound)
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let visibleTitle = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: textView.textContainerOrigin.x, dy: 0)
                #expect(abs(visibleTitle.midX - scrollView.contentSize.width / 2) < 1)
            }
            if width >= 622 {
                let bodyLine = source.range(of: "share and change all versions of a program--to make sure it remains free")
                try #require(bodyLine.location != NSNotFound)
                let glyphs = manager.glyphRange(forCharacterRange: bodyLine, actualCharacterRange: nil)
                let visibleBody = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: textView.textContainerOrigin.x, dy: 0)
                #expect(abs(visibleBody.minX - textView.textContainerOrigin.x - container.lineFragmentPadding) < 1)
            }
            #expect(scrollView.contentView.bounds.origin == .zero)
            #expect(textView.string == text)
        }

        let clause = source.range(of: "    a) The work must carry prominent notices")
        try #require(clause.location != NSNotFound)
        #expect(textView.textStorage?.attribute(.paragraphStyle, at: clause.location, effectiveRange: nil) == nil)
        #expect(textView.textStorage?.attribute(.kern, at: clause.location, effectiveRange: nil) == nil)
        textView.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == text)
        #expect(scrollView.window == nil)
    }

    @Test(.tags(.integration)) func componentHeadingsAreCenteredWithoutChangingLicenseText() async throws {
        let text = try await OpenSourceLicense.thirdParty.load(bundle: Bundle(for: LicenseBundleAnchor.self))
        let scrollView = LicenseTextScrollView(text: text, license: .thirdParty)
        scrollView.setFrameSize(NSSize(width: 622, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? NSTextView)
        let storage = try #require(textView.textStorage)
        let source = text as NSString
        #expect(textView.string == text)
        for title in ["SwiftTreeSitter", "Tree-sitter", "tree-sitter-bash", "Unicode data used by Tree-sitter", "Sparkle"] {
            let range = source.range(of: title + "\n")
            try #require(range.location != NSNotFound)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.alignment == .center)
            let separatorColor = storage.attribute(.foregroundColor, at: NSMaxRange(range), effectiveRange: nil) as? NSColor
            #expect(separatorColor == .clear)
        }
        let upstreamSeparator = source.range(of: "\n=================\n")
        try #require(upstreamSeparator.location != NSNotFound)
        let upstreamColor = storage.attribute(.foregroundColor, at: upstreamSeparator.location + 1, effectiveRange: nil) as? NSColor
        #expect(upstreamColor == .textColor)

        textView.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == text)
        #expect(scrollView.window == nil)
    }

    @Test(.tags(.integration), arguments: [false, true])
    func firstTabSelectionSurvivesInitialLoading(switchBeforeInitialLoad: Bool) async throws {
        let bundle = Bundle(for: LicenseBundleAnchor.self)
        let appLicense = try await OpenSourceLicense.codexBar.load(bundle: bundle)
        let thirdPartyLicense = try await OpenSourceLicense.thirdParty.load(bundle: bundle)
        let host = NSHostingView(rootView: OpenSourceLicensesView(bundle: bundle))
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 640)
        func waitForText(_ expected: String) async throws -> Bool {
            try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
                host.layoutSubtreeIfNeeded()
                return descendant(NSTextView.self, in: host)?.string == expected
            }
        }
        host.layoutSubtreeIfNeeded()
        let tabs = try #require(descendant(NSSegmentedControl.self, in: host))
        #expect(host.window == nil)
        #expect(tabs.segmentCount == 2)
        func selectTab(at index: Int) {
            tabs.selectedSegment = index
            #expect(tabs.sendAction(tabs.action, to: tabs.target))
        }
        if !switchBeforeInitialLoad {
            try #require(try await waitForText(appLicense))
            let scrollView = try #require(descendant(LicenseTextScrollView.self, in: host))
            #expect(scrollView.contentView.bounds.origin == .zero)
        }

        selectTab(at: 1)
        #expect(tabs.selectedSegment == 1)
        #expect(try await waitForText(thirdPartyLicense))
        #expect(tabs.selectedSegment == 1)
        let scrollView = try #require(descendant(LicenseTextScrollView.self, in: host))
        #expect(scrollView.contentView.bounds.origin == .zero)

        for (index, width) in zip([0, 1, 0, 1], [560.0, 900, 660, 560]) {
            host.setFrameSize(NSSize(width: width, height: 640))
            selectTab(at: index)
            try #require(try await waitForText(index == 0 ? appLicense : thirdPartyLicense))
            #expect(tabs.selectedSegment == index)
            let document = try #require(descendant(LicenseTextScrollView.self, in: host))
            #expect(document.contentView.bounds.origin == .zero)
            let tabBounds = tabs.convert(tabs.bounds, to: host)
            let documentBounds = document.convert(document.bounds, to: host)
            #expect(!tabBounds.intersects(documentBounds))
            #expect(abs(tabBounds.midX - documentBounds.midX) < 1)
            let gap = host.isFlipped ? documentBounds.minY - tabBounds.maxY : tabBounds.minY - documentBounds.maxY
            #expect(gap >= 10)

            let textView = try #require(document.documentView as? NSTextView)
            let selection = NSRange(location: (textView.string as NSString).length / 2, length: 10)
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            let readingPosition = document.contentView.bounds.origin
            #expect(readingPosition.y > 0)
            host.rootView = OpenSourceLicensesView(bundle: bundle)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(descendant(LicenseTextScrollView.self, in: host) === document)
            #expect(textView.selectedRange() == selection)
            #expect(document.contentView.bounds.origin == readingPosition)
        }
        #expect(host.window == nil)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }
}

private final class LicenseBundleAnchor: NSObject {}
