import AppKit
import Foundation

enum ShortcutValidation {
    static let supportedModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    static let keyNames: [UInt16: String] = [
        0: "A",
        1: "S",
        2: "D",
        3: "F",
        4: "H",
        5: "G",
        6: "Z",
        7: "X",
        8: "C",
        9: "V",
        11: "B",
        12: "Q",
        13: "W",
        14: "E",
        15: "R",
        16: "Y",
        17: "T",
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        22: "6",
        23: "5",
        24: "=",
        25: "9",
        26: "7",
        27: "-",
        28: "8",
        29: "0",
        30: "]",
        31: "O",
        32: "U",
        33: "[",
        34: "I",
        35: "P",
        36: "Return",
        37: "L",
        38: "J",
        39: "'",
        40: "K",
        41: ";",
        42: "\\",
        43: ",",
        44: "/",
        45: "N",
        46: "M",
        47: ".",
        48: "`",
        49: "Space",
        50: "`",
        51: "Delete",
        53: "Esc",
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        106: "F16",
        64: "F17",
        79: "F18",
        80: "F19",
        90: "F20",
        63: "Fn"
    ]
    static let manualAssignableKeyCodes: [UInt16] = [
        49, 36, 51, 53,
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,
        24, 27, 33, 30, 41, 39, 43, 47, 44, 42,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    static let defaultKeyCode: UInt16 = 49
    static let defaultModifiers: UInt = NSEvent.ModifierFlags([.control, .shift]).rawValue

    static func filteredModifierFlags(from rawValue: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue).intersection(supportedModifierFlags)
    }

    static func filteredModifierRawValue(from rawValue: UInt) -> UInt {
        filteredModifierFlags(from: rawValue).rawValue
    }

    static func isModifierOnlyKeyCode(_ keyCode: UInt16) -> Bool {
        modifierOnlyKeyCodes.contains(keyCode)
    }

    static func modifierCount(in flags: NSEvent.ModifierFlags) -> Int {
        var count = 0
        if flags.contains(.function) { count += 1 }
        if flags.contains(.control) { count += 1 }
        if flags.contains(.option) { count += 1 }
        if flags.contains(.shift) { count += 1 }
        if flags.contains(.command) { count += 1 }
        return count
    }

    static func isValid(keyCode: UInt16, modifiersRaw: UInt) -> Bool {
        let flags = filteredModifierFlags(from: modifiersRaw)
        let count = modifierCount(in: flags)

        if keyCode == UInt16.max {
            return (2...4).contains(count)
        }

        guard !isModifierOnlyKeyCode(keyCode) else { return false }
        return (1...3).contains(count)
    }

    static func displaySegments(keyCode: UInt16, modifiersRaw: UInt) -> [String] {
        let flags = filteredModifierFlags(from: modifiersRaw)
        var segments: [String] = []

        if flags.contains(.function) { segments.append("Fn") }
        if flags.contains(.control) { segments.append("⌃") }
        if flags.contains(.option) { segments.append("⌥") }
        if flags.contains(.shift) { segments.append("⇧") }
        if flags.contains(.command) { segments.append("⌘") }

        if keyCode != UInt16.max {
            segments.append(keyName(for: keyCode))
        }

        return segments.isEmpty ? ["Not set"] : segments
    }

    static func keyName(for code: UInt16) -> String {
        keyNames[code] ?? "Key \(code)"
    }
}
