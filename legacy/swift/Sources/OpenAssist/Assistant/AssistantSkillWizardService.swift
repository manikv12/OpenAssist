import Foundation

enum AssistantSkillWizardError: LocalizedError {
    case invalidName
    case missingDescription
    case duplicateSkillName(String)
    case generatedSkillNotFound

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a short skill name first."
        case .missingDescription:
            return "Add a short description for the skill."
        case .duplicateSkillName(let name):
            return "A skill named “\(name)” already exists."
        case .generatedSkillNotFound:
            return "The new skill could not be read after creation."
        }
    }
}

final class AssistantSkillWizardService {
    private let fileManager: FileManager
    private let scanService: AssistantSkillScanService

    init(
        fileManager: FileManager = .default,
        scanService: AssistantSkillScanService = AssistantSkillScanService()
    ) {
        self.fileManager = fileManager
        self.scanService = scanService
    }

    func createSkill(from draft: AssistantSkillWizardDraft) throws -> AssistantSkillDescriptor {
        guard let normalizedName = assistantNormalizedSkillIdentifier(draft.name) else {
            throw AssistantSkillWizardError.invalidName
        }
        guard draft.description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            throw AssistantSkillWizardError.missingDescription
        }

        let skillDirectoryURL = scanService.skillsRoot.appendingPathComponent(normalizedName, isDirectory: true)
        guard !fileManager.fileExists(atPath: skillDirectoryURL.path) else {
            throw AssistantSkillWizardError.duplicateSkillName(normalizedName)
        }

        try fileManager.createDirectory(at: skillDirectoryURL, withIntermediateDirectories: true)
        try buildOptionalDirectories(for: draft, under: skillDirectoryURL)

        let skillMarkdown = buildSkillMarkdown(
            draft: draft,
            normalizedName: normalizedName,
            displayName: assistantSkillDisplayName(fromIdentifier: normalizedName)
        )
        try skillMarkdown.write(
            to: skillDirectoryURL.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        if draft.includeOpenAIMetadata {
            let agentsDirectoryURL = skillDirectoryURL.appendingPathComponent("agents", isDirectory: true)
            try fileManager.createDirectory(at: agentsDirectoryURL, withIntermediateDirectories: true)
            try buildOpenAIYAML(
                draft: draft,
                normalizedName: normalizedName,
                displayName: assistantSkillDisplayName(fromIdentifier: normalizedName)
            ).write(
                to: agentsDirectoryURL.appendingPathComponent("openai.yaml", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(
            AssistantSkillOriginMetadata.make(source: .generated)
        )
        try metadata.write(
            to: scanService.metadataFileURL(for: skillDirectoryURL),
            options: .atomic
        )

        guard let descriptor = scanService.descriptor(forSkillDirectoryURL: skillDirectoryURL) else {
            throw AssistantSkillWizardError.generatedSkillNotFound
        }
        return descriptor
    }

    private func buildOptionalDirectories(
        for draft: AssistantSkillWizardDraft,
        under skillDirectoryURL: URL
    ) throws {
        if draft.includeScriptsDirectory {
            try fileManager.createDirectory(
                at: skillDirectoryURL.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        if draft.includeReferencesDirectory {
            try fileManager.createDirectory(
                at: skillDirectoryURL.appendingPathComponent("references", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        if draft.includeAssetsDirectory {
            try fileManager.createDirectory(
                at: skillDirectoryURL.appendingPathComponent("assets", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func buildSkillMarkdown(
        draft: AssistantSkillWizardDraft,
        normalizedName: String,
        displayName: String
    ) -> String {
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let whenToUse = draft.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? description
        let examples = draft.normalizedExampleRequests

        var sections: [String] = [
            "---",
            "name: \(normalizedName)",
            "description: \(description)",
            "metadata:",
            "  short-description: \(yamlQuotedValue(description))",
            "---",
            "",
            "# \(displayName)",
            "",
            "Use this skill when \(whenToUse).",
            "",
            "## Workflow",
            "",
            "- Read this skill before doing the task.",
            "- Use bundled scripts or references when they help.",
            "- Keep the final answer simple and practical."
        ]

        if !examples.isEmpty {
            sections.append(contentsOf: [
                "",
                "## Example Requests",
                ""
            ] + examples.map { "- \($0)" })
        }

        if draft.includeScriptsDirectory || draft.includeReferencesDirectory || draft.includeAssetsDirectory {
            sections.append(contentsOf: [
                "",
                "## Bundled Resources",
                ""
            ])
            if draft.includeScriptsDirectory {
                sections.append("- `scripts/`: Deterministic helpers for repeated tasks.")
            }
            if draft.includeReferencesDirectory {
                sections.append("- `references/`: Detailed docs to load only when needed.")
            }
            if draft.includeAssetsDirectory {
                sections.append("- `assets/`: Templates or files used in the final output.")
            }
        }

        sections.append("")
        return sections.joined(separator: "\n")
    }

    private func buildOpenAIYAML(
        draft: AssistantSkillWizardDraft,
        normalizedName: String,
        displayName: String
    ) -> String {
        let shortDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let whenToUse = draft.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? shortDescription
        let prompt = "Use $\(normalizedName) when \(whenToUse)."

        return """
        interface:
          display_name: \(yamlQuotedValue(displayName))
          short_description: \(yamlQuotedValue(shortDescription))
          default_prompt: \(yamlQuotedValue(prompt))
        """
    }

    private func yamlQuotedValue(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
