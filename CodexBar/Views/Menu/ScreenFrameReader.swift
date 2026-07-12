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

    static func dismantleNSView(_ nsView: ScreenFrameReportingView, coordinator _: ()) {
        nsView.frameProvider?.unbind(from: nsView)
        nsView.frameProvider = nil
        nsView.onChange = nil
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: ScreenFrameReportingView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

/// 在交互发生时同步读取最新 screen frame, 避免只依赖异步 SwiftUI 状态
@MainActor
final class ScreenFrameProvider {
    private weak var view: NSView?
    private weak var lastValidWindow: NSWindow?
    private var lastValidFrame: CGRect?

    func bind(to view: NSView) {
        self.view = view
    }

    func unbind(from view: NSView) {
        guard self.view === view else {
            return
        }
        self.view = nil
        lastValidWindow = nil
        lastValidFrame = nil
    }

    func currentScreenFrame() -> CGRect? {
        if let currentFrame = Self.screenFrame(for: view) {
            updateLastValidFrame(currentFrame, in: view?.window)
            return currentFrame
        }

        return lastValidFrame
    }

    func currentScreenFrame(
        in expectedWindow: NSWindow,
        allowingCachedFrame: Bool = true
    ) -> CGRect? {
        if view?.window === expectedWindow,
           let currentFrame = Self.screenFrame(for: view) {
            updateLastValidFrame(currentFrame, in: expectedWindow)
            return currentFrame
        }

        guard allowingCachedFrame, lastValidWindow === expectedWindow else {
            return nil
        }
        return lastValidFrame
    }

    func updateLastValidFrame(_ frame: CGRect?, in window: NSWindow?) {
        guard let frame, let window else {
            return
        }

        lastValidWindow = window
        lastValidFrame = frame
    }

    fileprivate static func screenFrame(for view: NSView?) -> CGRect? {
        guard let view, let window = view.window else {
            return nil
        }

        view.layoutSubtreeIfNeeded()
        let frameInWindow = view.convert(view.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow).standardized
        guard screenFrame.isValidScreenRect else {
            return nil
        }
        return screenFrame
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
        frameProvider?.updateLastValidFrame(screenFrame, in: window)
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
