import AppKit
import SwiftUI
import Testing

struct ActivityCardLayoutTests {
    @Test func narrowStatusContentExpandsWithoutClipping() {
        let short = statusSize(width: 300, long: false)
        let wide = statusSize(width: 480, long: true)
        let narrow = statusSize(width: 180, long: true)
        #expect(narrow.width == 180)
        #expect(narrow.height > wide.height)
        #expect(narrow.height > short.height)
        #expect(narrow.height.isFinite)
    }

    @Test func wrappedSupplementUsesOneLineEvenWhenItIsVeryLong() {
        let short = supplementarySize("2 个子 Agent 运行中")
        let long = supplementarySize(String(repeating: "附加信息", count: 40))
        #expect(long.width == 140)
        #expect(long.height == short.height)
    }

    private func supplementarySize(_ supplement: String) -> CGSize {
        let content = ActivityStatusText(
            text: "正在读取文件, 浏览目录, 搜索文件内容",
            tint: .blue, effect: .none, lineLimit: nil, supplement: supplement
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 140, alignment: .leading)
        return NSHostingView(rootView: content).fittingSize
    }

    private func statusSize(width: CGFloat, long: Bool) -> CGSize {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text("CodexBar • gpt-6-astra • high • 已运行 1 小时 24 分")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ActivityStatusText(
                text: long ? "正在读取文件, 浏览目录, 搜索文件内容" : "正在回答",
                tint: .blue, effect: .none, lineLimit: nil, supplement: "3 个子 Agent 运行中"
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("最近事件: 读取文件, 浏览目录, 搜索内容完成")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        return NSHostingView(rootView: content).fittingSize
    }
}
