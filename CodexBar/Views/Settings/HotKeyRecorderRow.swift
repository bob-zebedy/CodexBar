import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorderRow: View {
    @ObservedObject var settings: GlobalHotKeySettings
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("使用快捷键")

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
                    help: "恢复默认快捷键",
                    isDisabled: !canRestoreDefaultShortcut
                ) {
                    settings.restoreDefaultShortcut()
                    stopRecording()
                }

                iconButton(
                    systemName: "xmark.circle",
                    help: "清除设置快捷键",
                    isDisabled: !canClearShortcut
                ) {
                    settings.clearShortcut()
                    stopRecording()
                }
            }

            if let message = settings.errorMessage {
                errorMessageRow(message)
            }
        }
        .onDisappear {
            resetTransientState()
        }
    }

    private var shortcutLabel: String {
        if isRecording {
            return "请输入快捷键"
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

    private func errorMessageRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear
                .frame(width: Metrics.iconWidth)

            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        static let iconWidth: CGFloat = 18
        static let shortcutButtonMinWidth: CGFloat = 78
    }
}

private struct HotKeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (NSEvent) -> Void
    let onCancel: () -> Void
    let onWindowClose: () -> Void

    func makeNSView(context: Context) -> HotKeyCaptureNSView {
        let view = HotKeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onWindowClose = onWindowClose
        return view
    }

    func updateNSView(_ nsView: HotKeyCaptureNSView, context: Context) {
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

private final class HotKeyCaptureNSView: NSView {
    var onCapture: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    var onWindowClose: (() -> Void)?
    private var windowCloseObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool {
        true
    }

    deinit {
        removeWindowCloseObserver()
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

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onWindowClose?()
        }
    }

    private func removeWindowCloseObserver() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
    }
}
