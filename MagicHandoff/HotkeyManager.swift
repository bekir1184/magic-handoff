import Foundation
import Carbon

/// Global hotkeys ⌘⇧1 and ⌘⇧2, one per Mac. Carbon's RegisterEventHotKey works
/// from a menu bar app without the Accessibility permission.
final class HotkeyManager {
    /// Called on the main queue with the number that was pressed (1 or 2).
    var onHotkey: ((Int) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D48_4F46   // 'MHOF'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let number = Int(id.id)
            DispatchQueue.main.async { manager.onHotkey?(number) }
            return noErr
        }, 1, &spec, context, &handlerRef)

        // ⌘⇧1 and ⌘⇧2 (ANSI key codes 18 and 19).
        for (number, keyCode) in [(1, UInt32(kVK_ANSI_1)), (2, UInt32(kVK_ANSI_2))] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(number))
            RegisterEventHotKey(keyCode, UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    deinit {
        for ref in hotKeyRefs { if let ref { UnregisterEventHotKey(ref) } }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
