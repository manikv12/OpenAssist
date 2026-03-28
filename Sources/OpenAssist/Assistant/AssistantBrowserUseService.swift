import Foundation

enum AssistantBrowserUseToolDefinition {
    static let name = "browser_use"
    static let toolKind = "browserUse"

    static let description = """
    Use a real local browser profile on this Mac for browser work. Prefer this for opening sites, checking the current tab, reusing an existing signed-in browser session, or pausing when a site needs a manual login. Stay in the same browser profile and do not switch to a separate Playwright or MCP browser session.
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

struct AssistantBrowserLoginPrompt: Equatable, Sendable {
    let browser: SupportedBrowser
    let profileLabel: String
    let pageTitle: String?
    let pageURL: String?
    let taskSummary: String
    let reason: String

    var requestTitle: String {
        "Browser login required"
    }

    var requestRationale: String {
        [
            reason,
            pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "Page: \($0)" },
            pageURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "URL: \($0)" },
            "Please sign in with \(browser.displayName) using profile \(profileLabel), then press Proceed."
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    var requestSummary: String {
        [
            "Browser: \(browser.displayName)",
            "Profile: \(profileLabel)",
            pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "Title: \($0)" },
            pageURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { "URL: \($0)" },
            "Task: \(taskSummary)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

enum AssistantBrowserUseServiceError: Error, LocalizedError, Sendable {
    case loginRequired(AssistantBrowserLoginPrompt)

    var errorDescription: String? {
        switch self {
        case .loginRequired(let prompt):
            return prompt.requestRationale
        }
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
            let directSignals = [
                "current tab",
                "front tab",
                "active tab",
                "what page",
                "which page",
                "tab title",
                "url if available"
            ]
            if directSignals.contains(where: task.contains) {
                return true
            }

            let readSignals = [
                "read",
                "inspect",
                "identify",
                "report",
                "tell me",
                "check",
                "summarize",
                "summarise",
                "find"
            ]
            let contextSignals = [
                "current",
                "currently",
                "active",
                "front",
                "visible",
                "open"
            ]
            let pageTargets = [
                "tab",
                "page",
                "window",
                "url",
                "site"
            ]

            return readSignals.contains(where: task.contains)
                && contextSignals.contains(where: task.contains)
                && pageTargets.contains(where: task.contains)
        }

        var wantsLoginFlow: Bool {
            let task = normalizedTask
            let loginSignals = [
                "log in",
                "log into",
                "login",
                "sign in",
                "sign into",
                "signin",
                "sign-in",
                "authenticate",
                "authentication",
                "reauth",
                "re-auth"
            ]
            return loginSignals.contains(where: task.contains)
        }

        var needsComputerFallback: Bool {
            let fallbackSignals = [
                "click",
                "fill",
                "submit",
                "scroll",
                "drag",
                "type",
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

    init(
        settings: SettingsStore,
        helper: LocalAutomationHelper = .shared
    ) {
        self.settings = settings
        self.helper = helper
    }

    func run(arguments: Any, preferredModelID: String?) async -> AssistantToolExecutionResult {
        await execute(
            arguments: arguments,
            preferredModelID: preferredModelID,
            resumeAfterLogin: false
        )
    }

    func resumeAfterLogin(arguments: Any, preferredModelID: String?) async -> AssistantToolExecutionResult {
        await execute(
            arguments: arguments,
            preferredModelID: preferredModelID,
            resumeAfterLogin: true
        )
    }

    private func execute(
        arguments: Any,
        preferredModelID: String?,
        resumeAfterLogin: Bool
    ) async -> AssistantToolExecutionResult {
        do {
            let parsedTask = try Self.parseTask(from: arguments)
            let profile = try await resolveProfile(browserHint: parsedTask.browserHint)

            if parsedTask.needsComputerFallback {
                return Self.result(
                    summary: """
                    Browser Use can open sites, activate the browser, and read the current tab. This request needs live clicking or typing.
                    """,
                    detail: "Try `ui_inspect`, `ui_click`, `ui_type`, or `ui_press_key` first when the visible browser UI is exposed through macOS Accessibility. Only fall back to `computer_use` when the task truly depends on visible pixels in the same signed-in browser window. If the site needs a manual sign-in first, pause and let the user log in before continuing.",
                    success: false
                )
            }

            if !resumeAfterLogin, let requestedURL = parsedTask.requestedURL {
                try await helper.openBrowserURL(requestedURL, profile: profile)
            }

            let shouldInspectCurrentTab = resumeAfterLogin
                || parsedTask.requestedURL != nil
                || parsedTask.shouldReadCurrentTab
                || parsedTask.wantsLoginFlow

            if shouldInspectCurrentTab {
                try await helper.activateBrowser(profile.browser)
                let tab = try? await helper.readFrontBrowserTab(browser: profile.browser)

                if let prompt = Self.loginPrompt(
                    for: parsedTask,
                    browser: profile.browser,
                    profileLabel: profile.label,
                    tab: tab
                ) {
                    return Self.loginRequiredResult(prompt: prompt)
                }

                let summary = Self.summaryLine(
                    for: parsedTask,
                    browser: profile.browser,
                    profile: profile,
                    tab: tab,
                    resumeAfterLogin: resumeAfterLogin
                )
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

    private static func summaryLine(
        for parsedTask: ParsedTask,
        browser: SupportedBrowser,
        profile: BrowserProfile,
        tab: (title: String?, url: String?)?,
        resumeAfterLogin: Bool
    ) -> String {
        if resumeAfterLogin {
            if let requestedURL = parsedTask.requestedURL {
                return "Signed in and continued \(requestedURL.absoluteString) in \(browser.displayName) using profile \(profile.label)."
            }
            return "Signed in and read the current tab in \(browser.displayName) using profile \(profile.label)."
        }

        if let requestedURL = parsedTask.requestedURL {
            return "Opened \(requestedURL.absoluteString) in \(browser.displayName) using profile \(profile.label)."
        }

        if parsedTask.shouldReadCurrentTab || parsedTask.wantsLoginFlow {
            return browserDetail(from: tab) ?? "Read the current tab in \(browser.displayName)."
        }

        return "Activated \(browser.displayName) with profile \(profile.label)."
    }

    static func loginPrompt(
        for parsedTask: ParsedTask,
        browser: SupportedBrowser,
        profileLabel: String,
        tab: (title: String?, url: String?)?
    ) -> AssistantBrowserLoginPrompt? {
        guard let tab else { return nil }

        guard let reason = loginDetectionReason(
            for: parsedTask,
            title: tab.title,
            url: tab.url
        ) else {
            return nil
        }

        return AssistantBrowserLoginPrompt(
            browser: browser,
            profileLabel: profileLabel,
            pageTitle: tab.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            pageURL: tab.url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            taskSummary: parsedTask.summaryLine,
            reason: reason
        )
    }

    private static func loginDetectionReason(
        for parsedTask: ParsedTask,
        title: String?,
        url: String?
    ) -> String? {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let titleSignals = [
            "sign in",
            "sign-in",
            "signin",
            "login",
            "log in",
            "log-in",
            "authenticate",
            "authentication",
            "verification",
            "verify your identity",
            "security check",
            "two-factor",
            "2fa",
            "mfa"
        ]
        if titleSignals.contains(where: normalizedTitle.contains) {
            return "The page title looks like a sign-in screen."
        }

        let urlSignals = [
            "/login",
            "/signin",
            "/sign-in",
            "/oauth",
            "/sso",
            "/auth",
            "/session",
            "/verify",
            "/challenge",
            "/checkpoint",
            "accounts."
        ]
        if urlSignals.contains(where: normalizedURL.contains) {
            return "The page URL looks like a login flow."
        }

        if parsedTask.wantsLoginFlow {
            let loginContextSignals = [
                "account",
                "accounts.",
                "authorize",
                "authentication",
                "auth"
            ]
            if loginContextSignals.contains(where: normalizedTitle.contains)
                || loginContextSignals.contains(where: normalizedURL.contains) {
                return "This looks like the login flow you asked for."
            }
        }

        return nil
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

    private static func browserDetail(from tab: (title: String?, url: String?)?) -> String? {
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
    ) -> AssistantToolExecutionResult {
        var items: [AssistantToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil)
        ]
        if let detail {
            items.append(.init(type: "inputText", text: detail, imageURL: nil))
        }
        return AssistantToolExecutionResult(
            contentItems: items,
            success: success,
            summary: summary
        )
    }

    private static func loginRequiredResult(prompt: AssistantBrowserLoginPrompt) -> AssistantToolExecutionResult {
        AssistantToolExecutionResult(
            contentItems: [.init(type: "inputText", text: prompt.requestRationale, imageURL: nil)],
            success: false,
            summary: prompt.requestRationale,
            loginPrompt: prompt
        )
    }
}
