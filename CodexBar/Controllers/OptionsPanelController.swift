import AppKit
import Combine
import SwiftUI

/// 设置窗口右侧的子选项面板, 同一时刻只展开一个
enum SettingsOptionsPanel: CaseIterable, Hashable {
    case mainPanel
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
/// 设置面板包含交互控件, 使用常驻 hosting controller 和 ObservableObject 更新, 不像重置次数面板那样替换 rootView
@MainActor
final class OptionsPanelController {
    private let animationKey: String
    private let initialPanelSize: CGSize
    /// 展开前的准备动作, 例如刷新仅在此面板显示的设置项
    private let willShow: (() -> Void)?
    private let willHide: (() -> Void)?
    private let contentControllerProvider: (SidePanelEntryCue) -> NSViewController
    private let entryCue = SidePanelEntryCue()

    private var panel: NSPanel?
    private var hostingController: NSViewController?
    private var cancellables = Set<AnyCancellable>()
    /// 展开时保留主设置窗口的键盘焦点, 用户点击输入框后再由面板接管
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: animationKey,
        usesUntranslatedInitialLayout: true,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )
    private var panelResizeTask: Task<Void, Never>?
    private var isEntryAnimationRunning = false

    init(
        mainPanelSettings: MainPanelSettings,
        animationKey: String,
        initialPanelSize: CGSize,
        willShow: (() -> Void)? = nil,
        willHide: (() -> Void)? = nil,
        contentProvider: @escaping () -> some View,
        contentChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.animationKey = animationKey
        self.initialPanelSize = initialPanelSize
        self.willShow = willShow
        self.willHide = willHide
        // 内容闭包在首次构造面板时才执行, 保留 SwiftUI 状态的创建时机
        contentControllerProvider = { cue in
            let controller = NSHostingController(
                rootView: SidePanelEntryRebuildHost(cue: cue, content: contentProvider())
                    .contentAnimations(settings: mainPanelSettings)
            )
            // 高度重算依赖 preferredContentSize 提交的 fitting size
            controller.sizingOptions = [.preferredContentSize]
            return controller
        }
        // 只有内容行数会动态增删的面板才传变化源
        // 面板收着时由 scheduleResize 的守卫过滤变化
        if let contentChanges {
            contentChanges
                .sink { [weak self] in
                    self?.scheduleResize()
                }
                .store(in: &cancellables)
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
        // 原生输入框的焦点环不跟随内容层平移, 收起前结束编辑也避免下次展开恢复旧焦点
        panel?.makeFirstResponder(panel)
        presenter.hide(immediate: immediate)
    }

    private func scheduleResize() {
        // 同步检查 isVisible, 隐藏时跳过 Task 创建及两轮 runloop 等待
        guard panel?.isVisible == true, !isEntryAnimationRunning else {
            return
        }

        panelResizeTask?.cancel()
        panelResizeTask = Task { @MainActor [weak self] in
            // @Published 先于 SwiftUI 布局发出变更, 等待视图提交新的 fitting size
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
        let panel = ensurePanel()
        (panel as? KeyableBorderlessPanel)?.sharedUndoManager = window.undoManager
        // measuredPanelSize 会通过 validFittingSize 调用 layoutSubtreeIfNeeded, 无需提前布局
        // 此前的操作只影响设置窗口, 不会使面板布局失效
        let windowSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? windowSurfaceFrame
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            anchorProvider.currentScreenFrame(in: window),
            menuSurfaceFrame: windowSurfaceFrame
        )
        let panelSize = measuredPanelSize()
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

        panel.level = window.level
        panelResizeTask?.cancel()
        isEntryAnimationRunning = true
        presenter.present(panel, at: position, relativeTo: window) { [weak self] in
            guard let self else {
                return
            }

            isEntryAnimationRunning = false
            scheduleResize()
        }
        // present 已将内容移出可视区, 此时重建不会出现在画面中
        if needsEntryRebuild {
            entryCue.bump()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = SidePanelSupport.makePanel(
            initialSize: initialPanelSize,
            ignoresMouseEvents: false,
            keyable: true
        )
        let hostingController = contentControllerProvider(entryCue)
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

    private func measuredPanelSize() -> CGSize {
        hostingController?.view.validFittingSize ?? initialPanelSize
    }

    private func resizePanel(_ panel: NSPanel, to size: CGSize) {
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
            // 复用初次展开的夹紧规则, 保持重算位置与 position 的结果一致
            targetFrame = SidePanelSupport.clampedVertically(targetFrame, in: visibleFrame)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private enum Metrics {
        static let resizeDuration: TimeInterval = 0.16
    }
}
