import AppKit

/// 统一收口剪贴板写入
enum PasteboardWriter {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
