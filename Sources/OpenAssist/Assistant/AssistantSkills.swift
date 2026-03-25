import Foundation

enum AssistantSkillSource: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case imported
    case generated

    var isReadOnly: Bool {
        self == .system
    }

    var badgeTitle: String {
        switch self {
        case .system:
            return "Built-in"
        case .user:
            return "My Skill"
        case .imported:
            return "Imported"
        case .generated:
            return "Created"
        }
    }

    var symbolName: String {
        switch self {
        case .system:
            return "shippingbox.fill"
        case .user:
            return "wrench.and.screwdriver.fill"
        case .imported:
            return "square.and.arrow.down.fill"
        case .generated:
            return "sparkles.rectangle.stack.fill"
        }
    }
}

enum AssistantSkillLibraryGroup: String, CaseIterable, Identifiable, Sendable {
    case builtIn
    case mine
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn:
            return "Built-in"
        case .mine:
            return "My skills"
        case .imported:
            return "Imported"
        }
    }

    var emptyStateText: String {
        switch self {
        case .builtIn:
            return "No built-in skills were found."
        case .mine:
            return "Create a skill or add one to ~/.codex/skills."
        case .imported:
            return "Import a skill from a folder or GitHub."
        }
    }
}

struct AssistantSkillDescriptor: Identifiable, Equatable, Codable, Sendable {
    let name: String
    var displayName: String
    var description: String
    var shortDescription: String?
    var defaultPrompt: String?
    var source: AssistantSkillSource
    var skillDirectoryPath: String
    var skillFilePath: String
    var metadataFilePath: String?

    var id: String { name }

    var isReadOnly: Bool {
        source.isReadOnly
    }

    var libraryGroup: AssistantSkillLibraryGroup {
        switch source {
        case .system:
            return .builtIn
        case .user, .generated:
            return .mine
        case .imported:
            return .imported
        }
    }

    var skillDirectoryURL: URL {
        URL(fileURLWithPath: skillDirectoryPath, isDirectory: true)
    }

    var skillFileURL: URL {
        URL(fileURLWithPath: skillFilePath, isDirectory: false)
    }

    var metadataFileURL: URL? {
        metadataFilePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    var summaryText: String {
        shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "No description"
    }

    /// Contextual SF Symbol based on the skill's name/description keywords.
    var resolvedSymbolName: String {
        assistantSkillResolvedSymbol(name: name, displayName: displayName, description: description, fallback: source.symbolName)
    }
}

/// Maps common skill keywords to appropriate SF Symbols for richer visual identity.
func assistantSkillResolvedSymbol(name: String, displayName: String, description: String, fallback: String) -> String {
    let haystack = "\(name) \(displayName) \(description)".lowercased()

    let mappings: [(keywords: [String], symbol: String)] = [
        // Documents & writing
        (["pdf", "document", "report"], "doc.richtext.fill"),
        (["markdown", "md ", "readme"], "doc.text.fill"),
        (["obsidian", "note", "notebook"], "note.text"),
        (["write", "draft", "compose", "editor"], "pencil.and.outline"),

        // Code & development
        (["bug", "debug", "fix"], "ladybug.fill"),
        (["test", "spec", "assert", "playwright"], "checkmark.shield.fill"),
        (["github", "git ", "repo", "pull request", "pr "], "arrow.triangle.branch"),
        (["code", "script", "program", "compile"], "chevron.left.forwardslash.chevron.right"),
        (["api", "endpoint", "rest", "graphql"], "network"),
        (["database", "sql", "query", "db "], "cylinder.fill"),
        (["deploy", "ci/cd", "pipeline", "build"], "shippingbox.and.arrow.backward.fill"),
        (["docker", "container", "kubernetes"], "cube.fill"),
        (["terminal", "cli", "command", "shell"], "terminal.fill"),

        // AI & automation
        (["ai ", "openai", "llm", "model", "gpt", "claude"], "brain.fill"),
        (["automat", "workflow", "pipeline"], "gearshape.2.fill"),
        (["skill creator", "create skill", "wizard"], "wand.and.stars"),
        (["skill installer", "install skill"], "arrow.down.app.fill"),
        (["scan", "search", "find", "lookup"], "magnifyingglass"),
        (["chat", "conversation", "message"], "bubble.left.and.bubble.right.fill"),

        // Data & analytics
        (["chart", "graph", "analytics", "metric"], "chart.bar.fill"),
        (["data", "dataset", "csv", "json"], "tablecells.fill"),
        (["image", "photo", "picture", "screenshot"], "photo.fill"),
        (["video", "media", "stream"], "play.rectangle.fill"),
        (["audio", "sound", "voice", "speech"], "waveform"),

        // Web & cloud
        (["web", "browser", "http", "url"], "globe"),
        (["email", "mail", "smtp"], "envelope.fill"),
        (["slack", "telegram", "discord", "notification"], "bell.fill"),
        (["cloud", "aws", "azure", "gcp"], "cloud.fill"),
        (["security", "auth", "encrypt", "password"], "lock.shield.fill"),

        // Files & system
        (["file", "folder", "directory", "import"], "folder.fill"),
        (["config", "setting", "preference"], "gearshape.fill"),
        (["upgrade", "update", "migration"], "arrow.up.circle.fill"),

        // Reference & docs
        (["doc", "reference", "guide", "manual"], "book.fill"),
        (["review", "check", "validate", "lint"], "checklist"),
    ]

    for mapping in mappings {
        for keyword in mapping.keywords {
            if haystack.contains(keyword) {
                return mapping.symbol
            }
        }
    }

    return fallback
}

struct AssistantThreadSkillBinding: Identifiable, Equatable, Codable, Sendable {
    let threadID: String
    let skillName: String
    let attachedAt: Date

    var id: String {
        "\(threadID)::\(skillName)"
    }
}

struct AssistantThreadSkillState: Identifiable, Equatable, Sendable {
    let binding: AssistantThreadSkillBinding
    let descriptor: AssistantSkillDescriptor?

    var id: String { binding.id }

    var skillName: String { binding.skillName }

    var displayName: String {
        descriptor?.displayName.nonEmpty
            ?? assistantSkillDisplayName(fromIdentifier: binding.skillName)
    }

    var summaryText: String {
        descriptor?.summaryText ?? "This skill is missing from ~/.codex/skills."
    }

    var isMissing: Bool {
        descriptor == nil
    }

    var source: AssistantSkillSource? {
        descriptor?.source
    }

    var skillFilePath: String? {
        descriptor?.skillFilePath
    }
}

struct AssistantSkillOriginMetadata: Codable, Equatable, Sendable {
    var version: Int
    var source: AssistantSkillSource
    var originalReference: String?
    var createdAt: Date

    static func make(
        source: AssistantSkillSource,
        originalReference: String? = nil,
        createdAt: Date = Date()
    ) -> AssistantSkillOriginMetadata {
        AssistantSkillOriginMetadata(
            version: 1,
            source: source,
            originalReference: originalReference,
            createdAt: createdAt
        )
    }
}

struct AssistantSkillWizardDraft: Equatable, Sendable {
    var name: String = ""
    var description: String = ""
    var whenToUse: String = ""
    var exampleRequests: String = ""
    var includeOpenAIMetadata: Bool = true
    var includeScriptsDirectory: Bool = false
    var includeReferencesDirectory: Bool = false
    var includeAssetsDirectory: Bool = false

    var normalizedExampleRequests: [String] {
        exampleRequests
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. "))
            }
            .compactMap(\.nonEmpty)
    }
}

struct AssistantSkillPreviewDocument: Equatable, Sendable {
    let examplePrompt: String
    let bodyMarkdown: String
    let fullMarkdown: String
}

func assistantNormalizedSkillIdentifier(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    var scalars: [UnicodeScalar] = []
    var previousWasDash = false

    for scalar in trimmed.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
            previousWasDash = false
        } else if !previousWasDash {
            scalars.append("-")
            previousWasDash = true
        }
    }

    let normalized = String(String.UnicodeScalarView(scalars))
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .replacingOccurrences(
            of: #"-+"#,
            with: "-",
            options: .regularExpression
        )

    return normalized.nonEmpty
}

func assistantSkillDisplayName(fromIdentifier identifier: String) -> String {
    identifier
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .map { fragment in
            guard let first = fragment.first else { return "" }
            return String(first).uppercased() + fragment.dropFirst()
        }
        .joined(separator: " ")
}

func assistantSkillPreviewDocument(for skill: AssistantSkillDescriptor) -> AssistantSkillPreviewDocument {
    let fullMarkdown = (try? String(contentsOf: skill.skillFileURL, encoding: .utf8)) ?? ""
    let bodyMarkdown = assistantSkillBodyMarkdownWithoutLeadingTitle(fullMarkdown)
    let examplePrompt = skill.defaultPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        ?? assistantSkillFirstExampleRequest(in: bodyMarkdown)
        ?? assistantSkillFallbackPrompt(for: skill)

    return AssistantSkillPreviewDocument(
        examplePrompt: examplePrompt,
        bodyMarkdown: bodyMarkdown.nonEmpty ?? "No extra instructions were found in `SKILL.md`.",
        fullMarkdown: fullMarkdown
    )
}

private func assistantSkillBodyMarkdownWithoutLeadingTitle(_ markdown: String) -> String {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let body: String

    if normalized.hasPrefix("---\n"),
       let frontmatterRange = normalized.range(of: "\n---\n") {
        body = String(normalized[frontmatterRange.upperBound...])
    } else {
        body = normalized
    }

    var lines = body.components(separatedBy: .newlines)
    while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.removeFirst()
    }

    if let first = lines.first,
       first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") {
        lines.removeFirst()
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
    }

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func assistantSkillFirstExampleRequest(in markdown: String) -> String? {
    let lines = markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: .newlines)

    var isInsideExampleSection = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        if trimmed.hasPrefix("#") {
            let normalizedHeading = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                .lowercased()
            if normalizedHeading == "example requests" || normalizedHeading == "examples" {
                isInsideExampleSection = true
                continue
            }

            if isInsideExampleSection {
                break
            }
        }

        guard isInsideExampleSection else { continue }

        if let bullet = assistantSkillStrippedListPrefix(trimmed) {
            return bullet
        }
    }

    return nil
}

private func assistantSkillStrippedListPrefix(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    let digits = trimmed.prefix { $0.isNumber }
    if !digits.isEmpty {
        let remainder = trimmed.dropFirst(digits.count)
        if remainder.hasPrefix(". ") || remainder.hasPrefix(") ") {
            return String(remainder.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
    }

    return nil
}

private func assistantSkillFallbackPrompt(for skill: AssistantSkillDescriptor) -> String {
    let summary = skill.summaryText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    return "Use $\(skill.name) when the task matches this workflow: \(summary)."
}
