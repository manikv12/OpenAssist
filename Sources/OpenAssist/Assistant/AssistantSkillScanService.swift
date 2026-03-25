import Foundation

final class AssistantSkillScanService {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let skillsRootOverride: URL?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        skillsRootOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.skillsRootOverride = skillsRootOverride
    }

    var skillsRoot: URL {
        skillsRootOverride
            ?? homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true)
    }

    func scan() -> [AssistantSkillDescriptor] {
        guard let enumerator = fileManager.enumerator(
            at: skillsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        var descriptorsByID: [String: AssistantSkillDescriptor] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "SKILL.md",
                  isRegularFile(fileURL),
                  let descriptor = descriptor(forSkillFileURL: fileURL) else {
                continue
            }

            if descriptorsByID[descriptor.id] == nil {
                descriptorsByID[descriptor.id] = descriptor
            }
        }

        return descriptorsByID.values.sorted { lhs, rhs in
            if lhs.libraryGroup != rhs.libraryGroup {
                return libraryGroupSortOrder(lhs.libraryGroup) < libraryGroupSortOrder(rhs.libraryGroup)
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func descriptor(forSkillDirectoryURL directoryURL: URL) -> AssistantSkillDescriptor? {
        descriptor(forSkillFileURL: directoryURL.appendingPathComponent("SKILL.md", isDirectory: false))
    }

    func metadataFileURL(for skillDirectoryURL: URL) -> URL {
        skillDirectoryURL.appendingPathComponent(".openassist-skill.json", isDirectory: false)
    }

    func readOriginMetadata(for skillDirectoryURL: URL) -> AssistantSkillOriginMetadata? {
        let metadataURL = metadataFileURL(for: skillDirectoryURL)
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(AssistantSkillOriginMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    private func descriptor(forSkillFileURL skillFileURL: URL) -> AssistantSkillDescriptor? {
        guard fileManager.fileExists(atPath: skillFileURL.path),
              let skillContents = try? String(contentsOf: skillFileURL, encoding: .utf8),
              let frontmatter = frontmatterBlock(in: skillContents),
              let rawName = yamlValue(named: "name", in: frontmatter),
              let rawDescription = yamlValue(named: "description", in: frontmatter),
              let normalizedName = assistantNormalizedSkillIdentifier(rawName) else {
            return nil
        }

        let skillDirectoryURL = skillFileURL.deletingLastPathComponent()
        let metadata = readOriginMetadata(for: skillDirectoryURL)
        let openAIValues = parseOpenAIInterface(
            from: (try? String(
                contentsOf: skillDirectoryURL
                    .appendingPathComponent("agents", isDirectory: true)
                    .appendingPathComponent("openai.yaml", isDirectory: false),
                encoding: .utf8
            )) ?? ""
        )

        let canonicalSkillDirectoryPath = skillDirectoryURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let canonicalSystemSkillsRootPath = skillsRoot
            .appendingPathComponent(".system", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let inferredSource: AssistantSkillSource
        if canonicalSkillDirectoryPath == canonicalSystemSkillsRootPath
            || canonicalSkillDirectoryPath.hasPrefix(canonicalSystemSkillsRootPath + "/") {
            inferredSource = .system
        } else if let metadata {
            inferredSource = metadata.source
        } else {
            inferredSource = .user
        }

        let displayName = openAIValues["display_name"]?.nonEmpty
            ?? assistantSkillDisplayName(fromIdentifier: normalizedName)

        return AssistantSkillDescriptor(
            name: normalizedName,
            displayName: displayName,
            description: rawDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            shortDescription: openAIValues["short_description"]?.nonEmpty,
            defaultPrompt: openAIValues["default_prompt"]?.nonEmpty,
            source: inferredSource,
            skillDirectoryPath: skillDirectoryURL.standardizedFileURL.path,
            skillFilePath: skillFileURL.standardizedFileURL.path,
            metadataFilePath: metadataFileURL(for: skillDirectoryURL).path
        )
    }

    private func frontmatterBlock(in contents: String) -> String? {
        guard contents.hasPrefix("---\n") || contents.hasPrefix("---\r\n") else {
            return nil
        }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let components = normalized.components(separatedBy: "\n---\n")
        guard components.count >= 2 else {
            return nil
        }
        return components[0]
            .replacingOccurrences(of: "---\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func yamlValue(named key: String, in contents: String) -> String? {
        let normalizedContents = contents.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalizedContents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let rawValue = trimmed.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return unquoted(rawValue)
        }
        return nil
    }

    private func parseOpenAIInterface(from contents: String) -> [String: String] {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)

        var values: [String: String] = [:]
        var isInsideInterface = false
        var activeMultilineKey: String?
        var activeIndent = 0
        var multilineBuffer: [String] = []

        func finishMultilineValue() {
            guard let key = activeMultilineKey else { return }
            values[key] = multilineBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.consume(&multilineBuffer)
            activeMultilineKey = nil
            activeIndent = 0
        }

        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let activeMultilineKey, !trimmed.isEmpty {
                if indent >= activeIndent {
                    multilineBuffer.append(String(line.dropFirst(activeIndent)))
                    continue
                }
                finishMultilineValue()
                if values[activeMultilineKey] == nil {
                    values[activeMultilineKey] = ""
                }
            }

            if trimmed == "interface:" {
                isInsideInterface = true
                continue
            }

            guard isInsideInterface else { continue }

            if !line.hasPrefix("  ") && !trimmed.isEmpty {
                break
            }

            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if rawValue == "|" || rawValue == ">" {
                activeMultilineKey = key
                activeIndent = indent + 2
                multilineBuffer = []
                continue
            }

            values[key] = unquoted(rawValue)
        }

        if activeMultilineKey != nil {
            finishMultilineValue()
        }

        return values
    }

    private func unquoted<S: StringProtocol>(_ value: S) -> String {
        let trimmed = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return String(trimmed) }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return String(trimmed)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private func libraryGroupSortOrder(_ group: AssistantSkillLibraryGroup) -> Int {
        switch group {
        case .builtIn:
            return 0
        case .mine:
            return 1
        case .imported:
            return 2
        }
    }

    private func consume<T>(_ value: inout T?) {
        value = nil
    }

    private func consume<T>(_ value: inout [T]) {
        value.removeAll()
    }
}
