import CryptoKit
import Foundation

enum AssistantNotesToolAction: String, CaseIterable, Sendable {
    case listNotes = "list_notes"
    case searchNotes = "search_notes"
    case readNote = "read_note"
    case prepareAdd = "prepare_add"
    case prepareOrganize = "prepare_organize"
    case applyPreview = "apply_preview"
}

enum AssistantNotesToolDefinition {
    static let name = "assistant_notes"
    static let toolKind = "assistantNotes"

    static let description = """
    Read and manage Open Assist project and thread notes for the active project. Use this to list notes, search real note files, read one note, prepare a preview for adding content to the best note, prepare a preview for organizing an existing note, and apply a previously prepared preview after confirmation. Project notes are the main notes. Thread notes are side notes.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "One of list_notes, search_notes, read_note, prepare_add, prepare_organize, or apply_preview."
            ],
            "query": [
                "type": "string",
                "description": "Optional search text, note title hint, or question about which note to use."
            ],
            "noteId": [
                "type": "string",
                "description": "Optional exact note id when you already know the note to read or change."
            ],
            "content": [
                "type": "string",
                "description": "Content to add when action is prepare_add."
            ],
            "previewId": [
                "type": "string",
                "description": "Prepared preview id to apply when action is apply_preview."
            ],
            "ownerKind": [
                "type": "string",
                "description": "Optional scope override: project or thread."
            ],
            "ownerId": [
                "type": "string",
                "description": "Optional project id or thread id for the scope override."
            ]
        ],
        "required": ["action"],
        "additionalProperties": true
    ]
}

enum AssistantNotesToolServiceError: LocalizedError {
    case invalidArguments(String)
    case unavailableScope(String)
    case noteNotFound(String)
    case previewNotFound(String)
    case applyBlockedInPlanMode
    case previewExpired(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .unavailableScope(let message),
             .noteNotFound(let message),
             .previewNotFound(let message),
             .previewExpired(let message):
            return message
        case .applyBlockedInPlanMode:
            return "apply_preview is blocked in Plan mode. Prepare the preview in Plan mode, then switch to Agentic mode to save it."
        }
    }
}

struct AssistantNotesMutationEvent: Equatable, Sendable, Identifiable {
    let id: String
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let noteID: String
    let projectID: String?
    let createdNote: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        projectID: String?,
        createdNote: Bool
    ) {
        self.id = id
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.noteID = noteID
        self.projectID = projectID
        self.createdNote = createdNote
    }
}

enum AssistantNotesPlacementResult {
    case success(ProjectNoteTransferSuggestion)
    case failure(String)
}

enum AssistantNotesOrganizeResult {
    case success(String)
    case failure(String)
}

protocol AssistantNotesToolAIProviding {
    func suggestPlacement(
        content: String,
        sourceLabel: String,
        targetNoteTitle: String,
        targetNoteText: String,
        targetHeadingOutline: String
    ) async -> AssistantNotesPlacementResult

    func organizeNote(
        noteText: String,
        selectedText: String?
    ) async -> AssistantNotesOrganizeResult
}

struct AssistantNotesToolAIProvider: AssistantNotesToolAIProviding {
    func suggestPlacement(
        content: String,
        sourceLabel: String,
        targetNoteTitle: String,
        targetNoteText: String,
        targetHeadingOutline: String
    ) async -> AssistantNotesPlacementResult {
        let result = await MemoryEntryExplanationService.shared.suggestProjectNoteTransfer(
            selectedMarkdown: content,
            sourceNoteTitle: sourceLabel,
            targetNoteTitle: targetNoteTitle,
            targetHeadingOutline: targetHeadingOutline,
            targetNoteText: targetNoteText
        )
        switch result {
        case .success(let suggestion):
            return .success(suggestion)
        case .failure(let message):
            return .failure(message)
        }
    }

    func organizeNote(
        noteText: String,
        selectedText: String?
    ) async -> AssistantNotesOrganizeResult {
        let result = await MemoryEntryExplanationService.shared.organizeThreadNote(
            noteText: noteText,
            selectedText: selectedText
        )
        switch result {
        case .success(let text):
            return .success(text)
        case .failure(let message):
            return .failure(message)
        }
    }
}

@MainActor
final class AssistantNotesToolService {
    struct ParsedRequest: Equatable, Sendable {
        let action: AssistantNotesToolAction
        let query: String?
        let noteID: String?
        let content: String?
        let previewID: String?
        let ownerKind: AssistantNoteOwnerKind?
        let ownerID: String?

        var summaryLine: String {
            switch action {
            case .listNotes:
                return "List project notes"
            case .searchNotes:
                return query.map { "Search notes for \($0)" } ?? "Search notes"
            case .readNote:
                return query.map { "Read note \($0)" } ?? "Read a note"
            case .prepareAdd:
                if let query {
                    return "Prepare note update for \(query)"
                }
                return "Prepare note update"
            case .prepareOrganize:
                return query.map { "Prepare note cleanup for \($0)" } ?? "Prepare note cleanup"
            case .applyPreview:
                return "Apply prepared note preview"
            }
        }
    }

    struct NoteItem: Codable, Equatable, Sendable {
        let noteID: String
        let title: String
        let noteType: String
        let ownerKind: String
        let ownerID: String
        let sourceLabel: String
        let folderPath: [String]
        let updatedAt: String
        let snippet: String
    }

    struct ListResponse: Codable, Equatable, Sendable {
        let action: String
        let scope: String
        let noteCount: Int
        let notes: [NoteItem]
    }

    struct SearchResponse: Codable, Equatable, Sendable {
        let action: String
        let scope: String
        let query: String
        let noteCount: Int
        let notes: [NoteItem]
    }

    struct ReadResponse: Codable, Equatable, Sendable {
        let action: String
        let scope: String
        let note: NoteItem
        let markdown: String
    }

    struct PreparedTargetInfo: Codable, Equatable, Sendable {
        let ownerKind: String
        let ownerID: String
        let noteID: String?
        let title: String
        let noteType: String
        let isNewNote: Bool
    }

    struct PreparedChangeResponse: Codable, Equatable, Sendable {
        let action: String
        let previewId: String
        let scope: String
        let target: PreparedTargetInfo
        let reason: String
        let placement: String
        let noteFingerprint: String?
        let ownerFingerprint: String?
        let beforePreviewText: String
        let afterPreviewText: String
    }

    struct ApplyResponse: Codable, Equatable, Sendable {
        let action: String
        let previewId: String
        let applied: Bool
        let target: PreparedTargetInfo
        let note: NoteItem
    }

    private struct ScopedNote {
        let note: AssistantStoredNote
        let sourceLabel: String
        let folderPath: [String]
        let session: AssistantSessionSummary?
        let isCurrentThread: Bool
    }

    private struct ScopeResolution {
        let scopeLabel: String
        let project: AssistantProject?
        let creationProjectID: String?
        let currentThreadID: String?
        let notes: [ScopedNote]
    }

    private struct RankedCandidate {
        let scopedNote: ScopedNote
        let score: Int
        let titleExactMatch: Bool
        let titleContainsMatch: Bool
        let overlapCount: Int
    }

    private struct PreparedChangeRecord {
        let previewID: String
        let action: AssistantNotesToolAction
        let scopeLabel: String
        let ownerKind: AssistantNoteOwnerKind
        let ownerID: String
        let noteID: String?
        let title: String
        let noteType: AssistantNoteType
        let beforeText: String
        let afterText: String
        let reason: String
        let placement: String
        let noteFingerprint: String?
        let ownerFingerprint: String?
        let createdNote: Bool

        var targetInfo: PreparedTargetInfo {
            PreparedTargetInfo(
                ownerKind: ownerKind.rawValue,
                ownerID: ownerID,
                noteID: noteID,
                title: title,
                noteType: noteType.rawValue,
                isNewNote: createdNote
            )
        }
    }

    private struct HeadingSection {
        let title: String
        let normalizedTitle: String
        let level: Int
        let lineStartUTF16: Int
        let contentStartUTF16: Int
        let sectionEndUTF16: Int
        let path: [String]
        let normalizedPath: [String]
    }

    private let projectStore: AssistantProjectStore
    private let conversationStore: AssistantConversationStore
    private let aiProvider: any AssistantNotesToolAIProviding
    private let iso8601Formatter = ISO8601DateFormatter()
    private var sessionSummaryProvider: (String) -> AssistantSessionSummary? = { _ in nil }
    private var mutationHandler: ((AssistantNotesMutationEvent) -> Void)?
    private var preparedChangesByID: [String: PreparedChangeRecord] = [:]

    init(
        projectStore: AssistantProjectStore = AssistantProjectStore(),
        conversationStore: AssistantConversationStore = AssistantConversationStore(),
        aiProvider: any AssistantNotesToolAIProviding = AssistantNotesToolAIProvider()
    ) {
        self.projectStore = projectStore
        self.conversationStore = conversationStore
        self.aiProvider = aiProvider
    }

    func setSessionSummaryProvider(_ provider: @escaping (String) -> AssistantSessionSummary?) {
        sessionSummaryProvider = provider
    }

    func setMutationHandler(_ handler: ((AssistantNotesMutationEvent) -> Void)?) {
        mutationHandler = handler
    }

    nonisolated static func parseRequest(from arguments: Any) throws -> ParsedRequest {
        guard let dictionary = arguments as? [String: Any] else {
            throw AssistantNotesToolServiceError.invalidArguments(
                "assistant_notes needs a JSON object."
            )
        }

        guard let actionRaw = (dictionary["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              let action = AssistantNotesToolAction(rawValue: actionRaw) else {
            throw AssistantNotesToolServiceError.invalidArguments(
                "assistant_notes needs a valid `action`."
            )
        }

        let ownerKindRaw = (dictionary["ownerKind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ownerKind = ownerKindRaw.flatMap { AssistantNoteOwnerKind(rawValue: $0) }
        let ownerID = (dictionary["ownerId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        return ParsedRequest(
            action: action,
            query: (dictionary["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            noteID: (dictionary["noteId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            content: (dictionary["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            previewID: (dictionary["previewId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            ownerKind: ownerKind,
            ownerID: ownerID
        )
    }

    func run(
        arguments: Any,
        sessionID: String?,
        runtimeContext: AssistantNotesRuntimeContext?,
        preferredModelID _: String?,
        interactionMode: AssistantInteractionMode
    ) async -> AssistantToolExecutionResult {
        do {
            let request = try Self.parseRequest(from: arguments)
            switch request.action {
            case .listNotes:
                let scope = try resolveScope(
                    sessionID: sessionID,
                    runtimeContext: runtimeContext,
                    ownerKind: request.ownerKind,
                    ownerID: request.ownerID
                )
                let response = ListResponse(
                    action: request.action.rawValue,
                    scope: scope.scopeLabel,
                    noteCount: scope.notes.count,
                    notes: orderedNotesForListing(scope.notes).map { note in
                        makeNoteItem(from: note)
                    }
                )
                return successResult(
                    payload: response,
                    summary: "Listed \(scope.notes.count) notes."
                )

            case .searchNotes:
                guard let query = request.query else {
                    throw AssistantNotesToolServiceError.invalidArguments(
                        "search_notes needs a non-empty `query`."
                    )
                }
                let scope = try resolveScope(
                    sessionID: sessionID,
                    runtimeContext: runtimeContext,
                    ownerKind: request.ownerKind,
                    ownerID: request.ownerID
                )
                let ranked = rankNotes(
                    scope.notes,
                    query: query,
                    currentThreadID: scope.currentThreadID
                )
                let matches = ranked
                    .filter { $0.score > 0 }
                    .prefix(12)
                    .map { rankedNote in
                        makeNoteItem(
                            from: rankedNote.scopedNote,
                            snippetOverride: makeSearchSnippet(
                                text: rankedNote.scopedNote.note.text,
                                query: query
                            )
                        )
                    }
                let response = SearchResponse(
                    action: request.action.rawValue,
                    scope: scope.scopeLabel,
                    query: query,
                    noteCount: matches.count,
                    notes: matches
                )
                return successResult(
                    payload: response,
                    summary: matches.isEmpty
                        ? "No matching notes were found."
                        : "Found \(matches.count) matching notes."
                )

            case .readNote:
                let scope = try resolveScope(
                    sessionID: sessionID,
                    runtimeContext: runtimeContext,
                    ownerKind: request.ownerKind,
                    ownerID: request.ownerID
                )
                let target = try resolveExactOrBestNote(
                    in: scope,
                    noteID: request.noteID,
                    query: request.query,
                    runtimeContext: runtimeContext,
                    missingMessage: "I could not find that note in the current note scope."
                )
                let response = ReadResponse(
                    action: request.action.rawValue,
                    scope: scope.scopeLabel,
                    note: makeNoteItem(from: target, snippetOverride: makeBodySnippet(target.note.text)),
                    markdown: normalizedMarkdown(target.note.text)
                )
                return successResult(
                    payload: response,
                    summary: "Read note \(target.note.title)."
                )

            case .prepareAdd:
                let response = try await prepareAdd(
                    request: request,
                    sessionID: sessionID,
                    runtimeContext: runtimeContext
                )
                return successResult(
                    payload: response,
                    summary: "Prepared a note update preview."
                )

            case .prepareOrganize:
                let response = try await prepareOrganize(
                    request: request,
                    sessionID: sessionID,
                    runtimeContext: runtimeContext
                )
                return successResult(
                    payload: response,
                    summary: "Prepared a note organization preview."
                )

            case .applyPreview:
                guard interactionMode != .plan else {
                    throw AssistantNotesToolServiceError.applyBlockedInPlanMode
                }
                let response = try applyPreview(request: request)
                return successResult(
                    payload: response,
                    summary: "Saved the prepared note change."
                )
            }
        } catch let error as AssistantNotesToolServiceError {
            return failureResult(error.localizedDescription)
        } catch {
            return failureResult(
                error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                    ?? "assistant_notes failed."
            )
        }
    }

    private func prepareAdd(
        request: ParsedRequest,
        sessionID: String?,
        runtimeContext: AssistantNotesRuntimeContext?
    ) async throws -> PreparedChangeResponse {
        guard let content = request.content else {
            throw AssistantNotesToolServiceError.invalidArguments(
                "prepare_add needs non-empty `content`."
            )
        }

        let scope = try resolveScope(
            sessionID: sessionID,
            runtimeContext: runtimeContext,
            ownerKind: request.ownerKind,
            ownerID: request.ownerID
        )

        if let explicitTarget = request.noteID.flatMap({ note(in: scope.notes, noteID: $0) }) {
            return try await prepareAddPreview(
                scope: scope,
                target: explicitTarget,
                content: content,
                requestQuery: request.query
            )
        }

        let combinedRequestText = [request.query, request.content]
            .compactMap { $0 }
            .joined(separator: "\n")

        if let contextualTarget = contextualSelectedNote(
            in: scope,
            runtimeContext: runtimeContext,
            combinedRequestText: combinedRequestText,
            requireExplicitCurrentNoteReference: true
        ) {
            return try await prepareAddPreview(
                scope: scope,
                target: contextualTarget,
                content: content,
                requestQuery: request.query
            )
        }

        let rankingSeed = rankingSeed(query: request.query, content: content)
        let candidateNotes = automaticPrepareAddCandidates(
            in: scope.notes,
            runtimeContext: runtimeContext,
            combinedRequestText: combinedRequestText
        )
        let prefersCreatingNewNoteIfUnclear = requestPrefersNewNoteFallback(combinedRequestText)
        let ranked = rankNotes(
            candidateNotes,
            query: rankingSeed,
            currentThreadID: scope.currentThreadID,
            preferThreadOnly: request.ownerKind == .thread || queryLooksThreadSpecific(rankingSeed)
        )

        if let existingTarget = chooseExistingTarget(
            from: ranked,
            requireHighConfidence: prefersCreatingNewNoteIfUnclear
        ) {
            return try await prepareAddPreview(
                scope: scope,
                target: existingTarget,
                content: content,
                requestQuery: request.query
            )
        }

        guard let creationProjectID = scope.creationProjectID else {
            throw AssistantNotesToolServiceError.unavailableScope(
                "I could not find a safe existing note, and this thread is not linked to a project note area where I can create a new main note."
            )
        }

        let newNoteTitle = suggestedNewNoteTitle(
            query: request.query,
            content: content,
            reservedTitles: Set(
                (try? projectStore.loadProjectStoredNotes(projectID: creationProjectID).map(\.title)) ?? []
            )
        )
        let normalizedContent = normalizedMarkdown(content)
        let preview = PreparedChangeRecord(
            previewID: UUID().uuidString.lowercased(),
            action: .prepareAdd,
            scopeLabel: scope.scopeLabel,
            ownerKind: .project,
            ownerID: creationProjectID,
            noteID: nil,
            title: newNoteTitle,
            noteType: .note,
            beforeText: "",
            afterText: normalizedContent,
            reason: "No existing note was a safe match, so this creates a new project note instead of guessing.",
            placement: "END",
            noteFingerprint: nil,
            ownerFingerprint: stableProjectManifestFingerprint(projectID: creationProjectID),
            createdNote: true
        )
        preparedChangesByID[preview.previewID] = preview
        return previewResponse(from: preview)
    }

    private func prepareAddPreview(
        scope: ScopeResolution,
        target: ScopedNote,
        content: String,
        requestQuery: String?
    ) async throws -> PreparedChangeResponse {
        let currentText = normalizedMarkdown(target.note.text)
        let sections = headingSections(in: currentText)
        let outline = headingOutline(from: sections)
        let normalizedContent = normalizedMarkdown(content)
        let placementSuggestion = await aiProvider.suggestPlacement(
            content: normalizedContent,
            sourceLabel: requestQuery ?? "Assistant note addition",
            targetNoteTitle: target.note.title,
            targetNoteText: currentText,
            targetHeadingOutline: outline
        )

        let placement: String
        let reason: String
        let insertedMarkdown: String
        let insertionOffset: Int
        switch placementSuggestion {
        case .success(let suggestion):
            let matchedSection = resolveHeadingSection(
                matching: suggestion.headingPath,
                in: sections
            )
            placement = matchedSection.map { headingPathText($0.path) } ?? "END"
            reason = suggestion.reason
            insertedMarkdown = suggestion.insertedMarkdown
            insertionOffset = matchedSection?.sectionEndUTF16 ?? (currentText as NSString).length
        case .failure(let message):
            placement = "END"
            reason = "AI could not place this safely (\(message)). Falling back to the end of the note."
            insertedMarkdown = normalizedContent
            insertionOffset = (currentText as NSString).length
        }

        let mergedText = insertMarkdownBlock(
            into: currentText,
            block: insertedMarkdown,
            atUTF16Offset: insertionOffset
        )
        let preview = PreparedChangeRecord(
            previewID: UUID().uuidString.lowercased(),
            action: .prepareAdd,
            scopeLabel: scope.scopeLabel,
            ownerKind: target.note.ownerKind,
            ownerID: target.note.ownerID,
            noteID: target.note.noteID,
            title: target.note.title,
            noteType: target.note.noteType,
            beforeText: currentText,
            afterText: mergedText,
            reason: reason,
            placement: placement,
            noteFingerprint: stableNoteFingerprint(currentText),
            ownerFingerprint: nil,
            createdNote: false
        )
        preparedChangesByID[preview.previewID] = preview
        return previewResponse(from: preview)
    }

    private func prepareOrganize(
        request: ParsedRequest,
        sessionID: String?,
        runtimeContext: AssistantNotesRuntimeContext?
    ) async throws -> PreparedChangeResponse {
        let scope = try resolveScope(
            sessionID: sessionID,
            runtimeContext: runtimeContext,
            ownerKind: request.ownerKind,
            ownerID: request.ownerID
        )
        let target = try resolveExactOrBestNote(
            in: scope,
            noteID: request.noteID,
            query: request.query,
            runtimeContext: runtimeContext,
            missingMessage: "I could not tell which note you want to organize."
        )
        let beforeText = normalizedMarkdown(target.note.text)
        let organizedResult = await aiProvider.organizeNote(
            noteText: beforeText,
            selectedText: Optional<String>.none
        )
        let organizedText: String
        switch organizedResult {
        case .success(let text):
            organizedText = normalizedMarkdown(text)
        case .failure(let message):
            throw AssistantNotesToolServiceError.unavailableScope(message)
        }

        let preview = PreparedChangeRecord(
            previewID: UUID().uuidString.lowercased(),
            action: .prepareOrganize,
            scopeLabel: scope.scopeLabel,
            ownerKind: target.note.ownerKind,
            ownerID: target.note.ownerID,
            noteID: target.note.noteID,
            title: target.note.title,
            noteType: target.note.noteType,
            beforeText: beforeText,
            afterText: organizedText,
            reason: "This preview cleans up the note structure without saving yet.",
            placement: "REPLACE",
            noteFingerprint: stableNoteFingerprint(beforeText),
            ownerFingerprint: nil,
            createdNote: false
        )
        preparedChangesByID[preview.previewID] = preview
        return previewResponse(from: preview)
    }

    private func applyPreview(request: ParsedRequest) throws -> ApplyResponse {
        guard let previewID = request.previewID else {
            throw AssistantNotesToolServiceError.invalidArguments(
                "apply_preview needs a non-empty `previewId`."
            )
        }
        guard let preview = preparedChangesByID[previewID] else {
            throw AssistantNotesToolServiceError.previewNotFound(
                "I could not find that prepared note preview. Please prepare it again."
            )
        }

        let noteItem: NoteItem
        let finalTargetInfo: PreparedTargetInfo
        if preview.createdNote {
            guard preview.ownerKind == .project else {
                throw AssistantNotesToolServiceError.previewExpired(
                    "This preview is no longer valid."
                )
            }
            guard stableProjectManifestFingerprint(projectID: preview.ownerID) == preview.ownerFingerprint else {
                throw AssistantNotesToolServiceError.previewExpired(
                    "The project note list changed after this preview was prepared. Please prepare it again so I can choose the safest place."
                )
            }

            let previousSelectedNoteID = try projectStore
                .loadProjectNotesWorkspace(projectID: preview.ownerID)
                .selectedNote?
                .id
            let createdWorkspace = try projectStore.createProjectNote(
                projectID: preview.ownerID,
                title: preview.title,
                noteType: preview.noteType,
                selectNewNote: true
            )
            guard let createdNoteID = createdWorkspace.selectedNote?.id else {
                throw AssistantNotesToolServiceError.previewExpired(
                    "I could not create the new project note."
                )
            }
            _ = try projectStore.saveProjectNote(
                projectID: preview.ownerID,
                noteID: createdNoteID,
                text: preview.afterText
            )
            if let previousSelectedNoteID,
               previousSelectedNoteID != createdNoteID {
                _ = try? projectStore.selectProjectNote(
                    projectID: preview.ownerID,
                    noteID: previousSelectedNoteID
                )
            }
            let createdNote = try latestStoredNote(
                ownerKind: .project,
                ownerID: preview.ownerID,
                noteID: createdNoteID
            )
            noteItem = makeNoteItem(
                from: ScopedNote(
                    note: createdNote,
                    sourceLabel: "Project notes",
                    folderPath: projectFolderPath(
                        projectID: preview.ownerID,
                        folderID: createdNote.folderID
                    ),
                    session: nil,
                    isCurrentThread: false
                ),
                snippetOverride: makeBodySnippet(createdNote.text)
            )
            finalTargetInfo = PreparedTargetInfo(
                ownerKind: AssistantNoteOwnerKind.project.rawValue,
                ownerID: preview.ownerID,
                noteID: createdNoteID,
                title: createdNote.title,
                noteType: createdNote.noteType.rawValue,
                isNewNote: true
            )
            mutationHandler?(
                AssistantNotesMutationEvent(
                    ownerKind: .project,
                    ownerID: preview.ownerID,
                    noteID: createdNoteID,
                    projectID: preview.ownerID,
                    createdNote: true
                )
            )
        } else {
            guard let noteID = preview.noteID else {
                throw AssistantNotesToolServiceError.previewExpired(
                    "This preview no longer points to a valid note."
                )
            }
            let currentNote = try latestStoredNote(
                ownerKind: preview.ownerKind,
                ownerID: preview.ownerID,
                noteID: noteID
            )
            guard stableNoteFingerprint(currentNote.text) == preview.noteFingerprint else {
                throw AssistantNotesToolServiceError.previewExpired(
                    "That note changed after this preview was prepared. Please prepare it again so I do not overwrite newer edits."
                )
            }

            switch preview.ownerKind {
            case .thread:
                let previousSelectedNoteID = conversationStore
                    .loadThreadNotesWorkspace(threadID: preview.ownerID)
                    .selectedNote?
                    .id
                _ = try conversationStore.saveThreadNote(
                    threadID: preview.ownerID,
                    noteID: noteID,
                    text: preview.afterText
                )
                if let previousSelectedNoteID,
                   previousSelectedNoteID != noteID {
                    _ = try? conversationStore.selectThreadNote(
                        threadID: preview.ownerID,
                        noteID: previousSelectedNoteID
                    )
                }
            case .project:
                let previousSelectedNoteID = try projectStore
                    .loadProjectNotesWorkspace(projectID: preview.ownerID)
                    .selectedNote?
                    .id
                _ = try projectStore.saveProjectNote(
                    projectID: preview.ownerID,
                    noteID: noteID,
                    text: preview.afterText
                )
                if let previousSelectedNoteID,
                   previousSelectedNoteID != noteID {
                    _ = try? projectStore.selectProjectNote(
                        projectID: preview.ownerID,
                        noteID: previousSelectedNoteID
                    )
                }
            }

            let savedNote = try latestStoredNote(
                ownerKind: preview.ownerKind,
                ownerID: preview.ownerID,
                noteID: noteID
            )
            noteItem = makeNoteItem(
                from: ScopedNote(
                    note: savedNote,
                    sourceLabel: sourceLabel(
                        ownerKind: savedNote.ownerKind,
                        ownerID: savedNote.ownerID
                    ),
                    folderPath: savedNote.ownerKind == .project
                        ? projectFolderPath(
                            projectID: savedNote.ownerID,
                            folderID: savedNote.folderID
                        )
                        : [],
                    session: savedNote.ownerKind == .thread
                        ? sessionSummaryProvider(savedNote.ownerID)
                        : nil,
                    isCurrentThread: false
                ),
                snippetOverride: makeBodySnippet(savedNote.text)
            )
            finalTargetInfo = PreparedTargetInfo(
                ownerKind: preview.ownerKind.rawValue,
                ownerID: preview.ownerID,
                noteID: noteID,
                title: savedNote.title,
                noteType: savedNote.noteType.rawValue,
                isNewNote: false
            )
            mutationHandler?(
                AssistantNotesMutationEvent(
                    ownerKind: savedNote.ownerKind,
                    ownerID: savedNote.ownerID,
                    noteID: savedNote.noteID,
                    projectID: projectStore.context(forThreadID: savedNote.ownerID)?.project.id
                        ?? (savedNote.ownerKind == .project ? savedNote.ownerID : nil),
                    createdNote: false
                )
            )
        }

        preparedChangesByID.removeValue(forKey: previewID)
        return ApplyResponse(
            action: request.action.rawValue,
            previewId: previewID,
            applied: true,
            target: finalTargetInfo,
            note: noteItem
        )
    }

    private func resolveScope(
        sessionID: String?,
        runtimeContext: AssistantNotesRuntimeContext?,
        ownerKind: AssistantNoteOwnerKind?,
        ownerID: String?
    ) throws -> ScopeResolution {
        if let ownerKind {
            guard let ownerID else {
                throw AssistantNotesToolServiceError.invalidArguments(
                    "When `ownerKind` is set, `ownerId` is also required."
                )
            }
            switch ownerKind {
            case .project:
                return try resolveProjectScope(
                    projectID: ownerID,
                    currentThreadID: sessionID
                )
            case .thread:
                return resolveThreadScope(threadID: ownerID)
            }
        }

        if let runtimeContext {
            return try resolveProjectScope(
                projectID: runtimeContext.projectID,
                currentThreadID: sessionID
            )
        }

        guard let context = projectStore.context(forThreadID: sessionID) else {
            throw AssistantNotesToolServiceError.unavailableScope(
                "The current thread is not linked to a project yet, so I cannot search the full project note set."
            )
        }
        return try resolveProjectScope(
            projectID: context.project.id,
            currentThreadID: sessionID
        )
    }

    private func resolveProjectScope(
        projectID: String,
        currentThreadID: String?
    ) throws -> ScopeResolution {
        guard let project = projectStore.project(forProjectID: projectID),
              project.isProject else {
            throw AssistantNotesToolServiceError.unavailableScope(
                "I could not find that project note set."
            )
        }

        let normalizedCurrentThreadID = currentThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let folderPathByID = try projectStore.projectNoteFolderPathMap(projectID: project.id)
        let projectNotes = try projectStore.loadProjectStoredNotes(projectID: project.id).map {
            ScopedNote(
                note: $0,
                sourceLabel: "Project notes",
                folderPath: $0.folderID.flatMap { folderID in
                    folderPathByID.first(where: {
                        $0.key.caseInsensitiveCompare(folderID) == .orderedSame
                    })?.value
                } ?? [],
                session: nil,
                isCurrentThread: false
            )
        }

        let snapshot = projectStore.snapshot()
        let siblingThreadNotes = snapshot.threadAssignments.keys.sorted().flatMap { threadID -> [ScopedNote] in
            guard snapshot.threadAssignments[threadID]?.caseInsensitiveCompare(project.id) == .orderedSame else {
                return []
            }
            let session = sessionSummaryProvider(threadID)
            let notes = conversationStore.loadThreadStoredNotes(threadID: threadID)
            let sourceLabel = sourceLabel(ownerKind: .thread, ownerID: threadID)
            return notes.map {
                ScopedNote(
                    note: $0,
                    sourceLabel: sourceLabel,
                    folderPath: [],
                    session: session,
                    isCurrentThread: threadMatches($0.ownerID, normalizedCurrentThreadID)
                )
            }
        }

        return ScopeResolution(
            scopeLabel: "Project \(project.name)",
            project: project,
            creationProjectID: project.id,
            currentThreadID: normalizedCurrentThreadID,
            notes: projectNotes + siblingThreadNotes
        )
    }

    private func resolveThreadScope(threadID: String) -> ScopeResolution {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionSummaryProvider(normalizedThreadID)
        let context = projectStore.context(forThreadID: normalizedThreadID)
        let notes = conversationStore.loadThreadStoredNotes(threadID: normalizedThreadID).map {
            ScopedNote(
                note: $0,
                sourceLabel: sourceLabel(ownerKind: .thread, ownerID: normalizedThreadID),
                folderPath: [],
                session: session,
                isCurrentThread: true
            )
        }
        return ScopeResolution(
            scopeLabel: session?.title.nonEmpty ?? "Thread \(normalizedThreadID)",
            project: context?.project,
            creationProjectID: context?.project.id,
            currentThreadID: normalizedThreadID,
            notes: notes
        )
    }

    private func resolveExactOrBestNote(
        in scope: ScopeResolution,
        noteID: String?,
        query: String?,
        runtimeContext: AssistantNotesRuntimeContext?,
        missingMessage: String
    ) throws -> ScopedNote {
        if let noteID,
           let note = note(in: scope.notes, noteID: noteID) {
            return note
        }

        if let contextualTarget = contextualSelectedNote(
            in: scope,
            runtimeContext: runtimeContext,
            combinedRequestText: query ?? "",
            requireExplicitCurrentNoteReference: false
        ) {
            return contextualTarget
        }

        if let query {
            let ranked = rankNotes(
                scope.notes,
                query: query,
                currentThreadID: scope.currentThreadID,
                preferThreadOnly: queryLooksThreadSpecific(query)
            )
            if let best = ranked.first,
               best.score > 0 {
                return best.scopedNote
            }
        }

        if scope.notes.count == 1,
           let only = scope.notes.first {
            return only
        }

        throw AssistantNotesToolServiceError.noteNotFound(missingMessage)
    }

    private func contextualSelectedNote(
        in scope: ScopeResolution,
        runtimeContext: AssistantNotesRuntimeContext?,
        combinedRequestText: String,
        requireExplicitCurrentNoteReference: Bool
    ) -> ScopedNote? {
        guard let selectedTarget = runtimeContext?.selectedNoteTarget else {
            return nil
        }

        let shouldUseSelectedNote: Bool
        if requireExplicitCurrentNoteReference {
            shouldUseSelectedNote = requestRefersToCurrentNote(combinedRequestText)
        } else {
            let trimmed = combinedRequestText.trimmingCharacters(in: .whitespacesAndNewlines)
            shouldUseSelectedNote = trimmed.isEmpty || requestRefersToCurrentNote(trimmed)
        }

        guard shouldUseSelectedNote else {
            return nil
        }

        return scope.notes.first { scopedNote in
            scopedNote.note.ownerKind == selectedTarget.ownerKind
                && scopedNote.note.ownerID.caseInsensitiveCompare(selectedTarget.ownerID) == .orderedSame
                && scopedNote.note.noteID.caseInsensitiveCompare(selectedTarget.noteID) == .orderedSame
        }
    }

    private func automaticPrepareAddCandidates(
        in notes: [ScopedNote],
        runtimeContext: AssistantNotesRuntimeContext?,
        combinedRequestText: String
    ) -> [ScopedNote] {
        guard let runtimeContext,
              runtimeContext.source == .notesWorkspace,
              let selectedTarget = runtimeContext.selectedNoteTarget else {
            return notes
        }

        if requestRefersToCurrentNote(combinedRequestText) {
            return notes
        }

        if let selectedNoteTitle = runtimeContext.selectedNoteTitle,
           requestMentionsNoteTitle(combinedRequestText, noteTitle: selectedNoteTitle) {
            return notes
        }

        let filtered = notes.filter { scopedNote in
            !(scopedNote.note.ownerKind == selectedTarget.ownerKind
                && scopedNote.note.ownerID.caseInsensitiveCompare(selectedTarget.ownerID) == .orderedSame
                && scopedNote.note.noteID.caseInsensitiveCompare(selectedTarget.noteID) == .orderedSame)
        }

        return filtered.isEmpty ? notes : filtered
    }

    private func orderedNotesForListing(_ notes: [ScopedNote]) -> [ScopedNote] {
        notes.sorted { lhs, rhs in
            let lhsOwnerRank = ownerDisplayRank(lhs)
            let rhsOwnerRank = ownerDisplayRank(rhs)
            if lhsOwnerRank != rhsOwnerRank {
                return lhsOwnerRank > rhsOwnerRank
            }
            if lhs.note.updatedAt != rhs.note.updatedAt {
                return lhs.note.updatedAt > rhs.note.updatedAt
            }
            return lhs.note.title.localizedCaseInsensitiveCompare(rhs.note.title) == .orderedAscending
        }
    }

    private func ownerDisplayRank(_ note: ScopedNote) -> Int {
        if note.note.ownerKind == .project {
            return 3
        }
        if note.isCurrentThread {
            return 2
        }
        return 1
    }

    private func rankNotes(
        _ notes: [ScopedNote],
        query: String,
        currentThreadID: String?,
        preferThreadOnly: Bool = false
    ) -> [RankedCandidate] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(query).lowercased()
        let queryTokens = Set(MemoryTextNormalizer.keywords(from: query, limit: 20))
        let queryLooksShared = !preferThreadOnly
        let sortedByRecency = notes.sorted { $0.note.updatedAt > $1.note.updatedAt }
        let recencyIndexByStorageKey = Dictionary(
            uniqueKeysWithValues: sortedByRecency.enumerated().map { index, scopedNote in
                (scopedNote.note.id, index)
            }
        )

        return notes.map { scopedNote in
            let titleKey = MemoryTextNormalizer.collapsedWhitespace(scopedNote.note.title).lowercased()
            let titleTokens = Set(MemoryTextNormalizer.keywords(from: scopedNote.note.title, limit: 12))
            let bodyTokens = Set(MemoryTextNormalizer.keywords(from: scopedNote.note.text, limit: 48))
            let folderLabel = scopedNote.folderPath.joined(separator: " ")
            let folderKey = MemoryTextNormalizer.collapsedWhitespace(folderLabel).lowercased()
            let folderTokens = Set(MemoryTextNormalizer.keywords(from: folderLabel, limit: 16))
            let titleExactMatch = !normalizedQuery.isEmpty && titleKey == normalizedQuery
            let titleContainsMatch = !normalizedQuery.isEmpty && (
                titleKey.contains(normalizedQuery) || normalizedQuery.contains(titleKey)
            )
            let folderContainsMatch = !normalizedQuery.isEmpty && !folderKey.isEmpty && (
                folderKey.contains(normalizedQuery) || normalizedQuery.contains(folderKey)
            )
            let overlapCount = queryTokens.intersection(titleTokens).count * 2
                + queryTokens.intersection(bodyTokens).count
                + queryTokens.intersection(folderTokens).count * 2

            var score = 0
            if let currentThreadID,
               threadMatches(scopedNote.note.ownerID, currentThreadID),
               scopedNote.note.ownerKind == .thread {
                score += preferThreadOnly ? 140 : 40
            } else if scopedNote.note.ownerKind == .project {
                score += queryLooksShared ? 110 : 60
            } else {
                score += preferThreadOnly ? 20 : 15
            }

            if scopedNote.note.noteType == .master {
                score += queryLooksShared ? 90 : 25
            }

            if titleExactMatch {
                score += 900
            } else if titleContainsMatch {
                score += 320
            }

            if folderContainsMatch {
                score += 180
            }

            score += overlapCount * 28

            if let recencyIndex = recencyIndexByStorageKey[scopedNote.note.id] {
                score += max(0, 12 - recencyIndex)
            }

            return RankedCandidate(
                scopedNote: scopedNote,
                score: score,
                titleExactMatch: titleExactMatch,
                titleContainsMatch: titleContainsMatch,
                overlapCount: overlapCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            let lhsOwnerRank = ownerDisplayRank(lhs.scopedNote)
            let rhsOwnerRank = ownerDisplayRank(rhs.scopedNote)
            if lhsOwnerRank != rhsOwnerRank {
                return lhsOwnerRank > rhsOwnerRank
            }

            if lhs.scopedNote.note.updatedAt != rhs.scopedNote.note.updatedAt {
                return lhs.scopedNote.note.updatedAt > rhs.scopedNote.note.updatedAt
            }

            let titleOrder = lhs.scopedNote.note.title.localizedCaseInsensitiveCompare(
                rhs.scopedNote.note.title
            )
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            return lhs.scopedNote.note.noteID.localizedCaseInsensitiveCompare(
                rhs.scopedNote.note.noteID
            ) == .orderedAscending
        }
    }

    private func chooseExistingTarget(
        from ranked: [RankedCandidate],
        requireHighConfidence: Bool = false
    ) -> ScopedNote? {
        guard let top = ranked.first else { return nil }
        let secondScore = ranked.dropFirst().first?.score ?? Int.min

        if top.titleExactMatch {
            return top.scopedNote
        }

        if requireHighConfidence {
            let strongKeywordMatch = top.overlapCount >= 4
            if !top.titleContainsMatch && !strongKeywordMatch {
                return nil
            }
            if top.score < 220 {
                return nil
            }
            if secondScore != Int.min,
               !top.titleContainsMatch,
               abs(top.score - secondScore) < 35 {
                return nil
            }
        }

        if top.score < 150 {
            return nil
        }

        if top.overlapCount == 0 && top.score < 240 {
            return nil
        }

        if secondScore != Int.min,
           top.score < 280,
           abs(top.score - secondScore) < 25 {
            return nil
        }

        return top.scopedNote
    }

    private func note(
        in notes: [ScopedNote],
        noteID: String
    ) -> ScopedNote? {
        let normalizedNoteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.first {
            $0.note.noteID.caseInsensitiveCompare(normalizedNoteID) == .orderedSame
        }
    }

    private func latestStoredNote(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) throws -> AssistantStoredNote {
        let notes: [AssistantStoredNote]
        switch ownerKind {
        case .thread:
            notes = conversationStore.loadThreadStoredNotes(threadID: ownerID)
        case .project:
            notes = try projectStore.loadProjectStoredNotes(projectID: ownerID)
        }
        guard let note = notes.first(where: {
            $0.noteID.caseInsensitiveCompare(noteID) == .orderedSame
        }) else {
            throw AssistantNotesToolServiceError.noteNotFound(
                "I could not find that note anymore."
            )
        }
        return note
    }

    private func previewResponse(from preview: PreparedChangeRecord) -> PreparedChangeResponse {
        PreparedChangeResponse(
            action: preview.action.rawValue,
            previewId: preview.previewID,
            scope: preview.scopeLabel,
            target: preview.targetInfo,
            reason: preview.reason,
            placement: preview.placement,
            noteFingerprint: preview.noteFingerprint,
            ownerFingerprint: preview.ownerFingerprint,
            beforePreviewText: previewText(preview.beforeText),
            afterPreviewText: previewText(preview.afterText)
        )
    }

    private func makeNoteItem(
        from scopedNote: ScopedNote,
        snippetOverride: String? = nil
    ) -> NoteItem {
        NoteItem(
            noteID: scopedNote.note.noteID,
            title: scopedNote.note.title,
            noteType: scopedNote.note.noteType.rawValue,
            ownerKind: scopedNote.note.ownerKind.rawValue,
            ownerID: scopedNote.note.ownerID,
            sourceLabel: scopedNote.sourceLabel,
            folderPath: scopedNote.folderPath,
            updatedAt: iso8601Formatter.string(from: scopedNote.note.updatedAt),
            snippet: snippetOverride ?? makeBodySnippet(scopedNote.note.text)
        )
    }

    private func sourceLabel(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String
    ) -> String {
        switch ownerKind {
        case .project:
            return "Project notes"
        case .thread:
            return "Thread notes"
        }
    }

    private func projectFolderPath(
        projectID: String,
        folderID: String?
    ) -> [String] {
        guard let folderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let folderPathByID = try? projectStore.projectNoteFolderPathMap(projectID: projectID) else {
            return []
        }

        return folderPathByID.first(where: {
            $0.key.caseInsensitiveCompare(folderID) == .orderedSame
        })?.value ?? []
    }

    private func suggestedNewNoteTitle(
        query: String?,
        content: String,
        reservedTitles: Set<String>
    ) -> String {
        let headingTitle = content
            .components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") })
            .map { line in
                line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            }
            .flatMap { MemoryTextNormalizer.collapsedWhitespace($0).nonEmpty }
        let firstMeaningfulLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { line in
                guard let line = line.nonEmpty else { return false }
                return !line.hasPrefix("#")
            })
        let baseTitle = headingTitle
            ?? firstMeaningfulLine.map { MemoryTextNormalizer.normalizedTitle($0, fallback: "Project Note") }
            ?? query.map { MemoryTextNormalizer.normalizedTitle($0, fallback: "Project Note") }
            ?? "Project Note"
        return AssistantBatchNotePlanComposer.deduplicatedTitles(
            [baseTitle],
            reservedTitles: reservedTitles
        ).first ?? baseTitle
    }

    private func rankingSeed(query: String?, content: String) -> String {
        let normalizedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let headingTitle = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.hasPrefix("#") })
            .map { line in
                line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            }
            .flatMap { MemoryTextNormalizer.collapsedWhitespace($0).nonEmpty }
        let firstMeaningfulLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { line in
                guard let line = line.nonEmpty else { return false }
                return !line.hasPrefix("#")
            })
            .flatMap { MemoryTextNormalizer.collapsedWhitespace($0).nonEmpty }

        let parts = [normalizedQuery, headingTitle, firstMeaningfulLine]
            .compactMap { $0 }
            .reduce(into: [String]()) { partialResult, item in
                let normalizedItem = MemoryTextNormalizer.collapsedWhitespace(item)
                guard !normalizedItem.isEmpty else { return }
                if !partialResult.contains(where: {
                    $0.caseInsensitiveCompare(normalizedItem) == .orderedSame
                }) {
                    partialResult.append(normalizedItem)
                }
            }

        if parts.isEmpty {
            return String(content.prefix(400))
        }

        return parts.joined(separator: "\n")
    }

    private func queryLooksThreadSpecific(_ query: String) -> Bool {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(query).lowercased()
        let tokens = [
            "thread",
            "chat",
            "conversation",
            "side note",
            "scratch",
            "temporary"
        ]
        return tokens.contains(where: normalized.contains)
    }

    private func requestRefersToCurrentNote(_ value: String) -> Bool {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        let directPhrases = [
            "this note",
            "the open note",
            "current note",
            "selected note",
            "this project note",
            "this thread note"
        ]

        return directPhrases.contains(where: normalized.contains)
    }

    private func requestMentionsNoteTitle(
        _ value: String,
        noteTitle: String
    ) -> Bool {
        let normalizedValue = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        let normalizedTitle = MemoryTextNormalizer.collapsedWhitespace(noteTitle).lowercased()

        guard !normalizedValue.isEmpty, !normalizedTitle.isEmpty else {
            return false
        }

        return normalizedValue.contains(normalizedTitle)
    }

    private func requestPrefersNewNoteFallback(_ value: String) -> Bool {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        let phrases = [
            "create a new note",
            "or create a new note",
            "new note",
            "best note",
            "most applicable note",
            "most applicable",
            "most relevant note",
            "appropriate note",
            "best place"
        ]

        return phrases.contains(where: normalized.contains)
    }

    private func makeBodySnippet(_ text: String, limit: Int = 220) -> String {
        MemoryTextNormalizer.normalizedSummary(
            text.replacingOccurrences(of: "\n", with: " "),
            limit: limit
        )
    }

    private func makeSearchSnippet(
        text: String,
        query: String,
        radius: Int = 140
    ) -> String {
        let normalizedText = normalizedMarkdown(text)
        let queryTokens = MemoryTextNormalizer.keywords(from: query, limit: 8)
        let loweredText = normalizedText.lowercased()
        guard let token = queryTokens.first(where: { loweredText.contains($0) }) else {
            return makeBodySnippet(normalizedText)
        }

        let nsLowered = loweredText as NSString
        let matchRange = nsLowered.range(of: token)
        guard matchRange.location != NSNotFound else {
            return makeBodySnippet(normalizedText)
        }

        let nsText = normalizedText as NSString
        let lowerLocation = max(0, matchRange.location - radius)
        let upperLocation = min(nsText.length, matchRange.location + matchRange.length + radius)
        let window = NSRange(location: lowerLocation, length: max(0, upperLocation - lowerLocation))
        var snippet = nsText.substring(with: window).trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerLocation > 0 {
            snippet = "..." + snippet
        }
        if upperLocation < nsText.length {
            snippet += "..."
        }
        return snippet
    }

    private func normalizedMarkdown(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func previewText(_ text: String, limit: Int = 4_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n...[truncated]"
    }

    private func successResult<T: Encodable>(
        payload: T,
        summary: String
    ) -> AssistantToolExecutionResult {
        AssistantToolExecutionResult(
            contentItems: [
                .init(type: "inputText", text: encodedJSONString(payload), imageURL: nil)
            ],
            success: true,
            summary: summary
        )
    }

    private func failureResult(_ message: String) -> AssistantToolExecutionResult {
        AssistantToolExecutionResult(
            contentItems: [
                .init(type: "inputText", text: message, imageURL: nil)
            ],
            success: false,
            summary: message
        )
    }

    private func encodedJSONString<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"error\":\"Could not encode assistant_notes payload.\"}"
    }

    private func stableNoteFingerprint(_ text: String) -> String {
        let normalized = normalizedMarkdown(text)
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func stableProjectManifestFingerprint(projectID: String) -> String? {
        guard let workspace = try? projectStore.loadProjectNotesWorkspace(projectID: projectID) else {
            return nil
        }
        let payload = workspace.manifest.orderedNotes.map { note in
            [
                note.id,
                note.title,
                note.noteType.rawValue,
                note.fileName,
                String(note.order),
                String(note.updatedAt.timeIntervalSince1970)
            ]
            .joined(separator: "|")
        }
        .joined(separator: "\n")
        return stableNoteFingerprint(payload)
    }

    private func threadMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func normalizeHeadingTitle(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"<!--[\s\S]*?-->"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedHeadingKey(_ value: String) -> String {
        normalizeHeadingTitle(value).lowercased()
    }

    private func headingSections(in markdown: String) -> [HeadingSection] {
        let normalizedText = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        let headingPattern = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)\s*$"#)

        struct PendingHeading {
            let title: String
            let normalizedTitle: String
            let level: Int
            let lineStartUTF16: Int
            let contentStartUTF16: Int
            let path: [String]
            let normalizedPath: [String]
        }

        var headings: [PendingHeading] = []
        var utf16Offset = 0
        var stack: [(level: Int, title: String, normalizedTitle: String)] = []

        for (index, line) in lines.enumerated() {
            let nsLine = line as NSString
            if let headingPattern,
               let match = headingPattern.firstMatch(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
               ) {
                let hashes = nsLine.substring(with: match.range(at: 1))
                let rawTitle = nsLine.substring(with: match.range(at: 2))
                let title = normalizeHeadingTitle(rawTitle)
                if !title.isEmpty {
                    let normalizedTitle = normalizedHeadingKey(title)
                    while let last = stack.last, last.level >= hashes.count {
                        stack.removeLast()
                    }
                    let path = stack.map(\.title) + [title]
                    let normalizedPath = stack.map(\.normalizedTitle) + [normalizedTitle]
                    let newlineLength = index < lines.count - 1 ? 1 : 0
                    headings.append(
                        PendingHeading(
                            title: title,
                            normalizedTitle: normalizedTitle,
                            level: hashes.count,
                            lineStartUTF16: utf16Offset,
                            contentStartUTF16: utf16Offset + nsLine.length + newlineLength,
                            path: path,
                            normalizedPath: normalizedPath
                        )
                    )
                    stack.append((level: hashes.count, title: title, normalizedTitle: normalizedTitle))
                }
            }

            utf16Offset += nsLine.length
            if index < lines.count - 1 {
                utf16Offset += 1
            }
        }

        let textLength = (normalizedText as NSString).length
        return headings.enumerated().map { index, heading in
            let nextBoundary = headings.dropFirst(index + 1)
                .first(where: { $0.level <= heading.level })?
                .lineStartUTF16
                ?? textLength
            return HeadingSection(
                title: heading.title,
                normalizedTitle: heading.normalizedTitle,
                level: heading.level,
                lineStartUTF16: heading.lineStartUTF16,
                contentStartUTF16: heading.contentStartUTF16,
                sectionEndUTF16: nextBoundary,
                path: heading.path,
                normalizedPath: heading.normalizedPath
            )
        }
    }

    private func headingOutline(from sections: [HeadingSection]) -> String {
        sections.map { section in
            let indent = String(repeating: "  ", count: max(0, section.path.count - 1))
            return "\(indent)- \(section.title)"
        }
        .joined(separator: "\n")
    }

    private func resolveHeadingSection(
        matching path: [String]?,
        in sections: [HeadingSection]
    ) -> HeadingSection? {
        let normalizedPath = path?
            .map(normalizedHeadingKey(_:))
            .filter { !$0.isEmpty }
        guard let normalizedPath, !normalizedPath.isEmpty else {
            return nil
        }

        let matches = sections.filter { $0.normalizedPath == normalizedPath }
        return matches.count == 1 ? matches[0] : nil
    }

    private func headingPathText(_ path: [String]) -> String {
        path.joined(separator: " > ")
    }

    private func insertMarkdownBlock(
        into markdown: String,
        block: String,
        atUTF16Offset offset: Int
    ) -> String {
        let normalizedText = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBlock.isEmpty else {
            return normalizedText
        }

        let nsMarkdown = normalizedText as NSString
        let safeOffset = max(0, min(offset, nsMarkdown.length))
        let prefix = nsMarkdown.substring(to: safeOffset)
        let suffix = nsMarkdown.substring(from: safeOffset)

        let leadingGap: String
        if prefix.isEmpty {
            leadingGap = ""
        } else if prefix.hasSuffix("\n\n") {
            leadingGap = ""
        } else if prefix.hasSuffix("\n") {
            leadingGap = "\n"
        } else {
            leadingGap = "\n\n"
        }

        let trailingGap: String
        if suffix.isEmpty {
            trailingGap = ""
        } else if suffix.hasPrefix("\n\n") {
            trailingGap = ""
        } else if suffix.hasPrefix("\n") {
            trailingGap = "\n"
        } else {
            trailingGap = "\n\n"
        }

        return prefix + leadingGap + trimmedBlock + trailingGap + suffix
    }
}
