import Carbon
import AppKit

// Registers a global hotkey via the Carbon Event Manager.
// Default: ⌃⌥⌘S (configurable in Settings).
final class HotkeyManager {
    var onHotKeyPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Signature bytes for kEventHotKeyID: 'TIDS'
    private let signatureFourCC: OSType = 0x54494453

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_S),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey)) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let ptr = userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                manager.onHotKeyPressed?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: signatureFourCC, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    deinit { unregister() }
}
