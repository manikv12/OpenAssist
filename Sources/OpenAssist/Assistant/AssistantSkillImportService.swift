import Foundation

enum AssistantSkillImportError: LocalizedError {
    case invalidSkillFolder
    case duplicateSkillName(String)
    case readOnlySkill
    case unsupportedGitHubReference
    case gitFailed(String)
    case importedSkillNotFound

    var errorDescription: String? {
        switch self {
        case .invalidSkillFolder:
            return "That folder does not contain a valid Codex skill."
        case .duplicateSkillName(let name):
            return "A skill named “\(name)” already exists. Rename it or use the existing one."
        case .readOnlySkill:
            return "Built-in skills are read-only."
        case .unsupportedGitHubReference:
            return "Use a GitHub tree URL or an owner/repo/path reference."
        case .gitFailed(let message):
            return message
        case .importedSkillNotFound:
            return "The imported skill could not be found after copying."
        }
    }
}

final class AssistantSkillImportService {
    private struct GitHubSkillReference {
        let owner: String
        let repository: String
        let ref: String
        let path: String
        let originalInput: String
    }

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let scanService: AssistantSkillScanService
    private let runner: CommandRunning

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scanService: AssistantSkillScanService? = nil,
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.scanService = scanService ?? AssistantSkillScanService(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        self.runner = runner
    }

    var skillsRoot: URL {
        scanService.skillsRoot
    }

    func importSkill(
        fromFolderURL folderURL: URL,
        source: AssistantSkillSource = .imported,
        originalReference: String? = nil,
        preferredName: String? = nil
    ) throws -> AssistantSkillDescriptor {
        let sourceDirectoryURL = try resolveSkillDirectory(from: folderURL)
        let sourceDescriptor = try descriptorOrThrow(for: sourceDirectoryURL)
        let destinationName = try destinationSkillName(
            preferredName: preferredName,
            fallbackName: sourceDescriptor.name
        )
        let destinationDirectoryURL = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)

        guard destinationDirectoryURL.standardizedFileURL.path != sourceDirectoryURL.standardizedFileURL.path else {
            throw AssistantSkillImportError.duplicateSkillName(destinationName)
        }
        guard !fileManager.fileExists(atPath: destinationDirectoryURL.path) else {
            throw AssistantSkillImportError.duplicateSkillName(destinationName)
        }

        try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceDirectoryURL, to: destinationDirectoryURL)
        try writeMetadata(
            AssistantSkillOriginMetadata.make(
                source: source,
                originalReference: originalReference ?? sourceDirectoryURL.path
            ),
            toSkillDirectory: destinationDirectoryURL
        )

        guard let descriptor = scanService.descriptor(forSkillDirectoryURL: destinationDirectoryURL) else {
            throw AssistantSkillImportError.importedSkillNotFound
        }
        return descriptor
    }

    func duplicateSkill(_ descriptor: AssistantSkillDescriptor) throws -> AssistantSkillDescriptor {
        guard !descriptor.isReadOnly else {
            throw AssistantSkillImportError.readOnlySkill
        }

        let destinationName = try uniqueDuplicateName(basedOn: descriptor.name)
        return try importSkill(
            fromFolderURL: descriptor.skillDirectoryURL,
            source: .generated,
            originalReference: descriptor.skillDirectoryPath,
            preferredName: destinationName
        )
    }

    func deleteSkill(_ descriptor: AssistantSkillDescriptor) throws {
        guard !descriptor.isReadOnly else {
            throw AssistantSkillImportError.readOnlySkill
        }
        try fileManager.removeItem(at: descriptor.skillDirectoryURL)
    }

    func importSkill(
        fromGitHubReference reference: String,
        preferredName: String? = nil
    ) async throws -> AssistantSkillDescriptor {
        let parsedReference = try parseGitHubReference(reference)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openassist-skill-import-\(UUID().uuidString)", isDirectory: true)
        let checkoutDirectoryURL = temporaryRoot.appendingPathComponent("repo", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        var cloneArguments = [
            "clone",
            "--depth", "1",
            "--filter=blob:none",
            "--sparse",
            "https://github.com/\(parsedReference.owner)/\(parsedReference.repository).git",
            checkoutDirectoryURL.path
        ]
        if parsedReference.ref != "main" {
            cloneArguments.insert(contentsOf: ["--branch", parsedReference.ref], at: 1)
        }
        try await runGit(arguments: cloneArguments)
        try await runGit(arguments: [
            "-C", checkoutDirectoryURL.path,
            "sparse-checkout", "set", "--no-cone", parsedReference.path
        ])

        let sourceDirectoryURL = checkoutDirectoryURL
            .appendingPathComponent(parsedReference.path, isDirectory: true)
        return try importSkill(
            fromFolderURL: sourceDirectoryURL,
            source: .imported,
            originalReference: parsedReference.originalInput,
            preferredName: preferredName
        )
    }

    private func resolveSkillDirectory(from url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return standardizedURL
            }

            if standardizedURL.lastPathComponent == "SKILL.md" {
                return standardizedURL.deletingLastPathComponent()
            }
        }
        throw AssistantSkillImportError.invalidSkillFolder
    }

    private func descriptorOrThrow(for directoryURL: URL) throws -> AssistantSkillDescriptor {
        guard let descriptor = scanService.descriptor(forSkillDirectoryURL: directoryURL) else {
            throw AssistantSkillImportError.invalidSkillFolder
        }
        return descriptor
    }

    private func destinationSkillName(
        preferredName: String?,
        fallbackName: String
    ) throws -> String {
        guard let destinationName = assistantNormalizedSkillIdentifier(preferredName ?? fallbackName) else {
            throw AssistantSkillImportError.invalidSkillFolder
        }
        return destinationName
    }

    private func uniqueDuplicateName(basedOn skillName: String) throws -> String {
        let base = assistantNormalizedSkillIdentifier(skillName) ?? skillName
        for index in 1...200 {
            let suffix = index == 1 ? "-copy" : "-copy-\(index)"
            let candidate = base + suffix
            let destinationURL = skillsRoot.appendingPathComponent(candidate, isDirectory: true)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                return candidate
            }
        }
        throw AssistantSkillImportError.duplicateSkillName(base)
    }

    private func writeMetadata(
        _ metadata: AssistantSkillOriginMetadata,
        toSkillDirectory directoryURL: URL
    ) throws {
        let metadataURL = scanService.metadataFileURL(for: directoryURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func parseGitHubReference(_ reference: String) throws -> GitHubSkillReference {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantSkillImportError.unsupportedGitHubReference
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host.contains("github.com") {
            let components = url.path
                .split(separator: "/")
                .map(String.init)
            guard components.count >= 5,
                  components[2] == "tree" || components[2] == "blob" else {
                throw AssistantSkillImportError.unsupportedGitHubReference
            }
            return GitHubSkillReference(
                owner: components[0],
                repository: components[1],
                ref: components[3],
                path: components.dropFirst(4).joined(separator: "/"),
                originalInput: trimmed
            )
        }

        let pathAndRef = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        let rawPath = pathAndRef[0]
        let ref = pathAndRef.count > 1 ? pathAndRef[1] : "main"
        let components = rawPath.split(separator: "/").map(String.init)
        guard components.count >= 3 else {
            throw AssistantSkillImportError.unsupportedGitHubReference
        }

        return GitHubSkillReference(
            owner: components[0],
            repository: components[1],
            ref: ref,
            path: components.dropFirst(2).joined(separator: "/"),
            originalInput: trimmed
        )
    }

    private func runGit(arguments: [String]) async throws {
        let result = try await runner.run("/usr/bin/git", arguments: arguments)
        guard result.exitCode == 0 else {
            let message = result.stderr.assistantNonEmpty
                ?? result.stdout.assistantNonEmpty
                ?? "Git failed while importing the skill."
            throw AssistantSkillImportError.gitFailed(message)
        }
    }
}
