import AppKit
import Carbon.HIToolbox

nonisolated struct GlobalHotKeyShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    
    static let `default` = GlobalHotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_W),
        modifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "W"
    )
    
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
    
    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let keyLabel = Self.keyLabel(for: event)
        guard !keyLabel.isEmpty else {
            return nil
        }
        
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: keyLabel
        )
    }
    
    var label: String {
        modifierSymbols + keyLabel
    }
    
    var validationError: String? {
        if modifierCount < 2 {
            return "至少需要两个修饰键"
        }
        
        if isReservedSystemShortcut {
            return "不可使用系统快捷键"
        }
        
        return nil
    }
    
    private var modifierSymbols: String {
        [
            hasModifier(controlKey) ? "⌃" : nil,
            hasModifier(optionKey) ? "⌥" : nil,
            hasModifier(shiftKey) ? "⇧" : nil,
            hasModifier(cmdKey) ? "⌘" : nil
        ]
            .compactMap { $0 }
            .joined()
    }
    
    private var modifierCount: Int {
        [controlKey, optionKey, shiftKey, cmdKey].filter(hasModifier).count
    }
    
    private var isReservedSystemShortcut: Bool {
        hasModifier(cmdKey) && Self.reservedSystemKeyCodes.contains(keyCode)
    }
    
    private func hasModifier(_ modifier: Int) -> Bool {
        modifiers & UInt32(modifier) != 0
    }
    
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        
        return modifiers
    }
    
    private static func keyLabel(for event: NSEvent) -> String {
        if let specialLabel = specialKeyLabels[UInt32(event.keyCode)] {
            return specialLabel
        }
        
        return (event.charactersIgnoringModifiers ?? "")
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static let specialKeyLabels: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓"
    ]
    
    private static let reservedSystemKeyCodes: Set<UInt32> = [
        UInt32(kVK_Space),
        UInt32(kVK_Tab)
    ]
}
