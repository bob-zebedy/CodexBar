import AppKit
import QuartzCore
import SwiftUI

struct ProxyPasswordField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isRevealed: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context _: Context) -> PasswordInputView {
        PasswordInputView()
    }

    func updateNSView(_ view: PasswordInputView, context _: Context) {
        view.onChange = { text = $0 }
        view.onFocusChange = { focused in
            if isFocused != focused {
                isFocused = focused
            }
        }
        view.update(text: text, isEnabled: isEnabled, isRevealed: isRevealed)
    }

    final class PasswordInputView: NSView, NSTextFieldDelegate {
        var onChange: ((String) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        private let secureField = NSSecureTextField()
        private let plainField = NSTextField()
        private var isRevealed = false
        private var lastText = ""
        private var isSwitching = false
        private var requestedReveal = false
        private var hasPendingReveal = false
        private var activeField: NSTextField {
            isRevealed ? plainField : secureField
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for field in [secureField, plainField] {
                field.isBordered = false
                field.isBezeled = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.font = .systemFont(ofSize: NSFont.systemFontSize)
                field.placeholderString = String(localized: "proxy.password")
                field.cell?.usesSingleLineMode = true
                field.cell?.isScrollable = true
                field.delegate = self
                addSubview(field)
            }
            plainField.isHidden = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func layout() {
            super.layout()
            secureField.frame = bounds
            plainField.frame = bounds
        }

        func update(text: String, isEnabled: Bool, isRevealed: Bool) {
            for field in [secureField, plainField] {
                if text != lastText {
                    field.stringValue = text
                }
                field.isEnabled = isEnabled
            }
            lastText = text
            requestedReveal = isRevealed && isEnabled
            guard !hasPendingReveal else { return }
            hasPendingReveal = true
            // makeFirstResponder 会同步更新 SwiftUI 焦点图, 必须离开 updateNSView 的更新周期
            // 快速悬停只应用最后一次请求, 避免排队切换过期状态
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                hasPendingReveal = false
                setRevealed(requestedReveal)
            }
        }

        private func setRevealed(_ revealed: Bool) {
            guard revealed != isRevealed else { return }
            let editor = activeField.currentEditor() as? NSTextView
            let selection = editor?.selectedRange()
            let value = editor?.string ?? activeField.stringValue
            let hasMarkedText = editor?.hasMarkedText() == true
            isSwitching = true
            defer { isSwitching = false }

            // 两个原生控件保持挂载, 在同一轮更新中交接编辑器和选区
            // 淡化仅作用于文字所在的图层, 外部边框和焦点环不参与动画
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.1
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(transition, forKey: "passwordVisibility")
            // 安全编辑器不能继续输入法组合, 交接时确认现有文字并保留完整内容
            if hasMarkedText {
                editor?.unmarkText()
            }
            activeField.isHidden = true
            isRevealed = revealed
            activeField.stringValue = value
            activeField.isHidden = false
            if let selection, let window {
                window.makeFirstResponder(activeField)
                if let newEditor = activeField.currentEditor() as? NSTextView {
                    let length = (newEditor.string as NSString).length
                    let location = min(selection.location, length)
                    newEditor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
                    newEditor.scrollRangeToVisible(newEditor.selectedRange())
                }
            }
            if hasMarkedText, value != lastText {
                lastText = value
                onChange?(value)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isSwitching, let field = notification.object as? NSTextField else { return }
            lastText = field.stringValue
            onChange?(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.isAutomaticTextCompletionEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isContinuousSpellCheckingEnabled = false
            }
            updateFocus()
        }

        func controlTextDidEndEditing(_: Notification) {
            updateFocus()
        }

        private func updateFocus() {
            // 编辑器交接也会发送结束通知, 等交接完成后统一读取焦点
            Task { @MainActor [weak self] in
                guard let self else { return }
                onFocusChange?(activeField.currentEditor() != nil)
            }
        }
    }
}
