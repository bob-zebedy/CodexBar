import AppKit
import Combine
import SwiftUI

/// 设置窗口右侧的子选项面板, 同一时刻只展开一个
enum SettingsOptionsPanel: CaseIterable, Hashable {
    case mainPanel
    case notification
    case autoReset
    case keepAlive
}

/// 子选项面板动作, 由 AppSettingsView 发出并在 SettingsWindowController 中路由
/// 展开时带上主开关行的 anchor, 面板顶边要对齐那一行而不是设置窗口底边
enum SettingsOptionsPanelAction {
    case toggle(panel: SettingsOptionsPanel, anchorProvider: ScreenFrameProvider)
    case close(panel: SettingsOptionsPanel)
    /// 切换分页时一次收掉全部; 视图不必知道一共有几个面板
    case closeAll
}

/// 子面板入场时的内容重建信号
/// 原生 Switch 的 thumb 由 WindowPortal 投射, 面板首次布局那一轮建不起来也不会自愈, 只有重建补得上
/// bump 排在 present 之后, 那时动画效果已经把内容 translation 到可视区外, 重建才看不见
@MainActor
private final class SidePanelEntryCue: ObservableObject {
    @Published private(set) var pass = 0

    func bump() {
        pass += 1
    }
}

/// 把重建信号接到内容外面, 于是内容视图不必为这个宿主层的问题多带一个属性
private struct SidePanelEntryRebuildHost<Content: View>: View {
    @ObservedObject var cue: SidePanelEntryCue
    let content: Content

    var body: some View {
        content.id(cue.pass)
    }
}

/// 设置窗口右侧子选项面板的公共装配
/// 各子面板只差内容视图与高度变化来源, 窗口组关闭规则由 SettingsWindowController 统一维护
/// 与重置次数面板不同: 内容是交互控件, 用常驻 hosting controller + ObservableObject 驱动更新, 不替换 rootView
@MainActor
final class SettingsOptionsPanelController {
    private let animationKey: String
    private let initialPanelSize: CGSize
    /// 展开前的准备动作, 例如刷新只在这个面板里露面的设置项
    private let willShow: (() -> Void)?
    private let contentControllerProvider: (SidePanelEntryCue) -> NSViewController
    private let entryCue = SidePanelEntryCue()

    private var panel: NSPanel?
    private var hostingController: NSViewController?
    private var cancellables = Set<AnyCancellable>()
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: animationKey,
        makesKey: true,
        usesUntranslatedInitialLayout: true,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )
    private var panelResizeTask: Task<Void, Never>?
    private var isEntryAnimationRunning = false

    init(
        animationKey: String,
        initialPanelSize: CGSize,
        willShow: (() -> Void)? = nil,
        contentProvider: @escaping () -> some View,
        contentChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.animationKey = animationKey
        self.initialPanelSize = initialPanelSize
        self.willShow = willShow
        // 内容闭包在首次构造面板时才执行, 保留 SwiftUI 状态的创建时机
        contentControllerProvider = { cue in
            let controller = NSHostingController(
                rootView: SidePanelEntryRebuildHost(cue: cue, content: contentProvider())
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
        panelResizeTask?.cancel()
        panelResizeTask = nil
        isEntryAnimationRunning = false
        presenter.hide(immediate: immediate)
    }

    private func scheduleResize() {
        // isVisible 也在同步守卫里: 收着的面板不必为每次内容变化排一个 Task 再让出两轮 runloop
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
        // 只有刚构造出来的那一次需要重建, hosting controller 之后常驻, portal 已经建好
        let needsEntryRebuild = panel == nil
        let panel = ensurePanel()
        (panel as? KeyableBorderlessPanel)?.sharedUndoManager = window.undoManager
        // 这里不必先布局: 下面 measuredPanelSize 走的 validFittingSize 第一句就是 layoutSubtreeIfNeeded
        // 而中间两句只碰设置窗口那棵树, 不会把面板弄脏
        let windowSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? windowSurfaceFrame
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            anchorProvider.currentScreenFrame(in: window),
            menuSurfaceFrame: windowSurfaceFrame
        )
        let panelSize = measuredPanelSize()
        // clampsToSurfaceBottom 传 false: 顶边要对齐主开关行, 放不下时底边探出窗口也不能把整个面板上推
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
        // 排在 present 之后: 动画效果先把内容 translation 到可视区外, 这一次重建落在那段里, 看不见
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

        // 面板顶边对齐主开关行, 所以增删内容行时要向下生长
        // 直接改 size 会保持底边不动而把顶边顶上去, 那样就跟主开关行错开了
        var targetFrame = panel.frame
        let topEdge = targetFrame.maxY
        targetFrame.size = size
        targetFrame.origin.y = topEdge - targetFrame.height
        if let visibleFrame = panel.screen?.visibleFrame {
            // 与初次展开走同一条夹紧规则, 否则放不下时重算的位置会和 position 给的位置对不上
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
