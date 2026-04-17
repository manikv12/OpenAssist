import Foundation

struct AssistantPendingOutgoingMessage: Equatable {
    var text: String
    var imageAttachments: [Data]
    var createdAt: Date
}

struct AssistantQueuedPrompt {
    var text: String
    var attachments: [AssistantAttachment]
    var preferredModelID: String?
    var modelSupportsImageInput: Bool
    var selectedPluginIDs: [String]
    var automationJob: ScheduledJob?
    var createdAt: Date
    var submittedSlashCommand: AssistantSubmittedSlashCommand?
}

struct AssistantSessionExecutionState {
    var hudState: AssistantHUDState? = nil
    var planEntries: [AssistantPlanEntry] = []
    var toolCalls: [AssistantToolCallState] = []
    var recentToolCalls: [AssistantToolCallState] = []
    var pendingPermissionRequest: AssistantPermissionRequest? = nil
    var proposedPlan: String? = nil
    var hasActiveTurn = false
    var hasLiveClaudeProcess = false
    var subagents: [SubagentState] = []
    var pendingOutgoingMessage: AssistantPendingOutgoingMessage? = nil
    var queuedPrompts: [AssistantQueuedPrompt] = []
    var awaitingAssistantStart = false
}

struct AssistantSessionActivitySnapshot {
    let sessionID: String
    let hudState: AssistantHUDState?
    let hasActiveTurn: Bool
    let hasLiveClaudeProcess: Bool
    let canSteerActiveTurn: Bool
    let pendingPermissionRequest: AssistantPermissionRequest?
    let subagentCount: Int
    let pendingOutgoingMessage: AssistantPendingOutgoingMessage?
    let awaitingAssistantStart: Bool

    static let empty = AssistantSessionActivitySnapshot(
        sessionID: "",
        hudState: nil,
        hasActiveTurn: false,
        hasLiveClaudeProcess: false,
        canSteerActiveTurn: false,
        pendingPermissionRequest: nil,
        subagentCount: 0,
        pendingOutgoingMessage: nil,
        awaitingAssistantStart: false
    )
}
