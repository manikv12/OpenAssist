import AppKit
import Foundation

private final class ShortcutEventSuppressor {
    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
    private let onSuppressedKeyDown: () -> Void
    private let onSuppressedKeyUp: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        onSuppressedKeyDown: @escaping () -> Void,
        onSuppressedKeyUp: @escaping () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.onSuppressedKeyDown = onSuppressedKeyDown
        self.onSuppressedKeyUp = onSuppressedKeyUp
    }

    func start() {
        stop()

        let eventsOfInterest = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let suppressor = Unmanaged<ShortcutEventSuppressor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = suppressor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown || type == .keyUp else {
                return Unmanaged.passUnretained(event)
            }

            guard suppressor.shouldSuppress(event) else {
                return Unmanaged.passUnretained(event)
            }

            suppressor.notifySuppressedEvent(type)
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func shouldSuppress(_ event: CGEvent) -> Bool {
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else { return false }

        let eventModifiers = normalizedModifiers(from: event.flags)
        return eventModifiers.isSuperset(of: modifiers)
    }

    private func notifySuppressedEvent(_ type: CGEventType) {
        DispatchQueue.main.async {
            switch type {
            case .keyDown:
                self.onSuppressedKeyDown()
            case .keyUp:
                self.onSuppressedKeyUp()
            default:
                break
            }
        }
    }

    private func normalizedModifiers(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result.intersection(Self.supportedModifiers)
    }
}

final class HoldToTalkManager {
    typealias Action = () -> Void

    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
    private let suppressSystemShortcutSounds: Bool
    private let onStart: Action
    private let onStop: Action

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var flagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var localFlagsMonitor: Any?
    private var releaseWatchdog: DispatchSourceTimer?
    private var shortcutEventSuppressor: ShortcutEventSuppressor?
    private var active = false

    private var isModifierOnlyShortcut: Bool {
        keyCode == UInt16.max
    }

    init(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        suppressSystemShortcutSounds: Bool = false,
        onStart: @escaping Action,
        onStop: @escaping Action
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.suppressSystemShortcutSounds = suppressSystemShortcutSounds
        self.onStart = onStart
        self.onStop = onStop
    }

    deinit {
        stop()
    }

    func start() {
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOnMain()
            }
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.sync {
                self.stopOnMain()
            }
        }
    }

    private func startOnMain() {
        stopOnMain()

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleFlagsChanged(event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        if isModifierOnlyShortcut {
            stopShortcutEventSuppression()
            return
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event: event, isDown: true)
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event, isDown: true)
            return event
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event: event, isDown: false)
            }
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handle(event: event, isDown: false)
            return event
        }

        startShortcutEventSuppressionIfNeeded()
    }

    private func stopOnMain() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
            self.localKeyUpMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        stopShortcutEventSuppression()
        stopWatchdog()
        active = false
    }

    private func normalizedModifiers(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(Self.supportedModifiers)
    }

    private func isConfiguredShortcutDown(_ event: NSEvent) -> Bool {
        let eventKey = event.keyCode
        let eventMods = normalizedModifiers(from: event)
        return eventKey == keyCode && eventMods.isSuperset(of: modifiers)
    }

    private func handle(event: NSEvent, isDown: Bool) {
        if isDown {
            guard isConfiguredShortcutDown(event) else { return }
            if event.isARepeat { return }
            if !active {
                active = true
                startWatchdog()
                onStart()
            }
        } else if active && event.keyCode == keyCode {
            active = false
            stopWatchdog()
            onStop()
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentMods = normalizedModifiers(from: event)

        if isModifierOnlyShortcut {
            if currentMods.isSuperset(of: modifiers) {
                if !active {
                    active = true
                    startWatchdog()
                    onStart()
                }
            } else if active {
                active = false
                stopWatchdog()
                onStop()
            }
            return
        }

        if active && !currentMods.isSuperset(of: modifiers) {
            active = false
            stopWatchdog()
            onStop()
        }
    }

    private func startWatchdog() {
        stopWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            if !self.isShortcutPhysicallyHeld() {
                self.active = false
                self.stopWatchdog()
                self.onStop()
            }
        }
        releaseWatchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
    }

    private func startShortcutEventSuppressionIfNeeded() {
        guard suppressSystemShortcutSounds, !isModifierOnlyShortcut else {
            stopShortcutEventSuppression()
            return
        }

        let suppressor = ShortcutEventSuppressor(
            keyCode: keyCode,
            modifiers: modifiers,
            onSuppressedKeyDown: { [weak self] in
                self?.handleSuppressedShortcutEvent(isDown: true)
            },
            onSuppressedKeyUp: { [weak self] in
                self?.handleSuppressedShortcutEvent(isDown: false)
            }
        )
        suppressor.start()
        shortcutEventSuppressor = suppressor
    }

    private func stopShortcutEventSuppression() {
        shortcutEventSuppressor?.stop()
        shortcutEventSuppressor = nil
    }

    private func handleSuppressedShortcutEvent(isDown: Bool) {
        if isDown {
            guard !active else { return }
            active = true
            startWatchdog()
            onStart()
        } else {
            guard active else { return }
            active = false
            stopWatchdog()
            onStop()
        }
    }

    private func isShortcutPhysicallyHeld() -> Bool {
        let source: CGEventSourceStateID = .combinedSessionState

        if !isModifierOnlyShortcut,
           !CGEventSource.keyState(source, key: CGKeyCode(keyCode)) {
            return false
        }

        if modifiers.contains(.command) {
            let left = CGEventSource.keyState(source, key: 55)
            let right = CGEventSource.keyState(source, key: 54)
            if !(left || right) { return false }
        }

        if modifiers.contains(.option) {
            let left = CGEventSource.keyState(source, key: 58)
            let right = CGEventSource.keyState(source, key: 61)
            if !(left || right) { return false }
        }

        if modifiers.contains(.control) {
            let left = CGEventSource.keyState(source, key: 59)
            let right = CGEventSource.keyState(source, key: 62)
            if !(left || right) { return false }
        }

        if modifiers.contains(.shift) {
            let left = CGEventSource.keyState(source, key: 56)
            let right = CGEventSource.keyState(source, key: 60)
            if !(left || right) { return false }
        }

        if modifiers.contains(.function),
           !CGEventSource.keyState(source, key: 63) {
            return false
        }

        return true
    }
}

final class OneShotHotkeyManager {
    typealias Action = () -> Void

    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
    private let onTrigger: Action

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var flagsMonitor: Any?
    private var active = false

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, onTrigger: @escaping Action) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.onTrigger = onTrigger
    }

    deinit {
        stop()
    }

    func start() {
        if Thread.isMainThread {
            startOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOnMain()
            }
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.sync {
                self.stopOnMain()
            }
        }
    }

    private func startOnMain() {
        stopOnMain()

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleKeyDown(event)
            }
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleKeyUp(event)
            }
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleFlagsChanged(event)
            }
        }
    }

    private func stopOnMain() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        active = false
    }

    private func normalizedModifiers(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(Self.supportedModifiers)
    }

    private func handleKeyDown(_ event: NSEvent) {
        let eventModifiers = normalizedModifiers(from: event)
        guard event.keyCode == keyCode, eventModifiers.isSuperset(of: modifiers) else { return }

        if event.isARepeat {
            return
        }

        if active, !isShortcutPhysicallyHeld() {
            active = false
        }

        guard !active else { return }
        active = true
        onTrigger()
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        active = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentModifiers = normalizedModifiers(from: event)
        if !currentModifiers.isSuperset(of: modifiers) {
            active = false
        }
    }

    private func isShortcutPhysicallyHeld() -> Bool {
        let source: CGEventSourceStateID = .combinedSessionState

        if !CGEventSource.keyState(source, key: CGKeyCode(keyCode)) {
            return false
        }

        if modifiers.contains(.command) {
            let left = CGEventSource.keyState(source, key: 55)
            let right = CGEventSource.keyState(source, key: 54)
            if !(left || right) { return false }
        }

        if modifiers.contains(.option) {
            let left = CGEventSource.keyState(source, key: 58)
            let right = CGEventSource.keyState(source, key: 61)
            if !(left || right) { return false }
        }

        if modifiers.contains(.control) {
            let left = CGEventSource.keyState(source, key: 59)
            let right = CGEventSource.keyState(source, key: 62)
            if !(left || right) { return false }
        }

        if modifiers.contains(.shift) {
            let left = CGEventSource.keyState(source, key: 56)
            let right = CGEventSource.keyState(source, key: 60)
            if !(left || right) { return false }
        }

        if modifiers.contains(.function),
           !CGEventSource.keyState(source, key: 63) {
            return false
        }

        return true
    }
}
