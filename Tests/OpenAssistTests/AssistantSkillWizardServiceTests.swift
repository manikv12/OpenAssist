import Foundation
import XCTest
@testable import OpenAssist

final class AssistantSkillWizardServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCreateSkillWritesCodexCompatibleStructure() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-wizard-home")
        let scanService = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )
        let wizard = AssistantSkillWizardService(
            fileManager: .default,
            scanService: scanService
        )

        let draft = AssistantSkillWizardDraft(
            name: "Meeting Notes",
            description: "Summarize meeting notes into simple next steps.",
            whenToUse: "the user wants a short meeting recap",
            exampleRequests: """
            Summarize this meeting transcript
            Turn these notes into action items
            """,
            includeOpenAIMetadata: true,
            includeScriptsDirectory: true,
            includeReferencesDirectory: true,
            includeAssetsDirectory: true
        )

        let descriptor = try wizard.createSkill(from: draft)

        XCTAssertEqual(descriptor.name, "meeting-notes")
        XCTAssertEqual(descriptor.source, .generated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.skillFilePath))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: descriptor.skillDirectoryURL
                    .appendingPathComponent("agents/openai.yaml", isDirectory: false).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: descriptor.skillDirectoryURL
                    .appendingPathComponent("scripts", isDirectory: true).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: descriptor.skillDirectoryURL
                    .appendingPathComponent("references", isDirectory: true).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: descriptor.skillDirectoryURL
                    .appendingPathComponent("assets", isDirectory: true).path
            )
        )

        let markdown = try String(contentsOf: descriptor.skillFileURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("name: meeting-notes"))
        XCTAssertTrue(markdown.contains("## Example Requests"))
        XCTAssertTrue(markdown.contains("Summarize this meeting transcript"))

        let metadata = try XCTUnwrap(scanService.readOriginMetadata(for: descriptor.skillDirectoryURL))
        XCTAssertEqual(metadata.source, .generated)
    }

    func testCreateSkillRejectsDuplicateName() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "assistant-skill-wizard-duplicate")
        let scanService = AssistantSkillScanService(
            fileManager: .default,
            homeDirectory: homeDirectory
        )
        let wizard = AssistantSkillWizardService(
            fileManager: .default,
            scanService: scanService
        )

        let draft = AssistantSkillWizardDraft(
            name: "Release Notes",
            description: "Draft short release notes.",
            whenToUse: "",
            exampleRequests: "",
            includeOpenAIMetadata: false,
            includeScriptsDirectory: false,
            includeReferencesDirectory: false,
            includeAssetsDirectory: false
        )

        _ = try wizard.createSkill(from: draft)

        XCTAssertThrowsError(try wizard.createSkill(from: draft)) { error in
            guard case .duplicateSkillName(let name) = error as? AssistantSkillWizardError else {
                return XCTFail("Expected duplicate skill name error, got \(error)")
            }
            XCTAssertEqual(name, "release-notes")
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
