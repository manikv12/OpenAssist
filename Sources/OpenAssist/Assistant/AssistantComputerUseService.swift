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
    Use the visible macOS desktop on this Mac by taking a screenshot, then using mouse and keyboard actions against the current screen. Prefer `browser_use` for opening or reusing a signed-in browser session, and prefer `app_action` for supported structured app actions. Use this tool only as a last resort when the task truly needs generic visual interaction such as observing the screen, clicking, dragging, scrolling, or typing in an unsupported app UI.
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
            "action": [
                "type": "object",
                "description": "The explicit computer-use action to perform.",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "One of observe, click, double_click, move, drag, scroll, keypress, type, or wait."
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
                        "description": "Optional mouse button, usually left or right."
                    ],
                    "duration_ms": [
                        "type": "integer",
                        "description": "Optional wait duration in milliseconds."
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

enum AssistantComputerUseServiceError: LocalizedError {
    case invalidArguments(String)
    case observeRequired(String)
    case staleObservation(String)
    case manualLoginRequired(String)
    case secretEntryForbidden(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .observeRequired(let message),
             .staleObservation(let message),
             .manualLoginRequired(let message),
             .secretEntryForbidden(let message):
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
            case click(Point, button: String?)
            case doubleClick(Point, button: String?)
            case move(Point)
            case drag([Point])
            case scroll(Point, deltaX: Double, deltaY: Double)
            case keypress([String])
            case type(String)
            case wait(milliseconds: Int)

            var typeName: String {
                switch self {
                case .observe:
                    return "observe"
                case .click:
                    return "click"
                case .doubleClick:
                    return "double_click"
                case .move:
                    return "move"
                case .drag:
                    return "drag"
                case .scroll:
                    return "scroll"
                case .keypress:
                    return "keypress"
                case .type:
                    return "type"
                case .wait:
                    return "wait"
                }
            }

            var isCoordinateBased: Bool {
                switch self {
                case .click, .doubleClick, .move, .drag, .scroll:
                    return true
                case .observe, .keypress, .type, .wait:
                    return false
                }
            }

            var helperPayload: [String: Any] {
                switch self {
                case .observe:
                    return ["type": "observe"]
                case .click(let point, let button):
                    return [
                        "type": "click",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .doubleClick(let point, let button):
                    return [
                        "type": "double_click",
                        "x": point.x,
                        "y": point.y,
                        "button": button as Any
                    ]
                case .move(let point):
                    return [
                        "type": "move",
                        "x": point.x,
                        "y": point.y
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
                case .type(let text):
                    return [
                        "type": "type",
                        "text": text
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
                case .click(let point, _):
                    return "Clicked at \(point.compactDescription)."
                case .doubleClick(let point, _):
                    return "Double-clicked at \(point.compactDescription)."
                case .move(let point):
                    return "Moved the pointer to \(point.compactDescription)."
                case .drag(let path):
                    let lead = path.first?.compactDescription ?? "the selected path"
                    let tail = path.last?.compactDescription ?? lead
                    return "Dragged from \(lead) to \(tail)."
                case .scroll(let point, let deltaX, let deltaY):
                    return "Scrolled at \(point.compactDescription) by (\(Int(deltaX.rounded())), \(Int(deltaY.rounded())))."
                case .keypress(let keys):
                    return "Pressed \(keys.joined(separator: " + "))."
                case .type:
                    return "Typed text into the current app."
                case .wait(let milliseconds):
                    return "Waited \(milliseconds) ms."
                }
            }
        }

        let task: String
        let reason: String
        let targetLabel: String?
        let action: Action

        var summaryLine: String {
            let target = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let pieces = [
                task.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                target.map { "Target: \($0)" },
                "Action: \(action.typeName)"
            ]
            return pieces.compactMap { $0 }.joined(separator: " • ")
        }

        private var normalizedContext: String {
            let parts = [
                Optional(task),
                Optional(reason),
                targetLabel,
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

    private struct SessionState {
        var latestSnapshot: LocalAutomationDisplaySnapshot?
        var frontmostAppBundleID: String?
        var frontmostAppName: String?
        var lastActionSummary: String?
        var noProgressCounter = 0
    }

    private let executeActions: (_ actions: [[String: Any]], _ previousSnapshot: LocalAutomationDisplaySnapshot?) async throws -> LocalAutomationDisplaySnapshot
    private let frontmostAppProvider: @MainActor () -> AssistantComputerUseFrontmostAppContext
    private var sessionStateByID: [String: SessionState] = [:]

    init(
        helper: LocalAutomationHelper = .shared,
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
        }
    ) {
        self.executeActions = executeActions ?? { actions, previousSnapshot in
            try await helper.executeComputerActions(actions, previousSnapshot: previousSnapshot)
        }
        self.frontmostAppProvider = frontmostAppProvider
    }

    func frontmostAppContext() async -> AssistantComputerUseFrontmostAppContext {
        await MainActor.run {
            frontmostAppProvider()
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

            if request.action.isCoordinateBased, state.latestSnapshot == nil {
                throw AssistantComputerUseServiceError.observeRequired(
                    "Call computer_use with an observe action first so Open Assist can capture the current screen before using screenshot coordinates."
                )
            }

            if request.action.isCoordinateBased,
               let observedBundle = state.frontmostAppBundleID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
               let currentBundle = frontmostBeforeAction.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
               observedBundle.caseInsensitiveCompare(currentBundle) != .orderedSame {
                throw AssistantComputerUseServiceError.staleObservation(
                    "The frontmost app changed to \(frontmostBeforeAction.displayName). Use observe first so Open Assist can refresh the screenshot before clicking, dragging, moving, or scrolling."
                )
            }

            let clampNote = Self.coordinateClampNote(
                for: request.action,
                snapshot: state.latestSnapshot
            )

            let nextSnapshot = try await executeActions(
                [request.action.helperPayload],
                state.latestSnapshot
            )

            let frontmostAfterAction = await frontmostAppContext()
            if state.latestSnapshot?.imageDataURL == nextSnapshot.imageDataURL {
                state.noProgressCounter += 1
            } else {
                state.noProgressCounter = 0
            }
            state.latestSnapshot = nextSnapshot
            state.frontmostAppBundleID = frontmostAfterAction.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            state.frontmostAppName = frontmostAfterAction.displayName
            state.lastActionSummary = request.summaryLine
            sessionStateByID[normalizedSessionID] = state

            let summary = Self.successMessage(
                for: request,
                snapshot: nextSnapshot,
                appContext: frontmostAfterAction,
                clampNote: clampNote,
                noProgressCounter: state.noProgressCounter
            )
            return Self.result(
                summary: summary,
                success: true,
                snapshot: nextSnapshot
            )
        } catch let error as AssistantComputerUseServiceError {
            sessionStateByID[normalizedSessionID] = state
            return Self.result(
                summary: error.localizedDescription,
                success: false,
                snapshot: state.latestSnapshot
            )
        } catch {
            sessionStateByID[normalizedSessionID] = state
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Computer Use failed."
            return Self.result(
                summary: summary,
                success: false,
                snapshot: state.latestSnapshot
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

        let targetLabel = (
            dictionary["targetLabel"] as? String
                ?? dictionary["target_label"] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        guard let rawAction = dictionary["action"] as? [String: Any] else {
            throw AssistantComputerUseServiceError.invalidArguments(
                "Computer Use needs a structured action."
            )
        }

        let action = try parseAction(from: rawAction)
        return ParsedRequest(task: task, reason: reason, targetLabel: targetLabel, action: action)
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
            return .click(
                try parsePoint(from: dictionary),
                button: parseButton(from: dictionary)
            )
        case "double_click", "doubleclick":
            return .doubleClick(
                try parsePoint(from: dictionary),
                button: parseButton(from: dictionary)
            )
        case "move":
            return .move(try parsePoint(from: dictionary))
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

    private static func successMessage(
        for request: ParsedRequest,
        snapshot: LocalAutomationDisplaySnapshot,
        appContext: AssistantComputerUseFrontmostAppContext,
        clampNote: String?,
        noProgressCounter: Int
    ) -> String {
        let size = "\(Int(snapshot.imageSize.width))x\(Int(snapshot.imageSize.height))"
        var lines = [
            request.action.resultLead,
            "Coordinates use screenshot pixels with the origin at the top-left. Screenshot size: \(size).",
            "Frontmost app: \(appContext.displayName)."
        ]
        if let clampNote {
            lines.append(clampNote)
        }
        if noProgressCounter > 0 {
            lines.append("The screenshot still looks unchanged after this step.")
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
        case .click(let point, _),
             .doubleClick(let point, _),
             .move(let point),
             .scroll(let point, _, _):
            points = [point]
        case .drag(let path):
            points = path
        case .observe, .keypress, .type, .wait:
            return nil
        }

        let width = snapshot.imageSize.width
        let height = snapshot.imageSize.height
        let needsClamp = points.contains { point in
            point.x < 0 || point.y < 0 || point.x >= width || point.y >= height
        }
        guard needsClamp else { return nil }
        return "Some coordinates were outside the current screenshot and were clamped to the visible screen bounds."
    }

    private static func result(
        summary: String,
        success: Bool,
        snapshot: LocalAutomationDisplaySnapshot?
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
            summary: summary
        )
    }

    private static func normalizedSessionID(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"
    }
}
