import AppKit
import Foundation

private let modifierOnlyKeyCode = 65535
private let rawShift: UInt64 = 131_072
private let rawControl: UInt64 = 262_144
private let rawOption: UInt64 = 524_288
private let rawCommand: UInt64 = 1_048_576
private let rawFunction: UInt64 = 8_388_608

private struct ShortcutMonitorConfig: Decodable {
    let shortcuts: [ShortcutBinding]
}

private struct ShortcutBinding: Decodable {
    let target: String
    let keyCode: Int
    let modifiers: UInt64
}

private final class ShortcutMonitor {
    private let shortcuts: [ShortcutBinding]
    private var activeTargets = Set<String>()

    init(configPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try JSONDecoder().decode(ShortcutMonitorConfig.self, from: data)
        shortcuts = config.shortcuts.filter { $0.modifiers != 0 }
    }

    func handleModifiers(_ currentModifiers: UInt64) {
        for shortcut in shortcuts {
            guard shortcut.keyCode == modifierOnlyKeyCode else {
                if activeTargets.contains(shortcut.target), currentModifiers != shortcut.modifiers {
                    activeTargets.remove(shortcut.target)
                    if emitsUpPhase(shortcut.target) {
                        emit(target: shortcut.target, phase: "up")
                    }
                }
                continue
            }
            let isMatch = currentModifiers == shortcut.modifiers
            let isActive = activeTargets.contains(shortcut.target)
            if isMatch && !isActive {
                activeTargets.insert(shortcut.target)
                emit(target: shortcut.target, phase: downPhase(for: shortcut.target))
            } else if !isMatch && isActive {
                activeTargets.remove(shortcut.target)
                if emitsUpPhase(shortcut.target) {
                    emit(target: shortcut.target, phase: "up")
                }
            }
        }
    }

    func handleKeyEvent(_ type: CGEventType, keyCode: Int, currentModifiers: UInt64, isRepeat: Bool) {
        guard !isRepeat else { return }
        for shortcut in shortcuts where shortcut.keyCode != modifierOnlyKeyCode && shortcut.keyCode == keyCode {
            let isActive = activeTargets.contains(shortcut.target)
            switch type {
            case .keyDown:
                guard currentModifiers == shortcut.modifiers, !isActive else { continue }
                activeTargets.insert(shortcut.target)
                emit(target: shortcut.target, phase: downPhase(for: shortcut.target))
                if downPhase(for: shortcut.target) == "trigger" {
                    activeTargets.remove(shortcut.target)
                }
            case .keyUp:
                guard isActive else { continue }
                activeTargets.remove(shortcut.target)
                if emitsUpPhase(shortcut.target) {
                    emit(target: shortcut.target, phase: "up")
                }
            default:
                continue
            }
        }
    }

    private func downPhase(for target: String) -> String {
        switch target {
        case "holdToTalk", "assistantLiveVoice":
            return "down"
        default:
            return "trigger"
        }
    }

    private func emitsUpPhase(_ target: String) -> Bool {
        target == "holdToTalk" || target == "assistantLiveVoice"
    }

    private func emit(target: String, phase: String) {
        let payload = #"{"target":"\#(target)","phase":"\#(phase)"}"#
        FileHandle.standardOutput.write((payload + "\n").data(using: .utf8)!)
        fflush(stdout)
    }
}

private func modifierRawValue(from event: CGEvent) -> UInt64 {
    let flags = event.flags
    var raw: UInt64 = 0
    if flags.contains(.maskShift) { raw |= rawShift }
    if flags.contains(.maskControl) { raw |= rawControl }
    if flags.contains(.maskAlternate) { raw |= rawOption }
    if flags.contains(.maskCommand) { raw |= rawCommand }
    if flags.contains(.maskSecondaryFn) { raw |= rawFunction }
    return raw
}

private let shortcutEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .flagsChanged {
        monitor.handleModifiers(modifierRawValue(from: event))
    } else if type == .keyDown || type == .keyUp {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        monitor.handleKeyEvent(type, keyCode: keyCode, currentModifiers: modifierRawValue(from: event), isRepeat: isRepeat)
    }
    return Unmanaged.passUnretained(event)
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("Missing shortcut monitor config path.\n".data(using: .utf8)!)
    exit(2)
}

do {
    let monitor = try ShortcutMonitor(configPath: CommandLine.arguments[1])
    let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        | CGEventMask(1 << CGEventType.keyDown.rawValue)
        | CGEventMask(1 << CGEventType.keyUp.rawValue)
    guard let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask,
        callback: shortcutEventTapCallback,
        userInfo: Unmanaged.passUnretained(monitor).toOpaque()
    ) else {
        FileHandle.standardError.write("Shortcut monitor could not create event tap. Accessibility permission may be needed.\n".data(using: .utf8)!)
        exit(3)
    }
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    FileHandle.standardOutput.write("{\"status\":\"ready\"}\n".data(using: .utf8)!)
    fflush(stdout)
    withExtendedLifetime(monitor) {
        CFRunLoopRun()
    }
} catch {
    FileHandle.standardError.write("Shortcut monitor failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
