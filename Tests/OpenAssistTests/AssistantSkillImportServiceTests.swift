import Foundation
import XCTest
@testable import OpenAssist

final class AssistantSkillImportServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testImportSkillFromFolderCopiesSkillAndMetadata() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-import-home")
        let externalDirectory = try makeTemporaryDirectory(named: "assistant-skill-import-source")
            .appendingPathComponent("release-helper", isDirectory: true)
        try writeSkill(
            at: externalDirectory,
            name: "release-helper",
            description: "Prepare release notes."
        )

        let scanService = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )
        let service = AssistantSkillImportService(
            fileManager: .default,
            homeDirectory: homeDirectory,
            scanService: scanService,
            runner: GitNoopRunner()
        )

        let descriptor = try service.importSkill(fromFolderURL: externalDirectory)

        XCTAssertEqual(descriptor.name, "release-helper")
        XCTAssertEqual(descriptor.source, .imported)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: scanService.skillsRoot
                    .appendingPathComponent("release-helper/SKILL.md", isDirectory: false).path
            )
        )

        let metadata = try XCTUnwrap(scanService.readOriginMetadata(for: descriptor.skillDirectoryURL))
        XCTAssertEqual(metadata.source, .imported)
        XCTAssertEqual(metadata.originalReference, externalDirectory.path)
    }

    func testImportSkillRejectsDuplicateNames() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-import-duplicate-home")
        let firstSource = try makeTemporaryDirectory(named: "assistant-skill-import-first")
            .appendingPathComponent("qa-helper", isDirectory: true)
        let secondSource = try makeTemporaryDirectory(named: "assistant-skill-import-second")
            .appendingPathComponent("qa-helper", isDirectory: true)
        try writeSkill(at: firstSource, name: "qa-helper", description: "Check QA tasks.")
        try writeSkill(at: secondSource, name: "qa-helper", description: "Check QA tasks again.")

        let scanService = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )
        let service = AssistantSkillImportService(
            fileManager: .default,
            homeDirectory: homeDirectory,
            scanService: scanService,
            runner: GitNoopRunner()
        )

        _ = try service.importSkill(fromFolderURL: firstSource)

        XCTAssertThrowsError(try service.importSkill(fromFolderURL: secondSource)) { error in
            guard case .duplicateSkillName(let name) = error as? AssistantSkillImportError else {
                return XCTFail("Expected duplicate skill name error, got \(error)")
            }
            XCTAssertEqual(name, "qa-helper")
        }
    }

    func testImportSkillFromGitHubReferenceAcceptsShortOwnerRepoPath() async throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-import-github-home")
        let scanService = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )
        let runner = MockGitHubSkillImportRunner()
        let service = AssistantSkillImportService(
            fileManager: .default,
            homeDirectory: homeDirectory,
            scanService: scanService,
            runner: runner
        )

        let descriptor = try await service.importSkill(
            fromGitHubReference: "openai/skills/github-skill"
        )
        let calls = await runner.calls

        XCTAssertEqual(descriptor.name, "github-skill")
        XCTAssertEqual(descriptor.source, .imported)
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.first?.arguments.contains("https://github.com/openai/skills.git") == true)

        let metadata = try XCTUnwrap(scanService.readOriginMetadata(for: descriptor.skillDirectoryURL))
        XCTAssertEqual(metadata.source, .imported)
        XCTAssertEqual(metadata.originalReference, "openai/skills/github-skill")
    }

    private func writeSkill(
        at directory: URL,
        name: String,
        description: String
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(assistantSkillDisplayName(fromIdentifier: name))

        Use this skill when it helps.
        """.write(
            to: directory.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

private struct GitNoopRunner: CommandRunning {
    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult {
        CommandExecutionResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor MockGitHubSkillImportRunner: CommandRunning {
    struct Call: Sendable {
        let launchPath: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(_ launchPath: String, arguments: [String]) async throws -> CommandExecutionResult {
        calls.append(Call(launchPath: launchPath, arguments: arguments))

        if arguments.first == "clone", let destinationPath = arguments.last {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: destinationPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            return CommandExecutionResult(exitCode: 0, stdout: "", stderr: "")
        }

        if arguments.count >= 6,
           arguments[0] == "-C",
           arguments[2] == "sparse-checkout",
           arguments[3] == "set",
           let repositoryPath = arguments.dropFirst().first,
           let relativePath = arguments.last {
            let skillDirectory = URL(fileURLWithPath: repositoryPath, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try """
            ---
            name: github-skill
            description: Import from GitHub.
            ---

            # GitHub Skill

            Use this skill after importing it.
            """.write(
                to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
            return CommandExecutionResult(exitCode: 0, stdout: "", stderr: "")
        }

        return CommandExecutionResult(exitCode: 1, stdout: "", stderr: "unsupported command")
    }
}
