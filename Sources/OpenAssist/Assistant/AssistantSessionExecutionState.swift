import Foundation

struct AssistantSessionExecutionState {
    var hudState: AssistantHUDState? = nil
    var planEntries: [AssistantPlanEntry] = []
    var toolCalls: [AssistantToolCallState] = []
    var recentToolCalls: [AssistantToolCallState] = []
    var pendingPermissionRequest: AssistantPermissionRequest? = nil
    var proposedPlan: String? = nil
    var hasActiveTurn = false
    var subagents: [SubagentState] = []
}

struct AssistantSessionActivitySnapshot {
    let sessionID: String
    let hudState: AssistantHUDState?
    let hasActiveTurn: Bool
    let pendingPermissionRequest: AssistantPermissionRequest?
    let subagentCount: Int

    static let empty = AssistantSessionActivitySnapshot(
        sessionID: "",
        hudState: nil,
        hasActiveTurn: false,
        pendingPermissionRequest: nil,
        subagentCount: 0
    )
}
