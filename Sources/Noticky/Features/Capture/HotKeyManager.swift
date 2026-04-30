import Carbon.HIToolbox
import AppKit

struct HotKeyCombo {
    let keyCode: UInt32
    let modifiers: UInt32

    static let captureDefault = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

/// Carbon 全局热键封装。
/// 关键事实:`RegisterEventHotKey` **不需要任何系统权限**,
/// 这是相对 `NSEvent.addGlobalMonitorForEvents` 的核心优势。
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (() -> Void)?

    func register(combo: HotKeyCombo, action: @escaping () -> Void) {
        unregister()
        callback = action

        let signature: OSType = 0x4E_4F_54_4B  // "NOTK"
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let registered = ref else {
            print("Noticky: RegisterEventHotKey failed, status=\(status)")
            return
        }
        hotKeyRef = registered

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.callback?() }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &handlerRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    deinit { unregister() }
}
