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

struct AssistantRemoteAttentionEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case completed
        case failed
        case permissionRequired

        var isTerminal: Bool {
            switch self {
            case .completed, .failed:
                return true
            case .permissionRequired:
                return false
            }
        }
    }

    let id: String
    let kind: Kind
    let createdAt: Date
    let turnID: String?
    let permissionRequestID: Int?
    let failureText: String?
}

struct AssistantSessionExecutionState {
    var hudState: AssistantHUDState? = nil
    var planEntries: [AssistantPlanEntry] = []
    var toolCalls: [AssistantToolCallState] = []
    var recentToolCalls: [AssistantToolCallState] = []
    var pendingPermissionRequest: AssistantPermissionRequest? = nil
    var latestRemoteAttentionEvent: AssistantRemoteAttentionEvent? = nil
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
    let currentTurnID: String?
    let hasLiveClaudeProcess: Bool
    let canSteerActiveTurn: Bool
    let pendingPermissionRequest: AssistantPermissionRequest?
    let latestRemoteAttentionEvent: AssistantRemoteAttentionEvent?
    let subagentCount: Int
    let pendingOutgoingMessage: AssistantPendingOutgoingMessage?
    let awaitingAssistantStart: Bool
    let queuedPromptCount: Int

    static let empty = AssistantSessionActivitySnapshot(
        sessionID: "",
        hudState: nil,
        hasActiveTurn: false,
        currentTurnID: nil,
        hasLiveClaudeProcess: false,
        canSteerActiveTurn: false,
        pendingPermissionRequest: nil,
        latestRemoteAttentionEvent: nil,
        subagentCount: 0,
        pendingOutgoingMessage: nil,
        awaitingAssistantStart: false,
        queuedPromptCount: 0
    )
}
