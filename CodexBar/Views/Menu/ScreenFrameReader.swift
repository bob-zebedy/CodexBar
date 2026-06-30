import AppKit
import SwiftUI

/// 通过 NSView 桥接读取 SwiftUI 视图在屏幕坐标系中的 frame
struct ScreenFrameReader: NSViewRepresentable {
    let provider: ScreenFrameProvider?
    let onChange: ((CGRect?) -> Void)?

    init(
        provider: ScreenFrameProvider? = nil,
        onChange: ((CGRect?) -> Void)? = nil
    ) {
        self.provider = provider
        self.onChange = onChange
    }

    func makeNSView(context _: Context) -> ScreenFrameReportingView {
        let view = ScreenFrameReportingView()
        view.frameProvider = provider
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenFrameReportingView, context _: Context) {
        nsView.frameProvider = provider
        nsView.onChange = onChange
        nsView.scheduleReport()
    }
}

/// 在交互发生时同步读取最新 screen frame, 避免只依赖异步 SwiftUI 状态
@MainActor
final class ScreenFrameProvider {
    private weak var view: NSView?
    private var lastValidFrame: CGRect?

    func bind(to view: NSView) {
        self.view = view
    }

    func currentScreenFrame() -> CGRect? {
        if let currentFrame = Self.screenFrame(for: view) {
            lastValidFrame = currentFrame
            return currentFrame
        }

        return lastValidFrame
    }

    func updateLastValidFrame(_ frame: CGRect?) {
        guard let frame else {
            return
        }

        lastValidFrame = frame
    }

    fileprivate static func screenFrame(for view: NSView?) -> CGRect? {
        guard let view, let window = view.window else {
            return nil
        }

        view.layoutSubtreeIfNeeded()
        let frameInWindow = view.convert(view.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow).standardized
        guard isValidScreenFrame(screenFrame) else {
            return nil
        }
        return screenFrame
    }

    private static func isValidScreenFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

/// 只在 SwiftUI 布局稳定后上报 frame, 避免重渲染期间反复触发无效定位
@MainActor
final class ScreenFrameReportingView: NSView {
    var onChange: ((CGRect?) -> Void)?
    weak var frameProvider: ScreenFrameProvider? {
        didSet {
            frameProvider?.bind(to: self)
        }
    }

    private var lastReportedFrame: CGRect?
    private var reportScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameProvider?.bind(to: self)
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
        let screenFrame = ScreenFrameProvider.screenFrame(for: self)
        frameProvider?.updateLastValidFrame(screenFrame)
        updateFrame(screenFrame)
    }

    private func updateFrame(_ frame: CGRect?) {
        guard frame != lastReportedFrame else {
            return
        }

        lastReportedFrame = frame
        onChange?(frame)
    }
}
