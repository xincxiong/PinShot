import AppKit
import Carbon.HIToolbox

/// 一个可持久化的全局快捷键（keyCode + Carbon 修饰键）
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultCapturePin = HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let defaultCaptureCopy = HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey | shiftKey))
    /// 录制 GIF：⌃⌥⌘G，避开 Finder 的 ⇧⌘G
    static let defaultCaptureGIF = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_G),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    var hasModifier: Bool { carbonModifiers != 0 }

    /// "⇧⌘2" 这类展示文案
    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCodeNames.name(for: keyCode)
        return s
    }

    /// 从 AppKit 事件生成；需要至少一个修饰键（F1-F20 等特殊键可例外）
    static func from(event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        if carbon == 0 && !KeyCodeNames.isFunctionKey(combo.keyCode) { return nil }
        return combo
    }
}

/// 虚拟键码 → 展示名
enum KeyCodeNames {
    static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "↩", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key\(keyCode)"
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        (96...113).contains(keyCode) || [118, 120, 122].contains(keyCode)
    }
}

/// Carbon 全局热键管理器。回调在主线程。
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    var onAction: ((UInt32) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x50494E53 // 'PINS'

    private init() {
        installEventHandler()
    }

    deinit {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        unregisterAll()
    }

    @discardableResult
    func register(_ combo: HotKeyCombo, id: UInt32) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            return true
        }
        NSLog("[PinShot] RegisterEventHotKey failed id=\(id) status=\(status)")
        return false
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onAction?(hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, userData, &eventHandler)
    }
}
