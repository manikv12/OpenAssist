import XCTest
@testable import OpenAssist

final class AssistantNoteLinkSupportTests: XCTestCase {
    func testNoteLinkCodecRoundTripsURLAndMarkdownParsing() {
        let target = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "note-1"
        )

        let urlString = AssistantNoteLinkCodec.urlString(for: target)
        XCTAssertTrue(urlString.hasPrefix("oa-note://open?"))
        XCTAssertEqual(AssistantNoteLinkCodec.parseTarget(from: urlString), target)

        let markdown = """
        See \(AssistantNoteLinkCodec.markdownLink(label: "Plan [A]", target: target)) next.
        """
        let parsedLinks = AssistantNoteLinkParser.parseLinks(in: markdown)

        XCTAssertEqual(
            parsedLinks,
            [
                AssistantParsedNoteLink(
                    label: "Plan [A]",
                    target: target
                )
            ]
        )
    }

    func testRelationshipBuilderBuildsCrossSourceOutgoingLinksBacklinksAndGraph() {
        let currentTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "master-note"
        )
        let threadTarget = AssistantNoteLinkTarget(
            ownerKind: .thread,
            ownerID: "thread-1",
            noteID: "thread-note"
        )
        let projectTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "rollout-note"
        )

        let snapshot = AssistantNoteRelationshipBuilder.buildSnapshot(
            currentTarget: currentTarget,
            notes: [
                storedNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "master-note",
                    title: "Master note",
                    text: """
                    \(AssistantNoteLinkCodec.markdownLink(label: "Thread runbook", target: threadTarget))
                    \(AssistantNoteLinkCodec.markdownLink(label: "Rollout plan", target: projectTarget))
                    \(AssistantNoteLinkCodec.markdownLink(label: "Thread runbook", target: threadTarget))
                    """
                ),
                storedNote(
                    ownerKind: .thread,
                    ownerID: "thread-1",
                    noteID: "thread-note",
                    title: "Thread runbook",
                    text: AssistantNoteLinkCodec.markdownLink(label: "Master note", target: currentTarget)
                ),
                storedNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "rollout-note",
                    title: "Rollout plan",
                    text: ""
                ),
            ],
            sourceLabelForOwner: sourceLabel
        )

        XCTAssertEqual(snapshot.outgoingLinks.count, 2)
        XCTAssertEqual(snapshot.backlinks.count, 1)

        let threadOutgoing = snapshot.outgoingLinks.first { $0.target == threadTarget }
        XCTAssertEqual(threadOutgoing?.title, "Thread runbook")
        XCTAssertEqual(threadOutgoing?.sourceLabel, "Thread notes")
        XCTAssertEqual(threadOutgoing?.occurrenceCount, 2)
        XCTAssertEqual(threadOutgoing?.isMissing, false)

        let projectOutgoing = snapshot.outgoingLinks.first { $0.target == projectTarget }
        XCTAssertEqual(projectOutgoing?.title, "Rollout plan")
        XCTAssertEqual(projectOutgoing?.sourceLabel, "Project notes")
        XCTAssertEqual(projectOutgoing?.occurrenceCount, 1)

        let backlink = snapshot.backlinks.first
        XCTAssertEqual(backlink?.target, threadTarget)
        XCTAssertEqual(backlink?.title, "Thread runbook")
        XCTAssertEqual(backlink?.sourceLabel, "Thread notes")
        XCTAssertEqual(backlink?.occurrenceCount, 1)

        XCTAssertEqual(snapshot.graph?.nodeCount, 3)
        XCTAssertEqual(snapshot.graph?.edgeCount, 3)
        XCTAssertTrue(snapshot.graph?.mermaidCode.contains("click N0 href") == true)
    }

    func testRelationshipBuilderUsesTargetNoteTitleAfterRename() {
        let currentTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "master-note"
        )
        let renamedTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "stable-note-id"
        )

        let snapshot = AssistantNoteRelationshipBuilder.buildSnapshot(
            currentTarget: currentTarget,
            notes: [
                storedNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "master-note",
                    title: "Master note",
                    text: AssistantNoteLinkCodec.markdownLink(label: "Old title", target: renamedTarget)
                ),
                storedNote(
                    ownerKind: .project,
                    ownerID: "project-1",
                    noteID: "stable-note-id",
                    title: "Renamed title",
                    text: ""
                ),
            ],
            sourceLabelForOwner: sourceLabel
        )

        XCTAssertEqual(snapshot.outgoingLinks.count, 1)
        XCTAssertEqual(snapshot.outgoingLinks.first?.title, "Renamed title")
        XCTAssertEqual(snapshot.outgoingLinks.first?.target.noteID, "stable-note-id")
    }

    func testRelationshipBuilderMarksDeletedTargetsAsMissingAndKeepsThemOutOfGraph() {
        let currentTarget = AssistantNoteLinkTarget(
            ownerKind: .thread,
            ownerID: "thread-1",
            noteID: "master-note"
        )
        let missingTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "deleted-note"
        )

        let snapshot = AssistantNoteRelationshipBuilder.buildSnapshot(
            currentTarget: currentTarget,
            notes: [
                storedNote(
                    ownerKind: .thread,
                    ownerID: "thread-1",
                    noteID: "master-note",
                    title: "Master note",
                    text: AssistantNoteLinkCodec.markdownLink(label: "Deleted note", target: missingTarget)
                )
            ],
            sourceLabelForOwner: sourceLabel
        )

        XCTAssertEqual(snapshot.outgoingLinks.count, 1)
        XCTAssertEqual(snapshot.outgoingLinks.first?.title, "Deleted note")
        XCTAssertEqual(snapshot.outgoingLinks.first?.sourceLabel, "Missing note")
        XCTAssertEqual(snapshot.outgoingLinks.first?.isMissing, true)
        XCTAssertTrue(snapshot.backlinks.isEmpty)
        XCTAssertNil(snapshot.graph)
    }

    private func storedNote(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        title: String,
        text: String
    ) -> AssistantStoredNote {
        AssistantStoredNote(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID,
            title: title,
            noteType: .note,
            fileName: "\(noteID).md",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: text
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
