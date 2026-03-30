import AppKit
import ApplicationServices
import Foundation

enum AssistantUIInspectToolDefinition {
    static let name = "ui_inspect"
    static let toolKind = "uiAutomation"

    static let description = """
    Inspect visible macOS accessibility elements in a target app window. Use this to find buttons, fields, labels, and their bounds before interacting with them.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app": [
                "type": "string",
                "description": "Optional app name filter such as Chrome or Cursor."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title filter."
            ],
            "label": [
                "type": "string",
                "description": "Optional element label filter."
            ],
            "role": [
                "type": "string",
                "description": "Optional role filter such as button or text field."
            ],
            "top": [
                "type": "integer",
                "description": "Maximum number of matching elements to return."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantUIClickToolDefinition {
    static let name = "ui_click"
    static let toolKind = "uiAutomation"

    static let description = """
    Click a macOS accessibility element by label or role instead of raw screen coordinates.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app": [
                "type": "string",
                "description": "Optional app name filter."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title filter."
            ],
            "label": [
                "type": "string",
                "description": "Element label to click."
            ],
            "role": [
                "type": "string",
                "description": "Optional role filter such as button."
            ],
            "button": [
                "type": "string",
                "description": "Optional mouse button, usually left or right, for fallback clicking."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantUITypeToolDefinition {
    static let name = "ui_type"
    static let toolKind = "uiAutomation"

    static let description = """
    Focus a macOS accessibility text field and type text into it. When no label is given, it types into the currently focused field.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "Text to type."
            ],
            "app": [
                "type": "string",
                "description": "Optional app name filter."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title filter."
            ],
            "label": [
                "type": "string",
                "description": "Optional field label."
            ],
            "role": [
                "type": "string",
                "description": "Optional role filter such as text field."
            ]
        ],
        "required": ["text"],
        "additionalProperties": true
    ]
}

enum AssistantUIPressKeyToolDefinition {
    static let name = "ui_press_key"
    static let toolKind = "uiAutomation"

    static let description = """
    Press one or more keyboard keys in the current macOS app, such as cmd+l or enter.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "keys": [
                "type": "array",
                "description": "Keys to press, for example [\"cmd\", \"l\"] or [\"enter\"].",
                "items": ["type": "string"]
            ]
        ],
        "required": ["keys"],
        "additionalProperties": true
    ]
}

enum AssistantAccessibilityAutomationServiceError: LocalizedError {
    case invalidArguments(String)
    case accessibilityRequired
    case targetWindowNotFound
    case matchingElementNotFound
    case actionFailed(String)
    case typingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .actionFailed(let message),
             .typingFailed(let message):
            return message
        case .accessibilityRequired:
            return "Grant Accessibility so Open Assist can inspect and interact with macOS UI elements."
        case .targetWindowNotFound:
            return "Open Assist could not find a matching app window to inspect."
        case .matchingElementNotFound:
            return "Open Assist could not find a matching UI element."
        }
    }
}

actor AssistantAccessibilityAutomationService {
    struct UIInspectRequest: Equatable, Sendable {
        let appName: String?
        let windowTitle: String?
        let label: String?
        let role: String?
        let top: Int

        var summaryLine: String {
            if let label = label?.nonEmpty {
                return "Inspect UI elements matching \(label)"
            }
            if let appName = appName?.nonEmpty {
                return "Inspect UI in \(appName)"
            }
            return "Inspect the current app UI"
        }
    }

    struct UIClickRequest: Equatable, Sendable {
        let appName: String?
        let windowTitle: String?
        let label: String?
        let role: String?
        let button: String?

        var summaryLine: String {
            if let label = label?.nonEmpty {
                return "Click \(label)"
            }
            if let role = role?.nonEmpty {
                return "Click a \(role)"
            }
            return "Click a UI element"
        }
    }

    struct UITypeRequest: Equatable, Sendable {
        let text: String
        let appName: String?
        let windowTitle: String?
        let label: String?
        let role: String?

        var summaryLine: String {
            if let label = label?.nonEmpty {
                return "Type into \(label)"
            }
            return "Type into the focused field"
        }
    }

    struct UIPressKeyRequest: Equatable, Sendable {
        let keys: [String]

        var summaryLine: String {
            "Press \(keys.joined(separator: " + "))"
        }
    }

    private struct WindowCandidate {
        let appName: String
        let processIdentifier: pid_t
        let title: String
    }

    struct UIResolvedWindowContext: Sendable {
        let appName: String
        let windowTitle: String
    }

    struct UISemanticActionResult: Sendable {
        let summary: String
        let appName: String
        let windowTitle: String
        let targetDescription: String
        let actuator: String
        let confidence: Double
        let verificationText: String?
    }

    struct UIElementDescriptor: Sendable {
        let label: String?
        let role: String?
        let boundsDescription: String?
    }

    private struct ElementMatch {
        let element: AXUIElement
        let label: String?
        let role: String?
        let frame: CGRect?
        let actions: [String]
    }

    private let helper: LocalAutomationHelper

    init(helper: LocalAutomationHelper = .shared) {
        self.helper = helper
    }

    static func parseInspectRequest(from arguments: Any) throws -> UIInspectRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        let top = min(max(integer(from: dictionary["top"]) ?? 25, 1), 100)
        return UIInspectRequest(
            appName: normalizedString(dictionary["app"]),
            windowTitle: normalizedString(dictionary["title"]),
            label: normalizedString(dictionary["label"]),
            role: normalizedString(dictionary["role"]),
            top: top
        )
    }

    static func parseClickRequest(from arguments: Any) throws -> UIClickRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        let request = UIClickRequest(
            appName: normalizedString(dictionary["app"]),
            windowTitle: normalizedString(dictionary["title"]),
            label: normalizedString(dictionary["label"]),
            role: normalizedString(dictionary["role"]),
            button: normalizedString(dictionary["button"])?.lowercased()
        )
        guard request.label != nil || request.role != nil else {
            throw AssistantAccessibilityAutomationServiceError.invalidArguments(
                "ui_click needs a `label` or `role` so Open Assist knows what to click."
            )
        }
        return request
    }

    static func parseTypeRequest(from arguments: Any) throws -> UITypeRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        guard let text = normalizedString(dictionary["text"]) else {
            throw AssistantAccessibilityAutomationServiceError.invalidArguments(
                "ui_type needs non-empty `text`."
            )
        }
        return UITypeRequest(
            text: text,
            appName: normalizedString(dictionary["app"]),
            windowTitle: normalizedString(dictionary["title"]),
            label: normalizedString(dictionary["label"]),
            role: normalizedString(dictionary["role"])
        )
    }

    static func parsePressKeyRequest(from arguments: Any) throws -> UIPressKeyRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        let keys = (dictionary["keys"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty } ?? []
        guard !keys.isEmpty else {
            throw AssistantAccessibilityAutomationServiceError.invalidArguments(
                "ui_press_key needs a non-empty `keys` array."
            )
        }
        return UIPressKeyRequest(keys: keys)
    }

    func inspectUI(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseInspectRequest(from: arguments)
            guard AXIsProcessTrusted() else {
                throw AssistantAccessibilityAutomationServiceError.accessibilityRequired
            }

            let target = try await resolvedWindowElement(
                appName: request.appName,
                windowTitle: request.windowTitle
            )
            let matches = collectMatches(
                from: target.window,
                labelFilter: request.label,
                roleFilter: request.role,
                limit: request.top
            )

            let lines: [String]
            if matches.isEmpty {
                lines = ["No matching UI elements were found."]
            } else {
                lines = ["UI elements in \(target.appName) (\(target.windowTitle)):"]
                    + matches.enumerated().map { index, match in
                        let role = match.role ?? "element"
                        let label = match.label ?? "(unlabeled)"
                        let bounds = match.frame.map(Self.boundsDescription(for:)) ?? "no bounds"
                        return "\(index + 1). \(role)\t\(label)\t\(bounds)"
                    }
            }

            let summary = matches.isEmpty
                ? "No matching UI elements found."
                : "Inspected \(matches.count) UI elements."
            return Self.result(summary: summary, lines: lines, success: true)
        } catch {
            return Self.failureResult(error.localizedDescription)
        }
    }

    func clickUI(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseClickRequest(from: arguments)
            let outcome = try await performSemanticClick(
                appName: request.appName,
                windowTitle: request.windowTitle,
                labelFilter: request.label,
                roleFilter: request.role,
                buttonName: request.button
            )
            return Self.result(summary: outcome.summary, lines: [outcome.summary], success: true)
        } catch {
            return Self.failureResult(error.localizedDescription)
        }
    }

    func typeIntoUI(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseTypeRequest(from: arguments)
            let outcome = try await performSemanticType(
                text: request.text,
                appName: request.appName,
                windowTitle: request.windowTitle,
                labelFilter: request.label,
                roleFilter: request.role
            )
            return Self.result(summary: outcome.summary, lines: [outcome.summary], success: true)
        } catch {
            return Self.failureResult(error.localizedDescription)
        }
    }

    func pressKeys(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parsePressKeyRequest(from: arguments)
            try await helper.sendKeypress(request.keys)
            let summary = "Pressed \(request.keys.joined(separator: " + "))."
            return Self.result(summary: summary, lines: [summary], success: true)
        } catch {
            return Self.failureResult(error.localizedDescription)
        }
    }

    func performSemanticClick(
        appName: String?,
        windowTitle: String?,
        labelFilter: String?,
        roleFilter: String?,
        buttonName: String? = nil
    ) async throws -> UISemanticActionResult {
        guard AXIsProcessTrusted() else {
            throw AssistantAccessibilityAutomationServiceError.accessibilityRequired
        }

        let target = try await resolvedWindowElement(appName: appName, windowTitle: windowTitle)
        let match = try findElement(in: target.window, labelFilter: labelFilter, roleFilter: roleFilter)
        let targetDescription = match.label ?? match.role ?? "the target element"

        if try performPrimaryAction(on: match.element) {
            return UISemanticActionResult(
                summary: "Clicked \(targetDescription).",
                appName: target.appName,
                windowTitle: target.windowTitle,
                targetDescription: targetDescription,
                actuator: "ax",
                confidence: 0.92,
                verificationText: nil
            )
        }

        guard let frame = match.frame else {
            throw AssistantAccessibilityAutomationServiceError.actionFailed(
                "The matching UI element does not expose a clickable action or usable bounds."
            )
        }

        try await helper.clickScreenPoint(
            CGPoint(x: frame.midX, y: frame.midY),
            buttonName: buttonName,
            clickCount: 1
        )
        return UISemanticActionResult(
            summary: "Clicked \(targetDescription) using its screen position.",
            appName: target.appName,
            windowTitle: target.windowTitle,
            targetDescription: targetDescription,
            actuator: "ax-bounds",
            confidence: 0.82,
            verificationText: nil
        )
    }

    func performSemanticType(
        text: String,
        appName: String?,
        windowTitle: String?,
        labelFilter: String?,
        roleFilter: String?
    ) async throws -> UISemanticActionResult {
        guard AXIsProcessTrusted() else {
            throw AssistantAccessibilityAutomationServiceError.accessibilityRequired
        }

        var resolvedContext: UIResolvedWindowContext?
        if labelFilter != nil || roleFilter != nil || appName != nil || windowTitle != nil {
            let target = try await resolvedWindowElement(appName: appName, windowTitle: windowTitle)
            let match = try findElement(in: target.window, labelFilter: labelFilter, roleFilter: roleFilter)
            try await focusElementForTyping(match)
            resolvedContext = UIResolvedWindowContext(appName: target.appName, windowTitle: target.windowTitle)
        }

        let insertionResult = await MainActor.run {
            TextInserter.insert(text, copyToClipboard: false)
        }
        guard insertionResult == .pasted else {
            throw AssistantAccessibilityAutomationServiceError.typingFailed(
                "Open Assist could not type into the selected field. Try focusing the field manually and run the step again."
            )
        }

        return UISemanticActionResult(
            summary: labelFilter?.nonEmpty.map { "Typed into \($0)." } ?? "Typed into the focused field.",
            appName: resolvedContext?.appName ?? "Current App",
            windowTitle: resolvedContext?.windowTitle ?? "",
            targetDescription: labelFilter?.nonEmpty ?? "focused field",
            actuator: "ui-type",
            confidence: labelFilter?.nonEmpty == nil ? 0.78 : 0.9,
            verificationText: focusedElementValue()
        )
    }

    func elementDescription(at point: CGPoint) -> UIElementDescriptor? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard result == .success,
              let element else {
            return nil
        }
        return UIElementDescriptor(
            label: Self.normalizedLabel(axStringAttribute(kAXTitleAttribute as CFString, from: element))
                ?? Self.normalizedLabel(axStringValueAttribute(kAXValueAttribute as CFString, from: element))
                ?? Self.normalizedLabel(axStringAttribute(kAXDescriptionAttribute as CFString, from: element)),
            role: Self.normalizedLabel(axStringAttribute(kAXRoleAttribute as CFString, from: element))
                ?? Self.normalizedLabel(axStringAttribute(kAXSubroleAttribute as CFString, from: element)),
            boundsDescription: axFrame(of: element).map(Self.boundsDescription(for:))
        )
    }

    func resolvedWindowContext(
        appName: String?,
        windowTitle: String?
    ) async throws -> UIResolvedWindowContext {
        let target = try await resolvedWindowElement(appName: appName, windowTitle: windowTitle)
        return UIResolvedWindowContext(appName: target.appName, windowTitle: target.windowTitle)
    }

    private func resolvedWindowElement(
        appName: String?,
        windowTitle: String?
    ) async throws -> (appName: String, windowTitle: String, window: AXUIElement) {
        if let candidate = await MainActor.run(body: {
            self.matchingWindowCandidate(appName: appName, windowTitle: windowTitle)
        }) {
            let application = AXUIElementCreateApplication(candidate.processIdentifier)
            if let window = matchingWindow(
                in: application,
                expectedTitle: windowTitle ?? candidate.title
            ) ?? firstWindow(in: application) {
                let title = Self.normalizedLabel(
                    axStringAttribute(kAXTitleAttribute as CFString, from: window)
                ) ?? candidate.title.nonEmpty ?? "Untitled Window"
                return (candidate.appName, title, window)
            }
        }

        throw AssistantAccessibilityAutomationServiceError.targetWindowNotFound
    }

    @MainActor
    private func matchingWindowCandidate(
        appName: String?,
        windowTitle: String?
    ) -> WindowCandidate? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let appFilter = appName?.lowercased()
        let titleFilter = windowTitle?.lowercased()

        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for rawWindow in rawWindows {
            guard let bounds = rawWindow[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 40,
                  height >= 30 else {
                continue
            }

            let ownerPID = pid_t((rawWindow[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0)
            guard ownerPID != 0, ownerPID != selfPID else { continue }
            let ownerName = Self.normalizedLabel(rawWindow[kCGWindowOwnerName as String] as? String) ?? ""
            let title = Self.normalizedLabel(rawWindow[kCGWindowName as String] as? String) ?? ""
            let layer = (rawWindow[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (rawWindow[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0.01 else { continue }

            if let appFilter, !ownerName.lowercased().contains(appFilter) {
                continue
            }
            if let titleFilter, !title.lowercased().contains(titleFilter) {
                continue
            }

            return WindowCandidate(appName: ownerName, processIdentifier: ownerPID, title: title)
        }

        guard appFilter == nil, titleFilter == nil,
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != selfPID else {
            return nil
        }

        let fallbackName = Self.normalizedLabel(frontmostApp.localizedName) ?? "Current App"
        return WindowCandidate(
            appName: fallbackName,
            processIdentifier: frontmostApp.processIdentifier,
            title: ""
        )
    }

    private func findElement(
        in window: AXUIElement,
        labelFilter: String?,
        roleFilter: String?
    ) throws -> ElementMatch {
        guard let match = collectMatches(
            from: window,
            labelFilter: labelFilter,
            roleFilter: roleFilter,
            limit: 1
        ).first else {
            throw AssistantAccessibilityAutomationServiceError.matchingElementNotFound
        }
        return match
    }

    private func collectMatches(
        from window: AXUIElement,
        labelFilter: String?,
        roleFilter: String?,
        limit: Int
    ) -> [ElementMatch] {
        let loweredLabel = labelFilter?.lowercased()
        let loweredRole = roleFilter?.lowercased()
        var queue: [AXUIElement] = [window]
        var cursor = 0
        var matches: [ElementMatch] = []
        let traversalLimit = 600

        while cursor < queue.count, cursor < traversalLimit, matches.count < limit {
            let element = queue[cursor]
            cursor += 1

            let role = Self.normalizedLabel(axStringAttribute(kAXRoleAttribute as CFString, from: element))
            let subrole = Self.normalizedLabel(axStringAttribute(kAXSubroleAttribute as CFString, from: element))
            let labelCandidates = [
                Self.normalizedLabel(axStringAttribute(kAXTitleAttribute as CFString, from: element)),
                Self.normalizedLabel(axStringValueAttribute(kAXValueAttribute as CFString, from: element)),
                Self.normalizedLabel(axStringAttribute(kAXDescriptionAttribute as CFString, from: element)),
                Self.normalizedLabel(axStringAttribute(kAXHelpAttribute as CFString, from: element))
            ].compactMap { $0 }
            let label = labelCandidates.first
            let actions = actionNames(for: element)

            if matchesFilters(
                label: label,
                role: role,
                subrole: subrole,
                actions: actions,
                loweredLabel: loweredLabel,
                loweredRole: loweredRole
            ) {
                matches.append(
                    ElementMatch(
                        element: element,
                        label: label,
                        role: role ?? subrole,
                        frame: axFrame(of: element),
                        actions: actions
                    )
                )
            }

            let children = axElementsAttribute(kAXChildrenAttribute as CFString, from: element)
            if !children.isEmpty, queue.count < traversalLimit {
                queue.append(contentsOf: children.prefix(max(0, traversalLimit - queue.count)))
            }
        }

        return matches
    }

    private func matchesFilters(
        label: String?,
        role: String?,
        subrole: String?,
        actions: [String],
        loweredLabel: String?,
        loweredRole: String?
    ) -> Bool {
        if let loweredLabel {
            let haystacks = [label, role, subrole]
                .compactMap { $0?.lowercased() }
            guard haystacks.contains(where: { $0.contains(loweredLabel) }) else {
                return false
            }
        }

        if let loweredRole {
            let normalizedRoleTexts = [role, subrole]
                .compactMap { $0?.lowercased() }
            let normalizedActions = actions.map { $0.lowercased() }
            guard normalizedRoleTexts.contains(where: { $0.contains(loweredRole) })
                || normalizedActions.contains(where: { $0.contains(loweredRole) }) else {
                return false
            }
        }

        return label != nil || role != nil || subrole != nil
    }

    private func focusElementForTyping(_ match: ElementMatch) async throws {
        let focusedResult = AXUIElementSetAttributeValue(
            match.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        if focusedResult == .success {
            return
        }

        if try performPrimaryAction(on: match.element) {
            return
        }

        guard let frame = match.frame else {
            throw AssistantAccessibilityAutomationServiceError.actionFailed(
                "Open Assist found the field, but it could not focus it."
            )
        }

        try await helper.clickScreenPoint(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func performPrimaryAction(on element: AXUIElement) throws -> Bool {
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressResult == .success {
            return true
        }

        let confirmAction = "AXConfirm" as CFString
        let confirmResult = AXUIElementPerformAction(element, confirmAction)
        if confirmResult == .success {
            return true
        }

        return false
    }

    private func matchingWindow(
        in application: AXUIElement,
        expectedTitle: String
    ) -> AXUIElement? {
        let trimmedTitle = expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return focusedWindow(in: application) ?? firstWindow(in: application)
        }

        let lowered = trimmedTitle.lowercased()
        for window in windows(in: application) {
            if let title = Self.normalizedLabel(axStringAttribute(kAXTitleAttribute as CFString, from: window)),
               title.lowercased().contains(lowered) {
                return window
            }
        }
        return focusedWindow(in: application) ?? firstWindow(in: application)
    }

    private func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        axElementAttribute(kAXFocusedWindowAttribute as CFString, from: application)
    }

    private func firstWindow(in application: AXUIElement) -> AXUIElement? {
        windows(in: application).first
    }

    private func windows(in application: AXUIElement) -> [AXUIElement] {
        axElementsAttribute(kAXWindowsAttribute as CFString, from: application)
    }

    private static func result(
        summary: String,
        lines: [String],
        success: Bool
    ) -> AssistantToolExecutionResult {
        AssistantToolExecutionResult(
            contentItems: [.init(type: "inputText", text: lines.joined(separator: "\n"), imageURL: nil)],
            success: success,
            summary: summary
        )
    }

    private static func failureResult(_ message: String) -> AssistantToolExecutionResult {
        result(summary: message, lines: [message], success: false)
    }

    private static func normalizedDictionary(from arguments: Any) -> [String: Any]? {
        if let dictionary = arguments as? [String: Any] {
            return dictionary
        }
        if let json = arguments as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    private static func normalizedString(_ value: Any?) -> String? {
        (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func integer(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.nonEmpty
    }

    private static func boundsDescription(for rect: CGRect) -> String {
        "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
    }

    private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private func axElementsAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              let array = valueRef as? [Any] else {
            return []
        }

        var elements: [AXUIElement] = []
        elements.reserveCapacity(array.count)
        for item in array {
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { continue }
            elements.append(unsafeBitCast(cf, to: AXUIElement.self))
        }
        return elements
    }

    private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func axStringValueAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef else {
            return nil
        }
        if let stringValue = valueRef as? String {
            return stringValue
        }
        if let attributed = valueRef as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private func axCGPointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func axCGSizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = axCGPointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = axCGSizeAttribute(kAXSizeAttribute as CFString, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var actionNamesRef: CFArray?
        let result = AXUIElementCopyActionNames(element, &actionNamesRef)
        guard result == .success,
              let actionNamesRef else {
            return []
        }
        return actionNamesRef as? [String] ?? []
    }

    private func focusedElementValue() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        return Self.normalizedLabel(
            axStringValueAttribute(kAXValueAttribute as CFString, from: element)
        )
    }
}
