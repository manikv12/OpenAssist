import AppKit
import Foundation

enum ShortcutValidationRules {
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func filteredModifiers(rawValue: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue).intersection(supportedModifiers)
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

    static func isValid(keyCode: UInt16, modifiers: UInt) -> Bool {
        let filteredModifiers = filteredModifiers(rawValue: modifiers)
        let count = modifierCount(in: filteredModifiers)

        if keyCode == UInt16.max {
            return (2...3).contains(count)
        }

        guard !modifierOnlyKeyCodes.contains(keyCode) else { return false }
        return (1...2).contains(count)
    }
}
