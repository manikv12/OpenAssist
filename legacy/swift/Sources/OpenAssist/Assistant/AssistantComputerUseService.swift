import AppKit
import Foundation

struct AssistantComputerUseFrontmostAppContext: Equatable, Sendable {
    let bundleIdentifier: String?
    let displayName: String
}

enum AssistantComputerUseToolDefinition {
    static let name = "computer_use"
    static let toolKind = "computerUse"

    static let description = """
    Use the visible macOS desktop on this Mac by taking a screenshot, then using mouse and keyboard actions against the current screen. Prefer `browser_use` for opening or reusing a signed-in browser session, and prefer `app_action` for supported structured app actions. Use this tool only as a last resort when the task truly needs generic visual interaction such as observing the screen, clicking, dragging, scrolling, or typing in an unsupported app UI. When `app` or `window_id` is provided, the target app is automatically brought to focus and other apps are hidden for a clean, unobstructed interaction — you can skip the initial observe step and act directly. Supports: observe, click (left/right/middle with modifier keys), double_click, triple_click, right_click, middle_click, hover/move, mouse_down, mouse_up, drag, scroll, keypress, hold_key, type, open_application, clipboard_read, clipboard_write, cursor_position, switch_display, zoom (region inspect at full resolution), and wait.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "What the assistant is trying to do right now."
            ],
            "reason": [
                "type": "string",
                "description": "Why generic computer control is needed instead of browser_use or app_action."
            ],
            "targetLabel": [
                "type": "string",
                "description": "Optional short label for the visible target such as Filters button or Compose field."
            ],
            "app": [
                "type": "string",
                "description": "Optional app name hint for target locking, such as Cursor or Chrome."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title hint for target locking."
            ],
            "window_id": [
                "type": "integer",
                "description": "Optional exact window id to lock before observing or acting."
            ],
            "display_id": [
                "type": "integer",
                "description": "Optional exact display id to lock before observing or acting."
            ],
            "expected_change": [
                "type": "string",
                "description": "Optional short note about what should visibly change after the step."
            ],
            "action": [
                "type": "object",
                "description": "The explicit computer-use action to perform.",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "One of: observe, click, double_click, triple_click, right_click, middle_click, move, hover, mouse_down, mouse_up, drag, scroll, keypress, hold_key, type, open_application, clipboard_read, clipboard_write, cursor_position, switch_display, zoom, or wait."
                    ],
                    "x": [
                        "type": "number",
                        "description": "Horizontal coordinate in screenshot pixels from the top-left origin."
                    ],
                    "y": [
                        "type": "number",
                        "description": "Vertical coordinate in screenshot pixels from the top-left origin."
                    ],
                    "path": [
                        "type": "array",
                        "description": "Drag path as screenshot-pixel points.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "number"],
                                "y": ["type": "number"]
                            ],
                            "required": ["x", "y"]
                        ]
                    ],
                    "scroll_x": [
                        "type": "number",
                        "description": "Horizontal scroll delta in pixels."
                    ],
                    "scroll_y": [
                        "type": "number",
                        "description": "Vertical scroll delta in pixels."
                    ],
                    "keys": [
                        "type": "array",
                        "description": "Keys for a keypress action, such as [\"cmd\", \"l\"].",
                        "items": ["type": "string"]
                    ],
                    "text": [
                        "type": "string",
                        "description": "Text to type for a type action."
                    ],
                    "button": [
                        "type": "string",
                        "description": "Mouse button: left (default), right, or middle."
                    ],
                    "modifiers": [
                        "type": "array",
                        "description": "Modifier keys to hold during click (e.g. [\"cmd\"], [\"shift\", \"ctrl\"]).",
                        "items": ["type": "string"]
                    ],
                    "name": [
                        "type": "string",
                        "description": "Application name for open_application action (e.g. Safari, Slack, Finder)."
                    ],
                    "duration_ms": [
                        "type": "integer",
                        "description": "Duration in milliseconds for wait or hold_key actions."
                    ],
                    "region": [
                        "type": "array",
                        "description": "For zoom action: [x1, y1, x2, y2] defining top-left and bottom-right corners of the region to inspect at full resolution.",
                        "items": ["type": "number"],
                        "minItems": 4,
                        "maxItems": 4
                    ]
                ],
                "required": ["type"]
            ]
        ],
        "required": ["task", "reason", "action"],
        "additionalProperties": true
    ]

    static func dynamicToolSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

enum AssistantComputerBatchToolDefinition {
    static let name = "computer_batch"
    static let toolKind = "computerBatch"

    static let description = """
    Execute multiple low-level computer actions in rapid sequence without per-action verification. \
    Use this when you need to chain several actions quickly (e.g. click a field then type text, \
    or press multiple keyboard shortcuts in sequence). Each action uses the same format as the \
    computer_use tool's action object. A final screenshot is taken after all actions complete.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "actions": [
                "type": "array",
                "description": "An ordered list of actions to perform. Each uses the same schema as the computer_use action object.",
                "items": [
                    "type": "object",
                    "properties": [
                        "type": [
                            "type": "string",
                            "description": "One of: click, double_click, triple_click, right_click, middle_click, move, hover, mouse_down, mouse_up, drag, scroll, keypress, hold_key, type, open_application, clipboard_read, clipboard_write, cursor_position, switch_display, or wait."
                        ],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "path": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number"],
                                    "y": ["type": "number"]
                                ],
                                "required": ["x", "y"]
                            ]
                        ],
                        "scroll_x": ["type": "number"],
                        "scroll_y": ["type": "number"],
                        "keys": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "text": ["type": "string"],
                        "button": ["type": "string"],
                        "modifiers": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "name": ["type": "string"],
                        "duration_ms": ["type": "integer"],
                        "display_id": ["type": "integer"]
                    ],
                    "required": ["type"]
                ]
            ]
        ],
        "required": ["actions"]
    ]
}

enum AssistantComputerUseServiceError: LocalizedError {
    case invalidArguments(String)
    case observeRequired(String)
    case staleObservation(String)
    case manualLoginRequired(String)
    case secretEntryForbidden(String)
    case targetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .observeRequired(let message),
             .staleObservation(let message),
             .manualLoginRequired(let message),
             .secretEntryForbidden(let message),
             .targetNotFound(let message):
            return message
        }
    }
}

actor AssistantComputerUseService {
    struct ParsedRequest: Equatable, Sendable {
        struct Point: Equatable, Sendable {
            let x: Double
            let y: Double

            var compactDescription: String {
                "(\(Self.pretty(x)), \(Self.pretty(y)))"
            }

            private static func pretty(_ value: Double) -> String {
                if value.rounded() == value {
                    return String(Int(value))
                }
                return String(format: "%.1f", value)
            }
        }

        enum Action: Equatable, Sendable {
            case observe
            case click(Point, button: String?, modifiers: [String])
            case doubleClick(Point, button: String?)
            case tripleClick(Point, button: String?)
            case rightClick(Point)
            case middleClick(Point)
            case move(Point)
            case mouseDown(Point, button: String?)
            case mouseUp(Point, button: String?)
            case drag([Point])
            case scroll(Point, deltaX: Double, deltaY: Double)
            case keypress([String])
            case holdKey([String], durationMs: Int)
            case type(String)
            case openApplication(String)
            case clipboardRead
            case clipboardWrite(String)
            case cursorPosition
            case switchDisplay(CGDirectDisplayID)
            case zoom(x1: Double, y1: Double, x2: Double, y2: Double)
            case wait(milliseconds: Int)

            var typeName: String {
                switch self {
                case .observe: return "observe"
                case .click: return "click"
                case .doubleClick: return "double_click"
                case .tripleClick: return "triple_click"
                case .rightClick: return "right_click"
                case .middleClick: return "middle_click"
                case .move: return "move"
                case .mouseDown: return "mouse_down"
                case .mouseUp: return "mouse_up"
                case .drag: return "drag"
                case .scroll: return "scroll"
                case .keypress: return "keypress"
                case .holdKey: return "hold_key"
                case .type: return "type"
                case .openApplication: return "open_application"
                case .clipboardRead: return "clipboard_read"
                case .clipboardWrite: return "clipboard_write"
                case .cursorPosition: return "cursor_position"
                case .switchDisplay: return "switch_display"
                case .zoom: return "zoom"
                case .wait: return "wait"
                }
            }

            var requiresCurrentObservation: Bool {
                switch self {
                case .click, .doubleClick, .tripleClick, .rightClick, .middleClick,
                     .move, .mouseDown, .mouseUp, .drag, .scroll, .keypress:
                    return true
                case .observe, .holdKey, .type, .openApplication, .clipboardRead, .clipboardWrite, .cursorPosition, .switchDisplay, .zoom, .wait:
                    return false
                }
            }

            var isCoordinateBased: Bool {
                switch self {
                case .click, .doubleClick, .tripleClick, .rightClick, .middleClick,
                     .move, .mouseDown, .mouseUp, .drag, .scroll:
                    return true
                case .observe, .keypress, .holdKey, .type, .openApplication, .clipboardRead, .clipboardWrite, .cursorPosition, .switchDisplay, .zoom, .wait:
                    return false
                }
            }

            var helperPayload: [String: Any] {
                switch self {
                case .observe:
                    return ["type": "observe"]
                case .click(let point, let button, let modifiers):
                    var payload: [String: Any] = [
                        "type": "click",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                    if !modifiers.isEmpty { payload["modifiers"] = modifiers }
                    return payload
                case .doubleClick(let point, let button):
                    return [
                        "type": "double_click",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .tripleClick(let point, let button):
                    return [
                        "type": "triple_click",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .rightClick(let point):
                    return [
                        "type": "right_click",
                        "x": point.x,
                        "y": point.y
                    ]
                case .middleClick(let point):
                    return [
                        "type": "middle_click",
                        "x": point.x,
                        "y": point.y
                    ]
                case .move(let point):
                    return [
                        "type": "move",
                        "x": point.x,
                        "y": point.y
                    ]
                case .mouseDown(let point, let button):
                    return [
                        "type": "mouse_down",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .mouseUp(let point, let button):
                    return [
                        "type": "mouse_up",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .drag(let path):
                    return [
                        "type": "drag",
                        "path": path.map { ["x": $0.x, "y": $0.y] }
                    ]
                case .scroll(let point, let deltaX, let deltaY):
                    return [
                        "type": "scroll",
                        "x": point.x,
                        "y": point.y,
                        "scroll_x": deltaX,
                        "scroll_y": deltaY
                    ]
                case .keypress(let keys):
                    return [
                        "type": "keypress",
                        "keys": keys
                    ]
                case .holdKey(let keys, let durationMs):
                    return [
                        "type": "hold_key",
                        "keys": keys,
                        "duration_ms": durationMs
                    ]
                case .type(let text):
                    return [
                        "type": "type",
                        "text": text
                    ]
                case .openApplication(let name):
                    return [
                        "type": "open_application",
                        "name": name
                    ]
                case .clipboardRead:
                    return ["type": "clipboard_read"]
                case .clipboardWrite(let text):
                    return [
                        "type": "clipboard_write",
                        "text": text
                    ]
                case .cursorPosition:
                    return ["type": "cursor_position"]
                case .switchDisplay(let displayID):
                    return [
                        "type": "switch_display",
                        "display_id": Int(displayID)
                    ]
                case .zoom(let x1, let y1, let x2, let y2):
                    return [
                        "type": "zoom",
                        "region": [x1, y1, x2, y2]
                    ]
                case .wait(let milliseconds):
                    return [
                        "type": "wait",
                        "duration_ms": milliseconds
                    ]
                }
            }

            var resultLead: String {
                switch self {
                case .observe:
                    return "Observed the current screen."
                case .click(let point, _, _):
                    return "Clicked at \(point.compactDescription)."
                case .doubleClick(let point, _):
                    return "Double-clicked at \(point.compactDescription)."
                case .tripleClick(let point, _):
                    return "Triple-clicked at \(point.compactDescription)."
                case .rightClick(let point):
                    return "Right-clicked at \(point.compactDescription)."
                case .middleClick(let point):
                    return "Middle-clicked at \(point.compactDescription)."
                case .move(let point):
                    return "Moved the pointer to \(point.compactDescription)."
                case .mouseDown(let point, _):
                    return "Pressed mouse button at \(point.compactDescription)."
                case .mouseUp(let point, _):
                    return "Released mouse button at \(point.compactDescription)."
                case .drag(let path):
                    let lead = path.first?.compactDescription ?? "the selected path"
                    let tail = path.last?.compactDescription ?? lead
                    return "Dragged from \(lead) to \(tail)."
                case .scroll(let point, let deltaX, let deltaY):
                    return "Scrolled at \(point.compactDescription) by (\(Int(deltaX.rounded())), \(Int(deltaY.rounded())))."
                case .keypress(let keys):
                    return "Pressed \(keys.joined(separator: " + "))."
                case .holdKey(let keys, let durationMs):
                    return "Held \(keys.joined(separator: " + ")) for \(durationMs) ms."
                case .type:
                    return "Typed text into the target field."
                case .openApplication(let name):
                    return "Opened \(name)."
                case .clipboardRead:
                    return "Read clipboard."
                case .clipboardWrite:
                    return "Wrote to clipboard."
                case .cursorPosition:
                    return "Queried cursor position."
                case .switchDisplay(let displayID):
                    return "Switched to display \(displayID)."
                case .zoom(let x1, let y1, let x2, let y2):
                    return "Zoomed into region (\(Int(x1)), \(Int(y1))) to (\(Int(x2)), \(Int(y2)))."
                case .wait(let milliseconds):
                    return "Waited \(milliseconds) ms."
                }
            }
        }

        let task: String
        let reason: String
        let targetLabel: String?
        let appName: String?
        let windowTitle: String?
        let windowID: Int?
        let displayID: Int?
        let expectedChange: String?
        let action: Action

        var summaryLine: String {
            let pieces = [
                task.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                requestedTargetDescription.map { "Target: \($0)" },
                "Action: \(action.typeName)"
            ]
            return pieces.compactMap { $0 }.joined(separator: " • ")
        }

        var requestedTargetDescription: String? {
            let parts = [
                targetLabel,
                appName.map { "App: \($0)" },
                windowTitle.map { "Window: \($0)" },
                windowID.map { "Window ID: \($0)" },
                displayID.map { "Display ID: \($0)" }
            ]
            let joined = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            return joined.isEmpty ? nil : joined.joined(separator: " • ")
        }

        var hasExplicitTargetHint: Bool {
            appName != nil || windowTitle != nil || windowID != nil || displayID != nil
        }

        // computer_use always uses the pixel-click path (screenshot → LLM coordinates → CGEvent).
        // Semantic AX clicks are reserved for the dedicated ui_click tool. This matches
        // Claude Dispatch's behavior and avoids issues with Electron/web-view apps where
        // AXPress does not propagate to the web layer.
        var canTrySemanticClick: Bool {
            return false
        }

        // computer_use always uses the keyboard typing path (CGEvent keystrokes).
        // Semantic AX typing is reserved for the dedicated ui_type tool.
        var canTrySemanticType: Bool {
            return false
        }

        private var normalizedContext: String {
            let parts = [
                Optional(task),
                Optional(reason),
                targetLabel,
                appName,
                windowTitle,
                expectedChange,
                typedText,
                keysText
            ]
            return parts
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
                .joined(separator: "\n")
                .lowercased()
        }

        private var typedText: String? {
            guard case .type(let text) = action else { return nil }
            return text
        }

        private var keysText: String? {
            guard case .keypress(let keys) = action else { return nil }
            return keys.joined(separator: " ")
        }

        var needsManualLoginFlow: Bool {
            let loginSignals = [
                "log in", "login", "sign in", "signin", "sign-in",
                "authenticate", "authentication", "password", "passcode",
                "verification code", "one-time code", "otp", "2fa", "mfa"
            ]
            return loginSignals.contains(where: normalizedContext.contains)
        }

        var entersSensitiveSecret: Bool {
            guard case .type = action else { return false }
            let secretSignals = [
                "password", "passcode", "otp", "one-time code", "verification code",
                "api key", "token", "secret", "credential", "auth code", "security code"
            ]
            return secretSignals.contains(where: normalizedContext.contains)
        }

        var isHighRisk: Bool {
            let riskyKeywords = ["send", "post", "submit", "delete", "remove", "purchase", "checkout", "confirm", "transfer"]
            if riskyKeywords.contains(where: normalizedContext.contains) {
                return true
            }

            guard case .type = action else { return false }
            let publicSignals = ["reply", "message", "email", "comment", "post", "tweet", "publish", "share", "submit"]
            return publicSignals.contains(where: normalizedContext.contains)
        }
    }

    private struct AutomationTargetContext: Equatable, Sendable {
        let bundleIdentifier: String?
        let appName: String
        let ownerPID: pid_t?
        let windowID: Int?
        let displayID: CGDirectDisplayID?
        let windowTitle: String?
        let bounds: CGRect?

        var targetDescription: String {
            if let windowID {
                let title = windowTitle?.nonEmpty ?? "(untitled)"
                return "\(appName) • \(title) • window \(windowID)"
            }
            if let displayID {
                return "\(appName) • display \(displayID)"
            }
            return appName
        }
    }

    private struct AutomationObservation: Sendable {
        let snapshot: LocalAutomationDisplaySnapshot
        let targetContext: AutomationTargetContext
        let capturedAt: Date
    }

    private struct AutomationStepPlan: Equatable, Sendable {
        let stage: String
        let actuator: String
        let target: String
        let expectedResult: String
        let fallbackRule: String
        let confidence: Double

        func activityMetadata(verificationResult: String?) -> AssistantAutomationActivityMetadata {
            AssistantAutomationActivityMetadata(
                stage: stage,
                actuator: actuator,
                target: target,
                confidence: confidence,
                verificationResult: verificationResult
            )
        }
    }

    private struct VerificationOutcome: Sendable {
        let verified: Bool
        let resultLabel: String
        let explanation: String
    }

    struct FocusState: Sendable {
        let targetBundleIdentifier: String?
        let targetPID: pid_t
        let hiddenAppPIDs: [pid_t]
        let didHideOwnApp: Bool
    }

    private struct SessionState {
        var targetContext: AutomationTargetContext?
        var latestObservation: AutomationObservation?
        var frontmostAppBundleID: String?
        var frontmostAppName: String?
        var lastActionSummary: String?
        var noProgressCounter = 0
        var staleReason: String?
        var focusState: FocusState?
        var preferredDisplayID: CGDirectDisplayID?
    }

    private let helper: LocalAutomationHelper
    private let accessibilityAutomationService: AssistantAccessibilityAutomationService
    private let executeActions: (_ actions: [[String: Any]], _ previousSnapshot: LocalAutomationDisplaySnapshot?) async throws -> LocalAutomationDisplaySnapshot
    private let frontmostAppProvider: @MainActor () -> AssistantComputerUseFrontmostAppContext
    private let focusApp: (_ bundleIdentifier: String?, _ appName: String, _ ownerPID: pid_t) async -> FocusState?
    private let unfocusApp: (_ state: FocusState) async -> Void
    private var sessionStateByID: [String: SessionState] = [:]

    init(
        helper: LocalAutomationHelper = .shared,
        accessibilityAutomationService: AssistantAccessibilityAutomationService? = nil,
        executeActions: ((_ actions: [[String: Any]], _ previousSnapshot: LocalAutomationDisplaySnapshot?) async throws -> LocalAutomationDisplaySnapshot)? = nil,
        frontmostAppProvider: @escaping @MainActor () -> AssistantComputerUseFrontmostAppContext = {
            let app = NSWorkspace.shared.frontmostApplication
            let bundleIdentifier = app?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let displayName = app?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? bundleIdentifier
                ?? "Current App"
            return AssistantComputerUseFrontmostAppContext(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        },
        focusApp: ((_ bundleIdentifier: String?, _ appName: String, _ ownerPID: pid_t) async -> FocusState?)? = nil,
        unfocusApp: ((_ state: FocusState) async -> Void)? = nil
    ) {
        self.helper = helper
        self.accessibilityAutomationService = accessibilityAutomationService
            ?? AssistantAccessibilityAutomationService(helper: helper)
        self.executeActions = executeActions ?? { actions, previousSnapshot in
            try await helper.executeComputerActions(actions, previousSnapshot: previousSnapshot)
        }
        self.frontmostAppProvider = frontmostAppProvider
        self.focusApp = focusApp ?? { bundleIdentifier, appName, ownerPID in
            await Self.defaultFocusApp(bundleIdentifier: bundleIdentifier, appName: appName, ownerPID: ownerPID)
        }
        self.unfocusApp = unfocusApp ?? { state in
            await Self.defaultUnfocusApp(state)
        }
    }

    func frontmostAppContext() async -> AssistantComputerUseFrontmostAppContext {
        await MainActor.run {
            frontmostAppProvider()
        }
    }

    func endSession(_ sessionID: String) async {
        let normalized = Self.normalizedSessionID(sessionID)
        if let state = sessionStateByID[normalized], let focus = state.focusState {
            await unfocusApp(focus)
        }
        sessionStateByID.removeValue(forKey: normalized)
    }

    private static func defaultFocusApp(bundleIdentifier: String?, appName: String, ownerPID: pid_t) async -> FocusState? {
        await MainActor.run { () -> FocusState? in
            let ownBundleID = Bundle.main.bundleIdentifier
            guard let targetApp = NSRunningApplication(processIdentifier: ownerPID),
                  !targetApp.isTerminated else {
                return nil
            }
            targetApp.activate(options: .activateIgnoringOtherApps)

            var hiddenPIDs: [pid_t] = []
            var didHideOwn = false

            for app in NSWorkspace.shared.runningApplications {
                guard app.activationPolicy == .regular,
                      app.processIdentifier != ownerPID,
                      !app.isHidden,
                      !app.isTerminated else { continue }

                if app.bundleIdentifier == ownBundleID {
                    // Hide OpenAssist itself so its sidebar doesn't obstruct the
                    // target app or appear in screenshots. The orb/notch HUD uses
                    // a separate window level and will re-appear when we unhide.
                    app.hide()
                    didHideOwn = true
                } else {
                    app.hide()
                    hiddenPIDs.append(app.processIdentifier)
                }
            }

            return FocusState(
                targetBundleIdentifier: bundleIdentifier,
                targetPID: ownerPID,
                hiddenAppPIDs: hiddenPIDs,
                didHideOwnApp: didHideOwn
            )
        }
    }

    private static func defaultUnfocusApp(_ state: FocusState) async {
        await MainActor.run {
            for pid in state.hiddenAppPIDs {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }

            // Restore OpenAssist's own app visibility
            if state.didHideOwnApp {
                NSApp.unhide(nil)
            }
        }
    }

    func run(
        sessionID: String,
        arguments: Any,
        preferredModelID _: String?
    ) async -> AssistantToolExecutionResult {
        let normalizedSessionID = Self.normalizedSessionID(sessionID)
        var state = sessionStateByID[normalizedSessionID] ?? SessionState()

        do {
            let request = try Self.parseRequest(from: arguments)

            if request.entersSensitiveSecret {
                throw AssistantComputerUseServiceError.secretEntryForbidden(
                    "Computer Use will not type passwords, OTPs, API keys, or other secrets. Please enter that secret yourself, then continue once the target screen is ready."
                )
            }

            if request.needsManualLoginFlow {
                throw AssistantComputerUseServiceError.manualLoginRequired(
                    "This looks like a login or verification flow. Open Assist should pause here so you can sign in manually, then continue with another computer_use step after you are back on the target screen."
                )
            }

            let frontmostBeforeAction = await frontmostAppContext()
            let resolvedTarget = try await resolveTargetContext(
                request: request,
                state: state,
                frontmostApp: frontmostBeforeAction
            )

            // Focus mode: activate target app and hide others for a clean interaction
            if let ownerPID = resolvedTarget.ownerPID, resolvedTarget.windowID != nil {
                let needsFocus = state.focusState == nil
                    || state.focusState?.targetPID != ownerPID
                if needsFocus {
                    if let previousFocus = state.focusState {
                        await unfocusApp(previousFocus)
                    }
                    state.focusState = await focusApp(resolvedTarget.bundleIdentifier, resolvedTarget.appName, ownerPID)
                    if state.focusState != nil {
                        try await Task.sleep(nanoseconds: 150_000_000)
                        let freshSnapshot = try await helper.capturePreferredSnapshot(
                            previousSnapshot: nil,
                            windowID: resolvedTarget.windowID,
                            displayID: resolvedTarget.displayID
                        )
                        state.latestObservation = AutomationObservation(
                            snapshot: freshSnapshot,
                            targetContext: resolvedTarget,
                            capturedAt: freshSnapshot.capturedAt
                        )
                        state.frontmostAppBundleID = Self.normalized(resolvedTarget.bundleIdentifier)
                        state.frontmostAppName = resolvedTarget.appName
                    }
                }
            }

            if case .observe = request.action {
                state = try await refreshObservationState(
                    state: state,
                    normalizedSessionID: normalizedSessionID,
                    request: request,
                    lead: "Open Assist refreshed the locked target before planning the next step."
                )
                let metadata = AssistantAutomationActivityMetadata(
                    stage: "Observe",
                    actuator: state.latestObservation?.snapshot.captureKind == "window" ? "window-capture" : "display-capture",
                    target: state.targetContext?.targetDescription ?? resolvedTarget.targetDescription,
                    confidence: 0.96,
                    verificationResult: "ready"
                )
                return Self.result(
                    summary: Self.observationReadyMessage(
                        lead: request.action.resultLead,
                        observation: state.latestObservation,
                        appContext: frontmostBeforeAction
                    ),
                    success: true,
                    snapshot: state.latestObservation?.snapshot,
                    activityMetadata: metadata
                )
            }

            // Non-visual actions that don't need a screen observation
            if case .clipboardRead = request.action {
                let content = await helper.readClipboard() ?? ""
                sessionStateByID[normalizedSessionID] = state
                let message = content.isEmpty ? "Clipboard is empty." : "Clipboard contents:\n\(content)"
                return Self.result(summary: message, success: true, snapshot: nil, activityMetadata: nil)
            }

            if case .clipboardWrite(let text) = request.action {
                await helper.writeClipboard(text)
                sessionStateByID[normalizedSessionID] = state
                return Self.result(summary: "Wrote \(text.count) characters to clipboard.", success: true, snapshot: nil, activityMetadata: nil)
            }

            if case .openApplication(let name) = request.action {
                do {
                    try await helper.openApplication(name: name)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    sessionStateByID[normalizedSessionID] = state
                    return Self.result(summary: "Opened \(name).", success: true, snapshot: nil, activityMetadata: nil)
                } catch {
                    sessionStateByID[normalizedSessionID] = state
                    return Self.result(summary: error.localizedDescription, success: false, snapshot: nil, activityMetadata: nil)
                }
            }

            if case .cursorPosition = request.action {
                let pos = await helper.cursorPosition()
                // NSEvent.mouseLocation uses bottom-left origin; convert to top-left for consistency
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let x = Int(pos.x.rounded())
                let y = Int((screenHeight - pos.y).rounded())
                sessionStateByID[normalizedSessionID] = state
                return Self.result(summary: "Cursor position: (\(x), \(y)).", success: true, snapshot: nil, activityMetadata: nil)
            }

            if case .switchDisplay(let displayID) = request.action {
                // Validate the display ID exists
                let validDisplays = AssistantWindowAutomationService.allDisplays()
                guard validDisplays.contains(where: { $0.displayID == displayID }) else {
                    let available = validDisplays.map { "  - \($0.displayID): \($0.resolutionDescription)\($0.isMain ? " (main)" : "")" }.joined(separator: "\n")
                    sessionStateByID[normalizedSessionID] = state
                    return Self.result(
                        summary: "Display \(displayID) not found. Available displays:\n\(available)",
                        success: false, snapshot: nil, activityMetadata: nil
                    )
                }
                state.preferredDisplayID = CGDirectDisplayID(displayID)
                sessionStateByID[normalizedSessionID] = state
                return Self.result(summary: "Switched to display \(displayID). Future observations will capture from this display.", success: true, snapshot: nil, activityMetadata: nil)
            }

            if case .zoom(let x1, let y1, let x2, let y2) = request.action {
                // Capture a fresh full screenshot, then crop the requested region at full resolution
                let fullSnapshot: LocalAutomationDisplaySnapshot
                if let existing = state.latestObservation?.snapshot {
                    fullSnapshot = existing
                } else {
                    fullSnapshot = try await helper.capturePreferredSnapshot(
                        previousSnapshot: state.latestObservation?.snapshot,
                        windowID: request.windowID,
                        displayID: state.preferredDisplayID ?? request.displayID.map { CGDirectDisplayID($0) }
                    )
                }
                let croppedSnapshot = try Self.cropSnapshot(fullSnapshot, x1: x1, y1: y1, x2: x2, y2: y2)
                sessionStateByID[normalizedSessionID] = state
                let regionSize = "\(Int(x2 - x1))x\(Int(y2 - y1))"
                let summary = "Zoomed into region (\(Int(x1)), \(Int(y1))) to (\(Int(x2)), \(Int(y2))). Cropped size: \(regionSize) pixels at full resolution."
                return Self.result(summary: summary, success: true, snapshot: croppedSnapshot, activityMetadata: nil)
            }

            if let staleReason = observationRefreshReason(
                for: request,
                state: state,
                frontmostApp: frontmostBeforeAction
            ) {
                state = try await refreshObservationState(
                    state: state,
                    normalizedSessionID: normalizedSessionID,
                    request: request,
                    lead: staleReason
                )
                let metadata = AssistantAutomationActivityMetadata(
                    stage: "Observe",
                    actuator: state.latestObservation?.snapshot.captureKind == "window" ? "window-capture" : "display-capture",
                    target: state.targetContext?.targetDescription ?? resolvedTarget.targetDescription,
                    confidence: 0.94,
                    verificationResult: "re-observed"
                )
                return Self.result(
                    summary: Self.refreshedObservationMessage(
                        lead: staleReason,
                        observation: state.latestObservation,
                        appContext: frontmostBeforeAction
                    ),
                    success: false,
                    snapshot: state.latestObservation?.snapshot,
                    activityMetadata: metadata
                )
            }

            state.targetContext = resolvedTarget
            state.frontmostAppBundleID = Self.normalized(frontmostBeforeAction.bundleIdentifier)
            state.frontmostAppName = frontmostBeforeAction.displayName

            let pointDescriptor = await pointDescriptor(for: request.action, snapshot: state.latestObservation?.snapshot)
            let plan = makeStepPlan(
                for: request,
                targetContext: resolvedTarget,
                pointDescriptor: pointDescriptor
            )

            if request.canTrySemanticClick,
               case .click(_, let button, _) = request.action,
               let targetLabel = request.targetLabel?.nonEmpty {
                do {
                    let semanticResult = try await accessibilityAutomationService.performSemanticClick(
                        appName: resolvedTarget.appName,
                        windowTitle: resolvedTarget.windowTitle,
                        labelFilter: targetLabel,
                        roleFilter: nil,
                        buttonName: button
                    )
                    let nextSnapshot = try await helper.capturePreferredSnapshot(
                        previousSnapshot: state.latestObservation?.snapshot,
                        windowID: resolvedTarget.windowID,
                        displayID: resolvedTarget.displayID
                    )
                    let frontmostAfterAction = await frontmostAppContext()
                    let nextTarget = try await targetContext(
                        from: nextSnapshot,
                        preferred: resolvedTarget,
                        frontmostApp: frontmostAfterAction
                    )
                    let nextObservation = AutomationObservation(
                        snapshot: nextSnapshot,
                        targetContext: nextTarget,
                        capturedAt: nextSnapshot.capturedAt
                    )
                    let verification = verificationOutcome(
                        for: request,
                        plan: plan,
                        previousObservation: state.latestObservation,
                        nextObservation: nextObservation,
                        frontmostAfterAction: frontmostAfterAction,
                        semanticVerificationText: semanticResult.verificationText
                    )

                    return await finishRun(
                        normalizedSessionID: normalizedSessionID,
                        state: state,
                        request: request,
                        plan: plan,
                        verification: verification,
                        nextObservation: nextObservation,
                        frontmostAfterAction: frontmostAfterAction,
                        clampNote: nil,
                        leadOverride: semanticResult.summary
                    )
                } catch {
                    // Fall back to the locked screenshot path when Accessibility is unavailable or cannot resolve the target.
                }
            }

            if request.canTrySemanticType,
               case .type(let text) = request.action {
                do {
                    let semanticResult = try await accessibilityAutomationService.performSemanticType(
                        text: text,
                        appName: resolvedTarget.appName,
                        windowTitle: resolvedTarget.windowTitle,
                        labelFilter: request.targetLabel,
                        roleFilter: nil
                    )
                    let nextSnapshot = try await helper.capturePreferredSnapshot(
                        previousSnapshot: state.latestObservation?.snapshot,
                        windowID: resolvedTarget.windowID,
                        displayID: resolvedTarget.displayID
                    )
                    let frontmostAfterAction = await frontmostAppContext()
                    let nextTarget = try await targetContext(
                        from: nextSnapshot,
                        preferred: resolvedTarget,
                        frontmostApp: frontmostAfterAction
                    )
                    let nextObservation = AutomationObservation(
                        snapshot: nextSnapshot,
                        targetContext: nextTarget,
                        capturedAt: nextSnapshot.capturedAt
                    )
                    let verification = verificationOutcome(
                        for: request,
                        plan: plan,
                        previousObservation: state.latestObservation,
                        nextObservation: nextObservation,
                        frontmostAfterAction: frontmostAfterAction,
                        semanticVerificationText: semanticResult.verificationText
                    )
                    return await finishRun(
                        normalizedSessionID: normalizedSessionID,
                        state: state,
                        request: request,
                        plan: plan,
                        verification: verification,
                        nextObservation: nextObservation,
                        frontmostAfterAction: frontmostAfterAction,
                        clampNote: nil,
                        leadOverride: semanticResult.summary
                    )
                } catch {
                    // Fall back to keyboard typing when Accessibility cannot focus or verify the target field.
                }
            }

            let clampNote = Self.coordinateClampNote(
                for: request.action,
                snapshot: state.latestObservation?.snapshot
            )
            let payload = helperPayload(for: request.action, targetContext: resolvedTarget)
            let nextSnapshot = try await executeActions(
                [payload],
                state.latestObservation?.snapshot
            )
            let frontmostAfterAction = await frontmostAppContext()
            let nextTarget = try await targetContext(
                from: nextSnapshot,
                preferred: resolvedTarget,
                frontmostApp: frontmostAfterAction
            )
            let nextObservation = AutomationObservation(
                snapshot: nextSnapshot,
                targetContext: nextTarget,
                capturedAt: nextSnapshot.capturedAt
            )
            let verification = verificationOutcome(
                for: request,
                plan: plan,
                previousObservation: state.latestObservation,
                nextObservation: nextObservation,
                frontmostAfterAction: frontmostAfterAction,
                semanticVerificationText: nil
            )
            return await finishRun(
                normalizedSessionID: normalizedSessionID,
                state: state,
                request: request,
                plan: plan,
                verification: verification,
                nextObservation: nextObservation,
                frontmostAfterAction: frontmostAfterAction,
                clampNote: clampNote,
                leadOverride: nil
            )
        } catch let error as AssistantComputerUseServiceError {
            sessionStateByID[normalizedSessionID] = state
            return Self.result(
                summary: error.localizedDescription,
                success: false,
                snapshot: state.latestObservation?.snapshot,
                activityMetadata: AssistantAutomationActivityMetadata(
                    stage: "Recover",
                    actuator: "none",
                    target: state.targetContext?.targetDescription,
                    confidence: 0,
                    verificationResult: "blocked"
                )
            )
        } catch {
            sessionStateByID[normalizedSessionID] = state
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Computer Use failed."
            return Self.result(
                summary: summary,
                success: false,
                snapshot: state.latestObservation?.snapshot,
                activityMetadata: AssistantAutomationActivityMetadata(
                    stage: "Recover",
                    actuator: "none",
                    target: state.targetContext?.targetDescription,
                    confidence: 0,
                    verificationResult: "failed"
                )
            )
        }
    }

    func runBatch(
        arguments: Any,
        preferredModelID _: String?
    ) async -> AssistantToolExecutionResult {
        guard let dictionary = arguments as? [String: Any],
              let rawActions = dictionary["actions"] as? [[String: Any]],
              !rawActions.isEmpty else {
            return Self.result(
                summary: "computer_batch needs a non-empty actions array.",
                success: false, snapshot: nil, activityMetadata: nil
            )
        }

        do {
            let snapshot = try await executeActions(rawActions, nil)
            let count = rawActions.count
            let summary = "Executed \(count) action\(count == 1 ? "" : "s"). Here is the resulting screen."
            return Self.result(summary: summary, success: true, snapshot: snapshot, activityMetadata: nil)
        } catch {
            return Self.result(
                summary: error.localizedDescription,
                success: false, snapshot: nil, activityMetadata: nil
            )
        }
    }

    static func parseRequest(from arguments: Any) throws -> ParsedRequest {
        guard let dictionary = arguments as? [String: Any] else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use needs task, reason, and a structured action."
            )
        }

        let task = (dictionary["task"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard let task else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use needs a task."
            )
        }

        let reason = (dictionary["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard let reason else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use needs a reason."
            )
        }

        let targetLabel = firstNonEmptyString(
            dictionary["targetLabel"] as? String,
            dictionary["target_label"] as? String
        )
        let appName = firstNonEmptyString(
            dictionary["app"] as? String,
            dictionary["app_name"] as? String,
            dictionary["appName"] as? String
        )
        let windowTitle = firstNonEmptyString(
            dictionary["title"] as? String,
            dictionary["window_title"] as? String,
            dictionary["windowTitle"] as? String
        )
        let expectedChange = firstNonEmptyString(
            dictionary["expected_change"] as? String,
            dictionary["expectedChange"] as? String
        )
        let windowID = integer(from: dictionary["window_id"])
        let displayID = integer(from: dictionary["display_id"])

        guard let rawAction = dictionary["action"] as? [String: Any] else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use needs a structured action."
            )
        }

        let action = try parseAction(from: rawAction)
        return ParsedRequest(
            task: task,
            reason: reason,
            targetLabel: targetLabel,
            appName: appName,
            windowTitle: windowTitle,
            windowID: windowID,
            displayID: displayID,
            expectedChange: expectedChange,
            action: action
        )
    }

    static func sessionApprovalKey(for appContext: AssistantComputerUseFrontmostAppContext) -> String {
        let rawKey = appContext.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? appContext.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? AssistantComputerUseToolDefinition.toolKind
        let sanitized = rawKey
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard let sanitized = sanitized.nonEmpty else {
            return AssistantComputerUseToolDefinition.toolKind
        }
        return "\(AssistantComputerUseToolDefinition.toolKind).\(sanitized)"
    }

    private func finishRun(
        normalizedSessionID: String,
        state: SessionState,
        request: ParsedRequest,
        plan: AutomationStepPlan,
        verification: VerificationOutcome,
        nextObservation: AutomationObservation,
        frontmostAfterAction: AssistantComputerUseFrontmostAppContext,
        clampNote: String?,
        leadOverride: String?
    ) async -> AssistantToolExecutionResult {
        var nextState = state
        nextState.targetContext = nextObservation.targetContext
        nextState.latestObservation = nextObservation
        nextState.frontmostAppBundleID = Self.normalized(frontmostAfterAction.bundleIdentifier)
        nextState.frontmostAppName = frontmostAfterAction.displayName
        nextState.lastActionSummary = request.summaryLine

        if verification.verified {
            nextState.noProgressCounter = 0
            nextState.staleReason = nil
            sessionStateByID[normalizedSessionID] = nextState
            return Self.result(
                summary: Self.successMessage(
                    lead: leadOverride ?? request.action.resultLead,
                    request: request,
                    plan: plan,
                    verification: verification,
                    observation: nextObservation,
                    appContext: frontmostAfterAction,
                    clampNote: clampNote
                ),
                success: true,
                snapshot: nextObservation.snapshot,
                activityMetadata: plan.activityMetadata(verificationResult: verification.resultLabel)
            )
        }

        nextState.noProgressCounter += 1
        nextState.staleReason = verification.explanation
        let refreshedState = (try? await refreshObservationState(
            state: nextState,
            normalizedSessionID: normalizedSessionID,
            request: request,
            lead: verification.explanation
        )) ?? nextState
        let stopNow = refreshedState.noProgressCounter >= 2 || plan.confidence < 0.5
        let summary = Self.recoveryMessage(
            verification: verification,
            refreshedObservation: refreshedState.latestObservation,
            stopNow: stopNow
        )
        return Self.result(
            summary: summary,
            success: false,
            snapshot: refreshedState.latestObservation?.snapshot ?? nextObservation.snapshot,
            activityMetadata: AssistantAutomationActivityMetadata(
                stage: stopNow ? "Recover" : "Observe",
                actuator: plan.actuator,
                target: refreshedState.targetContext?.targetDescription ?? plan.target,
                confidence: plan.confidence,
                verificationResult: stopNow ? "needs-user-help" : "re-observed"
            )
        )
    }

    private func resolveTargetContext(
        request: ParsedRequest,
        state: SessionState,
        frontmostApp: AssistantComputerUseFrontmostAppContext
    ) async throws -> AutomationTargetContext {
        if request.hasExplicitTargetHint {
            if let window = AssistantWindowAutomationService.resolveWindow(
                windowID: request.windowID,
                appName: request.appName,
                title: request.windowTitle,
                preferFrontmost: true
            ) {
                return await targetContext(for: window)
            }

            if let displayID = request.displayID {
                let cgDisplayID = CGDirectDisplayID(displayID)
                return AutomationTargetContext(
                    bundleIdentifier: frontmostApp.bundleIdentifier,
                    appName: request.appName ?? frontmostApp.displayName,
                    ownerPID: nil,
                    windowID: nil,
                    displayID: cgDisplayID,
                    windowTitle: request.windowTitle,
                    bounds: AssistantWindowAutomationService.screen(for: cgDisplayID)?.frame
                )
            }

            throw AssistantComputerUseServiceError.targetNotFound(
                "Open Assist could not find the requested app or window on screen. Bring that target to the front, then try again."
            )
        }

        if let lockedTarget = state.targetContext {
            if let windowID = lockedTarget.windowID,
               let window = AssistantWindowAutomationService.resolveWindow(
                    windowID: windowID,
                    appName: nil,
                    title: nil,
                    preferFrontmost: false
               ) {
                return await targetContext(for: window)
            }
            if lockedTarget.displayID != nil {
                return lockedTarget
            }
        }

        if let frontmostWindow = AssistantWindowAutomationService.resolveWindow(
            windowID: nil,
            appName: frontmostApp.displayName,
            title: nil,
            preferFrontmost: true
        ) {
            return await targetContext(for: frontmostWindow)
        }

        if let activeDisplay = AssistantWindowAutomationService.activeDisplayInfo() {
            return AutomationTargetContext(
                bundleIdentifier: frontmostApp.bundleIdentifier,
                appName: frontmostApp.displayName,
                ownerPID: nil,
                windowID: nil,
                displayID: activeDisplay.displayID,
                windowTitle: nil,
                bounds: activeDisplay.frame
            )
        }

        return AutomationTargetContext(
            bundleIdentifier: frontmostApp.bundleIdentifier,
            appName: frontmostApp.displayName,
            ownerPID: nil,
            windowID: nil,
            displayID: nil,
            windowTitle: nil,
            bounds: nil
        )
    }

    private func targetContext(for window: AssistantWindowAutomationService.WindowInfo) async -> AutomationTargetContext {
        let bundleIdentifier = await MainActor.run {
            NSRunningApplication(processIdentifier: window.ownerPID)?
                .bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }
        return AutomationTargetContext(
            bundleIdentifier: bundleIdentifier,
            appName: window.ownerName,
            ownerPID: window.ownerPID,
            windowID: window.windowID,
            displayID: window.displayID,
            windowTitle: window.title.nonEmpty,
            bounds: window.bounds
        )
    }

    private func targetContext(
        from snapshot: LocalAutomationDisplaySnapshot,
        preferred: AutomationTargetContext,
        frontmostApp: AssistantComputerUseFrontmostAppContext
    ) async throws -> AutomationTargetContext {
        if let windowID = snapshot.windowID,
           let window = AssistantWindowAutomationService.resolveWindow(
                windowID: windowID,
                appName: nil,
                title: nil,
                preferFrontmost: false
           ) {
            return await targetContext(for: window)
        }

        let appName = snapshot.targetAppName?.nonEmpty ?? preferred.appName
        let bundleIdentifier = preferred.bundleIdentifier
            ?? (appName.caseInsensitiveCompare(frontmostApp.displayName) == .orderedSame
                ? frontmostApp.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                : nil)
        return AutomationTargetContext(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            ownerPID: preferred.ownerPID,
            windowID: snapshot.windowID ?? preferred.windowID,
            displayID: snapshot.displayID ?? preferred.displayID,
            windowTitle: snapshot.windowTitle?.nonEmpty ?? preferred.windowTitle,
            bounds: snapshot.screenFrame
        )
    }

    private func observationRefreshReason(
        for request: ParsedRequest,
        state: SessionState,
        frontmostApp: AssistantComputerUseFrontmostAppContext
    ) -> String? {
        let typeNeedsObservation: Bool
        if case .type = request.action {
            typeNeedsObservation = !request.canTrySemanticType
        } else {
            typeNeedsObservation = false
        }

        guard request.action.requiresCurrentObservation
                || typeNeedsObservation
                || (request.canTrySemanticClick && state.latestObservation == nil) else {
            return nil
        }

        guard let observation = state.latestObservation else {
            return "Open Assist captured a fresh screenshot because this step did not have a current observation yet."
        }

        if Date().timeIntervalSince(observation.capturedAt) > 2 {
            return "The last screenshot is older than 2 seconds, so Open Assist captured a fresh screenshot before acting."
        }

        if let observedBundle = state.frontmostAppBundleID,
           let currentBundle = Self.normalized(frontmostApp.bundleIdentifier),
           observedBundle.caseInsensitiveCompare(currentBundle) != .orderedSame {
            return "The frontmost app changed to \(frontmostApp.displayName), so Open Assist captured a fresh screenshot before acting."
        }

        if request.hasExplicitTargetHint,
           !targetContext(observation.targetContext, matches: request) {
            return "The saved observation no longer matches the requested target, so Open Assist captured a fresh screenshot first."
        }

        return state.staleReason
    }

    private func targetContext(_ target: AutomationTargetContext, matches request: ParsedRequest) -> Bool {
        if let windowID = request.windowID, target.windowID != windowID {
            return false
        }
        if let displayID = request.displayID, target.displayID != CGDirectDisplayID(displayID) {
            return false
        }
        if let appName = request.appName?.lowercased(),
           !target.appName.lowercased().contains(appName) {
            return false
        }
        if let title = request.windowTitle?.lowercased(),
           !(target.windowTitle?.lowercased().contains(title) ?? false) {
            return false
        }
        return true
    }

    private func refreshObservationState(
        state: SessionState,
        normalizedSessionID: String,
        request: ParsedRequest,
        lead: String
    ) async throws -> SessionState {
        var refreshedState = state
        let frontmostBeforeObserve = await frontmostAppContext()
        let target = try await resolveTargetContext(
            request: request,
            state: refreshedState,
            frontmostApp: frontmostBeforeObserve
        )
        let observePayload = helperPayload(for: .observe, targetContext: target)
        let snapshot = try await executeActions(
            [observePayload],
            refreshedState.latestObservation?.snapshot
        )
        let frontmostAfterObserve = await frontmostAppContext()
        let resolvedTarget = try await targetContext(
            from: snapshot,
            preferred: target,
            frontmostApp: frontmostAfterObserve
        )
        refreshedState.targetContext = resolvedTarget
        refreshedState.latestObservation = AutomationObservation(
            snapshot: snapshot,
            targetContext: resolvedTarget,
            capturedAt: snapshot.capturedAt
        )
        refreshedState.frontmostAppBundleID = Self.normalized(frontmostAfterObserve.bundleIdentifier)
        refreshedState.frontmostAppName = frontmostAfterObserve.displayName
        refreshedState.lastActionSummary = lead
        refreshedState.noProgressCounter = 0
        refreshedState.staleReason = nil
        sessionStateByID[normalizedSessionID] = refreshedState
        return refreshedState
    }

    private func helperPayload(
        for action: ParsedRequest.Action,
        targetContext: AutomationTargetContext
    ) -> [String: Any] {
        var payload = action.helperPayload
        if let windowID = targetContext.windowID {
            payload["window_id"] = windowID
        } else if let displayID = targetContext.displayID {
            payload["display_id"] = Int(displayID)
        }
        return payload
    }

    private func makeStepPlan(
        for request: ParsedRequest,
        targetContext: AutomationTargetContext,
        pointDescriptor: AssistantAccessibilityAutomationService.UIElementDescriptor?
    ) -> AutomationStepPlan {
        let target = [
            request.targetLabel,
            pointDescriptor?.label,
            pointDescriptor?.role,
            targetContext.targetDescription
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        .first ?? targetContext.targetDescription

        switch request.action {
        case .observe:
            return AutomationStepPlan(
                stage: "Observe",
                actuator: targetContext.windowID != nil ? "window-capture" : "display-capture",
                target: target,
                expectedResult: "A fresh screenshot of the locked target is ready.",
                fallbackRule: "If the window is unavailable, fall back to the locked display instead of the mouse position.",
                confidence: 0.96
            )
        case .click:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "validated-pixel",
                target: target,
                expectedResult: request.expectedChange ?? "The selected control should react.",
                fallbackRule: "Validate the click point against the locked screenshot before sending it.",
                confidence: pointDescriptor == nil ? 0.46 : 0.62
            )
        case .doubleClick, .tripleClick:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "validated-pixel",
                target: target,
                expectedResult: request.expectedChange ?? "The item should open or activate.",
                fallbackRule: "If the point looks unsafe, refresh the target instead of repeating the click blindly.",
                confidence: pointDescriptor == nil ? 0.44 : 0.58
            )
        case .rightClick, .middleClick:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "validated-pixel",
                target: target,
                expectedResult: request.expectedChange ?? "A context menu or secondary action should appear.",
                fallbackRule: "If nothing happens, refresh the target first.",
                confidence: pointDescriptor == nil ? 0.44 : 0.58
            )
        case .move:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "pixel",
                target: target,
                expectedResult: "The pointer should move to the planned location.",
                fallbackRule: "Refresh the target if the current screenshot looks stale.",
                confidence: 0.58
            )
        case .mouseDown, .mouseUp:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "pixel",
                target: target,
                expectedResult: request.expectedChange ?? "The mouse button state should change.",
                fallbackRule: "Refresh the target if the UI does not respond.",
                confidence: 0.54
            )
        case .drag:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "pixel",
                target: target,
                expectedResult: request.expectedChange ?? "The selected item should move or resize.",
                fallbackRule: "If the target does not visibly move, re-observe before trying again.",
                confidence: 0.54
            )
        case .scroll:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "validated-pixel",
                target: target,
                expectedResult: request.expectedChange ?? "The view should scroll.",
                fallbackRule: "If nothing changes, re-observe instead of stacking more blind scrolls.",
                confidence: pointDescriptor == nil ? 0.48 : 0.6
            )
        case .keypress:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "keyboard",
                target: target,
                expectedResult: request.expectedChange ?? "The focused target should react to the shortcut.",
                fallbackRule: "If the shortcut does not cause a visible change, refresh the target first.",
                confidence: 0.64
            )
        case .type:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "keyboard",
                target: target,
                expectedResult: request.expectedChange ?? "The target field should contain the typed text.",
                fallbackRule: "If typing cannot be verified, refresh the target and stop instead of typing again blindly.",
                confidence: 0.58
            )
        case .wait:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "timer",
                target: target,
                expectedResult: request.expectedChange ?? "The UI should finish changing.",
                fallbackRule: "If the UI still looks stuck, refresh the target and plan the next step.",
                confidence: 1
            )
        case .holdKey:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "keyboard",
                target: target,
                expectedResult: request.expectedChange ?? "The held keys should trigger the expected action.",
                fallbackRule: "If no visible change occurs, refresh the target and verify focus.",
                confidence: 0.62
            )
        case .openApplication:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "launch",
                target: target,
                expectedResult: request.expectedChange ?? "The application should launch and become frontmost.",
                fallbackRule: "If the app does not appear, check the name and retry.",
                confidence: 0.85
            )
        case .clipboardRead:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "clipboard",
                target: "system clipboard",
                expectedResult: "The current clipboard contents are returned.",
                fallbackRule: "If the clipboard is empty, report that to the caller.",
                confidence: 0.98
            )
        case .clipboardWrite:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "clipboard",
                target: "system clipboard",
                expectedResult: "The clipboard should contain the new text.",
                fallbackRule: "If writing fails, report the error.",
                confidence: 0.98
            )
        case .cursorPosition:
            return AutomationStepPlan(
                stage: "Act",
                actuator: "query",
                target: "mouse cursor",
                expectedResult: "The current cursor coordinates are returned.",
                fallbackRule: "This action always succeeds.",
                confidence: 1.0
            )
        case .switchDisplay(let displayID):
            return AutomationStepPlan(
                stage: "Act",
                actuator: "display",
                target: "display \(displayID)",
                expectedResult: "Future observations should capture from the specified display.",
                fallbackRule: "If the display ID is invalid, report available displays.",
                confidence: 0.9
            )
        case .zoom:
            return AutomationStepPlan(
                stage: "Observe",
                actuator: "zoom-crop",
                target: target,
                expectedResult: "A full-resolution crop of the specified screen region is returned.",
                fallbackRule: "If the region is invalid, fall back to a full screenshot.",
                confidence: 0.95
            )
        }
    }

    private func pointDescriptor(
        for action: ParsedRequest.Action,
        snapshot: LocalAutomationDisplaySnapshot?
    ) async -> AssistantAccessibilityAutomationService.UIElementDescriptor? {
        guard let snapshot else { return nil }

        let candidatePoint: ParsedRequest.Point?
        switch action {
        case .click(let point, _, _),
             .doubleClick(let point, _),
             .tripleClick(let point, _),
             .rightClick(let point),
             .middleClick(let point),
             .move(let point),
             .mouseDown(let point, _),
             .mouseUp(let point, _),
             .scroll(let point, _, _):
            candidatePoint = point
        case .drag(let path):
            candidatePoint = path.first
        case .observe, .keypress, .holdKey, .type, .openApplication, .clipboardRead, .clipboardWrite, .cursorPosition, .switchDisplay, .zoom, .wait:
            candidatePoint = nil
        }

        guard let candidatePoint else { return nil }
        let screenPoint = Self.screenPoint(for: candidatePoint, snapshot: snapshot)
        return await accessibilityAutomationService.elementDescription(at: screenPoint)
    }

    private func verificationOutcome(
        for request: ParsedRequest,
        plan: AutomationStepPlan,
        previousObservation: AutomationObservation?,
        nextObservation: AutomationObservation,
        frontmostAfterAction: AssistantComputerUseFrontmostAppContext,
        semanticVerificationText: String?
    ) -> VerificationOutcome {
        let imageChanged = previousObservation.map { $0.snapshot.imageDataURL != nextObservation.snapshot.imageDataURL } ?? false
        let windowChanged = previousObservation.map { $0.targetContext.windowID != nextObservation.targetContext.windowID } ?? false
        let appChanged = previousObservation.map {
            Self.normalized(frontmostAfterAction.bundleIdentifier) != $0.targetContext.bundleIdentifier
        } ?? false

        if case .type(let typedText) = request.action,
           let verificationText = semanticVerificationText?.lowercased(),
           verificationText.contains(typedText.lowercased()) {
            return VerificationOutcome(
                verified: true,
                resultLabel: "verified",
                explanation: "Verified through Accessibility that the target field now contains the typed text."
            )
        }

        if imageChanged || windowChanged || appChanged {
            return VerificationOutcome(
                verified: true,
                resultLabel: "verified",
                explanation: request.expectedChange?.nonEmpty.map {
                    "Verified a visible change after the step. Expected: \($0)."
                } ?? "Verified a visible change after the step."
            )
        }

        switch request.action {
        case .move, .wait:
            return VerificationOutcome(
                verified: true,
                resultLabel: "executed",
                explanation: "The step completed, even though the captured image did not visibly change."
            )
        case .click where plan.actuator == "ax-first":
            return VerificationOutcome(
                verified: request.expectedChange == nil,
                resultLabel: request.expectedChange == nil ? "likely" : "unverified",
                explanation: request.expectedChange?.nonEmpty.map {
                    "Accessibility completed the click, but Open Assist could not verify the expected change: \($0)."
                } ?? "Accessibility completed the click, but the screenshot looks unchanged."
            )
        case .type where plan.actuator == "ax-first":
            return VerificationOutcome(
                verified: false,
                resultLabel: "unverified",
                explanation: "Typing finished, but Open Assist could not read the new field value back yet."
            )
        default:
            return VerificationOutcome(
                verified: false,
                resultLabel: "unverified",
                explanation: request.expectedChange?.nonEmpty.map {
                    "Open Assist could not verify the expected change: \($0)."
                } ?? "The screenshot still looks unchanged after this step."
            )
        }
    }

    private static func parseAction(from dictionary: [String: Any]) throws -> ParsedRequest.Action {
        let rawType = (dictionary["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let rawType, !rawType.isEmpty else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use actions need a type."
            )
        }

        switch rawType {
        case "observe", "screenshot":
            return .observe
        case "click":
            let modifiers = (dictionary["modifiers"] as? [Any])?
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty } ?? []
            return .click(
                try parsePoint(from: dictionary),
                button: parseButton(from: dictionary),
                modifiers: modifiers
            )
        case "double_click", "doubleclick":
            return .doubleClick(
                try parsePoint(from: dictionary),
                button: parseButton(from: dictionary)
            )
        case "triple_click", "tripleclick":
            return .tripleClick(
                try parsePoint(from: dictionary),
                button: parseButton(from: dictionary)
            )
        case "right_click", "rightclick":
            return .rightClick(try parsePoint(from: dictionary))
        case "middle_click", "middleclick":
            return .middleClick(try parsePoint(from: dictionary))
        case "move", "hover":
            return .move(try parsePoint(from: dictionary))
        case "mouse_down", "mousedown":
            return .mouseDown(try parsePoint(from: dictionary), button: parseButton(from: dictionary))
        case "mouse_up", "mouseup":
            return .mouseUp(try parsePoint(from: dictionary), button: parseButton(from: dictionary))
        case "drag":
            let rawPath = dictionary["path"] as? [[String: Any]] ?? []
            guard !rawPath.isEmpty else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use drag actions need a non-empty path."
                )
            }
            return .drag(try rawPath.map(parsePoint(from:)))
        case "scroll":
            let point = try parsePoint(from: dictionary)
            let deltaX = number(from: dictionary["scroll_x"]) ?? 0
            let deltaY = number(from: dictionary["scroll_y"]) ?? 0
            guard deltaX != 0 || deltaY != 0 else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use scroll actions need scroll_x or scroll_y."
                )
            }
            return .scroll(point, deltaX: deltaX, deltaY: deltaY)
        case "keypress":
            let keys = (dictionary["keys"] as? [Any])?
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty } ?? []
            guard !keys.isEmpty else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use keypress actions need a non-empty keys array."
                )
            }
            return .keypress(keys)
        case "hold_key", "holdkey":
            let keys = (dictionary["keys"] as? [Any])?
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty } ?? []
            guard !keys.isEmpty else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use hold_key actions need a non-empty keys array."
                )
            }
            let durationMs = Int((number(from: dictionary["duration_ms"]) ?? number(from: dictionary["durationMs"]) ?? 500).rounded())
            return .holdKey(keys, durationMs: max(50, durationMs))
        case "type":
            let text = (dictionary["text"] as? String)?
                .trimmingCharacters(in: .newlines)
                .nonEmpty
            guard let text else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use type actions need non-empty text."
                )
            }
            return .type(text)
        case "open_application", "open_app", "launch":
            let name = firstNonEmptyString(
                dictionary["name"] as? String,
                dictionary["app"] as? String
            )
            guard let name else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use open_application actions need a non-empty app name."
                )
            }
            return .openApplication(name)
        case "clipboard_read":
            return .clipboardRead
        case "clipboard_write", "write_clipboard":

            let text = (dictionary["text"] as? String)
            guard let text, !text.isEmpty else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use clipboard_write actions need non-empty text."
                )
            }
            return .clipboardWrite(text)
        case "cursor_position":
            return .cursorPosition
        case "zoom":
            if let region = dictionary["region"] as? [Any], region.count == 4,
               let x1 = number(from: region[0]),
               let y1 = number(from: region[1]),
               let x2 = number(from: region[2]),
               let y2 = number(from: region[3]) {
                return .zoom(x1: x1, y1: y1, x2: x2, y2: y2)
            }
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use zoom actions need a region array of [x1, y1, x2, y2] in screenshot pixels."
            )
        case "switch_display":
            guard let rawDisplayID = integer(from: dictionary["display_id"]) else {
                throw AssistantComputerUseServiceError.invalidArguments(
                    "Computer Use switch_display actions need a display_id."
                )
            }
            return .switchDisplay(CGDirectDisplayID(rawDisplayID))
        case "wait":
            let milliseconds = Int((number(from: dictionary["duration_ms"]) ?? 1000).rounded())
            return .wait(milliseconds: max(0, milliseconds))
        default:
            throw AssistantComputerUseServiceError.invalidArguments(
                "Unsupported Computer Use action type: \(rawType)."
            )
        }
    }

    private static func parsePoint(from dictionary: [String: Any]) throws -> ParsedRequest.Point {
        guard let x = number(from: dictionary["x"]),
              let y = number(from: dictionary["y"]) else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use coordinate actions need x and y in screenshot pixels."
            )
        }
        return ParsedRequest.Point(x: x, y: y)
    }

    private static func parseButton(from dictionary: [String: Any]) -> String? {
        (dictionary["button"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty
    }

    private static func number(from rawValue: Any?) -> Double? {
        if let number = rawValue as? NSNumber {
            return number.doubleValue
        }
        if let text = rawValue as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func integer(from rawValue: Any?) -> Int? {
        guard let number = number(from: rawValue) else { return nil }
        return Int(number.rounded())
    }

    private static func firstNonEmptyString(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .first
    }

    private static func normalized(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func screenPoint(
        for point: ParsedRequest.Point,
        snapshot: LocalAutomationDisplaySnapshot
    ) -> CGPoint {
        LocalAutomationHelper.quartzScreenPoint(
            imageX: CGFloat(point.x),
            imageY: CGFloat(point.y),
            snapshot: snapshot
        )
    }

    private static func successMessage(
        lead: String,
        request: ParsedRequest,
        plan: AutomationStepPlan,
        verification: VerificationOutcome,
        observation: AutomationObservation,
        appContext: AssistantComputerUseFrontmostAppContext,
        clampNote: String?
    ) -> String {
        let size = "\(Int(observation.snapshot.imageSize.width))x\(Int(observation.snapshot.imageSize.height))"
        var lines = [
            lead,
            "Stage: \(plan.stage). Actuator: \(plan.actuator).",
            "Target: \(observation.targetContext.targetDescription).",
            "Verification: \(verification.explanation)",
            "Screenshot size: \(size).",
            "Frontmost app: \(appContext.displayName)."
        ]
        if let clampNote {
            lines.append(clampNote)
        }
        if let expectedChange = request.expectedChange?.nonEmpty {
            lines.append("Expected change: \(expectedChange).")
        }
        return lines.joined(separator: " ")
    }

    private static func observationReadyMessage(
        lead: String,
        observation: AutomationObservation?,
        appContext: AssistantComputerUseFrontmostAppContext
    ) -> String {
        var lines = [lead]
        if let observation {
            let size = "\(Int(observation.snapshot.imageSize.width))x\(Int(observation.snapshot.imageSize.height))"
            lines.append("Locked target: \(observation.targetContext.targetDescription).")
            lines.append("Coordinates use screenshot pixels with the origin at the top-left. Screenshot size: \(size).")
        }
        lines.append("Frontmost app: \(appContext.displayName).")
        return lines.joined(separator: " ")
    }

    private static func recoveryMessage(
        verification: VerificationOutcome,
        refreshedObservation: AutomationObservation?,
        stopNow: Bool
    ) -> String {
        var lines = [verification.explanation]
        if stopNow {
            lines.append("Open Assist stopped here instead of repeating the action blindly. Please check the target window, then continue with a new step.")
        } else {
            lines.append("Open Assist refreshed the target so the next step can use a current screenshot.")
        }
        if let refreshedObservation {
            let size = "\(Int(refreshedObservation.snapshot.imageSize.width))x\(Int(refreshedObservation.snapshot.imageSize.height))"
            lines.append("Locked target: \(refreshedObservation.targetContext.targetDescription).")
            lines.append("Coordinates use screenshot pixels with the origin at the top-left. Screenshot size: \(size).")
        }
        return lines.joined(separator: " ")
    }

    private static func coordinateClampNote(
        for action: ParsedRequest.Action,
        snapshot: LocalAutomationDisplaySnapshot?
    ) -> String? {
        guard let snapshot else { return nil }

        let points: [ParsedRequest.Point]
        switch action {
        case .click(let point, _, _),
             .doubleClick(let point, _),
             .tripleClick(let point, _),
             .rightClick(let point),
             .middleClick(let point),
             .move(let point),
             .mouseDown(let point, _),
             .mouseUp(let point, _),
             .scroll(let point, _, _):
            points = [point]
        case .drag(let path):
            points = path
        case .observe, .keypress, .holdKey, .type, .openApplication, .clipboardRead, .clipboardWrite, .cursorPosition, .switchDisplay, .zoom, .wait:
            return nil
        }

        let width = snapshot.imageSize.width
        let height = snapshot.imageSize.height
        let needsClamp = points.contains { point in
            point.x < 0 || point.y < 0 || point.x >= width || point.y >= height
        }
        guard needsClamp else { return nil }
        return "Some coordinates were outside the current screenshot and were clamped to the visible target bounds."
    }

    private static func refreshedObservationMessage(
        lead: String,
        observation: AutomationObservation?,
        appContext: AssistantComputerUseFrontmostAppContext
    ) -> String {
        var lines = [lead]
        lines.append("Retry the action using this refreshed target.")
        if let observation {
            let size = "\(Int(observation.snapshot.imageSize.width))x\(Int(observation.snapshot.imageSize.height))"
            lines.append("Locked target: \(observation.targetContext.targetDescription).")
            lines.append("Coordinates use screenshot pixels with the origin at the top-left. Screenshot size: \(size).")
        }
        lines.append("Frontmost app: \(appContext.displayName).")
        return lines.joined(separator: " ")
    }

    private static func result(
        summary: String,
        success: Bool,
        snapshot: LocalAutomationDisplaySnapshot?,
        activityMetadata: AssistantAutomationActivityMetadata?
    ) -> AssistantToolExecutionResult {
        var items: [AssistantToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil)
        ]
        if let snapshot {
            items.append(.init(type: "inputImage", text: nil, imageURL: snapshot.imageDataURL))
        }
        return AssistantToolExecutionResult(
            contentItems: items,
            success: success,
            summary: summary,
            activityMetadata: activityMetadata
        )
    }

    private static func cropSnapshot(
        _ snapshot: LocalAutomationDisplaySnapshot,
        x1: Double, y1: Double, x2: Double, y2: Double
    ) throws -> LocalAutomationDisplaySnapshot {
        let imgW = Double(snapshot.image.width)
        let imgH = Double(snapshot.image.height)

        // Clamp to image bounds
        let cx1 = max(0, min(x1, imgW))
        let cy1 = max(0, min(y1, imgH))
        let cx2 = max(cx1 + 1, min(x2, imgW))
        let cy2 = max(cy1 + 1, min(y2, imgH))

        let cropRect = CGRect(x: cx1, y: cy1, width: cx2 - cx1, height: cy2 - cy1)
        guard let cropped = snapshot.image.cropping(to: cropRect) else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Could not crop the screenshot to the requested region."
            )
        }

        let rep = NSBitmapImageRep(cgImage: cropped)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Could not encode the cropped region as PNG."
            )
        }
        let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"

        return LocalAutomationDisplaySnapshot(
            image: cropped,
            imageSize: CGSize(width: cropped.width, height: cropped.height),
            screenFrame: snapshot.screenFrame,
            imageDataURL: dataURL,
            captureKind: "zoom",
            windowID: snapshot.windowID,
            displayID: snapshot.displayID,
            targetAppName: snapshot.targetAppName,
            windowTitle: snapshot.windowTitle
        )
    }

    private static func normalizedSessionID(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"
    }
}
