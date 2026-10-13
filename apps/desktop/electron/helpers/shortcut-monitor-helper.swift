import AppKit
import Darwin
import Foundation

private let modifierOnlyKeyCode = 65535
private let rawShift: UInt64 = 131_072
private let rawControl: UInt64 = 262_144
private let rawOption: UInt64 = 524_288
private let rawCommand: UInt64 = 1_048_576
private let rawFunction: UInt64 = 8_388_608

private func emitJSON(_ payload: [String: Any]) {
    guard
        let data = try? JSONSerialization.data(withJSONObject: payload),
        let line = String(data: data, encoding: .utf8),
        let output = (line + "\n").data(using: .utf8)
    else { return }
    FileHandle.standardOutput.write(output)
    fflush(stdout)
}

private func argumentValue(after flag: String) -> String? {
    guard
        let index = CommandLine.arguments.firstIndex(of: flag),
        index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

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
    private let parentPID: pid_t?
    private var activeTargets = Set<String>()
    private var eventTap: CFMachPort?
    private var watchdog: Timer?

    init(configPath: String, parentPID: pid_t?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try JSONDecoder().decode(ShortcutMonitorConfig.self, from: data)
        shortcuts = config.shortcuts.filter { $0.modifiers != 0 }
        self.parentPID = parentPID
    }

    func attachEventTap(_ eventTap: CFMachPort) {
        self.eventTap = eventTap
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let parentPID = self.parentPID, kill(parentPID, 0) != 0, errno == ESRCH {
                emitJSON(["status": "parent-exited"])
                exit(0)
            }
            self.restoreEventTapIfNeeded(reason: "watchdog")
        }
    }

    func restoreEventTapIfNeeded(reason: String) {
        guard let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        emitStatus("reenabled", reason: reason)
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
        case "holdToTalk":
            return "down"
        default:
            return "trigger"
        }
    }

    private func emitsUpPhase(_ target: String) -> Bool {
        target == "holdToTalk"
    }

    private func emit(target: String, phase: String) {
        var payload: [String: Any] = ["target": target, "phase": phase]
        if let application = NSWorkspace.shared.frontmostApplication {
            payload["application"] = [
                "pid": Int(application.processIdentifier),
                "bundleIdentifier": application.bundleIdentifier ?? "",
                "name": application.localizedName ?? ""
            ]
        }
        emitJSON(payload)
    }

    private func emitStatus(_ status: String, reason: String? = nil) {
        var payload: [String: Any] = ["status": status]
        if let reason { payload["reason"] = reason }
        emitJSON(payload)
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
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.restoreEventTapIfNeeded(reason: type == .tapDisabledByTimeout ? "timeout" : "user-input")
    } else if type == .flagsChanged {
        monitor.handleModifiers(modifierRawValue(from: event))
    } else if type == .keyDown || type == .keyUp {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        monitor.handleKeyEvent(type, keyCode: keyCode, currentModifiers: modifierRawValue(from: event), isRepeat: isRepeat)
    }
    return Unmanaged.passUnretained(event)
}

if CommandLine.arguments.contains("--request-permission") {
    let allowed = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    emitJSON(["status": allowed ? "permission-granted" : "input-monitoring-required"])
    exit(allowed ? 0 : 4)
}

guard CommandLine.arguments.count >= 2, !CommandLine.arguments[1].hasPrefix("--") else {
    FileHandle.standardError.write("Missing shortcut monitor config path.\n".data(using: .utf8)!)
    exit(2)
}

do {
    let lockPath = NSTemporaryDirectory() + "com.developingadventures.OpenAssist.ShortcutMonitor.\(getuid()).lock"
    let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
    guard lockFD >= 0 else {
        emitJSON(["status": "lock-failed"])
        exit(1)
    }
    var acquiredLock = false
    for _ in 0..<20 {
        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
            acquiredLock = true
            break
        }
        usleep(50_000)
    }
    guard acquiredLock else {
        emitJSON(["status": "already-running"])
        Darwin.close(lockFD)
        exit(0)
    }
    defer {
        flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
    }

    let parentPID = argumentValue(after: "--parent-pid").flatMap { pid_t($0) }
    let monitor = try ShortcutMonitor(configPath: CommandLine.arguments[1], parentPID: parentPID)
    guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
        emitJSON(["status": "input-monitoring-required"])
        FileHandle.standardError.write("Shortcut monitor needs Input Monitoring access in System Settings.\n".data(using: .utf8)!)
        exit(4)
    }
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
    monitor.attachEventTap(eventTap)
    emitJSON(["status": "ready"])
    withExtendedLifetime(monitor) {
        CFRunLoopRun()
    }
} catch {
    FileHandle.standardError.write("Shortcut monitor failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
