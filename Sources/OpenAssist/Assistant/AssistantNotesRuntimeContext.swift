import Foundation

enum AssistantTaskMode: String, CaseIterable, Codable, Sendable {
    case chat
    case note

    var label: String {
        switch self {
        case .chat:
            return "Chat"
        case .note:
            return "Note"
        }
    }
}

enum AssistantNotesRuntimeSource: String, Codable, Sendable {
    case chatNoteMode
    case notesWorkspace
}

struct AssistantNotesRuntimeContext: Equatable, Sendable {
    struct WorkspaceNoteReference: Equatable, Sendable {
        let target: AssistantNoteLinkTarget
        let title: String
        let sourceLabel: String
        let folderPath: [String]
        let fileName: String?
        let isSelected: Bool
    }

    let source: AssistantNotesRuntimeSource
    let projectID: String
    let projectName: String
    let selectedNoteTarget: AssistantNoteLinkTarget?
    let selectedNoteTitle: String?
    let defaultScopeDescription: String
    let workspaceScopeLabel: String?
    let workspaceNotes: [WorkspaceNoteReference]

    init(
        source: AssistantNotesRuntimeSource,
        projectID: String,
        projectName: String,
        selectedNoteTarget: AssistantNoteLinkTarget?,
        selectedNoteTitle: String?,
        defaultScopeDescription: String,
        workspaceScopeLabel: String? = nil,
        workspaceNotes: [WorkspaceNoteReference] = []
    ) {
        self.source = source
        self.projectID = projectID
        self.projectName = projectName
        self.selectedNoteTarget = selectedNoteTarget
        self.selectedNoteTitle = selectedNoteTitle
        self.defaultScopeDescription = defaultScopeDescription
        self.workspaceScopeLabel = workspaceScopeLabel
        self.workspaceNotes = workspaceNotes
    }

    private var selectedWorkspaceNote: WorkspaceNoteReference? {
        guard let selectedNoteTarget else { return nil }
        return workspaceNotes.first(where: { $0.target == selectedNoteTarget })
    }

    var instructionText: String {
        var lines: [String] = [
            "Use `assistant_notes` as the source of truth for note questions before relying on memory summaries.",
            "Default note scope: \(defaultScopeDescription).",
            "Project notes are the main notes. Thread notes are side notes.",
            "For note changes, prepare a preview first and only apply after confirmation."
        ]

        switch source {
        case .chatNoteMode:
            lines.insert(
                "You are in Note Mode for project `\(projectName)` (`\(projectID)`).",
                at: 0
            )
        case .notesWorkspace:
            lines.insert(
                "You are helping inside the Notes workspace for project `\(projectName)` (`\(projectID)`).",
                at: 0
            )
            lines.append(
                "Stay focused on note work unless the user clearly asks to switch topics."
            )
        }

        if let selectedNoteTarget,
           let selectedNoteTitle = selectedNoteTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append(
                "If the user refers to \"this note\" or \"the open note\", first prefer note `\(selectedNoteTitle)` (`\(selectedNoteTarget.noteID)`) before searching for another target."
            )

            var openNoteLine = "Open note right now: `\(selectedNoteTitle)` (`\(selectedNoteTarget.noteID)`)."
            if let sourceLabel = selectedWorkspaceNote?.sourceLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty {
                openNoteLine += " Source: \(sourceLabel)."
            }
            if let folderPath = selectedWorkspaceNote?.folderPath,
               !folderPath.isEmpty {
                openNoteLine += " Folder: `\(folderPath.joined(separator: " / "))`."
            }
            if let fileName = selectedWorkspaceNote?.fileName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty {
                openNoteLine += " Saved file: `\(fileName)`."
            }
            lines.append(openNoteLine)
            lines.append(
                "If the user asks to organize, summarize, clean up, or review \"this note\" without naming a different note, use the open note first."
            )
            lines.append(
                "Do not ask the user to paste note text, upload a note file, or repeat the note name when the open note already gives enough context."
            )
        }

        if !workspaceNotes.isEmpty {
            let scopeLabel = workspaceScopeLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? "the current notes list"
            lines.append("Notes currently visible in \(scopeLabel):")
            let visibleNotes = Array(workspaceNotes.prefix(12))
            lines.append(contentsOf: visibleNotes.map { note in
                var line = note.isSelected ? "- OPEN " : "- "
                line += "`\(note.title)`"
                if let fileName = note.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    line += " (`\(fileName)`)"
                }
                let sourceLabel = note.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sourceLabel.isEmpty {
                    line += " from \(sourceLabel)"
                }
                if !note.folderPath.isEmpty {
                    line += " in folder `\(note.folderPath.joined(separator: " / "))`"
                }
                return line
            })
            if workspaceNotes.count > visibleNotes.count {
                lines.append(
                    "- \(workspaceNotes.count - visibleNotes.count) more notes are available in this scope."
                )
            }
        }

        lines.append(
            "For bigger note cleanups, many-note comparisons, or online idea gathering, you may use a side agent when helpful, but keep final note saves through `assistant_notes`."
        )

        return lines.joined(separator: "\n")
    }
}
