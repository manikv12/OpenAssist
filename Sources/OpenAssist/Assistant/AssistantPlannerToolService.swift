import Foundation

enum AssistantPlannerToolAction: String, CaseIterable, Sendable {
    case readDay = "read_day"
    case searchDays = "search_days"
    case listOpenTasks = "list_open_tasks"
    case prepareAdd = "prepare_add"
    case prepareMove = "prepare_move"
    case prepareCarryForward = "prepare_carry_forward"
    case applyPreview = "apply_preview"
}

enum AssistantPlannerToolDefinition {
    static let name = "assistant_planner"
    static let toolKind = "assistantPlanner"

    static let description = """
    Read and manage the Open Assist daily planner (dated day pages like Today). Use this to read day files, search planner days, list unfinished tasks, prepare planner changes, carry unfinished tasks forward, and apply a prepared preview only after the user confirms it. Adds default to TODAY when no day is given, so do NOT use this tool for project notes or named notes — use `assistant_notes` for those. Only use this tool when the user clearly means the daily planner or a specific calendar day.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "One of read_day, search_days, list_open_tasks, prepare_add, prepare_move, prepare_carry_forward, or apply_preview."
            ],
            "dayId": [
                "type": "string",
                "description": "Planner day in YYYY-MM-DD format. Defaults to today."
            ],
            "targetDayId": [
                "type": "string",
                "description": "Target planner day in YYYY-MM-DD format for add, move, or carry-forward previews."
            ],
            "query": [
                "type": "string",
                "description": "Search text for search_days."
            ],
            "content": [
                "type": "string",
                "description": "Markdown content for prepare_add or prepare_move."
            ],
            "previewId": [
                "type": "string",
                "description": "Prepared preview id to apply when action is apply_preview."
            ]
        ],
        "required": ["action"],
        "additionalProperties": true
    ]
}

enum AssistantPlannerToolServiceError: LocalizedError {
    case invalidArguments(String)
    case applyBlockedInPlanMode

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .applyBlockedInPlanMode:
            return "apply_preview is blocked in Plan mode. Prepare the planner preview first, then switch to Agentic mode to save it."
        }
    }
}

struct AssistantPlannerRuntimeContext: Equatable, Sendable {
    let currentDayID: String?
    let selectedDayID: String?
    let selectedDayTitle: String?
    let linkedNoteTitles: [String]

    var instructionText: String {
        var lines = [
            "The Daily Planner is open. Use `assistant_planner` for planner reads and planner changes.",
        ]
        if let selectedDayID {
            lines.append("Selected planner day: \(selectedDayID).")
        }
        if let selectedDayTitle, !selectedDayTitle.isEmpty {
            lines.append("Selected planner title: \(selectedDayTitle).")
        }
        if let currentDayID {
            lines.append("Today in the local planner calendar is \(currentDayID).")
        }
        if !linkedNoteTitles.isEmpty {
            lines.append("Visible linked notes: \(linkedNoteTitles.joined(separator: ", ")).")
        }
        lines.append("For writes, prepare a preview first and only apply after user confirmation.")
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class AssistantPlannerToolService {
    struct ParsedRequest: Equatable, Sendable {
        let action: AssistantPlannerToolAction
        let dayID: String?
        let targetDayID: String?
        let query: String?
        let content: String?
        let previewID: String?

        var summaryLine: String {
            switch action {
            case .readDay:
                return "Read planner day \(dayID ?? "today")"
            case .searchDays:
                return "Search planner days"
            case .listOpenTasks:
                return "List open planner tasks"
            case .prepareAdd:
                return "Prepare planner add"
            case .prepareMove:
                return "Prepare planner move"
            case .prepareCarryForward:
                return "Prepare planner carry-forward"
            case .applyPreview:
                return "Apply planner preview"
            }
        }
    }

    private struct NoteItem: Codable, Equatable {
        let dayID: String
        let title: String
        let updatedAt: Date
        let snippet: String
    }

    private struct ReadResponse: Codable, Equatable {
        let action: String
        let dayID: String
        let title: String
        let markdown: String
    }

    private struct SearchResponse: Codable, Equatable {
        let action: String
        let query: String
        let dayCount: Int
        let days: [NoteItem]
    }

    private struct OpenTasksResponse: Codable, Equatable {
        let action: String
        let taskCount: Int
        let tasks: [String]
    }

    private struct PreviewResponse: Codable, Equatable {
        let action: String
        let previewID: String
        let kind: String
        let targetDayID: String?
        let summary: String
        let markdown: String
    }

    private let plannerStore: AssistantPlannerStore

    init(plannerStore: AssistantPlannerStore = AssistantPlannerStore()) {
        self.plannerStore = plannerStore
    }

    nonisolated static func parseRequest(from arguments: Any) throws -> ParsedRequest {
        guard let dictionary = arguments as? [String: Any] else {
            throw AssistantPlannerToolServiceError.invalidArguments(
                "assistant_planner needs a JSON object."
            )
        }
        guard let actionRaw = (dictionary["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              let action = AssistantPlannerToolAction(rawValue: actionRaw) else {
            throw AssistantPlannerToolServiceError.invalidArguments(
                "assistant_planner needs a valid `action`."
            )
        }
        return ParsedRequest(
            action: action,
            dayID: (dictionary["dayId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            targetDayID: (dictionary["targetDayId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            query: (dictionary["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            content: (dictionary["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            previewID: (dictionary["previewId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        )
    }

    func run(
        arguments: Any,
        runtimeContext: AssistantPlannerRuntimeContext?,
        interactionMode: AssistantInteractionMode
    ) async -> AssistantToolExecutionResult {
        do {
            let request = try Self.parseRequest(from: arguments)
            switch request.action {
            case .readDay:
                let dayID = request.dayID ?? runtimeContext?.selectedDayID ?? plannerStore.dayID(for: Date())
                let day = try plannerStore.loadDay(dayID: dayID)
                return successResult(
                    payload: ReadResponse(
                        action: request.action.rawValue,
                        dayID: day.dateContext.dayID,
                        title: day.note.title,
                        markdown: day.markdown
                    ),
                    summary: "Read planner day \(day.dateContext.dayID)."
                )

            case .searchDays:
                guard let query = request.query else {
                    throw AssistantPlannerToolServiceError.invalidArguments(
                        "search_days needs a non-empty `query`."
                    )
                }
                let notes = try plannerStore.searchDays(query: query)
                let response = SearchResponse(
                    action: request.action.rawValue,
                    query: query,
                    dayCount: notes.count,
                    days: notes.map(makeNoteItem)
                )
                return successResult(
                    payload: response,
                    summary: notes.isEmpty ? "No planner days matched." : "Found \(notes.count) planner days."
                )

            case .listOpenTasks:
                let tasks = try plannerStore.listOpenTasks()
                return successResult(
                    payload: OpenTasksResponse(
                        action: request.action.rawValue,
                        taskCount: tasks.count,
                        tasks: tasks
                    ),
                    summary: "Listed \(tasks.count) open planner tasks."
                )

            case .prepareAdd:
                guard let content = request.content else {
                    throw AssistantPlannerToolServiceError.invalidArguments(
                        "prepare_add needs non-empty `content`."
                    )
                }
                let targetDayID = request.targetDayID ?? request.dayID ?? runtimeContext?.selectedDayID ?? plannerStore.dayID(for: Date())
                let preview = try plannerStore.prepareAdd(dayID: targetDayID, content: content)
                return successResult(
                    payload: makePreviewResponse(action: request.action, preview: preview),
                    summary: preview.summary
                )

            case .prepareMove:
                guard let content = request.content else {
                    throw AssistantPlannerToolServiceError.invalidArguments(
                        "prepare_move needs non-empty `content`."
                    )
                }
                let targetDayID = request.targetDayID ?? runtimeContext?.selectedDayID ?? plannerStore.dayID(for: Date())
                let preview = try plannerStore.prepareAdd(dayID: targetDayID, content: content)
                return successResult(
                    payload: makePreviewResponse(action: request.action, preview: preview),
                    summary: preview.summary
                )

            case .prepareCarryForward:
                let sourceDayID = request.dayID ?? runtimeContext?.selectedDayID ?? plannerStore.dayID(for: Date())
                let fallbackTargetDayID = try plannerStore.dateContext(
                    for: plannerStore.date(from: sourceDayID)
                ).tomorrowID
                let targetDayID = request.targetDayID ?? fallbackTargetDayID
                let preview = try plannerStore.prepareCarryForward(from: sourceDayID, to: targetDayID)
                return successResult(
                    payload: makePreviewResponse(action: request.action, preview: preview),
                    summary: preview.summary
                )

            case .applyPreview:
                guard interactionMode != .plan else {
                    throw AssistantPlannerToolServiceError.applyBlockedInPlanMode
                }
                guard let previewID = request.previewID else {
                    throw AssistantPlannerToolServiceError.invalidArguments(
                        "apply_preview needs `previewId`."
                    )
                }
                let workspace = try plannerStore.applyPreview(id: previewID)
                return successResult(
                    payload: [
                        "action": request.action.rawValue,
                        "selectedDayId": workspace.selectedNote?.id ?? ""
                    ],
                    summary: "Saved the prepared planner change."
                )
            }
        } catch let error as AssistantPlannerToolServiceError {
            return failureResult(error.localizedDescription)
        } catch {
            return failureResult(
                error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                    ?? "assistant_planner failed."
            )
        }
    }

    private func makeNoteItem(from note: AssistantStoredNote) -> NoteItem {
        NoteItem(
            dayID: note.noteID,
            title: note.title,
            updatedAt: note.updatedAt,
            snippet: MemoryTextNormalizer.normalizedSummary(
                note.text.replacingOccurrences(of: "\n", with: " "),
                limit: 220
            )
        )
    }

    private func makePreviewResponse(
        action: AssistantPlannerToolAction,
        preview: AssistantPlannerPreview
    ) -> PreviewResponse {
        PreviewResponse(
            action: action.rawValue,
            previewID: preview.id,
            kind: preview.kind,
            targetDayID: preview.targetDayID,
            summary: preview.summary,
            markdown: preview.markdown
        )
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
        return "{\"error\":\"Could not encode assistant_planner payload.\"}"
    }
}
