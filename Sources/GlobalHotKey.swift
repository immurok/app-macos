import AppKit

/// 全局热键监听器（默认 Ctrl+\，可自定义）
class GlobalHotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var onTrigger: (() -> Void)?

    // UserDefaults keys
    static let keyCodeKey = "immurok.quickFillKeyCode"
    static let modifiersKey = "immurok.quickFillModifiers"

    // Default: Ctrl+\ (keyCode 42)
    static let defaultKeyCode: UInt16 = 42
    static let defaultModifiers: UInt = NSEvent.ModifierFlags.control.rawValue

    static var storedKeyCode: UInt16 {
        let v = UserDefaults.standard.integer(forKey: keyCodeKey)
        return v == 0 ? defaultKeyCode : UInt16(v)
    }

    static var storedModifiers: NSEvent.ModifierFlags {
        let v = UserDefaults.standard.integer(forKey: modifiersKey)
        return v == 0 ? NSEvent.ModifierFlags(rawValue: defaultModifiers) : NSEvent.ModifierFlags(rawValue: UInt(v))
    }

    func register() {
        let keyCode = Self.storedKeyCode
        let mods = Self.storedModifiers
        let checkMask: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode && event.modifierFlags.intersection(checkMask) == mods.intersection(checkMask) {
                DispatchQueue.main.async {
                    self?.onTrigger?()
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode && event.modifierFlags.intersection(checkMask) == mods.intersection(checkMask) {
                DispatchQueue.main.async {
                    self?.onTrigger?()
                }
                return nil
            }
            return event
        }
    }

    func unregister() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        unregister()
    }

    // MARK: - Display

    /// Format a keyCode + modifiers as human-readable string (e.g., "⌃\")
    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        let check = modifiers.intersection([.control, .option, .command, .shift])
        if check.contains(.control) { parts.append("⌃") }
        if check.contains(.option) { parts.append("⌥") }
        if check.contains(.shift) { parts.append("⇧") }
        if check.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static var currentDisplayString: String {
        displayString(keyCode: storedKeyCode, modifiers: storedModifiers)
    }

    private static func keyName(for keyCode: UInt16) -> String {
        // Common key names
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`",
            51: "⌫", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 109: "F10", 111: "F12",
            118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            36: "↩", 76: "⌅",
        ]
        return names[keyCode] ?? "(\(keyCode))"
    }
}
