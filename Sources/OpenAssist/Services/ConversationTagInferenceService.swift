import CryptoKit
import Foundation

struct ConversationThreadTupleKey: Hashable {
    let bundleID: String
    let logicalSurfaceKey: String
    let projectKey: String
    let identityKey: String
    let nativeThreadKey: String
}

enum ConversationIdentityKind: String {
    case channel
    case person
    case unknown
}

final class ConversationTagInferenceService {
    static let shared = ConversationTagInferenceService()
    private let codingWorkspaceBundleID = "com.openassist.coding-workspace"
    private let browserWorkspaceBundleID = "com.openassist.browser-workspace"
    private let browserWorkspaceProjectKey = "project:browser-workspace"
    private let browserWorkspaceIdentityKey = "identity:browser-workspace"
    private let browserWorkspaceNativeThreadKey = "thread:browser-workspace"
    private let codexConversationProjectKey = "project:codex-app"
    private let codexConversationProjectLabel = "Unknown Project"
    private let codexConversationIdentityKey = "identity:codex-app"
    private let codexConversationIdentityLabel = "Unknown Identity"
    private let codexConversationNativeThreadKey = "thread:codex-app"

    private init() {}

    func inferTags(
        capturedContext: PromptRewriteConversationContext,
        userText: String,
        assistantText: String? = nil
    ) -> ConversationTupleTags {
        let normalizedScreenContextText = collapseWhitespace(capturedContext.screenLabel)
        let normalizedFieldContextText = collapseWhitespace(capturedContext.fieldLabel)
        let normalizedContextText = [normalizedScreenContextText, normalizedFieldContextText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let supplementalText = [userText, assistantText ?? ""]
            .joined(separator: "\n")
        let normalizedSupplementalText = collapseWhitespace(supplementalText)

        if isCodexApp(bundleID: capturedContext.bundleIdentifier, appName: capturedContext.appName) {
            return ConversationTupleTags(
                projectKey: codexConversationProjectKey,
                projectLabel: codexConversationProjectLabel,
                identityKey: codexConversationIdentityKey,
                identityType: ConversationIdentityKind.unknown.rawValue,
                identityLabel: codexConversationIdentityLabel,
                people: [],
                nativeThreadKey: codexConversationNativeThreadKey
            )
        }

        let projectLabel = inferProjectLabel(
            bundleID: capturedContext.bundleIdentifier,
            appName: capturedContext.appName,
            contextText: normalizedContextText,
            supplementalText: normalizedSupplementalText
        )
        let projectKey = canonicalProjectKey(projectLabel)
        let identityContextText: String
        if !normalizedScreenContextText.isEmpty {
            // Keep identity extraction focused on screen-level text so UI field labels
            // (for example AXTextArea) do not pollute inferred thread IDs.
            identityContextText = normalizedScreenContextText
        } else {
            identityContextText = normalizedContextText
        }

        let identity = inferIdentity(
            bundleID: capturedContext.bundleIdentifier,
            appName: capturedContext.appName,
            contextText: identityContextText,
            supplementalText: normalizedSupplementalText
        )

        return ConversationTupleTags(
            projectKey: projectKey,
            projectLabel: projectLabel,
            identityKey: identity.key,
            identityType: identity.type.rawValue,
            identityLabel: identity.label,
            people: identity.people,
            nativeThreadKey: identity.nativeThreadKey
        )
    }

    func logicalSurfaceKey(for context: PromptRewriteConversationContext) -> String {
        let joined = [
            context.bundleIdentifier,
            context.screenLabel,
            context.fieldLabel
        ]
            .map(collapseWhitespace)
            .map { $0.lowercased() }
            .joined(separator: "|")
        return stableKey(prefix: "surface", value: joined)
    }

    func tupleKey(
        capturedContext: PromptRewriteConversationContext,
        tags: ConversationTupleTags
    ) -> ConversationThreadTupleKey {
        if isCodexApp(bundleID: capturedContext.bundleIdentifier, appName: capturedContext.appName) {
            let normalizedBundle = collapseWhitespace(capturedContext.bundleIdentifier).lowercased()
            let canonicalBundle = normalizedBundle.isEmpty ? "com.openai.codex" : normalizedBundle
            let logicalSurface = stableKey(
                prefix: "surface",
                value: "\(canonicalBundle)|codex-app"
            )
            return ConversationThreadTupleKey(
                bundleID: canonicalBundle,
                logicalSurfaceKey: logicalSurface,
                projectKey: codexConversationProjectKey,
                identityKey: codexConversationIdentityKey,
                nativeThreadKey: codexConversationNativeThreadKey
            )
        }

        let isBrowserContext = isBrowser(bundleID: capturedContext.bundleIdentifier, appName: capturedContext.appName)
        let canonicalBundle = canonicalBundleID(
            bundleID: capturedContext.bundleIdentifier,
            appName: capturedContext.appName,
            projectKey: tags.projectKey,
            isBrowserContext: isBrowserContext
        )
        let canonicalSurface = canonicalLogicalSurfaceKey(
            capturedContext: capturedContext,
            canonicalBundleID: canonicalBundle,
            projectKey: tags.projectKey,
            isBrowserContext: isBrowserContext
        )
        let canonicalProjectKey: String = isBrowserContext
            ? browserWorkspaceProjectKey
            : collapseWhitespace(tags.projectKey).lowercased()
        let canonicalIdentityKey: String = isBrowserContext
            ? browserWorkspaceIdentityKey
            : collapseWhitespace(tags.identityKey).lowercased()
        let canonicalNativeThreadKey: String = isBrowserContext
            ? browserWorkspaceNativeThreadKey
            : collapseWhitespace(tags.nativeThreadKey).lowercased()
        return ConversationThreadTupleKey(
            bundleID: canonicalBundle,
            logicalSurfaceKey: canonicalSurface,
            projectKey: canonicalProjectKey,
            identityKey: canonicalIdentityKey,
            nativeThreadKey: canonicalNativeThreadKey
        )
    }

    func threadID(for tuple: ConversationThreadTupleKey) -> String {
        stableKey(
            prefix: "thread",
            value: [
                tuple.bundleID,
                tuple.logicalSurfaceKey,
                tuple.projectKey,
                tuple.identityKey,
                tuple.nativeThreadKey
            ].joined(separator: "|")
        )
    }

    private func inferProjectLabel(
        bundleID: String,
        appName: String,
        contextText: String,
        supplementalText: String
    ) -> String {
        let primaryText = contextText.isEmpty ? supplementalText : contextText

        if let path = extractPathLikeValue(from: primaryText),
           let projectFromPath = derivePathLabel(from: path) {
            return projectFromPath
        }
        if let path = extractPathLikeValue(from: supplementalText),
           let projectFromPath = derivePathLabel(from: path) {
            return projectFromPath
        }

        if isCodexApp(bundleID: bundleID, appName: appName) {
            if let codexProject = firstMatch(
                pattern: #"(?i)\b(?:project|workspace)\s*[:\-]\s*([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
                in: primaryText
            ) {
                return codexProject
            }
            if let codexBuildProject = firstMatch(
                pattern: #"(?i)\blet['’]s\s+build\s+([a-z0-9][a-z0-9 ._()\-]{1,80})\b"#,
                in: primaryText
            ) {
                return codexBuildProject
            }
        }

        if let regexMatch = firstMatch(
            pattern: #"(?i)\b(?:project|workspace|repo|repository)\s*[:\-]?\s*([a-z0-9._()\-][a-z0-9._()\- /]{1,80})\b"#,
            in: primaryText
        ), !isBlockedProjectLabel(regexMatch) {
            return regexMatch
        }

        if isBrowser(bundleID: bundleID, appName: appName),
           let domain = extractDomain(from: primaryText) {
            return domain
        }

        if isTeamsApp(bundleID: bundleID, appName: appName),
           let teamsWorkspace = inferTeamsWorkspace(from: primaryText) {
            return teamsWorkspace
        }

        return "Unknown Project"
    }

    private func isBlockedProjectLabel(_ value: String) -> Bool {
        let normalized = collapseWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !normalized.isEmpty else {
            return true
        }
        let blocked: Set<String> = [
            "unknown",
            "unknown project",
            "unknown workspace",
            "current screen",
            "focused input"
        ]
        if blocked.contains(normalized) {
            return true
        }
        let slugged = slug(normalized)
        return isBlockedProjectSlug(slugged)
    }

    private func isBlockedProjectSlug(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return true
        }
        let blocked: Set<String> = [
            "unknown",
            "unknown-project",
            "current-screen",
            "focused-input"
        ]
        if blocked.contains(value) || value.hasPrefix("unknown-") {
            return true
        }
        return false
    }

    private func canonicalBundleID(
        bundleID: String,
        appName: String,
        projectKey: String,
        isBrowserContext: Bool
    ) -> String {
        if isBrowserContext {
            return browserWorkspaceBundleID
        }
        if isCrossIDECodingProjectContext(bundleID: bundleID, appName: appName, projectKey: projectKey) {
            return codingWorkspaceBundleID
        }
        return collapseWhitespace(bundleID).lowercased()
    }

    private func canonicalLogicalSurfaceKey(
        capturedContext: PromptRewriteConversationContext,
        canonicalBundleID: String,
        projectKey: String,
        isBrowserContext: Bool
    ) -> String {
        if isBrowserContext {
            // Use one browser-wide surface so tabs/windows from any browser app share history.
            return stableKey(prefix: "surface", value: "\(canonicalBundleID)|browser-workspace")
        }
        if isCrossIDECodingProjectContext(
            bundleID: capturedContext.bundleIdentifier,
            appName: capturedContext.appName,
            projectKey: projectKey
        ) {
            // Share one conversation bucket across coding IDEs for the same project.
            return stableKey(prefix: "surface", value: "\(canonicalBundleID)|\(projectKey)|project-workspace")
        }
        return logicalSurfaceKey(for: capturedContext)
    }

    func isBrowserContext(bundleID: String, appName: String) -> Bool {
        isBrowser(bundleID: bundleID, appName: appName)
    }

    func shouldShareCrossIDECodingContext(
        bundleID: String,
        appName: String,
        projectKey: String,
        featureEnabled: Bool
    ) -> Bool {
        isCrossIDECodingProjectContext(
            bundleID: bundleID,
            appName: appName,
            projectKey: projectKey,
            featureEnabled: featureEnabled
        )
    }

    func shouldSuppressUnknownCodingHistory(
        bundleID: String,
        appName: String,
        projectKey: String,
        identityKey: String
    ) -> Bool {
        guard isCodingWorkspaceApp(bundleID: bundleID, appName: appName) else {
            return false
        }
        let normalizedProject = collapseWhitespace(projectKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedIdentity = collapseWhitespace(identityKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedProject == "project:unknown" && normalizedIdentity == "identity:unknown"
    }

    private func isCrossIDECodingProjectContext(
        bundleID: String,
        appName: String,
        projectKey: String,
        featureEnabled: Bool = FeatureFlags.crossIDEConversationSharingEnabled
    ) -> Bool {
        guard featureEnabled else {
            return false
        }
        guard !isCodexApp(bundleID: bundleID, appName: appName) else {
            return false
        }
        guard hasMeaningfulProjectKey(projectKey) else {
            return false
        }
        return isCodingWorkspaceApp(bundleID: bundleID, appName: appName)
    }

    private func hasMeaningfulProjectKey(_ projectKey: String) -> Bool {
        let normalized = collapseWhitespace(projectKey).lowercased()
        guard normalized.hasPrefix("project:") else {
            return false
        }
        let value = String(normalized.dropFirst("project:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return false
        }
        // Treat generic/unknown placeholders as non-meaningful so they never
        // cause cross-app thread sharing.
        let blockedValues: Set<String> = [
            "unknown",
            "unknown-project",
            "current-screen",
            "focused-input"
        ]
        if blockedValues.contains(value) || value.hasPrefix("unknown-") {
            return false
        }
        return true
    }

    private func inferIdentity(
        bundleID: String,
        appName: String,
        contextText: String,
        supplementalText: String
    ) -> (key: String, type: ConversationIdentityKind, label: String, people: [String], nativeThreadKey: String) {
        let primaryText = contextText.isEmpty ? supplementalText : contextText
        var nativeThreadKey = inferNativeThreadKey(from: primaryText)
        if nativeThreadKey.isEmpty {
            nativeThreadKey = inferNativeThreadKey(from: supplementalText)
        }

        var people = extractPeople(from: primaryText)
        if people.isEmpty {
            people = extractMentionHandles(from: supplementalText)
        }

        if let explicitThreadLabel = firstMatch(
            pattern: #"(?i)\bthread\s*[:\-]\s*([a-z0-9][a-z0-9 .,_'’()\-]{2,120})\b"#,
            in: primaryText
        ),
           let normalizedThread = sanitizedThreadIdentityLabel(explicitThreadLabel) {
            let key = "thread:\(slug(normalizedThread))"
            let resolvedNativeThreadKey = nativeThreadKey.isEmpty ? key : nativeThreadKey
            return (key, .channel, normalizedThread, people, resolvedNativeThreadKey)
        }

        if isTeamsApp(bundleID: bundleID, appName: appName),
           let teamsIdentity = inferTeamsIdentity(from: primaryText) {
            let keyPrefix = teamsIdentity.type == .person ? "person" : "channel"
            return ("\(keyPrefix):\(slug(teamsIdentity.label))", teamsIdentity.type, teamsIdentity.label, people, nativeThreadKey)
        }

        if isAppleMessagesApp(bundleID: bundleID, appName: appName),
           let messagesPerson = inferAppleMessagesPerson(from: primaryText) {
            let key = "person:\(slug(messagesPerson))"
            let mergedPeople = Array(Set((people + [messagesPerson]).map(collapseWhitespace)))
                .filter { !$0.isEmpty }
                .sorted()
            return (key, .person, messagesPerson, mergedPeople, nativeThreadKey)
        }

        if isCodexApp(bundleID: bundleID, appName: appName),
           let codexThreadLabel = firstMatch(
               pattern: #"(?i)\bthread\s*[:\-]\s*([a-z0-9][a-z0-9 .,_'’()\-]{2,120})\b"#,
               in: contextText
           ),
           let normalizedThread = sanitizedThreadIdentityLabel(codexThreadLabel) {
            let key = "thread:\(slug(normalizedThread))"
            let resolvedNativeThreadKey = nativeThreadKey.isEmpty ? key : nativeThreadKey
            return (key, .channel, normalizedThread, people, resolvedNativeThreadKey)
        }

        if isGroupChatApp(bundleID: bundleID, appName: appName) {
            if let channel = inferChannelLabel(from: primaryText) {
                let key = "channel:\(slug(channel))"
                return (key, .channel, channel, people, nativeThreadKey)
            }
            if let person = people.first {
                let key = "person:\(slug(person))"
                return (key, .person, person, people, nativeThreadKey)
            }
            return ("channel:unknown", .channel, "Unknown Channel", people, nativeThreadKey)
        }

        if let person = people.first {
            let key = "person:\(slug(person))"
            return (key, .person, person, people, nativeThreadKey)
        }

        if isLikelyChannelIdentityApp(bundleID: bundleID, appName: appName),
           let channel = inferChannelLabel(from: primaryText) {
            let key = "channel:\(slug(channel))"
            return (key, .channel, channel, people, nativeThreadKey)
        }

        return ("identity:unknown", .unknown, "Unknown Identity", people, nativeThreadKey)
    }

    private func inferChannelLabel(from text: String) -> String? {
        if let hashChannel = firstMatch(pattern: #"(?i)#([a-z0-9._\-]{2,64})"#, in: text) {
            return hashChannel
        }
        if let explicit = firstMatch(
            pattern: #"(?i)\b(?:channel|room|team|chat|conversation|thread)\s*[:\-]?\s*([A-Za-z0-9][A-Za-z0-9 ._()'’&\-/]{1,80})\b"#,
            in: text
        ) {
            return collapseWhitespace(explicit)
        }
        return nil
    }

    private func sanitizedThreadIdentityLabel(_ value: String) -> String? {
        let normalized = collapseWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else { return nil }
        let lowered = normalized.lowercased()

        let blockedExact: Set<String> = [
            "thread actions",
            "new thread",
            "threads",
            "settings",
            "explorer",
            "explorer section",
            "source control"
        ]
        if blockedExact.contains(lowered) {
            return nil
        }

        if lowered.range(of: #"^\d+\s*[smhdw]$"#, options: .regularExpression) != nil {
            return nil
        }

        if lowered.range(
            of: #"^(?:hide|show|toggle|open|close|expand|collapse)\b"#,
            options: .regularExpression
        ) != nil {
            return nil
        }

        if lowered.contains("axtextarea")
            || lowered.contains("axtextfield")
            || lowered.contains("axbutton")
            || lowered.contains("axgroup")
            || lowered.contains("axscrollarea") {
            return nil
        }

        return normalized
    }

    private func inferNativeThreadKey(from text: String) -> String {
        if let value = firstMatch(
            pattern: #"(?i)\b(?:thread|conversation|chat)\s*(?:id)?\s*[:=#]\s*([a-z0-9._\-]{3,80})"#,
            in: text
        ) {
            return value.lowercased()
        }
        if let urlThread = firstMatch(
            pattern: #"(?i)(?:threadId|conversationId|chatId)=([a-z0-9._\-]{3,80})"#,
            in: text
        ) {
            return urlThread.lowercased()
        }
        return ""
    }

    private func extractPeople(from text: String) -> [String] {
        extractMentionHandles(from: text)
    }

    private func extractMentionHandles(from text: String) -> [String] {
        var people: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"@([a-z0-9._\-]{2,64})"#, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let personRange = Range(match.range(at: 1), in: text) else {
                    continue
                }
                people.append(String(text[personRange]))
            }
        }
        let unique = Array(Set(people.map { collapseWhitespace($0).lowercased() }))
            .sorted()
        return unique
    }

    private func inferTeamsIdentity(from text: String) -> (label: String, type: ConversationIdentityKind)? {
        if let directPerson = firstMatch(
            pattern: #"(?i)\b(?:chat|direct message|dm|conversation)\s*(?:with|:|-)?\s*([A-Z][A-Za-z0-9 .,'’&\-]{1,80})"#,
            in: text
        ) {
            let cleaned = collapseWhitespace(directPerson)
            if looksLikePersonName(cleaned) {
                return (cleaned, .person)
            }
        }

        for candidate in splitByStrongSeparators(text) {
            guard let cleaned = cleanedTeamsSegment(candidate) else { continue }
            if looksLikeTeamsChannel(cleaned) {
                return (cleaned, .channel)
            }
            if looksLikePersonName(cleaned) {
                return (cleaned, .person)
            }
        }

        return nil
    }

    private func inferTeamsWorkspace(from text: String) -> String? {
        for segment in splitByStrongSeparators(text) {
            let cleaned = collapseWhitespace(segment)
            let lowered = cleaned.lowercased()
            guard !cleaned.isEmpty else { continue }
            if lowered == "microsoft teams"
                || lowered == "teams"
                || lowered == "current screen"
                || lowered == "focused input"
                || lowered == "type a message" {
                continue
            }
            if looksLikeTeamsChannel(cleaned) {
                return cleaned
            }
        }
        return nil
    }

    private func inferAppleMessagesPerson(from text: String) -> String? {
        if let directMatch = firstMatch(
            pattern: #"(?i)\b([A-Z][A-Za-z'’.\-]{1,40}(?:\s+[A-Z][A-Za-z'’.\-]{1,40}){0,3})\s*(?:[>›]|[-•|:]\s*(?:text\s+message|iMessage|sms))\b"#,
            in: text
        ) {
            let cleaned = normalizedAppleMessagesPersonLabel(directMatch)
            if looksLikePersonName(cleaned) {
                return cleaned
            }
        }

        var segments = splitByStrongSeparators(text)
        if segments.isEmpty {
            segments = [text]
        }

        for segment in segments {
            let cleaned = normalizedAppleMessagesPersonLabel(segment)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            guard !cleaned.isEmpty else { continue }

            let lowered = cleaned.lowercased()
            let blocked: Set<String> = [
                "messages",
                "message",
                "text message",
                "imessage",
                "sms",
                "chat",
                "new message",
                "new messages",
                "search",
                "current screen",
                "focused input",
                "type a message"
            ]
            if blocked.contains(lowered) {
                continue
            }
            if lowered.range(of: #"\b(?:text\s+message|imessage|sms)\b"#, options: .regularExpression) != nil {
                continue
            }
            if lowered.range(of: #"\b(?:today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, options: .regularExpression) != nil {
                continue
            }
            if cleaned.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
                continue
            }
            if looksLikePersonName(cleaned) {
                return cleaned
            }
        }

        return nil
    }

    private func normalizedAppleMessagesPersonLabel(_ value: String) -> String {
        var normalized = collapseWhitespace(value)
        guard !normalized.isEmpty else { return normalized }

        // Messages sometimes prefixes contact candidates as "Maybe: Name".
        // Strip that prefix so identity keys remain stable (person:<normalized-name>).
        normalized = normalized.replacingOccurrences(
            of: #"(?i)^\s*maybe\s*:\s*"#,
            with: "",
            options: .regularExpression
        )

        return collapseWhitespace(normalized)
    }

    private func cleanedTeamsSegment(_ value: String) -> String? {
        var candidate = collapseWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !candidate.isEmpty else { return nil }

        let normalizedPrefixes = [
            "chat with ",
            "direct message with ",
            "meeting chat ",
            "channel ",
            "team "
        ]
        for prefix in normalizedPrefixes {
            if candidate.lowercased().hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }

        let lowered = candidate.lowercased()
        let blocked: Set<String> = [
            "microsoft teams",
            "teams",
            "chat",
            "current screen",
            "focused input",
            "type a message",
            "activity",
            "calendar",
            "calls",
            "files",
            "posts",
            "meetings",
            "new chat",
            "search"
        ]
        if blocked.contains(lowered) {
            return nil
        }
        if lowered.contains("http://") || lowered.contains("https://") {
            return nil
        }
        if candidate.count < 2 || candidate.count > 90 {
            return nil
        }
        return candidate
    }

    private func looksLikePersonName(_ value: String) -> Bool {
        let normalized = collapseWhitespace(value)
        guard !normalized.isEmpty else { return false }
        if normalized.contains("/") || normalized.contains(" | ") || normalized.hasPrefix("#") {
            return false
        }

        if normalized.range(of: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        let words = normalized.split(separator: " ").map(String.init)
        guard words.count >= 1 && words.count <= 5 else { return false }
        let capitalizedCount = words.reduce(into: 0) { partial, word in
            guard let first = word.first else { return }
            if first.isUppercase {
                partial += 1
            }
        }
        if words.count == 1 {
            return capitalizedCount == 1 && normalized.count >= 3
        }
        return capitalizedCount >= 2
    }

    private func looksLikeTeamsChannel(_ value: String) -> Bool {
        let normalized = collapseWhitespace(value)
        let lowered = normalized.lowercased()
        if normalized.hasPrefix("#") {
            return true
        }
        if lowered == "general" {
            return true
        }
        if lowered.contains("channel")
            || lowered.contains("team")
            || lowered.contains(" / ")
            || lowered.contains(">") {
            return true
        }
        return false
    }

    private func extractDomain(from value: String) -> String? {
        let pattern = #"(?i)\b(?:https?://)?([a-z0-9.-]+\.[a-z]{2,})(?:/|\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let domainRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let domain = String(value[domainRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty ? nil : domain
    }

    private func extractPathLikeValue(from value: String) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  let tokenRange = Range(match.range(at: 0), in: value) else {
                continue
            }
            return String(value[tokenRange])
        }
        return nil
    }

    private func derivePathLabel(from rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let components = normalized
            .split(separator: "/")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        for component in components.reversed() {
            let lower = component.lowercased()
            if [
                "users", "library", "application support", "workspace", "storage", "state", "history",
                "sessions", "projects", "repos", "repositories", "repo", "tmp", "temp"
            ].contains(lower) {
                continue
            }
            if component.range(of: #"\.[A-Za-z]{1,8}$"#, options: .regularExpression) != nil {
                continue
            }
            if component.range(of: #"^[0-9a-f-]{16,}$"#, options: .regularExpression) != nil {
                continue
            }
            return component
        }
        return nil
    }

    private func canonicalProjectKey(_ label: String) -> String {
        let normalized = slug(label)
        if isBlockedProjectSlug(normalized) {
            return "project:unknown"
        }
        let aliasMap: [String: String] = [
            "key-scribe": "openassist",
            "openassist-app": "openassist"
        ]
        let canonical = aliasMap[normalized] ?? normalized
        return "project:\(canonical)"
    }

    private func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let captured = collapseWhitespace(String(value[valueRange]))
        return captured.isEmpty ? nil : captured
    }

    private func splitByStrongSeparators(_ value: String) -> [String] {
        let separators = ["|", "•", " - ", " : "]
        for separator in separators where value.contains(separator) {
            return value
                .components(separatedBy: separator)
                .map(collapseWhitespace)
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func isGroupChatApp(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return ["teams", "slack", "discord", "chat"].contains(where: value.contains)
    }

    private func isLikelyChannelIdentityApp(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        let needles = [
            "teams",
            "slack",
            "discord",
            "telegram",
            "whatsapp",
            "mobilesms",
            "messages",
            "signal",
            "imessage",
            "chat"
        ]
        return needles.contains(where: value.contains)
    }

    private func isTeamsApp(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return value.contains("teams")
    }

    private func isAppleMessagesApp(bundleID: String, appName: String) -> Bool {
        let normalizedBundle = collapseWhitespace(bundleID).lowercased()
        let normalizedName = collapseWhitespace(appName).lowercased()
        if normalizedBundle == "com.apple.mobilesms" {
            return true
        }
        return normalizedName == "messages" || normalizedName.contains("messages")
    }

    private func isBrowser(bundleID: String, appName: String) -> Bool {
        let value = "\(bundleID) \(appName)".lowercased()
        return ["safari", "chrome", "firefox", "arc", "brave", "opera", "edge"].contains(where: value.contains)
    }

    private func isCodexApp(bundleID: String, appName: String) -> Bool {
        let normalizedBundle = collapseWhitespace(bundleID).lowercased()
        let normalizedName = collapseWhitespace(appName).lowercased()
        if normalizedBundle == "com.openai.codex" {
            return true
        }
        return normalizedName == "codex" || normalizedName.contains("codex")
    }

    private func isCodingWorkspaceApp(bundleID: String, appName: String) -> Bool {
        let normalizedBundle = collapseWhitespace(bundleID).lowercased()
        let normalizedName = collapseWhitespace(appName).lowercased()
        let combined = "\(normalizedBundle) \(normalizedName)"

        let bundlePrefixes = [
            "com.microsoft.vscode",
            "com.vscodium",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.apple.dt.xcode",
            "com.jetbrains."
        ]
        if bundlePrefixes.contains(where: normalizedBundle.hasPrefix) {
            return true
        }

        let nameNeedles = [
            "visual studio code",
            "vs code",
            "cursor",
            "xcode",
            "jetbrains",
            "intellij",
            "pycharm",
            "webstorm",
            "android studio",
            "codex",
            "antigravity",
            "anti-gravity"
        ]
        return nameNeedles.contains(where: combined.contains)
    }

    private func slug(_ value: String) -> String {
        let lower = collapseWhitespace(value).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let reduced = lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let joined = String(reduced)
        let collapsedDashes = joined.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        return collapsedDashes.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func collapseWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func stableKey(prefix: String, value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let digestPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return "\(prefix)-\(digestPrefix)"
    }
}
