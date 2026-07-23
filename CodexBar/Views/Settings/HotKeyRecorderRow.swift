import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 快捷键录制行, 隐藏 NSView 负责真正捕获 keyDown
struct HotKeyRecorderRow: View {
    @ObservedObject var settings: GlobalHotKeySettings
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SettingsRowMetrics.spacing) {
                Image(systemName: "keyboard")
                    .frame(width: SettingsRowMetrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("APP 快捷键")

                Spacer()

                Button {
                    startRecording()
                } label: {
                    Text(shortcutLabel)
                        .frame(minWidth: Metrics.shortcutButtonMinWidth)
                        .contentShape(Rectangle())
                }
                .font(.body.monospacedDigit())
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canStartRecording)
                .background {
                    HotKeyCaptureView(
                        isRecording: $isRecording,
                        onCapture: captureShortcut,
                        onCancel: {
                            stopRecording()
                        },
                        onWindowClose: {
                            resetTransientState()
                        }
                    )
                    .frame(width: 0, height: 0)
                }

                iconButton(
                    systemName: "arrow.counterclockwise.circle",
                    help: "恢复默认",
                    isDisabled: !canRestoreDefaultShortcut
                ) {
                    settings.restoreDefaultShortcut()
                    stopRecording()
                }

                iconButton(
                    systemName: "xmark.circle",
                    help: "清除 APP 快捷键",
                    isDisabled: !canClearShortcut
                ) {
                    settings.clearShortcut()
                    stopRecording()
                }
            }

            if let message = settings.errorMessage {
                SettingsCaptionMessageRow(message: message)
            }
        }
        .onDisappear {
            resetTransientState()
        }
    }

    private var shortcutLabel: String {
        if isRecording {
            return "请设置快捷键"
        }

        return settings.shortcut?.label ?? "未设置"
    }

    private var canStartRecording: Bool {
        !hasShortcut || isRecording
    }

    private var canRestoreDefaultShortcut: Bool {
        !hasShortcut
    }

    private var canClearShortcut: Bool {
        hasShortcut || isRecording
    }

    private var hasShortcut: Bool {
        settings.shortcut != nil
    }

    private func startRecording() {
        guard settings.shortcut == nil else {
            return
        }

        isRecording = true
    }

    private func stopRecording() {
        isRecording = false
    }

    private func resetTransientState() {
        stopRecording()
        settings.clearError()
    }

    private func captureShortcut(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            stopRecording()
            return
        }

        guard let shortcut = GlobalHotKeyShortcut(event: event) else {
            settings.setRegistrationError("无法识别该快捷键")
            stopRecording()
            return
        }

        settings.setShortcut(shortcut)
        stopRecording()
    }

    private func iconButton(
        systemName: String,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .disabled(isDisabled)
    }

    private enum Metrics {
        static let shortcutButtonMinWidth: CGFloat = 78
    }
}

/// SwiftUI 到 AppKit first responder 的桥接层
private struct HotKeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (NSEvent) -> Void
    let onCancel: () -> Void
    let onWindowClose: () -> Void

    func makeNSView(context _: Context) -> HotKeyCaptureNSView {
        let view = HotKeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onWindowClose = onWindowClose
        return view
    }

    func updateNSView(_ nsView: HotKeyCaptureNSView, context _: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.onWindowClose = onWindowClose

        if isRecording {
            Task { @MainActor [weak nsView] in
                nsView?.window?.makeFirstResponder(nsView)
            }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

/// 捕获下一次按键并监听窗口关闭, 关闭时清理录制态
private final class HotKeyCaptureNSView: NSView {
    var onCapture: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowClose: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowCloseObserver()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            onCapture?(event)
        }
    }

    private func updateWindowCloseObserver() {
        removeWindowCloseObserver()

        guard let window else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillClose(_: Notification) {
        onWindowClose?()
    }

    private func removeWindowCloseObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }
}
