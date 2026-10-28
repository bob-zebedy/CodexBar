import AppKit

/// 共用的剪贴板写入方法
enum PasteboardWriter {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
