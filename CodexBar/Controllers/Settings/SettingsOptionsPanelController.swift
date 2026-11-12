import AppKit
import Combine
import SwiftUI

/// 设置窗口右侧的子选项面板, 同一时刻只展开一个
enum SettingsOptionsPanel: CaseIterable, Hashable {
    case mainPanel
    case menuBarIndicator
    case taskGlow
    case notification
    case autoReset
    case keepAlive
}

/// 子选项面板动作, 由 AppSettingsView 发出并在 SettingsWindowController 中路由
/// 展开时传入主开关行的 anchor, 用于对齐面板顶边
enum SettingsOptionsPanelAction {
    case toggle(panel: SettingsOptionsPanel, anchorProvider: ScreenFrameProvider)
    case close(panel: SettingsOptionsPanel)
    /// 切换分页时收起全部子面板, 视图无需逐个处理
    case closeAll
}

/// 子面板入场时的内容重建信号
/// 原生 Switch 的 thumb 由 WindowPortal 投射, 首次布局失败后需要重建内容才能显示
/// bump 在 present 之后执行, 此时动画已将内容移出可视区, 重建过程不可见
@MainActor
private final class SidePanelEntryCue: ObservableObject {
    @Published private(set) var pass = 0

    func bump() {
        pass += 1
    }
}

/// 在内容外层接收重建信号, 内容视图无需保存宿主的重建状态
private struct SidePanelEntryRebuildHost<Content: View>: View {
    @ObservedObject var cue: SidePanelEntryCue
    let content: Content

    var body: some View {
        content.id(cue.pass)
    }
}

/// 设置窗口右侧子选项面板的公共装配
/// 各子面板只差内容视图与高度变化来源, 窗口组关闭规则由 SettingsWindowController 统一维护
/// 常驻 hosting controller 保留交互状态, 内容通过 ObservableObject 更新
@MainActor
final class SettingsOptionsPanelController {
    private let animationKey: String
    private let resizeDuration: TimeInterval
    private let resizesWithContent: Bool
    private let mainPanelSettings: MainPanelSettings
    /// 展开前的准备动作, 例如刷新仅在此面板显示的设置项
    private let willShow: (() -> Void)?
    private let willHide: (() -> Void)?
    private let contentControllerProvider: (SidePanelEntryCue, @escaping @MainActor (CGSize) -> Void) -> NSViewController
    private let entryCue = SidePanelEntryCue()

    private var panel: NSPanel?
    private var hostingController: NSViewController?
    private weak var anchorContentView: NSView?
    private var expansionSide = SidePanelSide.right
    /// 展开时保留主设置窗口的键盘焦点, 用户点击输入框后再由面板接管
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: animationKey,
        usesUntranslatedInitialLayout: true,
        areAnimationsEnabled: { [weak self] in self?.mainPanelSettings.areAnimationsEnabled ?? false },
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )
    private var panelResizeTask: Task<Void, Never>?
    private var isEntryAnimationRunning = false
    private var acceptsContentResize = false

    init(
        mainPanelSettings: MainPanelSettings,
        animationKey: String,
        resizeDuration: TimeInterval = SettingsOptionsPanelMetrics.resizeDuration,
        resizesWithContent: Bool = false,
        willShow: (() -> Void)? = nil,
        willHide: (() -> Void)? = nil,
        contentProvider: @escaping () -> some View
    ) {
        self.animationKey = animationKey
        self.resizeDuration = resizeDuration
        self.resizesWithContent = resizesWithContent
        self.mainPanelSettings = mainPanelSettings
        self.willShow = willShow
        self.willHide = willHide
        // 内容闭包在首次构造面板时才执行, 保留 SwiftUI 状态的创建时机
        contentControllerProvider = { cue, onSizeChanged in
            let controller = NSHostingController(
                rootView: SidePanelEntryRebuildHost(cue: cue, content: contentProvider())
                    .contentAnimations(settings: mainPanelSettings)
                    .environment(\.settingsOptionsPanelSizeObserver, SettingsOptionsPanelSizeObserver(onChange: onSizeChanged))
            )
            // 保留 fittingSize 所需的固有尺寸报告, 窗口动画仍由控制器统一提交
            controller.sizingOptions = [.intrinsicContentSize]
            return controller
        }
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func owns(_ window: NSWindow) -> Bool {
        window === panel
    }

    func toggle(
        relativeTo window: NSWindow?,
        contentView: NSView?,
        anchorProvider: ScreenFrameProvider
    ) {
        if isVisible {
            hide()
            return
        }

        show(relativeTo: window, contentView: contentView, anchorProvider: anchorProvider)
    }

    func hide(immediate: Bool = false) {
        if isVisible {
            willHide?()
        }
        panelResizeTask?.cancel()
        panelResizeTask = nil
        isEntryAnimationRunning = false
        acceptsContentResize = false
        // 原生输入框的焦点环不跟随内容层平移, 收起前结束编辑也避免下次展开恢复旧焦点
        panel?.makeFirstResponder(panel)
        presenter.hide(immediate: immediate)
    }

    private func scheduleResize() {
        // 同步检查 isVisible, 隐藏时跳过 Task 创建及两轮 runloop 等待
        guard !resizesWithContent, panel?.isVisible == true, !isEntryAnimationRunning else {
            return
        }

        panelResizeTask?.cancel()
        panelResizeTask = Task { @MainActor [weak self] in
            // 等待入场重建后的 SwiftUI 布局提交, 再读取 fitting size
            await Task.yield()
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  let panel,
                  panel.isVisible,
                  let size = hostingController?.view.validFittingSize else {
                return
            }

            resizePanel(panel, to: size)
        }
    }

    private func show(
        relativeTo window: NSWindow?,
        contentView: NSView?,
        anchorProvider: ScreenFrameProvider
    ) {
        guard let window else {
            hide(immediate: true)
            return
        }

        willShow?()
        // 仅首次构造后需要重建, 后续复用常驻 hosting controller 和已创建的 portal
        let needsEntryRebuild = panel == nil
        guard let panel = ensurePanel(),
              let panelSize = hostingController?.view.validFittingSize else {
            return
        }
        (panel as? KeyableBorderlessPanel)?.sharedUndoManager = window.undoManager
        // validFittingSize 已完成布局, 无需再次测量
        // 此前的操作只影响设置窗口, 不会使面板布局失效
        let windowSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? windowSurfaceFrame
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            anchorProvider.currentScreenFrame(in: window),
            menuSurfaceFrame: windowSurfaceFrame
        )
        // clampsToSurfaceBottom 设为 false, 保持顶边对齐主开关行, 允许底边超出设置窗口
        let position = SidePanelSupport.anchoredPosition(
            panelSize: panelSize,
            menuSurfaceFrame: windowSurfaceFrame,
            visibleFrame: visibleFrame,
            screenFrame: screen?.frame,
            alignmentScreenFrame: alignmentScreenFrame,
            preferredSide: .right,
            clampsToSurfaceBottom: false
        )
        anchorContentView = contentView
        expansionSide = position.side

        panel.level = window.level
        panelResizeTask?.cancel()
        isEntryAnimationRunning = true
        acceptsContentResize = false
        presenter.present(panel, at: position, relativeTo: window) { [weak self] in
            guard let self else {
                return
            }

            isEntryAnimationRunning = false
            acceptsContentResize = true
            if resizesWithContent, let size = hostingController?.view.validFittingSize {
                resizeFromContent(size)
            } else {
                scheduleResize()
            }
        }
        // present 已将内容移出可视区, 此时重建不会出现在画面中
        if needsEntryRebuild {
            entryCue.bump()
        }
    }

    private func ensurePanel() -> NSPanel? {
        if let panel {
            return panel
        }

        let hostingController = contentControllerProvider(entryCue) { [weak self] size in
            self?.resizeFromContent(size)
        }
        guard let size = hostingController.view.validFittingSize else {
            return nil
        }
        let panel = SidePanelSupport.makePanel(
            initialSize: size,
            ignoresMouseEvents: false,
            keyable: true
        )
        panel.contentViewController = hostingController
        SidePanelSupport.configureLayers(
            hostingView: hostingController.view,
            contentView: panel.contentView,
            cornerRadius: SettingsOptionsPanelMetrics.cornerRadius
        )
        self.hostingController = hostingController
        self.panel = panel
        return panel
    }

    private func resizeFromContent(_ size: CGSize) {
        guard resizesWithContent,
              acceptsContentResize,
              let panel,
              panel.isVisible,
              !isEntryAnimationRunning,
              size.width.isFinite, size.width > 0,
              size.height.isFinite, size.height > 0 else {
            return
        }
        resizePanel(panel, to: size, animated: false)
    }

    private func resizePanel(_ panel: NSPanel, to size: CGSize, animated: Bool = true) {
        guard size != panel.frame.size else {
            return
        }

        // 增删内容时固定顶边, 让高度向下变化, 保持与主开关行对齐
        // 直接修改 size 会固定底边, 导致顶边偏移
        var targetFrame = panel.frame
        let topEdge = targetFrame.maxY
        targetFrame.size = size
        targetFrame.origin.y = topEdge - targetFrame.height
        if let visibleFrame = panel.screen?.visibleFrame {
            if size.width != panel.frame.width, let parent = panel.parent {
                let surfaceFrame = SidePanelSupport.contentScreenFrame(for: anchorContentView, in: parent) ?? parent.frame
                let position = SidePanelSupport.position(
                    panelSize: size,
                    menuSurfaceFrame: surfaceFrame,
                    visibleFrame: visibleFrame,
                    preferredSide: expansionSide,
                    proposedY: targetFrame.minY,
                    clampsToSurfaceBottom: false
                )
                targetFrame = position.frame
                expansionSide = position.side
                presenter.updateSide(position.side)
            } else {
                targetFrame = SidePanelSupport.clampedVertically(targetFrame, in: visibleFrame)
            }
        }

        guard animated, mainPanelSettings.areAnimationsEnabled else {
            panel.setFrame(targetFrame, display: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
}
