import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsHelpPresenter {
    private var panel: NSPanel?
    private var presentedAnchorFrame: CGRect?
    private var dismissObservers = Set<AnyCancellable>()

    func show(_ help: LocalizedStringResource, anchorProvider: ScreenFrameProvider) {
        hide()
        guard let window = anchorProvider.window, window.isVisible,
              let anchorFrame = anchorProvider.currentScreenFrame(in: window, allowingCachedFrame: false) else {
            return
        }

        let visibleFrame = window.screen?.visibleFrame ?? window.frame
        let maximumWidth = min(280, visibleFrame.width - SidePanelSupport.Metrics.screenPadding * 2)
        let content = Text(help)
            .font(.footnote)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        let measuringController = NSHostingController(rootView: content)
        measuringController.sizingOptions = []

        // 测量宿主不接入窗口, 只排版文字, 避免表面效果参与无界高度的测量
        let fittingSize = measuringController.sizeThatFits(in: CGSize(
            width: maximumWidth,
            height: .greatestFiniteMagnitude
        ))
        guard CGRect(origin: .zero, size: fittingSize).isValidScreenRect else {
            return
        }
        let size = CGSize(
            width: min(fittingSize.width.rounded(.up), maximumWidth),
            height: fittingSize.height.rounded(.up)
        )

        // 提示不参与焦点与鼠标命中, 避免收起设置子面板或触发反复进入和移出
        let panel = SidePanelSupport.makePanel(initialSize: size, ignoresMouseEvents: true)
        let contentFrame = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(rootView:
            content
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .sidePanelChrome(cornerRadius: 10)
        )
        hostingView.sizingOptions = []
        hostingView.frame = contentFrame
        hostingView.autoresizingMask = [.width, .height]

        // 普通容器拥有窗口尺寸, SwiftUI 只绘制已测量的固定区域, 不反向更新窗口约束
        let container = NSView(frame: contentFrame)
        container.addSubview(hostingView)
        panel.contentView = container
        panel.level = window.level
        let position = SidePanelSupport.position(
            panelSize: size,
            menuSurfaceFrame: anchorFrame,
            visibleFrame: visibleFrame,
            preferredSide: .right,
            proposedY: anchorFrame.maxY - size.height,
            clampsToSurfaceBottom: false
        )
        panel.setFrame(position.frame, display: false)
        self.panel = panel
        presentedAnchorFrame = anchorFrame
        SidePanelSupport.attach(panel, to: window)
        panel.order(.above, relativeTo: window.windowNumber)
        observeDismissal(in: window)
    }

    func hide() {
        dismissObservers.removeAll()
        presentedAnchorFrame = nil
        guard let panel else {
            return
        }

        SidePanelSupport.orderOut(panel, menuSurfaceWindow: panel.parent)
        self.panel = nil
    }

    func updateAnchorFrame(_ frame: CGRect?) {
        if let presentedAnchorFrame, presentedAnchorFrame != frame {
            hide()
        }
    }

    private func observeDismissal(in window: NSWindow) {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &dismissObservers)

        // 子选项面板可能没有键盘焦点, 也要跟随主设置窗口的关闭和失焦
        var ancestor: NSWindow? = window
        while let current = ancestor {
            center.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: current)
                .sink { [weak self, weak current] _ in
                    if current?.isVisible != true {
                        self?.hide()
                    }
                }
                .store(in: &dismissObservers)

            for name in [
                NSWindow.willCloseNotification,
                NSWindow.willMiniaturizeNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willMoveNotification,
                NSWindow.didResizeNotification
            ] {
                center.publisher(for: name, object: current)
                    .sink { [weak self] _ in self?.hide() }
                    .store(in: &dismissObservers)
            }
            ancestor = current.parent
        }
    }
}
