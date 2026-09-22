import SwiftUI

struct TaskGlowOptionsView: View {
    @ObservedObject var settings: TaskGlowSettings

    var body: some View {
        VStack(spacing: SettingsOptionsPanelMetrics.rowSpacing) {
            ForEach(TaskGlowColorRole.allCases, id: \.self) { role in
                optionRow(role.title) {
                    TaskGlowColorHexField(settings: settings, role: role)
                }
            }

            LiquidGlassDivider()
                .padding(.vertical, 4)

            optionRow("task-glow.speed.title") {
                SettingsOptionsPicker(
                    title: "task-glow.speed.title",
                    selection: Binding(
                        get: { settings.appearance.animationSpeed },
                        set: { settings.setAnimationSpeed($0) }
                    ),
                    options: TaskGlowAnimationSpeed.allCases,
                    label: { $0.title },
                    width: 100,
                    alignment: .trailing
                )
            }
            optionRow("task-glow.duration.title") {
                SettingsOptionsPicker(
                    title: "task-glow.duration.title",
                    selection: Binding(
                        get: { settings.appearance.terminalDuration },
                        set: { settings.setTerminalDuration($0) }
                    ),
                    options: TaskGlowSettings.terminalDurationOptions,
                    label: { String(localized: "duration.seconds", defaultValue: "\(Int($0), specifier: "%lld")") },
                    width: 100,
                    alignment: .trailing
                )
            }
            optionRow("task-glow.brightness.title") {
                TaskGlowBrightnessControl(value: Binding(
                    get: { settings.appearance.brightness },
                    set: { settings.setBrightness($0) }
                ))
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, SettingsOptionsPanelMetrics.horizontalPadding)
        .padding(.vertical, SettingsOptionsPanelMetrics.verticalPadding)
        .frame(width: Self.panelWidth)
        .sidePanelChrome(cornerRadius: SettingsOptionsPanelMetrics.cornerRadius)
    }

    private static let panelWidth: CGFloat = 280

    static var initialPanelSize: CGSize {
        CGSize(width: panelWidth, height: 220)
    }

    private func optionRow(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: SettingsOptionsPanelMetrics.controlSpacing) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
        .frame(height: SettingsOptionsPanelMetrics.rowHeight)
    }
}

private struct TaskGlowBrightnessControl: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 7) {
            TaskGlowBrightnessSlider(value: $value)
                .frame(width: 88, height: 22)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct TaskGlowBrightnessSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = BrightnessSliderCell()
        slider.controlSize = .small
        slider.minValue = TaskGlowSettings.brightnessRange.lowerBound
        slider.maxValue = TaskGlowSettings.brightnessRange.upperBound
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value
    }

    final class Coordinator: NSObject {
        var parent: TaskGlowBrightnessSlider

        init(_ parent: TaskGlowBrightnessSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.doubleValue
        }
    }

    private final class BrightnessSliderCell: NSSliderCell {
        override var knobThickness: CGFloat {
            12
        }

        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let knob = knobRect(flipped: flipped)
            let track = NSRect(x: rect.minX + knob.width / 2, y: rect.midY - 2, width: rect.width - knob.width, height: 4)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

            let endX = knob.midX
            let filled = NSRect(x: track.minX, y: track.minY, width: max(0, endX - track.minX), height: track.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
        }

        override func drawKnob(_ knobRect: NSRect) {
            let knob = NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.08).setStroke()
            let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.25, dy: 0.25))
            outline.lineWidth = 0.5
            outline.stroke()
        }
    }
}

private struct TaskGlowColorHexField: View {
    @ObservedObject var settings: TaskGlowSettings
    let role: TaskGlowColorRole
    @State private var draft: String
    @State private var isFocused = false

    init(settings: TaskGlowSettings, role: TaskGlowColorRole) {
        self.settings = settings
        self.role = role
        _draft = State(initialValue: settings.appearance.colors[role] ?? "")
    }

    private var isValid: Bool {
        draft.isEmpty || TaskGlowAppearance.normalizedColorHex(draft) != nil
    }

    var body: some View {
        HStack(spacing: SettingsOptionsPanelMetrics.controlSpacing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: settings.appearance.color(for: role)))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                }
                .frame(width: 14, height: 14)

            Text(verbatim: "#")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 8)

            TaskGlowHexInput(
                text: $draft,
                isFocused: $isFocused,
                placeholder: TaskGlowAppearance.encodeColor(role.defaultColor) ?? "",
                onChange: { settings.setColorHex($0, for: role) },
                onEndEditing: { value in
                    let hex = TaskGlowAppearance.normalizedColorHex(value) ?? ""
                    settings.setColorHex(hex, for: role)
                    return hex
                },
                onCancel: { settings.appearance.colors[role] ?? "" }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isValid ? .clear : .red, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .frame(width: 74)
        }
        .onChange(of: settings.appearance.colors[role]) { _, _ in
            if !isFocused {
                draft = settings.appearance.colors[role] ?? ""
            }
        }
    }
}

private struct TaskGlowHexInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let onChange: (String) -> Void
    let onEndEditing: (String) -> String
    let onCancel: () -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.controlSize = .small
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode = true
        field.formatter = TaskGlowHexFormatter()
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskGlowHexInput
        init(_ parent: TaskGlowHexInput) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.isAutomaticTextCompletionEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isContinuousSpellCheckingEnabled = false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // 原生结束编辑回调逐次提交, 不依赖 SwiftUI 可能合并的焦点状态变化
            let value = parent.onEndEditing(field.currentEditor()?.string ?? field.stringValue)
            setText(value, in: field)
            parent.isFocused = false
        }

        func control(_ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(control.window)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                setText(parent.onCancel(), in: field)
                control.window?.makeFirstResponder(control.window)
                return true
            }
            return false
        }

        private func setText(_ value: String, in field: NSTextField) {
            // 结束编辑通知发出时 field editor 可能仍存在, 与控件及绑定一起收敛
            field.currentEditor()?.string = value
            field.stringValue = value
            parent.text = value
        }
    }
}

/// 原生编辑器在应用输入前校验文本, 避免 SwiftUI 回写与连续按键争用文本和选区
final nonisolated class TaskGlowHexFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription _: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>, proposedSelectedRange proposedSelRangePtr: NSRangePointer?, originalString origString: String, originalSelectedRange origSelRange: NSRange, errorDescription _: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let original = origString as NSString
        let proposed = partialStringPtr.pointee
        let prefix = original.substring(to: origSelRange.location)
        let suffix = original.substring(from: NSMaxRange(origSelRange))
        let insertedLength = proposed.length - (prefix as NSString).length - (suffix as NSString).length
        guard insertedLength >= 0 else { return false }
        var inserted = proposed.substring(with: NSRange(location: origSelRange.location, length: insertedLength))
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .uppercased()
        if insertedLength > 0, inserted.isEmpty {
            partialStringPtr.pointee = original
            proposedSelRangePtr?.pointee = origSelRange
            return false
        }
        inserted = String(inserted.prefix(max(0, 6 - prefix.count - suffix.count)))
        let result = prefix + inserted + suffix
        guard result != proposed as String else { return true }
        partialStringPtr.pointee = result as NSString
        proposedSelRangePtr?.pointee = NSRange(location: (prefix as NSString).length + (inserted as NSString).length, length: 0)
        return false
    }
}
