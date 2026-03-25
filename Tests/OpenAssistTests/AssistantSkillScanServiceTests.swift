import Foundation
import XCTest
@testable import OpenAssist

final class AssistantSkillScanServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testScanFindsSystemUserAndImportedSkills() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-scan-home")
        let skillsRoot = homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true)

        try writeSkill(
            at: skillsRoot.appendingPathComponent(".system/checks", isDirectory: true),
            name: "checks",
            description: "Run the project checks.",
            openAIYAML: """
            interface:
              display_name: "Checks Pro"
              short_description: "Run quick checks"
              default_prompt: "Use $checks before merging."
            """
        )
        try writeSkill(
            at: skillsRoot.appendingPathComponent("daily-notes", isDirectory: true),
            name: "daily-notes",
            description: "Update the team notes."
        )
        try writeSkill(
            at: skillsRoot.appendingPathComponent("pdf-helper", isDirectory: true),
            name: "pdf-helper",
            description: "Review PDF layouts.",
            metadata: .make(source: .imported, originalReference: "github.com/example/pdf-helper")
        )

        let invalidDirectory = skillsRoot.appendingPathComponent("invalid-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try """
        # Missing frontmatter
        This is not a valid skill.
        """.write(
            to: invalidDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let service = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )

        let descriptors = service.scan()

        XCTAssertEqual(descriptors.map(\.name), ["checks", "daily-notes", "pdf-helper"])

        let builtIn = try XCTUnwrap(descriptors.first { $0.name == "checks" })
        XCTAssertEqual(builtIn.source, .system)
        XCTAssertEqual(builtIn.libraryGroup, .builtIn)
        XCTAssertEqual(builtIn.displayName, "Checks Pro")
        XCTAssertEqual(builtIn.shortDescription, "Run quick checks")
        XCTAssertEqual(builtIn.defaultPrompt, "Use $checks before merging.")

        let mySkill = try XCTUnwrap(descriptors.first { $0.name == "daily-notes" })
        XCTAssertEqual(mySkill.source, .user)
        XCTAssertEqual(mySkill.libraryGroup, .mine)

        let imported = try XCTUnwrap(descriptors.first { $0.name == "pdf-helper" })
        XCTAssertEqual(imported.source, .imported)
        XCTAssertEqual(imported.libraryGroup, .imported)
    }

    private func writeSkill(
        at directory: URL,
        name: String,
        description: String,
        openAIYAML: String? = nil,
        metadata: AssistantSkillOriginMetadata? = nil
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let markdown = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(assistantSkillDisplayName(fromIdentifier: name))

        Use this skill when it helps.
        """
        try markdown.write(
            to: directory.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        if let openAIYAML {
            let agentsDirectory = directory.appendingPathComponent("agents", isDirectory: true)
            try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            try openAIYAML.write(
                to: agentsDirectory.appendingPathComponent("openai.yaml", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        if let metadata {
            let data = try JSONEncoder().encode(metadata)
            try data.write(
                to: directory.appendingPathComponent(".openassist-skill.json", isDirectory: false),
                options: .atomic
            )
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
