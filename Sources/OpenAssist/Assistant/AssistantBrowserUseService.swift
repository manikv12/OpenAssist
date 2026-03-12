import Foundation

enum AssistantBrowserUseToolDefinition {
    static let name = "browser_use"
    static let toolKind = "browserUse"

    static let description = """
    Use a real local browser profile on this Mac for browser work. Prefer this for opening sites, checking the current tab, or reusing an existing signed-in browser session. Falls back to computer control when the task needs more live clicking or typing.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "What to do in the browser."
            ],
            "url": [
                "type": "string",
                "description": "Optional URL to open."
            ],
            "browser": [
                "type": "string",
                "description": "Optional browser hint such as Chrome, Brave, or Edge."
            ],
            "reason": [
                "type": "string",
                "description": "Short reason why real browser access is needed."
            ]
        ],
        "required": ["task"],
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

actor AssistantBrowserUseService {
    struct ParsedTask: Equatable, Sendable {
        let task: String
        let urlString: String?
        let browserHint: String?
        let reason: String?

        var requestedURL: URL? {
            if let urlString,
               let url = Self.parseURL(from: urlString) {
                return url
            }
            return Self.firstURL(in: task)
        }

        var normalizedTask: String {
            task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var shouldReadCurrentTab: Bool {
            let task = normalizedTask
            return task.contains("current tab")
                || task.contains("front tab")
                || task.contains("active tab")
                || task.contains("what page")
                || task.contains("which page")
        }

        var needsComputerFallback: Bool {
            let fallbackSignals = [
                "click",
                "fill",
                "submit",
                "scroll",
                "drag",
                "type",
                "log in",
                "login",
                "sign in",
                "reply",
                "post",
                "send",
                "upload",
                "download",
                "purchase",
                "checkout",
                "delete"
            ]
            return fallbackSignals.contains(where: normalizedTask.contains)
        }

        var summaryLine: String {
            requestedURL?.absoluteString ?? task
        }

        private static func parseURL(from raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>.,!?;:\"'"))
            guard !sanitized.isEmpty,
                  !sanitized.contains(where: \.isWhitespace) else {
                return nil
            }

            if let direct = URL(string: sanitized),
               let scheme = direct.scheme,
               !scheme.isEmpty,
               (
                   direct.host?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                || direct.isFileURL
                    || scheme.caseInsensitiveCompare("about") == .orderedSame
               ) {
                return direct
            }

            guard looksLikeBareHost(sanitized) else { return nil }
            return URL(string: "https://\(sanitized)")
        }

        private static func firstURL(in text: String) -> URL? {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = detector?.firstMatch(in: text, options: [], range: range),
               let url = match.url {
                return url
            }
            let tokens = text
                .split(whereSeparator: \.isWhitespace)
                .map { String($0) }
            for token in tokens {
                if let url = parseURL(from: token) {
                    return url
                }
            }
            return nil
        }

        private static func looksLikeBareHost(_ raw: String) -> Bool {
            let hostAndMaybePath = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
            let host = hostAndMaybePath.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostAndMaybePath
            let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedHost.caseInsensitiveCompare("localhost") == .orderedSame {
                return true
            }

            if normalizedHost.range(
                of: #"^\d{1,3}(\.\d{1,3}){3}$"#,
                options: .regularExpression
            ) != nil {
                return true
            }

            return normalizedHost.range(
                of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                options: .regularExpression
            ) != nil
        }
    }

    private let settings: SettingsStore
    private let helper: LocalAutomationHelper
    private let computerUseService: AssistantComputerUseService

    init(
        settings: SettingsStore,
        helper: LocalAutomationHelper = .shared,
        computerUseService: AssistantComputerUseService
    ) {
        self.settings = settings
        self.helper = helper
        self.computerUseService = computerUseService
    }

    func run(arguments: Any, preferredModelID: String?) async -> AssistantComputerUseService.ToolExecutionResult {
        do {
            let parsedTask = try Self.parseTask(from: arguments)
            let profile = try await resolveProfile(browserHint: parsedTask.browserHint)

            if parsedTask.needsComputerFallback {
                return await computerUseService.run(
                    arguments: [
                        "task": parsedTask.task,
                        "app": profile.browser.displayName,
                        "reason": "Use the real \(profile.browser.displayName) session first when possible, then continue with live computer control if needed."
                    ],
                    preferredModelID: preferredModelID
                )
            }

            if let requestedURL = parsedTask.requestedURL {
                try await helper.openBrowserURL(requestedURL, profile: profile)
                let tab = try? await helper.readFrontBrowserTab(browser: profile.browser)
                let summary = "Opened \(requestedURL.absoluteString) in \(profile.browser.displayName) using profile \(profile.label)."
                return Self.result(
                    summary: summary,
                    detail: browserDetail(from: tab)
                )
            }

            if parsedTask.shouldReadCurrentTab {
                try await helper.activateBrowser(profile.browser)
                let tab = try await helper.readFrontBrowserTab(browser: profile.browser)
                let summary = browserDetail(from: tab) ?? "Read the current tab in \(profile.browser.displayName)."
                return Self.result(summary: summary, detail: nil)
            }

            try await helper.activateBrowser(profile.browser)
            return Self.result(
                summary: "Activated \(profile.browser.displayName) with profile \(profile.label).",
                detail: nil
            )
        } catch {
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Browser Use failed."
            return Self.result(summary: summary, detail: nil, success: false)
        }
    }

    static func parseTask(from arguments: Any) throws -> ParsedTask {
        if let text = (arguments as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ParsedTask(task: text, urlString: nil, browserHint: nil, reason: nil)
        }

        guard let dictionary = arguments as? [String: Any] else {
            throw LocalAutomationError.invalidArguments("Browser Use needs a browser task.")
        }

        let task = [
            dictionary["task"] as? String,
            dictionary["goal"] as? String,
            dictionary["instruction"] as? String,
            dictionary["prompt"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        guard let task else {
            throw LocalAutomationError.invalidArguments("Browser Use needs a browser task.")
        }

        let urlString = [
            dictionary["url"] as? String,
            dictionary["site"] as? String,
            dictionary["website"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        let browserHint = [
            dictionary["browser"] as? String,
            dictionary["app"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        let reason = [
            dictionary["reason"] as? String,
            dictionary["why"] as? String,
            dictionary["context"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        return ParsedTask(task: task, urlString: urlString, browserHint: browserHint, reason: reason)
    }

    private func resolveProfile(browserHint: String?) async throws -> BrowserProfile {
        let browserAutomationEnabled = await MainActor.run { settings.browserAutomationEnabled }
        guard browserAutomationEnabled else {
            throw LocalAutomationError.browserAutomationDisabled
        }

        let preferredID = await MainActor.run { settings.browserSelectedProfileID }
        let profiles = BrowserProfileManager.shared.allProfiles()
        let selectedProfile = BrowserProfileManager.shared.profile(withID: preferredID)
        if let browserHint,
           let hintedBrowser = Self.supportedBrowser(from: browserHint) {
            if let selectedProfile,
               selectedProfile.browser == hintedBrowser {
                return selectedProfile
            }
            if let hintedProfile = profiles.first(where: { $0.browser == hintedBrowser }) {
                return hintedProfile
            }
        }

        if let selected = selectedProfile {
            return selected
        }

        throw LocalAutomationError.browserProfileUnavailable
    }

    private static func supportedBrowser(from rawValue: String) -> SupportedBrowser? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case let value where value.contains("chrome"):
            return .chrome
        case let value where value.contains("brave"):
            return .brave
        case let value where value.contains("edge"):
            return .edge
        default:
            return nil
        }
    }

    private func browserDetail(from tab: (title: String?, url: String?)?) -> String? {
        guard let tab else { return nil }
        var lines: [String] = []
        if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("Tab: \(title)")
        }
        if let url = tab.url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("URL: \(url)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func result(
        summary: String,
        detail: String?,
        success: Bool = true
    ) -> AssistantComputerUseService.ToolExecutionResult {
        var items: [AssistantComputerUseService.ToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil)
        ]
        if let detail {
            items.append(.init(type: "inputText", text: detail, imageURL: nil))
        }
        return AssistantComputerUseService.ToolExecutionResult(
            contentItems: items,
            success: success,
            summary: summary
        )
    }
}
