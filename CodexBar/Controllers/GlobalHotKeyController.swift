import Carbon.HIToolbox
import Foundation

final class GlobalHotKeyController {
    private let onPressed: @MainActor () -> Void
    private var registration: GlobalHotKeyRegistration?
    private var nextHotKeyID: UInt32 = 1

    init(onPressed: @escaping @MainActor () -> Void) {
        self.onPressed = onPressed
    }

    func install(shortcut: GlobalHotKeyShortcut) -> Bool {
        let newEventHandler = Self.makeEventHandler()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var installedHandlerRef: EventHandlerRef?

        guard InstallEventHandler(
            GetApplicationEventTarget(),
            newEventHandler,
            1,
            &eventType,
            userData,
            &installedHandlerRef
        ) == noErr else {
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
        var registeredHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKeyRef
        )

        guard status == noErr else {
            if let installedHandlerRef {
                GlobalHotKeyRegistration.remove(hotKeyRef: nil, eventHandlerRef: installedHandlerRef)
            }
            return false
        }

        clearCurrentRegistration()

        registration = GlobalHotKeyRegistration(
            eventHandler: newEventHandler,
            eventHandlerRef: installedHandlerRef,
            hotKeyRef: registeredHotKeyRef
        )
        nextHotKeyID &+= 1
        return true
    }

    func uninstall() {
        clearCurrentRegistration()
    }

    private func clearCurrentRegistration() {
        registration?.invalidate()
        registration = nil
    }

    private func handleHotKeyPressed() {
        Task { @MainActor [onPressed] in
            onPressed()
        }
    }

    private static func makeEventHandler() -> EventHandlerUPP {
        { _, _, userData in
            guard let userData else {
                return noErr
            }

            let controller = Unmanaged<GlobalHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            controller.handleHotKeyPressed()
            return noErr
        }
    }

    private static let hotKeySignature: OSType = {
        let scalars = Array("CDBR".unicodeScalars)
        return scalars.reduce(UInt32(0)) { result, scalar in
            (result << 8) + scalar.value
        }
    }()
}

private final nonisolated class GlobalHotKeyRegistration {
    private var eventHandler: EventHandlerUPP?
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(
        eventHandler: EventHandlerUPP,
        eventHandlerRef: EventHandlerRef?,
        hotKeyRef: EventHotKeyRef?
    ) {
        self.eventHandler = eventHandler
        self.eventHandlerRef = eventHandlerRef
        self.hotKeyRef = hotKeyRef
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        Self.remove(hotKeyRef: hotKeyRef, eventHandlerRef: eventHandlerRef)
        hotKeyRef = nil
        eventHandlerRef = nil
        eventHandler = nil
    }

    static func remove(
        hotKeyRef: EventHotKeyRef?,
        eventHandlerRef: EventHandlerRef?
    ) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
