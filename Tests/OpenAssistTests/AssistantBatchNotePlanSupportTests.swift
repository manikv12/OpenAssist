import XCTest
@testable import OpenAssist

final class AssistantBatchNotePlanSupportTests: XCTestCase {
    func testLegacyNoteManifestDefaultsMissingNoteTypeToNote() throws {
        let data = Data(
            """
            {
              "version": 1,
              "selectedNoteID": "note-1",
              "notes": [
                {
                  "id": "note-1",
                  "title": "Runbook",
                  "fileName": "note-1.md",
                  "order": 0,
                  "createdAt": 1000,
                  "updatedAt": 1001
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(AssistantNoteManifest.self, from: data)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.notes.count, 1)
        XCTAssertEqual(manifest.notes.first?.noteType, .note)
    }

    func testBatchNotePlanParserAcceptsStructuredJSON() throws {
        let output = try AssistantBatchNotePlanParser.parseResponse(
            """
            {
              "notes": [
                {
                  "tempId": "master-note",
                  "title": "Project Master Note",
                  "noteType": "master",
                  "markdown": "# Summary\\n\\nImportant details.",
                  "sourceNoteRefs": ["S1", "S2"]
                },
                {
                  "tempId": "decision-auth",
                  "title": "Auth Decision",
                  "noteType": "decision",
                  "markdown": "Use OAuth.",
                  "sourceNoteRefs": ["S2"]
                }
              ],
              "links": [
                {
                  "fromTempId": "master-note",
                  "toTarget": {
                    "kind": "proposed",
                    "ref": "decision-auth"
                  }
                },
                {
                  "fromTempId": "decision-auth",
                  "toTarget": {
                    "kind": "source",
                    "ref": "S2"
                  }
                }
              ]
            }
            """,
            allowedSourceRefs: ["S1", "S2"]
        )

        XCTAssertEqual(output.notes.count, 2)
        XCTAssertEqual(output.notes.first?.noteType, .master)
        XCTAssertEqual(output.links.count, 2)
        XCTAssertEqual(output.links.last?.toTarget.kind, .source)
    }

    func testBatchNotePlanParserRejectsDuplicateTempIDs() {
        XCTAssertThrowsError(
            try AssistantBatchNotePlanParser.parseResponse(
                """
                {
                  "notes": [
                    {
                      "tempId": "dup-note",
                      "title": "One",
                      "noteType": "master",
                      "markdown": "A",
                      "sourceNoteRefs": ["S1"]
                    },
                    {
                      "tempId": "dup-note",
                      "title": "Two",
                      "noteType": "note",
                      "markdown": "B",
                      "sourceNoteRefs": ["S1"]
                    }
                  ],
                  "links": []
                }
                """,
                allowedSourceRefs: ["S1"]
            )
        ) { error in
            XCTAssertEqual(
                error as? AssistantBatchNotePlanParser.ParseError,
                .duplicateTempID("dup-note")
            )
        }
    }

    func testBatchNotePlanParserRejectsInvalidNoteType() {
        XCTAssertThrowsError(
            try AssistantBatchNotePlanParser.parseResponse(
                """
                {
                  "notes": [
                    {
                      "tempId": "master-note",
                      "title": "Overview",
                      "noteType": "summary",
                      "markdown": "A",
                      "sourceNoteRefs": ["S1"]
                    }
                  ],
                  "links": []
                }
                """,
                allowedSourceRefs: ["S1"]
            )
        ) { error in
            XCTAssertEqual(
                error as? AssistantBatchNotePlanParser.ParseError,
                .invalidNoteType("summary")
            )
        }
    }

    func testComposeMarkdownCreatesLinksThatFeedTheExistingGraphBuilder() {
        let currentTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "master-note"
        )
        let sourceTarget = AssistantNoteLinkTarget(
            ownerKind: .thread,
            ownerID: "thread-1",
            noteID: "source-note"
        )
        let relatedTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "decision-note"
        )

        let markdown = AssistantBatchNotePlanComposer.composeMarkdown(
            baseMarkdown: "# Summary\n\nCollected details.",
            sourceLinks: [
                AssistantBatchNotePlanComposedLink(
                    title: "Source note",
                    href: AssistantNoteLinkCodec.urlString(for: sourceTarget)
                )
            ],
            relatedLinks: [
                AssistantBatchNotePlanComposedLink(
                    title: "Decision note",
                    href: AssistantNoteLinkCodec.urlString(for: relatedTarget)
                )
            ]
        )

        let snapshot = AssistantNoteRelationshipBuilder.buildSnapshot(
            currentTarget: currentTarget,
            notes: [
                AssistantStoredNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "master-note",
                    title: "Master note",
                    noteType: .master,
                    fileName: "master-note.md",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    text: markdown
                ),
                AssistantStoredNote(
                    ownerKind: .thread,
                    ownerID: "thread-1",
                    noteID: "source-note",
                    title: "Source note",
                    noteType: .note,
                    fileName: "source-note.md",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
                    text: ""
                ),
                AssistantStoredNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "decision-note",
                    title: "Decision note",
                    noteType: .decision,
                    fileName: "decision-note.md",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_002),
                    text: ""
                ),
            ],
            sourceLabelForOwner: sourceLabel
        )

        XCTAssertEqual(snapshot.outgoingLinks.count, 2)
        XCTAssertEqual(snapshot.graph?.nodeCount, 3)
        XCTAssertEqual(snapshot.graph?.edgeCount, 2)
        XCTAssertEqual(
            snapshot.outgoingLinks.map { $0.title }.sorted(),
            ["Decision note", "Source note"]
        )
    }

    private func sourceLabel(
        for ownerKind: AssistantNoteOwnerKind,
        ownerID _: String
    ) -> String {
        switch ownerKind {
        case .thread:
            return "Thread notes"
        case .project:
            return "Project notes"
        }
    }
}
