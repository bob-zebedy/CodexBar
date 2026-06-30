import AppKit
import SwiftUI

/// 通过 NSView 桥接读取 SwiftUI 视图在屏幕坐标系中的 frame
struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect?) -> Void

    func makeNSView(context _: Context) -> ScreenFrameReportingView {
        let view = ScreenFrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenFrameReportingView, context _: Context) {
        nsView.onChange = onChange
        nsView.scheduleReport()
    }
}

/// 只在 SwiftUI 布局稳定后上报 frame, 避免重渲染期间反复触发无效定位
@MainActor
final class ScreenFrameReportingView: NSView {
    var onChange: ((CGRect?) -> Void)?
    private var lastReportedFrame: CGRect?
    private var reportScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func scheduleReport() {
        // updateNSView 每次 SwiftUI 重渲染都会调到这里
        // 合并掉重复的待执行 report, 至多保留一个
        guard !reportScheduled else {
            return
        }
        reportScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            reportScheduled = false
            reportFrame()
        }
    }

    private func reportFrame() {
        guard let window else {
            updateFrame(nil)
            return
        }

        let frameInWindow = convert(bounds, to: nil)
        updateFrame(window.convertToScreen(frameInWindow))
    }

    private func updateFrame(_ frame: CGRect?) {
        guard frame != lastReportedFrame else {
            return
        }

        lastReportedFrame = frame
        onChange?(frame)
    }
}
