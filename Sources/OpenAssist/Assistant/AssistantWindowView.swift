import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AssistantSidebarPane {
    case threads
    case archived
    case automations
    case skills
}

extension AssistantSidebarPane {
    fileprivate var shellID: String {
        switch self {
        case .threads:
            return "threads"
        case .archived:
            return "archived"
        case .automations:
            return "automations"
        case .skills:
            return "skills"
        }
    }

    fileprivate init?(shellID: String) {
        switch shellID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "threads":
            self = .threads
        case "archived":
            self = .archived
        case "automations":
            self = .automations
        case "skills":
            self = .skills
        default:
            return nil
        }
    }
}

private struct AssistantProjectIconOption: Identifiable {
    let title: String
    let symbol: String

    var id: String { symbol }
}

private struct AssistantWorkspaceLaunchTarget: Identifiable {
    enum LaunchStyle {
        case openDocuments
        case revealInFinder
    }

    let title: String
    let bundleIdentifiers: [String]
    let fallbackSymbol: String
    let launchStyle: LaunchStyle
    let remembersAsPreferred: Bool

    var id: String { title }

    @MainActor
    var applicationURL: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier)
            {
                return url
            }
        }
        return nil
    }

    @MainActor
    var isInstalled: Bool {
        switch launchStyle {
        case .openDocuments:
            return applicationURL != nil
        case .revealInFinder:
            return true
        }
    }
}

struct AssistantWindowView: View {
    private static let initialVisibleHistoryLimit = 12
    private static let historyBatchSize = 12
    private static let autoScrollThreshold: CGFloat = 24
    private static let manualScrollFollowPause: TimeInterval = 0.85
    private static let manualLoadOlderPause: TimeInterval = 0.75
    private static let nearBottomThreshold: CGFloat = 80
    private static let loadOlderThreshold: CGFloat = 140
    private static let projectIconOptions: [AssistantProjectIconOption] = [
        .init(title: "Folder", symbol: "folder.fill"),
        .init(title: "Stack", symbol: "square.stack.3d.up.fill"),
        .init(title: "Briefcase", symbol: "briefcase.fill"),
        .init(title: "Book", symbol: "book.closed.fill"),
        .init(title: "Terminal", symbol: "terminal.fill"),
        .init(title: "Sparkles", symbol: "sparkles"),
        .init(title: "Star", symbol: "star.fill"),
        .init(title: "Brain", symbol: "brain"),
    ]
    private static let workspaceLaunchTargets: [AssistantWorkspaceLaunchTarget] = [
        .init(
            title: "VS Code",
            bundleIdentifiers: ["com.microsoft.VSCode"],
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "VS Code Insiders",
            bundleIdentifiers: ["com.microsoft.VSCodeInsiders"],
            fallbackSymbol: "chevron.left.forwardslash.chevron.right",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            fallbackSymbol: "command.square",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Windsurf",
            bundleIdentifiers: ["com.exafunction.windsurf"],
            fallbackSymbol: "wind",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Antigravity",
            bundleIdentifiers: ["com.google.antigravity"],
            fallbackSymbol: "sparkles",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Finder",
            bundleIdentifiers: ["com.apple.finder"],
            fallbackSymbol: "folder.fill",
            launchStyle: .revealInFinder,
            remembersAsPreferred: false
        ),
        .init(
            title: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            fallbackSymbol: "terminal.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: false
        ),
        .init(
            title: "Xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            fallbackSymbol: "hammer.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Android Studio",
            bundleIdentifiers: ["com.google.android.studio"],
            fallbackSymbol: "curlybraces.square.fill",
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
    ]
    private static let sidebarRelativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private struct ChatLayoutMetrics {
        let windowWidth: CGFloat
        let sidebarWidth: CGFloat
        let collapsedSidebarWidth: CGFloat
        let collapsedSidebarPreviewWidth: CGFloat
        let visibleSidebarWidth: CGFloat
        let outerPadding: CGFloat
        let timelineHorizontalPadding: CGFloat
        let contentMaxWidth: CGFloat
        let topBarMaxWidth: CGFloat
        let composerMaxWidth: CGFloat
        let userBubbleMaxWidth: CGFloat
        let userMediaMaxWidth: CGFloat
        let assistantMediaMaxWidth: CGFloat
        let leadingReserve: CGFloat
        let assistantTrailingPaddingRegular: CGFloat
        let assistantTrailingPaddingCompact: CGFloat
        let assistantTrailingPaddingStatus: CGFloat
        let activityLeadingPadding: CGFloat
        let activityTrailingPadding: CGFloat
        let jumpButtonTrailing: CGFloat
        let emptyStateCardWidth: CGFloat
        let emptyStateTextWidth: CGFloat
        let isNarrow: Bool
    }

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var assistant: AssistantStore
    @ObservedObject private var jobQueue = JobQueueCoordinator.shared

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingPermanentDeleteSession: AssistantSessionSummary?
    @State private var pendingDeleteProject: AssistantProject?
    @State private var showSessionInstructions = false
    @State private var userHasScrolledUp = false
    @State private var autoScrollPinnedToBottom = true
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit
    @State private var chatViewportHeight: CGFloat = 0
    @State private var composerMeasuredHeight: CGFloat?
    @State private var isLoadingOlderHistory = false
    @State private var hoveredInlineCopyMessageID: String?
    @State private var inlineCopyHideWorkItem: DispatchWorkItem?
    @State private var previewAttachment: AssistantAttachment?
    @State private var expandedHistoricalActivityRenderItemIDs: Set<String> = []
    @State private var expandedHistoricalConversationBlockIDs: Set<String> = []
    @State private var chatScrollTracking = AssistantChatScrollTracking()
    @State private var selectedSidebarPane: AssistantSidebarPane = .threads
    @State private var showSkillWizardSheet = false
    @State private var showGitHubSkillImportSheet = false
    @State private var pendingScrollToLatestWorkItem: DispatchWorkItem?
    @State private var suppressNextTimelineAutoScrollAnimation = true
    @State private var isLiveVoicePanelCollapsed = false
    @State private var isPreservingHistoryScrollPosition = false
    @State private var isWorkspaceLaunchPrimaryHovered = false
    @State private var cachedVisibleRenderItems: [AssistantTimelineRenderItem] = []
    @State private var chatWebContainer: AssistantChatWebContainerView?
    @State private var isThreadNoteOpen = false
    @State private var activeThreadNoteThreadID: String?
    @State private var threadNoteDraftTextByThreadID: [String: String] = [:]
    @State private var threadNoteLastSavedAtByThreadID: [String: Date] = [:]
    @State private var threadNoteSavingThreadIDs: Set<String> = []
    @StateObject private var selectionTracker = AssistantTextSelectionTracker.shared
    @AppStorage("assistantSidebarCollapsed") private var isSidebarCollapsed = false
    @State private var collapsedSidebarPreviewPane: String?
    @AppStorage("assistantSidebarProjectsExpanded") private var areProjectsExpanded = true
    @AppStorage("assistantSidebarThreadsExpanded") private var areThreadsExpanded = true
    @AppStorage("assistantSidebarArchivedExpanded") private var areArchivedExpanded = true
    @AppStorage("assistantChatTextScale") private var chatTextScale: Double = 1.0
    @AppStorage("assistantPreferredWorkspaceLaunchTargetID") private
        var preferredWorkspaceLaunchTargetID = ""

    /// Uses the pre-computed render items from AssistantStore (rebuilt only when
    /// timelineItems changes, not on every @Published update).
    private var allRenderItems: [AssistantTimelineRenderItem] {
        assistant.cachedRenderItems
    }

    private var visibleRenderItems: [AssistantTimelineRenderItem] {
        cachedVisibleRenderItems
    }

    private func recomputeVisibleRenderItems() {
        cachedVisibleRenderItems = assistantTimelineVisibleWindow(
            from: allRenderItems,
            visibleLimit: visibleHistoryLimit
        )
    }

    private var chatWebMessages: [AssistantChatWebMessage] {
        let _ = assistant.historyActionsRevision
        let historyActions = assistant.historyActionMetadata(for: visibleRenderItems)
        let renderContext = AssistantChatWebRenderContext(
            pendingPermissionRequest: assistant.pendingPermissionRequest,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            hasActiveTurn: assistant.hasActiveTurn,
            sessionStatusByNormalizedID: sessionStatusByNormalizedID,
            sessionWorkingDirectoryByNormalizedID: sessionWorkingDirectoryByNormalizedID
        )
        let collapsedConversationGroups = collapsedHistoricalConversationGroups(
            in: visibleRenderItems
        )
        let collapsedConversationGroupByFirstHiddenIndex = Dictionary(
            uniqueKeysWithValues: collapsedConversationGroups.map { ($0.firstHiddenIndex, $0) }
        )
        let collapsedConversationGroupByHiddenIndex = Dictionary(
            uniqueKeysWithValues: collapsedConversationGroups.flatMap { group in
                group.hiddenIndices.map { ($0, group) }
            }
        )
        var messages: [AssistantChatWebMessage] = []

        for (index, renderItem) in visibleRenderItems.enumerated() {
            let expandedConversationGroup = collapsedConversationGroupByHiddenIndex[index].flatMap {
                expandedHistoricalConversationBlockIDs.contains($0.id) ? $0 : nil
            }

            if let group = collapsedConversationGroupByFirstHiddenIndex[index],
                let summary = AssistantChatWebMessage.collapsedConversationSummary(
                    hiddenRenderItems: group.hiddenRenderItems,
                    blockID: group.id,
                    expanded: expandedHistoricalConversationBlockIDs.contains(group.id)
                )
            {
                messages.append(summary)
                if !expandedHistoricalConversationBlockIDs.contains(group.id) {
                    continue
                }
            } else if let group = collapsedConversationGroupByHiddenIndex[index],
                !expandedHistoricalConversationBlockIDs.contains(group.id)
            {
                continue
            }

            if expandedConversationGroup == nil,
                shouldCollapseHistoricalActivityRenderItem(
                    renderItem,
                    at: index,
                    in: visibleRenderItems
                ),
                let summary = AssistantChatWebMessage.collapsedActivitySummary(
                    renderItem: renderItem
                )
            {
                messages.append(summary)
                continue
            }

            if expandedHistoricalActivityRenderItemIDs.contains(renderItem.id),
                let summary = AssistantChatWebMessage.expandedActivitySummary(
                    renderItem: renderItem
                )
            {
                messages.append(summary)
            }

            messages.append(
                contentsOf: AssistantChatWebMessage.from(
                    renderItem: renderItem,
                    historyActions: historyActions,
                    renderContext: renderContext
                )
            )
        }

        return messages
    }

    private var chatWebRewindState: AssistantChatWebRewindState? {
        guard let branch = assistant.historyBranchState,
              assistant.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == branch.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return nil
        }

        let redoHostMessageID = chatWebMessages.reversed().first(where: {
            $0.type == "assistant"
        })?.id

        return AssistantChatWebRewindState(
            kind: branch.kind.rawValue,
            canStepBackward: assistant.canStepHistoryBranchBackward,
            redoHostMessageID: redoHostMessageID
        )
    }

    private var selectedThreadNoteID: String? {
        assistant.selectedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
    }

    private var currentThreadNoteDraftText: String {
        guard let threadID = selectedThreadNoteID else { return "" }
        if let draft = threadNoteDraftTextByThreadID[threadID] {
            return draft
        }
        return assistant.loadThreadNote(threadID: threadID)
    }

    private var chatWebThreadNoteState: AssistantChatWebThreadNoteState {
        let threadID = selectedThreadNoteID
        let text = currentThreadNoteDraftText
        let hasNote = text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
        let savedAt = threadID.flatMap { threadNoteLastSavedAtByThreadID[$0] ?? assistant.threadNoteLastSavedAt(threadID: $0) }

        return AssistantChatWebThreadNoteState(
            threadID: threadID,
            text: text,
            isOpen: threadID == nil ? false : isThreadNoteOpen,
            hasNote: hasNote,
            isSaving: threadID.map { threadNoteSavingThreadIDs.contains($0) } ?? false,
            lastSavedAtLabel: threadNoteSavedLabel(for: savedAt),
            canEdit: threadID != nil,
            placeholder: "Write decisions, next steps, constraints, and follow-ups for this thread. Type / for Markdown blocks."
        )
    }

    private func threadNoteSavedLabel(for date: Date?) -> String? {
        guard let date else { return nil }
        let relative = Self.sidebarRelativeDateFormatter.localizedString(for: date, relativeTo: Date())
        return relative == "now" ? "Saved now" : "Saved \(relative)"
    }

    private func syncThreadNoteSelection(_ sessionID: String?, persistCurrent: Bool) {
        if persistCurrent {
            persistThreadNoteIfNeeded(for: activeThreadNoteThreadID)
        }

        let nextThreadID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
        activeThreadNoteThreadID = nextThreadID

        guard let nextThreadID else {
            isThreadNoteOpen = false
            return
        }

        if threadNoteDraftTextByThreadID[nextThreadID] == nil {
            threadNoteDraftTextByThreadID[nextThreadID] = assistant.loadThreadNote(threadID: nextThreadID)
        }
        if threadNoteLastSavedAtByThreadID[nextThreadID] == nil,
           let savedAt = assistant.threadNoteLastSavedAt(threadID: nextThreadID) {
            threadNoteLastSavedAtByThreadID[nextThreadID] = savedAt
        }
    }

    private func persistThreadNoteIfNeeded(for threadID: String?) {
        guard let threadID,
              let draftText = threadNoteDraftTextByThreadID[threadID] else {
            return
        }

        threadNoteSavingThreadIDs.insert(threadID)
        assistant.saveThreadNote(threadID: threadID, text: draftText)
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            threadNoteLastSavedAtByThreadID[threadID] = Date()
        } else {
            threadNoteLastSavedAtByThreadID.removeValue(forKey: threadID)
        }
        threadNoteSavingThreadIDs.remove(threadID)
    }

    private func toggleThreadNoteDrawer() {
        if isThreadNoteOpen {
            persistThreadNoteIfNeeded(for: selectedThreadNoteID)
        } else {
            syncThreadNoteSelection(assistant.selectedSessionID, persistCurrent: false)
        }
        isThreadNoteOpen.toggle()
    }

    private func handleThreadNoteCommand(_ command: AssistantChatWebThreadNoteCommand) {
        let resolvedThreadID = command.threadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased() ?? selectedThreadNoteID

        switch command.type {
        case "setOpen":
            guard let isOpen = command.isOpen else { return }
            if !isOpen {
                persistThreadNoteIfNeeded(for: resolvedThreadID)
            } else {
                syncThreadNoteSelection(resolvedThreadID, persistCurrent: false)
            }
            isThreadNoteOpen = isOpen
        case "updateDraft":
            guard let resolvedThreadID, let text = command.text else { return }
            threadNoteDraftTextByThreadID[resolvedThreadID] = text
        case "save":
            guard let resolvedThreadID else { return }
            if let text = command.text {
                threadNoteDraftTextByThreadID[resolvedThreadID] = text
            }
            persistThreadNoteIfNeeded(for: resolvedThreadID)
        default:
            break
        }
    }

    private func loadOlderHistoryBatchWeb() {
        guard !isLoadingOlderHistory else { return }

        if hiddenRenderItemCount > 0 {
            visibleHistoryLimit += Self.historyBatchSize
            recomputeVisibleRenderItems()
        } else {
            isLoadingOlderHistory = true
            Task {
                _ = await assistant.loadMoreHistoryForSelectedSession()
                await MainActor.run {
                    visibleHistoryLimit += Self.historyBatchSize
                    recomputeVisibleRenderItems()
                    isLoadingOlderHistory = false
                }
            }
        }
    }

    private var hiddenRenderItemCount: Int {
        max(0, allRenderItems.count - visibleRenderItems.count)
    }

    private var chatViewportContentMinHeight: CGFloat {
        max(260, chatViewportHeight - 24)
    }

    private var canScrollToLatestVisibleContent: Bool {
        !visibleRenderItems.isEmpty || shouldShowPendingAssistantPlaceholder
    }

    private var hasVisibleStreamingAssistantMessage: Bool {
        guard let lastVisibleItem = visibleRenderItems.last else { return false }
        guard case .timeline(let item) = lastVisibleItem else { return false }
        switch item.kind {
        case .assistantProgress, .assistantFinal:
            return item.isStreaming
        default:
            return false
        }
    }

    private var shouldShowPendingAssistantPlaceholder: Bool {
        assistantShouldShowPendingAssistantPlaceholder(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            hasPendingPermissionRequest: assistant.pendingPermissionRequest != nil,
            hasVisibleStreamingAssistantMessage: hasVisibleStreamingAssistantMessage,
            hudPhase: assistant.hudState.phase
        )
    }

    private var canLoadOlderHistory: Bool {
        hiddenRenderItemCount > 0 || assistant.selectedSessionCanLoadMoreHistory
    }

    private var timelineLastUpdatedAt: Date {
        allRenderItems.last?.lastUpdatedAt ?? .distantPast
    }

    /// Pre-built lookup from lowercased-trimmed session ID → session status,
    /// avoiding O(n) linear scan with string trimming per permission card.
    private var sessionStatusByNormalizedID: [String: AssistantSessionStatus] {
        var dict = [String: AssistantSessionStatus]()
        dict.reserveCapacity(assistant.sessions.count)
        for session in assistant.sessions {
            let key = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { dict[key] = session.status }
        }
        return dict
    }

    private var sessionWorkingDirectoryByNormalizedID: [String: String] {
        var dict = [String: String]()
        dict.reserveCapacity(assistant.sessions.count)
        for session in assistant.sessions {
            let key = session.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cwd = session.effectiveCWD?.assistantNonEmpty ?? session.cwd?.assistantNonEmpty
            if !key.isEmpty, let cwd {
                dict[key] = cwd
            }
        }
        return dict
    }

    private func sessionStatus(forSessionID sessionID: String?) -> AssistantSessionStatus? {
        guard let sid = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !sid.isEmpty
        else { return nil }
        return sessionStatusByNormalizedID[sid]
    }

    private var shouldAutoFollowLatestMessage: Bool {
        autoScrollPinnedToBottom
            && !userHasScrolledUp
            && !isPreservingHistoryScrollPosition
            && Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt)
                >= Self.manualScrollFollowPause
    }

    private var isAgentBusy: Bool {
        let phase = assistant.hudState.phase
        return phase == .acting || phase == .thinking || phase == .streaming
    }

    private var isVoiceCapturing: Bool {
        assistant.hudState.phase == .listening
    }

    private var canChat: Bool {
        assistant.isRuntimeReadyForConversation
    }

    private var canStartConversation: Bool {
        settings.assistantBetaEnabled && assistant.canStartConversation
    }

    private var sidebarTextScale: CGFloat {
        CGFloat(chatTextScale)
    }

    private var sidebarToggleAnimation: Animation {
        .timingCurve(0.22, 0.84, 0.24, 1.0, duration: 0.16)
    }

    private var sidebarDisclosureAnimation: Animation {
        .timingCurve(0.24, 0.82, 0.26, 1.0, duration: 0.13)
    }

    private var sidebarListAnimation: Animation {
        .easeOut(duration: 0.12)
    }

    private var sidebarRowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.997, anchor: .top)),
            removal: .opacity
        )
    }

    private func sidebarScaled(_ value: CGFloat) -> CGFloat {
        value * sidebarTextScale
    }

    private func scaledSidebarWidth(for safeWindowWidth: CGFloat, outerPadding: CGFloat) -> CGFloat
    {
        let baseSidebarWidth = min(260.0, max(210.0, safeWindowWidth * 0.22))
        let expandedSidebarWidth = baseSidebarWidth * max(1.0, sidebarTextScale)
        let maxSidebarWidth = max(210.0, safeWindowWidth - (outerPadding * 2) - 320.0 - 0.5)
        return min(expandedSidebarWidth, maxSidebarWidth)
    }

    private func sidebarActivityState(for session: AssistantSessionSummary)
        -> AssistantSessionRow.ActivityState
    {
        let activity = assistant.sessionActivitySnapshot(for: session.id)
        return assistantSidebarActivityState(
            forSessionID: session.id,
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: activity.hasActiveTurn ? session.id : nil,
            sessionStatus: session.status,
            hasPendingPermissionRequest: activity.pendingPermissionRequest != nil,
            hudPhase: activity.hudState?.phase ?? .idle,
            isTransitioningSession: assistant.isTransitioningSession
                && assistant.selectedSessionID == session.id,
            isLiveVoiceSessionActive: assistant.isLiveVoiceSessionActive
                && assistant.selectedSessionID == session.id,
            hasActiveTurn: activity.hasActiveTurn
        )
    }

    private func sidebarChildSubagents(for session: AssistantSessionSummary) -> [SubagentState] {
        assistantSidebarChildSubagents(
            parentSessionID: session.id,
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            subagents: assistant.subagents
        )
    }

    private func openThread(_ threadID: String) {
        Task { await assistant.openSession(threadID: threadID) }
    }

    private func revealLatestFileChangeActivity() {
        guard let latestFileChangeMessageID else { return }
        chatWebContainer?.revealMessage(id: latestFileChangeMessageID, animated: true, expand: true)
    }

    private var shouldShowLiveVoicePanel: Bool {
        settings.assistantBetaEnabled
    }

    private var liveVoiceStatusText: String {
        assistant.liveVoiceSessionSnapshot.displayText
    }

    private var liveVoiceTranscriptStatusText: String? {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .sending, .waitingForPermission, .speaking, .paused, .ended:
            return assistant.liveVoiceSessionSnapshot.transcriptStatusText
        case .idle, .listening, .transcribing:
            return nil
        }
    }

    private var liveVoiceStatusSymbol: String {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .idle, .ended:
            return "person.wave.2.fill"
        case .listening:
            return "mic.fill"
        case .transcribing, .sending:
            return "waveform"
        case .waitingForPermission:
            return "hand.raised.fill"
        case .speaking:
            return "speaker.wave.2.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }

    private var liveVoiceStatusTint: Color {
        switch assistant.liveVoiceSessionSnapshot.phase {
        case .waitingForPermission:
            return .orange
        case .speaking:
            return .purple
        case .listening:
            return .green
        case .transcribing, .sending:
            return .cyan
        case .paused:
            return .yellow
        case .idle, .ended:
            return .cyan
        }
    }

    private var composerPlaceholder: String {
        if !settings.assistantBetaEnabled {
            return "Enable assistant in Settings to chat."
        }
        if isVoiceCapturing {
            return "Listening... release to paste."
        }
        if assistant.isLoadingModels {
            return "Loading models..."
        }
        if assistant.selectedModel == nil {
            return assistant.visibleModels.isEmpty
                ? "Models will appear here when \(assistant.visibleAssistantBackendName) is ready."
                : "Select a model to start chatting..."
        }
        return "What would you like to do?"
    }

    private var emptyStateMessage: String {
        if !settings.assistantBetaEnabled {
            return "Enable the assistant in Settings, then come back here."
        }
        if !canChat {
            return
                "Open Setup to connect to \(assistant.visibleAssistantBackendName), then come back to chat."
        }
        return assistant.conversationBlockedReason
            ?? "Send a message to start a conversation with the assistant."
    }

    private var activeSessionSummary: AssistantSessionSummary? {
        guard let selectedSessionID = assistant.selectedSessionID else { return nil }
        return assistant.sessions.first(where: {
            assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
        })
    }

    private var activeSessionProject: AssistantProject? {
        guard
            let projectID = activeSessionSummary?.projectID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty
        else {
            return nil
        }
        return assistant.visibleProjects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    private var activeSessionTitle: String {
        guard let activeSessionSummary else { return "No session selected" }
        if activeSessionSummary.isTemporary,
            activeSessionSummary.title.caseInsensitiveCompare("New Assistant Session")
                == .orderedSame
        {
            return "Temporary Chat"
        }
        return activeSessionSummary.title
    }

    private var activeSessionHeaderTitle: String {
        shortHeaderTitle(activeSessionTitle, maxWords: 5)
    }

    private var activeSessionWorkspaceURL: URL? {
        existingDirectoryURL(for: activeSessionSummary?.linkedProjectFolderPath)
            ?? existingDirectoryURL(for: activeSessionSummary?.effectiveCWD)
            ?? existingDirectoryURL(for: activeSessionSummary?.cwd)
    }

    private var primaryWorkspaceLaunchTarget: AssistantWorkspaceLaunchTarget {
        if let preferred = Self.workspaceLaunchTargets.first(where: {
            $0.id == preferredWorkspaceLaunchTargetID && $0.remembersAsPreferred && $0.isInstalled
        }) {
            return preferred
        }

        return Self.workspaceLaunchTargets.first(where: {
            $0.remembersAsPreferred && $0.isInstalled
        })
            ?? Self.workspaceLaunchTargets.first(where: { $0.isInstalled })
            ?? Self.workspaceLaunchTargets.first
            ?? AssistantWorkspaceLaunchTarget(
                title: "Finder",
                bundleIdentifiers: ["com.apple.finder"],
                fallbackSymbol: "folder.fill",
                launchStyle: .revealInFinder,
                remembersAsPreferred: false
            )
    }

    private func existingDirectoryURL(for path: String?) -> URL? {
        guard let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return nil
        }

        let candidateURL = URL(fileURLWithPath: normalizedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory)
        else {
            return nil
        }

        if isDirectory.boolValue {
            return candidateURL
        }

        let parentURL = candidateURL.deletingLastPathComponent()
        guard parentURL.path != candidateURL.path else { return nil }
        return parentURL
    }

    private func shortHeaderTitle(_ title: String, maxWords: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxWords > 0 else { return trimmed }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return words.joined(separator: " ") }

        return words.prefix(maxWords).joined(separator: " ") + "..."
    }

    private var visibleSidebarSessionCount: Int {
        assistant.visibleSidebarSessions.count
    }

    private var visibleArchivedSessionCount: Int {
        assistant.visibleArchivedSidebarSessions.count
    }

    private func composerFallbackHeight(for layout: ChatLayoutMetrics) -> CGFloat {
        let accessoryRowCount =
            (assistant.activeThreadSkills.isEmpty ? 0 : 1)
            + (assistant.attachments.isEmpty ? 0 : 1)

        return 182 + (CGFloat(accessoryRowCount) * 34)
    }

    private func composerWebHeight(for layout: ChatLayoutMetrics) -> CGFloat {
        let minHeight: CGFloat = 170
        let maxHeight: CGFloat = 300
        let proposedHeight = composerMeasuredHeight ?? composerFallbackHeight(for: layout)
        return min(max(proposedHeight, minHeight), maxHeight)
    }

    private func updateComposerMeasuredHeight(_ height: CGFloat) {
        guard height.isFinite else { return }

        let boundedHeight = min(max(ceil(height), 140), 420)
        guard composerMeasuredHeight == nil || abs((composerMeasuredHeight ?? 0) - boundedHeight) > 1
        else {
            return
        }

        composerMeasuredHeight = boundedHeight
    }

    private var sidebarWebState: AssistantSidebarWebState {
        AssistantSidebarWebState(
            selectedPane: selectedSidebarPane.shellID,
            isCollapsed: isSidebarCollapsed,
            collapsedPreviewPane: collapsedSidebarPreviewPane,
            canCreateThread: assistant.canCreateThread,
            canCollapse: true,
            projectsTitle: projectSectionTitle,
            projectsHelperText: sidebarProjectsHelperText,
            threadsTitle: "Threads",
            threadsHelperText: threadsFilterHelperText,
            archivedTitle: "Archived",
            archivedHelperText: visibleArchivedSessionCount == 0
                ? nil : "Older chats you saved for later.",
            projectsExpanded: areProjectsExpanded,
            threadsExpanded: areThreadsExpanded,
            archivedExpanded: areArchivedExpanded,
            canLoadMoreThreads: visibleSidebarSessionCount > assistant.visibleSessionsLimit,
            canLoadMoreArchived: visibleArchivedSessionCount > assistant.visibleSessionsLimit,
            archivedCount: visibleArchivedSessionCount,
            hiddenProjectCount: assistant.hiddenProjects.count,
            navItems: [
                .init(
                    id: AssistantSidebarPane.threads.shellID, label: "Threads",
                    symbol: "bubble.left.and.bubble.right"),
                .init(
                    id: AssistantSidebarPane.automations.shellID, label: "Automations",
                    symbol: "clock"),
                .init(id: AssistantSidebarPane.skills.shellID, label: "Skills", symbol: "sparkles"),
            ],
            allProjects: assistant.visibleProjects.map { project in
                let isSelected =
                    assistant.selectedProjectFilterID?.caseInsensitiveCompare(project.id)
                    == .orderedSame
                return AssistantSidebarWebProject(
                    id: project.id,
                    name: project.name,
                    symbol: project.displayIconSymbolName,
                    subtitle: projectThreadSubtitle(for: project, focused: isSelected),
                    isSelected: isSelected,
                    hasLinkedFolder: project.linkedFolderPath?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nonEmpty != nil,
                    hasCustomIcon: project.iconSymbolName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nonEmpty != nil
                )
            },
            hiddenProjects: assistant.hiddenProjects.map { project in
                AssistantSidebarWebHiddenProject(
                    id: project.id,
                    name: project.name,
                    symbol: project.displayIconSymbolName
                )
            },
            projects: displayedSidebarProjects.map { project in
                let isSelected =
                    assistant.selectedProjectFilterID?.caseInsensitiveCompare(project.id)
                    == .orderedSame
                return AssistantSidebarWebProject(
                    id: project.id,
                    name: project.name,
                    symbol: project.displayIconSymbolName,
                    subtitle: projectThreadSubtitle(for: project, focused: isSelected),
                    isSelected: isSelected,
                    hasLinkedFolder: project.linkedFolderPath?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nonEmpty != nil,
                    hasCustomIcon: project.iconSymbolName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nonEmpty != nil
                )
            },
            threads: assistant.visibleSidebarSessions
                .prefix(assistant.visibleSessionsLimit)
                .map { sidebarWebSession(for: $0) },
            archived: assistant.visibleArchivedSidebarSessions
                .prefix(assistant.visibleSessionsLimit)
                .map { sidebarWebSession(for: $0) }
        )
    }

    private var composerWebState: AssistantComposerWebState {
        AssistantComposerWebState(
            draftText: assistant.promptDraft,
            placeholder: composerPlaceholder,
            isEnabled: settings.assistantBetaEnabled && !isVoiceCapturing,
            canSend: canSendMessage && !isVoiceCapturing,
            isBusy: isAgentBusy,
            isVoiceCapturing: isVoiceCapturing,
            canUseVoiceInput: settings.assistantVoiceTaskEntryEnabled,
            showStopVoicePlayback: assistant.assistantVoicePlaybackActive && !isAgentBusy,
            canOpenSkills: assistant.canAttachSkillsToSelectedThread,
            selectedInteractionMode: assistant.interactionMode.normalizedForActiveUse.rawValue,
            interactionModes: AssistantInteractionMode.allCases.map {
                AssistantComposerWebOption(id: $0.rawValue, label: $0.label)
            },
            selectedModelID: assistant.selectedModelID,
            modelOptions: assistant.visibleModels.map {
                AssistantComposerWebOption(id: $0.id, label: $0.displayName)
            },
            selectedReasoningID: assistant.reasoningEffort.rawValue,
            reasoningOptions: supportedEfforts.map {
                AssistantComposerWebOption(id: $0.rawValue, label: $0.label)
            },
            activeSkills: assistant.activeThreadSkills.map {
                AssistantComposerWebSkill(
                    skillName: $0.skillName,
                    displayName: $0.displayName,
                    isMissing: $0.isMissing
                )
            },
            attachments: assistant.attachments.map {
                AssistantComposerWebAttachment(
                    id: $0.id.uuidString,
                    filename: $0.filename,
                    kind: $0.isImage ? "image" : "file",
                    previewDataURL: $0.isImage ? $0.dataURL : nil
                )
            }
        )
    }

    private var sidebarSessionAnimationKey: String {
        (assistant.visibleSidebarSessions + assistant.visibleArchivedSidebarSessions).map {
            session in
            let updatedAt = session.updatedAt ?? session.createdAt ?? .distantPast
            return
                "\(session.id)|\(session.title)|\(session.isArchived)|\(updatedAt.timeIntervalSince1970)"
        }
        .joined(separator: "||")
    }

    private var archiveRetentionOptions: [Int] {
        Array(Set([24, 24 * 7, 24 * 30, settings.assistantArchiveDefaultRetentionHours])).sorted()
    }

    private var projectThreadCountByProjectID: [String: Int] {
        assistant.visibleSidebarSessions.reduce(into: [:]) { result, session in
            guard
                let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            else {
                return
            }
            result[projectID, default: 0] += 1
        }
    }

    private var displayedSidebarProjects: [AssistantProject] {
        if let selectedProject = assistant.selectedProjectFilter {
            return [selectedProject]
        }
        return assistant.visibleProjects
    }

    private var isProjectFocusModeActive: Bool {
        assistant.selectedProjectFilter != nil
    }

    private var projectSectionTitle: String {
        isProjectFocusModeActive ? "Project" : "Projects"
    }

    private var sidebarProjectsHelperText: String? {
        if isProjectFocusModeActive {
            return "Click the current project again to go back to all projects."
        }

        let hiddenProjectCount = assistant.hiddenProjects.count
        guard hiddenProjectCount > 0 else { return nil }
        return hiddenProjectCount == 1
            ? "1 project is hidden right now."
            : "\(hiddenProjectCount) projects are hidden right now."
    }

    private var threadsFilterHelperText: String? {
        guard let project = assistant.selectedProjectFilter else { return nil }
        return "Only \(project.name) threads are shown. New threads stay here."
    }

    private func projectThreadSubtitle(for project: AssistantProject, focused: Bool) -> String {
        let count = projectThreadCountByProjectID[project.id.lowercased(), default: 0]

        switch count {
        case 0:
            return focused ? "No threads here yet" : "No threads yet"
        case 1:
            return focused ? "1 thread here" : "1 thread"
        default:
            return focused ? "\(count) threads here" : "\(count) threads"
        }
    }

    private func showArchivedSidebar() {
        selectedSidebarPane = .archived
        guard let firstArchivedSession = assistant.visibleArchivedSidebarSessions.first else {
            return
        }
        let isAlreadySelected =
            assistant.selectedSessionID?.caseInsensitiveCompare(firstArchivedSession.id)
            == .orderedSame
        guard !isAlreadySelected else { return }
        Task { await assistant.openSession(firstArchivedSession) }
    }

    private func sidebarWebSession(for session: AssistantSessionSummary)
        -> AssistantSidebarWebSession
    {
        AssistantSidebarWebSession(
            id: session.id,
            title: session.title,
            subtitle: session.subtitle,
            timeLabel: sidebarTimeLabel(for: session),
            isSelected: assistant.selectedSessionID.map {
                assistantTimelineSessionIDsMatch(session.id, $0)
            } ?? false,
            isTemporary: session.isTemporary,
            projectID: session.projectID
        )
    }

    private func sidebarTimeLabel(for session: AssistantSessionSummary) -> String? {
        guard let referenceDate = session.updatedAt ?? session.createdAt else { return nil }
        return Self.sidebarRelativeDateFormatter.localizedString(
            for: referenceDate, relativeTo: Date())
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        withAnimation(sidebarToggleAnimation) {
            isSidebarCollapsed = collapsed
            collapsedSidebarPreviewPane = nil
        }
    }

    private func sidebarProject(for projectID: String) -> AssistantProject? {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return nil }
        return (assistant.visibleProjects + assistant.hiddenProjects).first {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedProjectID) == .orderedSame
        }
    }

    private func sidebarSession(for sessionID: String) -> AssistantSessionSummary? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        return assistant.sessions.first {
            assistantTimelineSessionIDsMatch($0.id, normalizedSessionID)
        }
    }

    private func archiveRetentionLabel(for hours: Int) -> String {
        if hours % (24 * 30) == 0 {
            let months = max(1, hours / (24 * 30))
            return months == 1 ? "1 month" : "\(months) months"
        }
        if hours % (24 * 7) == 0 {
            let weeks = max(1, hours / (24 * 7))
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        if hours % 24 == 0 {
            let days = max(1, hours / 24)
            return days == 1 ? "24 hours" : "\(days) days"
        }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func startNewThreadFromSidebar() {
        selectedSidebarPane = .threads
        if !areThreadsExpanded {
            withAnimation(sidebarDisclosureAnimation) {
                areThreadsExpanded = true
            }
        }
        Task { await assistant.startNewSession() }
    }

    private func handleSidebarWebCommand(type: String, payload: [String: Any]?) {
        switch type {
        case "newThread":
            startNewThreadFromSidebar()
        case "setSidebarCollapsed":
            guard let collapsed = payload?["collapsed"] as? Bool else { return }
            setSidebarCollapsed(collapsed)
        case "setSelectedPane":
            guard let paneID = payload?["pane"] as? String,
                let pane = AssistantSidebarPane(shellID: paneID)
            else {
                return
            }
            if pane == .archived {
                showArchivedSidebar()
            } else {
                selectedSidebarPane = pane
            }
        case "setCollapsedPreviewPane":
            let isOpen = payload?["open"] as? Bool ?? false
            let paneID = (payload?["pane"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            withAnimation(sidebarToggleAnimation) {
                collapsedSidebarPreviewPane = isOpen ? paneID : nil
            }
        case "toggleProjectsExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areProjectsExpanded.toggle()
            }
        case "toggleThreadsExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areThreadsExpanded.toggle()
            }
        case "toggleArchivedExpanded":
            withAnimation(sidebarDisclosureAnimation) {
                areArchivedExpanded.toggle()
            }
        case "selectProjectFilter":
            selectedSidebarPane = .threads
            let projectID = (payload?["projectId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            Task { await assistant.selectProjectFilter(projectID) }
        case "openSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            if let paneID = payload?["pane"] as? String,
                paneID.caseInsensitiveCompare(AssistantSidebarPane.archived.shellID) == .orderedSame
            {
                selectedSidebarPane = .archived
            } else {
                selectedSidebarPane = .threads
            }
            openThread(sessionID)
        case "loadMoreSessions":
            assistant.loadMoreSessions()
        case "createProjectPrompt":
            presentCreateProjectPrompt()
        case "createProjectFromFolderPrompt":
            presentCreateProjectFromFolderPrompt()
        case "createNamedProjectPrompt":
            presentNamedProjectPrompt()
        case "unhideProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task { await assistant.unhideProject(projectID) }
        case "inspectProjectMemory":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            assistant.inspectMemory(for: project)
        case "renameProjectPrompt":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentRenameProjectPrompt(for: project)
        case "changeProjectIconPrompt":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentProjectIconPrompt(for: project)
        case "setProjectIcon":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let symbol = (payload?["symbol"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.updateProjectIcon(projectID, symbol: symbol)
        case "linkProjectFolder":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            presentProjectFolderPicker(for: project)
        case "removeProjectFolderLink":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.updateProjectLinkedFolder(projectID, path: nil)
        case "hideProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task { await assistant.hideProject(projectID) }
        case "deleteProject":
            guard
                let projectID = (payload?["projectId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let project = sidebarProject(for: projectID)
            else {
                return
            }
            pendingDeleteProject = project
        case "renameSessionPrompt":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let session = sidebarSession(for: sessionID)
            else {
                return
            }
            presentRenameSessionPrompt(for: session)
        case "promoteTemporarySession":
            let sessionID = (payload?["sessionId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.promoteTemporarySession(sessionID)
        case "assignSessionToProject":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            let projectID = (payload?["projectId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            assistant.assignSessionToProject(sessionID, projectID: projectID)
        case "removeSessionFromProject":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.assignSessionToProject(sessionID, projectID: nil)
        case "archiveSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task {
                await assistant.archiveSession(
                    sessionID,
                    retentionHours: settings.assistantArchiveDefaultRetentionHours,
                    updateDefaultRetention: false
                )
            }
        case "unarchiveSession":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            Task {
                await assistant.unarchiveSession(sessionID)
                guard selectedSidebarPane == .archived else { return }
                await MainActor.run {
                    showArchivedSidebar()
                }
            }
        case "deleteSessionPermanently":
            guard
                let sessionID = (payload?["sessionId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty,
                let session = sidebarSession(for: sessionID)
            else {
                return
            }
            pendingPermanentDeleteSession = session
        case "openAssistantSetup":
            NotificationCenter.default.post(name: .openAssistOpenAssistantSetup, object: nil)
        default:
            break
        }
    }

    private func handleComposerWebCommand(type: String, payload: [String: Any]?) {
        switch type {
        case "updatePromptDraft":
            assistant.promptDraft = (payload?["text"] as? String) ?? ""
        case "sendPrompt":
            sendCurrentPrompt()
        case "openFilePicker":
            openFilePicker()
        case "openSkillsPane":
            selectedSidebarPane = .skills
        case "removeAttachment":
            guard
                let attachmentID = (payload?["attachmentId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.attachments.removeAll {
                $0.id.uuidString.caseInsensitiveCompare(attachmentID) == .orderedSame
            }
        case "addAttachments":
            guard let rawAttachments = payload?["attachments"] as? [[String: Any]] else {
                return
            }

            let attachments = rawAttachments.compactMap { item -> AssistantAttachment? in
                let filename = (item["filename"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let dataURL = item["dataUrl"] as? String {
                    return AssistantAttachmentSupport.attachment(
                        fromDataURL: dataURL,
                        suggestedFilename: filename
                    )
                }
                return nil
            }

            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        case "detachSkill":
            guard
                let skillName = (payload?["skillName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.detachSkill(skillName)
        case "repairMissingSkillBindings":
            assistant.repairMissingSkillBindings()
        case "setInteractionMode":
            guard let rawMode = payload?["mode"] as? String,
                let mode = AssistantInteractionMode(rawValue: rawMode)
            else {
                return
            }
            assistant.interactionMode = mode
        case "setModel":
            guard
                let modelID = (payload?["modelId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            else {
                return
            }
            assistant.chooseModel(modelID)
        case "setReasoningEffort":
            guard let effortID = payload?["effort"] as? String,
                let effort = AssistantReasoningEffort(rawValue: effortID)
            else {
                return
            }
            assistant.reasoningEffort = effort
        case "cancelActiveTurn":
            Task { await assistant.cancelActiveTurn() }
        case "startVoiceCapture":
            NotificationCenter.default.post(
                name: .openAssistStartAssistantVoiceCapture, object: nil)
        case "stopVoiceCapture":
            NotificationCenter.default.post(name: .openAssistStopAssistantVoiceCapture, object: nil)
        case "stopVoicePlayback":
            assistant.stopAssistantVoicePlayback()
        default:
            break
        }
    }

    private func chatLayoutMetrics(for windowWidth: CGFloat) -> ChatLayoutMetrics {
        let safeWindowWidth = max(windowWidth, 640)
        let outerPadding = safeWindowWidth < 900 ? 2.0 : 4.0
        let sidebarWidth = scaledSidebarWidth(for: safeWindowWidth, outerPadding: outerPadding)
        let collapsedSidebarWidth = safeWindowWidth < 900 ? 60.0 : 64.0
        let collapsedSidebarPreviewWidth = min(sidebarWidth, max(248.0, safeWindowWidth * 0.28))
        let visibleSidebarWidth = isSidebarCollapsed ? collapsedSidebarWidth : sidebarWidth
        let detailWidth = max(
            320.0,
            safeWindowWidth - visibleSidebarWidth - (outerPadding * 2) - 0.5)
        let isNarrow = detailWidth < 760
        let isMedium = detailWidth < 1080
        let timelineHorizontalPadding = isNarrow ? 16.0 : (isMedium ? 24.0 : 32.0)
        let maxColumnWidth =
            isNarrow
            ? detailWidth - (timelineHorizontalPadding * 2) : min(780.0, detailWidth * 0.82)
        let contentMaxWidth = max(
            280.0, min(detailWidth - (timelineHorizontalPadding * 2), maxColumnWidth))
        let topBarMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 8 : 28))
        let composerMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 0 : 18))
        let userBubbleMaxWidth = min(
            contentMaxWidth * (isNarrow ? 0.96 : 0.80), isNarrow ? 540.0 : 640.0)
        let userMediaMaxWidth = min(userBubbleMaxWidth, isNarrow ? 320.0 : 420.0)
        let assistantMediaMaxWidth = min(contentMaxWidth, isNarrow ? 440.0 : 660.0)
        let leadingReserve = isNarrow ? 36.0 : (isMedium ? 56.0 : 80.0)
        let assistantTrailingPaddingRegular = isNarrow ? 8.0 : (isMedium ? 16.0 : 24.0)
        let assistantTrailingPaddingCompact = isNarrow ? 8.0 : (isMedium ? 12.0 : 20.0)
        let assistantTrailingPaddingStatus = isNarrow ? 8.0 : (isMedium ? 14.0 : 20.0)
        let activityLeadingPadding = isNarrow ? 10.0 : (isMedium ? 18.0 : 44.0)
        let activityTrailingPadding = isNarrow ? 10.0 : (isMedium ? 22.0 : 60.0)
        let jumpButtonTrailing = isNarrow ? 12.0 : 24.0
        let emptyStateCardWidth = min(contentMaxWidth, isNarrow ? 420.0 : 520.0)
        let emptyStateTextWidth = min(contentMaxWidth - 48, isNarrow ? 320.0 : 440.0)

        return ChatLayoutMetrics(
            windowWidth: safeWindowWidth,
            sidebarWidth: sidebarWidth,
            collapsedSidebarWidth: collapsedSidebarWidth,
            collapsedSidebarPreviewWidth: collapsedSidebarPreviewWidth,
            visibleSidebarWidth: visibleSidebarWidth,
            outerPadding: outerPadding,
            timelineHorizontalPadding: timelineHorizontalPadding,
            contentMaxWidth: contentMaxWidth,
            topBarMaxWidth: topBarMaxWidth,
            composerMaxWidth: composerMaxWidth,
            userBubbleMaxWidth: userBubbleMaxWidth,
            userMediaMaxWidth: userMediaMaxWidth,
            assistantMediaMaxWidth: assistantMediaMaxWidth,
            leadingReserve: leadingReserve,
            assistantTrailingPaddingRegular: assistantTrailingPaddingRegular,
            assistantTrailingPaddingCompact: assistantTrailingPaddingCompact,
            assistantTrailingPaddingStatus: assistantTrailingPaddingStatus,
            activityLeadingPadding: activityLeadingPadding,
            activityTrailingPadding: activityTrailingPadding,
            jumpButtonTrailing: jumpButtonTrailing,
            emptyStateCardWidth: emptyStateCardWidth,
            emptyStateTextWidth: emptyStateTextWidth,
            isNarrow: isNarrow
        )
    }

    private func centeredDetailColumn<Content: View>(
        maxWidth: CGFloat,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: maxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func assistantSplitBackground(layout: ChatLayoutMetrics) -> some View {
        AppSplitChromeBackground(
            leadingPaneFraction: min(
                0.32, max(0.12, layout.visibleSidebarWidth / max(layout.windowWidth, 1))),
            leadingPaneMaxWidth: 280,
            leadingPaneWidth: layout.visibleSidebarWidth,
            leadingTint: AppVisualTheme.sidebarTint,
            trailingTint: AppVisualTheme.windowBackground,
            accent: AppVisualTheme.accentTint,
            leadingPaneTransparent: isSidebarCollapsed
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = chatLayoutMetrics(for: proxy.size.width)
            let collapsedOverlayWidth =
                collapsedSidebarPreviewPane == nil
                ? layout.collapsedSidebarWidth
                : layout.collapsedSidebarPreviewWidth

            ZStack(alignment: .leading) {
                assistantSplitBackground(layout: layout)

                HStack(spacing: 0) {
                    if isSidebarCollapsed {
                        Color.clear
                            .frame(width: layout.collapsedSidebarWidth)
                    } else {
                        sidebar(layout: layout, width: layout.sidebarWidth)
                    }

                    Rectangle()
                        .fill(AppVisualTheme.surfaceFill(0.06))
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)

                    detailPane(layout: layout)
                }
                .padding(.horizontal, layout.outerPadding)
                .padding(.bottom, 4)

                if isSidebarCollapsed {
                    sidebar(layout: layout, width: collapsedOverlayWidth)
                        .padding(.leading, layout.outerPadding)
                        .padding(.bottom, 4)
                }
            }
        }
        .onAppear {
            recomputeVisibleRenderItems()
            Task { await refreshEverything(refreshPermissions: true) }
        }
        .onChange(of: timelineLastUpdatedAt) { _ in
            recomputeVisibleRenderItems()
        }
        .onChange(of: allRenderItems.count) { _ in
            recomputeVisibleRenderItems()
        }
        .onChange(of: visibleHistoryLimit) { _ in
            recomputeVisibleRenderItems()
        }
        .alert(
            "Delete this archived chat forever?",
            isPresented: Binding(
                get: { pendingPermanentDeleteSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingPermanentDeleteSession = nil
                    }
                }
            ),
            presenting: pendingPermanentDeleteSession
        ) { session in
            Button("Delete Forever", role: .destructive) {
                pendingPermanentDeleteSession = nil
                Task {
                    await assistant.deleteSession(session.id)
                    guard selectedSidebarPane == .archived else { return }
                    await MainActor.run {
                        showArchivedSidebar()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDeleteSession = nil
            }
        } message: { session in
            Text("This permanently removes the archived chat “\(session.title)”.")
        }
        .alert(
            "Delete this project?",
            isPresented: Binding(
                get: { pendingDeleteProject != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteProject = nil
                    }
                }
            ),
            presenting: pendingDeleteProject
        ) { project in
            Button("Delete", role: .destructive) {
                assistant.deleteProject(project.id)
                pendingDeleteProject = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteProject = nil
            }
        } message: { project in
            Text(
                "This removes the Open Assist project “\(project.name)”. Threads will stay saved, but they will no longer belong to this project."
            )
        }
        .sheet(isPresented: $assistant.showBrowserProfilePicker) {
            BrowserProfilePickerSheet(
                onSelect: { profile in
                    assistant.selectBrowserProfile(profile)
                },
                onCancel: {
                    assistant.showBrowserProfilePicker = false
                }
            )
        }
        .sheet(isPresented: $assistant.showMemorySuggestionReview) {
            AssistantMemorySuggestionReviewSheet(assistant: assistant)
        }
        .sheet(
            isPresented: $assistant.showMemoryInspector,
            onDismiss: {
                assistant.dismissMemoryInspector()
            }
        ) {
            AssistantMemoryInspectorSheet(assistant: assistant)
        }
        .sheet(isPresented: $showGitHubSkillImportSheet) {
            AssistantGitHubSkillImportSheet { reference in
                Task { await assistant.importSkill(fromGitHubReference: reference) }
            }
        }
        .sheet(isPresented: $showSkillWizardSheet) {
            AssistantSkillWizardSheet { draft in
                assistant.createSkill(from: draft)
            }
        }
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center)) { attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(AppVisualTheme.foreground(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800, maxHeight: 600)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 400, minHeight: 300)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomIn)) { _ in
            chatTextScale = min(2.0, chatTextScale + 0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomOut)) { _ in
            chatTextScale = max(0.6, chatTextScale - 0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistAssistantZoomReset)) { _ in
            chatTextScale = 1.0
        }
        .onChange(of: selectionTracker.selectionContext) { context in
            guard let context else {
                guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection
                else {
                    return
                }
                AssistantSelectionActionHUDManager.shared.hide()
                return
            }

            presentSelectionActions(for: context)
        }
        .onChange(of: assistant.selectedSessionID) { newSessionID in
            guard newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return
            }
            selectionTracker.clearSelection()
            AssistantSelectionActionHUDManager.shared.hide()
            if selectedSidebarPane != .archived {
                selectedSidebarPane = .threads
            }
            resetVisibleHistoryWindow()
            suppressNextTimelineAutoScrollAnimation = true
        }
    }

    private func sidebar(layout: ChatLayoutMetrics, width: CGFloat) -> some View {
        AssistantSidebarWebView(
            state: sidebarWebState,
            accentColor: AppVisualTheme.accentTint,
            onCommand: handleSidebarWebCommand
        )
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func detailPane(layout: ChatLayoutMetrics) -> some View {
        switch selectedSidebarPane {
        case .threads:
            chatDetail(layout: layout)
        case .archived:
            archivedDetail(layout: layout)
        case .automations:
            automationDetail
        case .skills:
            skillsDetail
        }
    }

    @ViewBuilder
    private func archivedDetail(layout: ChatLayoutMetrics) -> some View {
        let hasArchivedSelection = assistant.visibleArchivedSidebarSessions.contains { session in
            assistant.selectedSessionID?.caseInsensitiveCompare(session.id) == .orderedSame
        }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archived Settings")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.88))

                Text(
                    "New archives will use this cleanup time automatically. Change it here only when you want a different default."
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.50))
                .fixedSize(horizontal: false, vertical: true)

                Picker(
                    "Default cleanup time",
                    selection: Binding(
                        get: { settings.assistantArchiveDefaultRetentionHours },
                        set: { settings.assistantArchiveDefaultRetentionHours = $0 }
                    )
                ) {
                    ForEach(archiveRetentionOptions, id: \.self) { hours in
                        Text(archiveRetentionLabel(for: hours)).tag(hours)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                    )
            )
            .padding(.horizontal, layout.outerPadding)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if assistant.visibleArchivedSidebarSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                    Text("No archived chats")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                    Text(
                        "Archived chats will appear here. You can unarchive them or delete them forever from the right-click menu."
                    )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.44))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasArchivedSelection {
                chatDetail(layout: layout)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                    Text("Select an archived chat")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                    Text("Choose a chat from the Archived list to view it.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.44))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sidebarNavItem(symbol: String, label: String) -> some View {
        HStack(spacing: sidebarScaled(8)) {
            Image(systemName: symbol)
                .font(.system(size: sidebarScaled(11), weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.44))
                .frame(width: sidebarScaled(16))
            Text(label)
                .font(.system(size: sidebarScaled(13), weight: .regular))
                .foregroundStyle(AppVisualTheme.foreground(0.60))
            Spacer()
        }
        .padding(.horizontal, sidebarScaled(10))
        .padding(.vertical, sidebarScaled(6))
    }

    private func sidebarNavButton(
        symbol: String,
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: sidebarScaled(8)) {
                Image(systemName: symbol)
                    .font(.system(size: sidebarScaled(11), weight: .medium))
                    .foregroundStyle(
                        isSelected ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.44)
                    )
                    .frame(width: sidebarScaled(16))
                Text(label)
                    .font(.system(size: sidebarScaled(13), weight: .regular))
                    .foregroundStyle(
                        isSelected
                            ? AppVisualTheme.foreground(0.88) : AppVisualTheme.foreground(0.60))
                Spacer()
            }
            .padding(.horizontal, sidebarScaled(10))
            .padding(.vertical, sidebarScaled(6))
            .background(
                RoundedRectangle(cornerRadius: sidebarScaled(8), style: .continuous)
                    .fill(isSelected ? AppVisualTheme.foreground(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: sidebarScaled(8), style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func projectContextMenu(for project: AssistantProject) -> some View {
        Button {
            assistant.inspectMemory(for: project)
        } label: {
            Label("View Memory", systemImage: "brain")
        }

        if let selectedSession = activeSessionSummary,
            selectedSession.projectID?.caseInsensitiveCompare(project.id) != .orderedSame
        {
            Divider()

            Button {
                assistant.assignSessionToProject(selectedSession.id, projectID: project.id)
            } label: {
                Label("Move \"\(selectedSession.title)\" Here", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        Button {
            presentRenameProjectPrompt(for: project)
        } label: {
            Label("Rename Project", systemImage: "pencil")
        }

        Menu {
            Button {
                assistant.updateProjectIcon(project.id, symbol: nil)
            } label: {
                Label("Use Default Icon", systemImage: "arrow.counterclockwise")
            }
            .disabled(project.iconSymbolName == nil)

            Divider()

            ForEach(Self.projectIconOptions) { option in
                Button {
                    assistant.updateProjectIcon(project.id, symbol: option.symbol)
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }

            Divider()

            Button {
                presentProjectIconPrompt(for: project)
            } label: {
                Label("Custom Symbol...", systemImage: "pencil")
            }
        } label: {
            Label("Change Icon", systemImage: project.displayIconSymbolName)
        }

        Button {
            presentProjectFolderPicker(for: project)
        } label: {
            Label(
                project.linkedFolderPath == nil ? "Link Folder" : "Change Folder",
                systemImage: "folder")
        }

        if project.linkedFolderPath != nil {
            Button {
                assistant.updateProjectLinkedFolder(project.id, path: nil)
            } label: {
                Label("Remove Folder Link", systemImage: "folder.badge.minus")
            }
        }

        Divider()

        Button {
            Task { await assistant.hideProject(project.id) }
        } label: {
            Label("Hide Project", systemImage: "eye.slash")
        }

        Button(role: .destructive) {
            pendingDeleteProject = project
        } label: {
            Label("Delete Project", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func threadContextMenu(for session: AssistantSessionSummary) -> some View {
        if session.isArchived {
            Button {
                Task {
                    await assistant.unarchiveSession(session.id)
                    guard selectedSidebarPane == .archived else { return }
                    await MainActor.run {
                        showArchivedSidebar()
                    }
                }
            } label: {
                Label("Unarchive Session", systemImage: "tray.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                pendingPermanentDeleteSession = session
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button {
                presentRenameSessionPrompt(for: session)
            } label: {
                Label("Rename Session", systemImage: "pencil")
            }

            if session.isTemporary {
                Button {
                    assistant.promoteTemporarySession(session.id)
                } label: {
                    Label("Keep as Regular Chat", systemImage: "pin")
                }
            }

            Divider()

            if !assistant.visibleProjects.isEmpty {
                Menu {
                    ForEach(assistant.visibleProjects) { project in
                        let isCurrentProject =
                            session.projectID?.caseInsensitiveCompare(project.id) == .orderedSame
                        Button {
                            assistant.assignSessionToProject(session.id, projectID: project.id)
                        } label: {
                            Label(project.name, systemImage: project.displayIconSymbolName)
                        }
                        .disabled(isCurrentProject)
                    }
                } label: {
                    Label(
                        session.projectID == nil ? "Add to Project" : "Move to Project",
                        systemImage: "folder.badge.plus"
                    )
                }

            } else {
                Button {
                    presentCreateProjectPrompt()
                } label: {
                    Label("Create Project", systemImage: "plus")
                }
            }

            if session.projectID != nil {
                Button {
                    assistant.assignSessionToProject(session.id, projectID: nil)
                } label: {
                    Label("Remove from Project", systemImage: "minus.circle")
                }
            }

            Divider()

            Button {
                Task {
                    await assistant.archiveSession(
                        session.id,
                        retentionHours: settings.assistantArchiveDefaultRetentionHours,
                        updateDefaultRetention: false
                    )
                }
            } label: {
                Label("Archive Session", systemImage: "archivebox")
            }
        }
    }

    private func chatDetail(layout: ChatLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            chatTopBar(layout: layout)

            if assistant.selectedSessionID != nil {
                compactRuntimeProviderPicker
            }

            AssistantChatWebView(
                messages: chatWebMessages,
                runtimePanel: chatWebRuntimePanel,
                reviewPanel: inlineTrackedCodePanel,
                rewindState: chatWebRewindState,
                threadNoteState: chatWebThreadNoteState,
                showTypingIndicator: shouldShowPendingAssistantPlaceholder,
                typingTitle: assistant.hudState.title.isEmpty
                    ? "Thinking" : assistant.hudState.title,
                typingDetail: assistant.hudState.detail ?? "Working on your message",
                textScale: CGFloat(chatTextScale),
                canLoadOlderHistory: canLoadOlderHistory,
                accentColor: AppVisualTheme.accentTint,
                onScrollStateChanged: { isPinned, isScrolledUp in
                    autoScrollPinnedToBottom = isPinned
                    userHasScrolledUp = isScrolledUp
                },
                onLoadOlderHistory: {
                    guard canLoadOlderHistory, !isLoadingOlderHistory else { return }
                    loadOlderHistoryBatchWeb()
                },
                onLoadActivityDetails: { renderItemID in
                    if renderItemID.hasPrefix("collapsed-conversation-") {
                        expandedHistoricalConversationBlockIDs.insert(renderItemID)
                    } else {
                        expandedHistoricalActivityRenderItemIDs.insert(renderItemID)
                    }
                },
                onCollapseActivityDetails: { renderItemID in
                    if renderItemID.hasPrefix("collapsed-conversation-") {
                        expandedHistoricalConversationBlockIDs.remove(renderItemID)
                    } else {
                        expandedHistoricalActivityRenderItemIDs.remove(renderItemID)
                    }
                },
                onSelectRuntimeBackend: { backendID in
                    guard let backend = AssistantRuntimeBackend(rawValue: backendID) else { return }
                    assistant.selectAssistantBackend(backend)
                },
                onOpenRuntimeSettings: {
                    NotificationCenter.default.post(
                        name: .openAssistOpenSettings, object: SettingsRoute.gettingStartedHome)
                },
                onUndoMessage: { anchorID in
                    Task { await assistant.undoUserMessage(anchorID: anchorID) }
                },
                onEditMessage: { anchorID in
                    Task { await assistant.beginEditLastUserMessage(anchorID: anchorID) }
                },
                onUndoCodeCheckpoint: {
                    Task { await assistant.undoTrackedCodeCheckpoint() }
                },
                onRedoHistoryMutation: {
                    Task { await assistant.redoUndoneUserMessage() }
                },
                onRestoreCodeCheckpoint: { checkpointID in
                    Task { await assistant.restoreTrackedCodeCheckpoint(checkpointID: checkpointID) }
                },
                onCloseCodeReviewPanel: {
                    // Inline tracked coding does not need a separate native close action.
                },
                onThreadNoteCommand: handleThreadNoteCommand,
                onTextSelected: { selectedText, messageID, parentText, screenRect in
                    handleWebViewTextSelection(
                        selectedText: selectedText,
                        messageID: messageID,
                        parentText: parentText,
                        screenRect: screenRect
                    )
                },
                onContainerReady: { container in
                    if chatWebContainer !== container {
                        chatWebContainer = container
                    }
                }
            )
            .frame(maxHeight: .infinity)
            .onAppear {
                resetVisibleHistoryWindow()
                syncThreadNoteSelection(assistant.selectedSessionID, persistCurrent: false)
            }
            .onChange(of: assistant.selectedSessionID) { newSessionID in
                syncThreadNoteSelection(newSessionID, persistCurrent: true)
                guard newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else {
                    return
                }
                resetVisibleHistoryWindow()
            }
            .onChange(of: assistant.selectedCodeTrackingState) { _ in
                chatWebContainer?.applyReviewPanel(inlineTrackedCodePanel)
                // Auto-scroll so the checkpoint card is visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    chatWebContainer?.scrollToBottom(animated: true)
                }
            }
            .onChange(of: assistant.hasActiveTurn) { _ in
                chatWebContainer?.applyReviewPanel(inlineTrackedCodePanel)
            }

            chatBottomDock(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, isSidebarCollapsed ? 0 : 4)
        .ignoresSafeArea(edges: .top)
    }

    private var automationDetail: some View {
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.46, green: 0.79, blue: 0.66).opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "clock.badge.checkmark.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.46, green: 0.79, blue: 0.66))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Automations")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                    Text("Create and manage recurring assistant jobs")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.44))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                AppVisualTheme.surfaceFill(0.03)
            )
            .overlay(
                Rectangle()
                    .fill(AppVisualTheme.surfaceStroke(0.08))
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)

            ScheduledJobsView(showsHeader: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, 4)
        .ignoresSafeArea(edges: .top)
    }

    private var skillsDetail: some View {
        return VStack(spacing: 0) {
            AssistantSkillsPane(
                assistant: assistant,
                onImportFolder: openSkillFolderImportPanel,
                onImportGitHub: { showGitHubSkillImportSheet = true },
                onCreateSkill: { showSkillWizardSheet = true },
                onDeleteSkill: confirmDeleteSkill,
                onTrySkill: trySkillFromLibrary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
        )
        .padding(.top, 10)
        .padding(.leading, 4)
        .ignoresSafeArea(edges: .top)
    }

    private var hasToolActivity: Bool {
        selectedSessionToolActivity.hasActivity
    }

    private var selectedSessionActiveWorkSnapshot: AssistantSessionActiveWorkSnapshot? {
        assistantSelectedSessionActiveWorkSnapshot(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            planEntries: assistant.planEntries,
            subagents: assistant.subagents,
            toolCalls: assistant.toolCalls,
            recentToolCalls: assistant.recentToolCalls
        )
    }

    private var hasSelectedSessionActiveWork: Bool {
        selectedSessionActiveWorkSnapshot != nil
    }

    private var selectedChildParentLinkState: AssistantParentThreadLinkState? {
        assistantParentThreadLinkState(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            subagents: assistant.subagents
        )
    }

    private var latestFileChangeMessageID: String? {
        chatWebMessages.reversed().first { message in
            if message.activityIcon == "fileChange" {
                return true
            }
            return message.groupItems?.contains(where: { $0.icon == "fileChange" }) == true
        }?.id
    }

    private var inlineTrackedCodePanel: AssistantChatWebCodeReviewPanel? {
        assistant.selectedCodeTrackingState.flatMap {
            AssistantChatWebCodeReviewPanel(
                trackingState: $0,
                hasActiveTurn: assistant.hasActiveTurn,
                actionsLocked: assistant.isRestoringHistoryBranch,
                embedded: true
            )
        }
    }

    private var selectedSessionToolActivity: AssistantSessionToolActivitySnapshot {
        assistantSelectedSessionToolActivity(
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            hasActiveTurn: assistant.hasActiveTurn,
            toolCalls: assistant.toolCalls,
            recentToolCalls: assistant.recentToolCalls
        )
    }

    private func chatBottomDock(layout: ChatLayoutMetrics) -> some View {
        VStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if let request = assistant.pendingPermissionRequest {
                    HStack(alignment: .top, spacing: 0) {
                        permissionCard(
                            request,
                            state: request.toolKind == "userInput"
                                ? .waitingForInput
                                : .waitingForApproval
                        )
                        Spacer(minLength: layout.leadingReserve)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else if let workSnapshot = selectedSessionActiveWorkSnapshot {
                    AssistantParentWorkCard(
                        snapshot: workSnapshot,
                        onOpenThread: openThread,
                        onReviewChanges: latestFileChangeMessageID == nil
                            ? nil : revealLatestFileChangeActivity
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else if hasToolActivity || toolCallsExpanded {
                    toolActivityStrip
                        .opacity(hasToolActivity ? 1 : 0)
                        .frame(height: hasToolActivity ? nil : 0)
                        .clipped()
                }

                chatComposer(layout: layout)
            }
            .frame(maxWidth: layout.composerMaxWidth, alignment: .leading)

            // Integrated status bar
            HStack(spacing: 6) {
                if !assistant.rateLimits.isEmpty {
                    statusBarRateLimits
                }

                Spacer(minLength: 4)

                if assistant.accountSnapshot.isLoggedIn {
                    AccountBadgeCircle(snapshot: assistant.accountSnapshot)
                }

                ContextUsageCircle(usage: assistant.tokenUsage)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: layout.composerMaxWidth)
        }
        .animation(.easeInOut(duration: 0.25), value: hasToolActivity)
        .animation(.easeInOut(duration: 0.25), value: hasSelectedSessionActiveWork)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, layout.timelineHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func chatTopBarTitleCluster(layout: ChatLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            Text(activeSessionHeaderTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.88))
                .lineLimit(1)
                .help(activeSessionTitle)

            if activeSessionSummary?.isTemporary == true {
                AssistantStatusBadge(
                    title: "Temporary",
                    tint: .orange,
                    symbol: "clock.badge.exclamationmark"
                )
            }

            if let project = activeSessionProject {
                AssistantStatusBadge(
                    title: project.name,
                    tint: AppVisualTheme.accentTint,
                    symbol: project.displayIconSymbolName
                )
                .help(activeSessionWorkspaceURL?.path ?? project.name)
            } else if activeSessionSummary?.projectID == nil,
                let projectName = activeSessionSummary?.projectName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).nonEmpty
            {
                AssistantStatusBadge(
                    title: projectName,
                    tint: AppVisualTheme.accentTint,
                    symbol: "folder"
                )
                .help(activeSessionWorkspaceURL?.path ?? projectName)
            }

            if activeSessionSummary?.projectFolderMissing == true {
                AssistantStatusBadge(
                    title: "Missing folder",
                    tint: .orange,
                    symbol: "exclamationmark.triangle.fill"
                )
            }
        }
        .lineLimit(1)
        .frame(maxWidth: layout.topBarMaxWidth, alignment: .center)
    }

    private func chatTopBar(layout: ChatLayoutMetrics) -> some View {
        let sideControlWidth: CGFloat = 138
        let titleHorizontalPadding: CGFloat = 16
        let hasThreadNote = currentThreadNoteDraftText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil

        return HStack(spacing: 0) {
            HStack(spacing: 0) {}
                .frame(width: sideControlWidth, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // Runtime connection indicator
                Circle()
                    .fill(runtimeDotColor)
                    .frame(width: 5, height: 5)
                    .help(runtimeStatusLabel)

                if let selectedChildParentLinkState {
                    Button {
                        openThread(selectedChildParentLinkState.parentThreadID)
                    } label: {
                        AssistantTopBarActionButton(
                            title: "Parent thread",
                            symbol: "bubble.left.and.bubble.right",
                            tint: AppVisualTheme.foreground(0.86)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open the parent thread for this sub-agent")
                }

                if activeSessionSummary?.isTemporary == true {
                    Button {
                        assistant.promoteTemporarySession()
                    } label: {
                        topBarTextActionButton(title: "Keep Chat", tint: AppVisualTheme.accentTint)
                    }
                    .buttonStyle(.plain)
                    .help("Keep this temporary chat as a regular thread")
                }

                workspaceLaunchControl

                if assistant.selectedSessionID != nil {
                    Button {
                        toggleThreadNoteDrawer()
                    } label: {
                        topBarIconButton(
                            symbol: "note.text",
                            emphasized: isThreadNoteOpen || hasThreadNote
                        )
                    }
                    .buttonStyle(.plain)
                    .help(isThreadNoteOpen ? "Close thread note" : "Open thread note")
                }

                Button {
                    showSessionInstructions.toggle()
                } label: {
                    topBarIconButton(symbol: "text.quote")
                }
                .buttonStyle(.plain)
                .help("Session instructions")
                .popover(isPresented: $showSessionInstructions, arrowEdge: .bottom) {
                    SessionInstructionsPopover(instructions: $assistant.sessionInstructions)
                }

                // Memory indicator — icon color alone shows on/off
                Button {
                    assistant.inspectCurrentMemory()
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            sessionMemoryIsActive
                                ? Color.green.opacity(0.85) : AppVisualTheme.foreground(0.28)
                        )
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(AppVisualTheme.surfaceFill(0.04))
                        )
                }
                .buttonStyle(.plain)
                .help("Open memory for this chat")

                if assistant.selectedSessionID != nil {
                    Button {
                        minimizeToCompact()
                    } label: {
                        topBarIconButton(symbol: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Back to Orb")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .center) {
            chatTopBarTitleCluster(layout: layout)
                .padding(.horizontal, titleHorizontalPadding)
                .padding(.horizontal, sideControlWidth)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, titleHorizontalPadding)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            Rectangle()
                .fill(AppVisualTheme.surfaceFill(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleKeyWindowFullScreen)
    }

    private var workspaceLaunchControl: some View {
        HStack(spacing: 0) {
            Button {
                openCurrentWorkspace(in: primaryWorkspaceLaunchTarget)
            } label: {
                workspaceLaunchTargetIcon(primaryWorkspaceLaunchTarget, size: 18)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                AppVisualTheme.surfaceFill(
                                    isWorkspaceLaunchPrimaryHovered ? 0.12 : 0.0)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        AppVisualTheme.surfaceStroke(
                                            isWorkspaceLaunchPrimaryHovered ? 0.18 : 0.0),
                                        lineWidth: 0.6
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isWorkspaceLaunchPrimaryHovered = hovering
            }
            .disabled(activeSessionWorkspaceURL == nil || !primaryWorkspaceLaunchTarget.isInstalled)
            .animation(.easeInOut(duration: 0.14), value: isWorkspaceLaunchPrimaryHovered)
            .help(
                activeSessionWorkspaceURL == nil
                    ? "This chat does not have a usable folder yet."
                    : "Open this chat folder in \(primaryWorkspaceLaunchTarget.title)."
            )

            Rectangle()
                .fill(AppVisualTheme.surfaceStroke(0.12))
                .frame(width: 0.6, height: 18)
                .padding(.vertical, 5)

            Menu {
                if activeSessionWorkspaceURL == nil {
                    Text("Open a project chat or link a folder first.")
                    Divider()
                }

                ForEach(Self.workspaceLaunchTargets) { target in
                    Button {
                        if target.remembersAsPreferred {
                            preferredWorkspaceLaunchTargetID = target.id
                        }
                        openCurrentWorkspace(in: target)
                    } label: {
                        HStack(spacing: 8) {
                            workspaceLaunchTargetIcon(target, size: 18)
                            Text(target.title)
                            if target.id == primaryWorkspaceLaunchTarget.id {
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                            }
                            if !target.isInstalled {
                                Spacer(minLength: 8)
                                Text("Not installed")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(activeSessionWorkspaceURL == nil || !target.isInstalled)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 5.5, height: 3.5)
                    .foregroundStyle(AppVisualTheme.foreground(0.36))
                    .padding(.vertical, 1)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose your default editor.")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.12), lineWidth: 0.6)
                )
        )
    }

    @ViewBuilder
    private func workspaceLaunchTargetIcon(
        _ target: AssistantWorkspaceLaunchTarget,
        size: CGFloat
    ) -> some View {
        if let applicationURL = target.applicationURL {
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous))
        } else {
            Image(systemName: target.fallbackSymbol)
                .font(.system(size: max(10, size * 0.72), weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.62))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.05))
                )
        }
    }

    private func openCurrentWorkspace(in target: AssistantWorkspaceLaunchTarget) {
        guard let workspaceURL = activeSessionWorkspaceURL else {
            assistant.lastStatusMessage =
                "This chat does not have a folder yet. Open a project chat first."
            return
        }

        switch target.launchStyle {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
            assistant.lastStatusMessage = "Opened this folder in Finder."

        case .openDocuments:
            guard let applicationURL = target.applicationURL else {
                assistant.lastStatusMessage = "\(target.title) is not installed on this Mac."
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.promptsUserIfNeeded = false

            NSWorkspace.shared.open(
                [workspaceURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                Task { @MainActor in
                    if let error {
                        CrashReporter.logError(
                            "Workspace launch failed target=\(target.title) path=\(workspaceURL.path) error=\(error.localizedDescription)"
                        )
                        assistant.lastStatusMessage =
                            "Could not open this folder in \(target.title)."
                    } else {
                        assistant.lastStatusMessage = "Opened this folder in \(target.title)."
                    }
                }
            }
        }
    }

    private func topBarIconButton(symbol: String, emphasized: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                emphasized ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.50)
            )
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(emphasized ? 0.08 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func toggleKeyWindowFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil)
    }

    private var chatStatusBar: some View {
        HStack(spacing: 10) {
            AssistantModePicker(selection: assistant.interactionMode) { mode in
                assistant.interactionMode = mode
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(runtimeDotColor)
                    .frame(width: 5, height: 5)
                Text(runtimeStatusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
            }

            if !assistant.rateLimits.isEmpty {
                statusBarRateLimits
            }

            Spacer()

            if assistant.accountSnapshot.isLoggedIn {
                Text(assistant.accountSnapshot.summary)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                    .lineLimit(1)
            }

            ContextUsageCircle(usage: assistant.tokenUsage)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBarRateLimits: some View {
        if let bucket = assistant.selectedRateLimitBucket {
            HStack(spacing: 10) {
                if let selectedBucketLabel = assistant.selectedRateLimitBucketLabel,
                   let secondary = bucket.secondary {
                    statusBarRateLimitInline(
                        window: secondary,
                        bucketLabel: selectedBucketLabel,
                        showsResetInline: true
                    )
                } else {
                    if let primary = bucket.primary {
                        statusBarRateLimitInline(
                            window: primary,
                            bucketLabel: assistant.selectedRateLimitBucketLabel,
                            showsResetInline: assistant.selectedRateLimitBucketLabel != nil
                        )
                    }
                    if let secondary = bucket.secondary {
                        statusBarRateLimitInline(
                            window: secondary,
                            bucketLabel: assistant.selectedRateLimitBucketLabel,
                            showsResetInline: assistant.selectedRateLimitBucketLabel != nil
                        )
                    }
                }
            }
        }
    }

    private func statusBarRateLimitInline(
        window: RateLimitWindow,
        bucketLabel: String?,
        showsResetInline: Bool = false
    )
        -> some View
    {
        let isHigh = window.usedPercent > 80
        let percentColor: Color =
            isHigh ? .red.opacity(0.85) : AppVisualTheme.accentTint.opacity(0.75)
        let compactBucketLabel = bucketLabel?
            .replacingOccurrences(of: "Claude ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let baseLabel = window.windowLabel.isEmpty ? "Usage" : window.windowLabel
        let label = [compactBucketLabel, baseLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: " ")
        let resetLabel = showsResetInline ? window.resetsInLabel : nil

        return HStack(spacing: 4) {
            Image(systemName: "gauge.low")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.30))
            Text(label.isEmpty ? baseLabel : label)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(AppVisualTheme.foreground(0.36))
            Text("\(window.usedPercent)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(percentColor)
            if let resetLabel {
                Text("resets \(resetLabel)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.32))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                )
        )
        .help(window.resetsInLabel.map { "Resets \($0)" } ?? "")
    }

    private var runtimeStatusLabel: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return "Connected"
        case .checking: return "Checking..."
        case .connecting: return "Connecting..."
        case .failed: return "Failed"
        case .installRequired: return "Install Required"
        case .loginRequired: return "Login Required"
        case .idle: return "Idle"
        case .unavailable: return "Unavailable"
        }
    }

    private var runtimeStatusSymbol: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return "checkmark.circle.fill"
        case .checking, .connecting:
            return "arrow.triangle.2.circlepath"
        case .installRequired:
            return "arrow.down.circle.fill"
        case .loginRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .failed:
            return "xmark.circle.fill"
        case .idle:
            return "moon.fill"
        case .unavailable:
            return "slash.circle.fill"
        }
    }

    private func historyWindowNotice(action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.message")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.92))

            Text("Older chat history is hidden for speed. Use Load more to show older messages.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.72))

            Button(action: action) {
                Text("Load more")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AssistantWindowChrome.buttonEmphasis.opacity(0.68))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.55)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Latest")
                    .font(.system(size: 12, weight: .semibold))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(AssistantWindowChrome.elevatedPanel)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Jump to the newest message")
    }

    private func presentRenameSessionPrompt(for session: AssistantSessionSummary) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = session.title
        field.placeholderString = "Session name"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename Session"
        alert.informativeText =
            "Choose a friendly name for this thread. It will stay the same until you rename it again."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await assistant.renameSession(session.id, to: proposedTitle) }
    }

    private func presentCreateProjectPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add Project"
        alert.informativeText =
            "You can open a folder and add it as one project, or create a project by name now and link a folder later."
        alert.addButton(withTitle: "Open Folder")
        alert.addButton(withTitle: "Create by Name")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            presentCreateProjectFromFolderPrompt()
        case .alertSecondButtonReturn:
            presentNamedProjectPrompt()
        default:
            return
        }
    }

    private func presentNamedProjectPrompt() {
        presentProjectNamePrompt(
            title: "Create Project",
            message:
                "Give this project a simple name. You can add threads to it now and link a local folder later.",
            confirmTitle: "Create",
            initialValue: assistant.selectedProjectFilter?.name ?? ""
        ) { proposedName in
            assistant.createProject(name: proposedName)
        }
    }

    private func presentCreateProjectFromFolderPrompt() {
        let panel = NSOpenPanel()
        panel.message = "Choose the local folder to add as a project."
        panel.prompt = "Open Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK,
            let folderURL = panel.url
        else {
            return
        }

        presentProjectNamePrompt(
            title: "Add Project From Folder",
            message:
                "We used the folder name as the project name. You can keep it or type a different name.",
            confirmTitle: "Add Project",
            initialValue: AssistantProject.suggestedName(forLinkedFolderPath: folderURL.path)
        ) { proposedName in
            assistant.createProject(name: proposedName, linkedFolderPath: folderURL.path)
        }
    }

    private func presentRenameProjectPrompt(for project: AssistantProject) {
        presentProjectNamePrompt(
            title: "Rename Project",
            message:
                "Choose the new name for this project. Its threads and memory will stay attached.",
            confirmTitle: "Rename",
            initialValue: project.name
        ) { proposedName in
            assistant.renameProject(project.id, to: proposedName)
        }
    }

    private func presentProjectIconPrompt(for project: AssistantProject) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = project.iconSymbolName ?? ""
        field.placeholderString = "folder.fill"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Change Project Icon"
        alert.informativeText =
            "Type an SF Symbol name, like folder.fill or star.fill. Leave it blank to use the default icon."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedSymbol = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposedSymbol.isEmpty {
            assistant.updateProjectIcon(project.id, symbol: nil)
            return
        }

        guard AssistantProject.isValidIconSymbolName(proposedSymbol) else {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .warning
            errorAlert.messageText = "Unknown Icon"
            errorAlert.informativeText =
                "That symbol name was not found. Try folder.fill, star.fill, or pick one of the preset icons."
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            return
        }

        assistant.updateProjectIcon(project.id, symbol: proposedSymbol)
    }

    private func presentProjectFolderPicker(for project: AssistantProject) {
        let panel = NSOpenPanel()
        panel.message = "Choose the local folder for this project."
        panel.prompt = project.linkedFolderPath == nil ? "Link Folder" : "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nonEmpty {
            let existingURL = URL(fileURLWithPath: linkedFolderPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: existingURL.path) {
                panel.directoryURL = existingURL
            }
        }

        guard panel.runModal() == .OK else { return }
        assistant.updateProjectLinkedFolder(project.id, path: panel.url?.path)
    }

    private func presentProjectNamePrompt(
        title: String,
        message: String,
        confirmTitle: String,
        initialValue: String,
        onSubmit: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initialValue
        field.placeholderString = "Project name"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposedName.isEmpty else { return }
        onSubmit(proposedName)
    }

    private func copyMessageButton(text: String, helpText: String, isVisible: Bool = true)
        -> some View
    {
        Button {
            copyAssistantTextToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(isVisible ? 0.56 : 0.22))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(AppVisualTheme.surfaceFill(isVisible ? 0.045 : 0.001))
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func resetVisibleHistoryWindow() {
        pendingScrollToLatestWorkItem?.cancel()
        visibleHistoryLimit = Self.initialVisibleHistoryLimit
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        isLoadingOlderHistory = false
        isPreservingHistoryScrollPosition = false
        chatScrollTracking.lastManualScrollAt = .distantPast
        expandedActivityIDs.removeAll()
        expandedHistoricalActivityRenderItemIDs.removeAll()
        expandedHistoricalConversationBlockIDs.removeAll()
    }

    private func shouldCollapseHistoricalActivityRenderItem(
        _ renderItem: AssistantTimelineRenderItem,
        at index: Int,
        in renderItems: [AssistantTimelineRenderItem]
    ) -> Bool {
        guard !expandedHistoricalActivityRenderItemIDs.contains(renderItem.id) else {
            return false
        }

        let activities = activityItems(for: renderItem)
        guard !activities.isEmpty else { return false }
        guard activities.allSatisfy({ !$0.status.isActive }) else { return false }

        let laterItems = renderItems.dropFirst(index + 1)
        return laterItems.contains(where: { activityItems(for: $0).isEmpty })
    }

    private func activityItems(for renderItem: AssistantTimelineRenderItem) -> [AssistantActivityItem] {
        switch renderItem {
        case .timeline(let item):
            guard item.kind == .activity, let activity = item.activity else { return [] }
            return [activity]
        case .activityGroup(let group):
            return group.activities
        }
    }

    private struct CollapsedHistoricalConversationGroup {
        let id: String
        let firstHiddenIndex: Int
        let hiddenIndices: [Int]
        let hiddenRenderItems: [AssistantTimelineRenderItem]
    }

    private func collapsedHistoricalConversationGroups(
        in renderItems: [AssistantTimelineRenderItem]
    ) -> [CollapsedHistoricalConversationGroup] {
        guard !renderItems.isEmpty else { return [] }

        var groups: [CollapsedHistoricalConversationGroup] = []
        var segmentStart = 0

        func flushSegment(endExclusive: Int) {
            guard segmentStart < endExclusive else { return }

            let indices = Array(segmentStart..<endExclusive)
            guard let lastAssistantIndex = indices.last(where: {
                isCollapsibleAssistantResponseRenderItem(renderItems[$0])
            }) else {
                return
            }

            let hiddenIndices = indices.filter { index in
                guard index < lastAssistantIndex else { return false }
                return !isUserRenderItem(renderItems[index])
                    && isHistoricalConversationRenderItem(renderItems[index])
            }

            guard !hiddenIndices.isEmpty else { return }

            let hiddenRenderItems = hiddenIndices.map { renderItems[$0] }
            let firstHiddenID = hiddenRenderItems.first?.id ?? UUID().uuidString
            let lastVisibleID = renderItems[lastAssistantIndex].id
            groups.append(
                CollapsedHistoricalConversationGroup(
                    id: "collapsed-conversation-\(firstHiddenID)-\(lastVisibleID)",
                    firstHiddenIndex: hiddenIndices[0],
                    hiddenIndices: hiddenIndices,
                    hiddenRenderItems: hiddenRenderItems
                )
            )
        }

        for index in renderItems.indices {
            if isUserRenderItem(renderItems[index]) {
                flushSegment(endExclusive: index)
                segmentStart = index + 1
            }
        }

        flushSegment(endExclusive: renderItems.count)
        return groups
    }

    private func isUserRenderItem(_ renderItem: AssistantTimelineRenderItem) -> Bool {
        guard case .timeline(let item) = renderItem else { return false }
        return item.kind == .userMessage
    }

    private func isCollapsibleAssistantResponseRenderItem(
        _ renderItem: AssistantTimelineRenderItem
    ) -> Bool {
        guard case .timeline(let item) = renderItem else { return false }
        switch item.kind {
        case .assistantProgress, .assistantFinal, .plan:
            return item.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
        default:
            return false
        }
    }

    private func isHistoricalConversationRenderItem(
        _ renderItem: AssistantTimelineRenderItem
    ) -> Bool {
        switch renderItem {
        case .activityGroup(let group):
            return group.activities.allSatisfy { !$0.status.isActive }
        case .timeline(let item):
            switch item.kind {
            case .activity:
                return item.activity?.status.isActive != true
            case .assistantProgress, .assistantFinal, .plan:
                return !item.isStreaming
            default:
                return true
            }
        }
    }

    private func handleUserScrollInteraction() {
        pendingScrollToLatestWorkItem?.cancel()
        chatScrollTracking.lastManualScrollAt = Date()
        userHasScrolledUp = true
        autoScrollPinnedToBottom = false
        AssistantSelectionActionHUDManager.shared.hide()
    }

    private func updateUserScrollState(bottomOffset: CGFloat) {
        guard !assistant.isTransitioningSession, chatViewportHeight > 0 else { return }

        let distanceFromBottom = max(0, bottomOffset - chatViewportHeight)
        let isPinnedToBottom = distanceFromBottom <= Self.autoScrollThreshold
        let hasScrolledUp = distanceFromBottom > Self.nearBottomThreshold

        if autoScrollPinnedToBottom != isPinnedToBottom {
            autoScrollPinnedToBottom = isPinnedToBottom
        }
        if userHasScrolledUp != hasScrolledUp {
            userHasScrolledUp = hasScrolledUp
        }
    }

    private func loadOlderHistoryIfNeeded(topOffset: CGFloat, with proxy: ScrollViewProxy) {
        let hasRecentManualScrollIntent =
            Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt)
            <= Self.manualLoadOlderPause
        guard !assistant.isTransitioningSession,
            hasRecentManualScrollIntent,
            canLoadOlderHistory,
            topOffset > -Self.loadOlderThreshold,
            !isLoadingOlderHistory
        else {
            return
        }

        loadOlderHistoryBatch(with: proxy)
    }

    private func loadOlderHistoryBatch(with proxy: ScrollViewProxy) {
        guard !assistant.isTransitioningSession,
            !isLoadingOlderHistory,
            let anchorID = visibleRenderItems.first.flatMap(historyPreservationAnchorID(for:))
        else {
            return
        }

        if hiddenRenderItemCount > 0 {
            let nextLimit = assistantTimelineNextVisibleLimit(
                currentLimit: visibleHistoryLimit,
                totalCount: allRenderItems.count,
                batchSize: Self.historyBatchSize
            )
            guard nextLimit > visibleHistoryLimit else { return }

            pendingScrollToLatestWorkItem?.cancel()
            userHasScrolledUp = true
            autoScrollPinnedToBottom = false
            isPreservingHistoryScrollPosition = true
            isLoadingOlderHistory = true
            visibleHistoryLimit = nextLimit
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
                DispatchQueue.main.async {
                    isLoadingOlderHistory = false
                    isPreservingHistoryScrollPosition = false
                }
            }
            return
        }

        guard assistant.selectedSessionCanLoadMoreHistory else { return }

        let previousVisibleLimit = visibleHistoryLimit
        pendingScrollToLatestWorkItem?.cancel()
        userHasScrolledUp = true
        autoScrollPinnedToBottom = false
        isPreservingHistoryScrollPosition = true
        isLoadingOlderHistory = true
        Task { @MainActor in
            let didGrow = await assistant.loadMoreHistoryForSelectedSession()
            if didGrow {
                let nextLimit = assistantTimelineNextVisibleLimit(
                    currentLimit: previousVisibleLimit,
                    totalCount: allRenderItems.count,
                    batchSize: Self.historyBatchSize
                )
                if nextLimit > visibleHistoryLimit {
                    visibleHistoryLimit = nextLimit
                }
            }

            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
                DispatchQueue.main.async {
                    isLoadingOlderHistory = false
                    isPreservingHistoryScrollPosition = false
                }
            }
        }
    }

    private func jumpToLatestMessage(with proxy: ScrollViewProxy) {
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        isPreservingHistoryScrollPosition = false
        scrollToLatestMessage(with: proxy)
    }

    private func chatEmptyState(layout: ChatLayoutMetrics) -> some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 16) {
                AppIconBadge(
                    symbol: "sparkles",
                    tint: AppVisualTheme.accentTint,
                    size: 54,
                    symbolSize: 20,
                    isEmphasized: true
                )

                Text("How can I help?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))

                Text(emptyStateMessage)
                    .font(.system(size: 14.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppVisualTheme.foreground(0.56))
                    .frame(maxWidth: layout.emptyStateTextWidth)

                if !canChat {
                    Button("Open Settings") {
                        NotificationCenter.default.post(
                            name: .openAssistOpenSettings, object: SettingsRoute.gettingStartedHome)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 36)
            .frame(maxWidth: layout.emptyStateCardWidth)
            .appThemedSurface(
                cornerRadius: 14,
                tint: AppVisualTheme.baseTint,
                strokeOpacity: 0.13,
                tintOpacity: 0.02
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: chatViewportContentMinHeight)
        .padding(.vertical, 48)
    }

    private var sessionTransitionPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(AppVisualTheme.foreground(0.5))
            Text("Loading session")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: chatViewportContentMinHeight)
    }

    private var sessionTransitionOverlay: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(AppVisualTheme.foreground(0.72))

            Text("Loading this chat…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.80))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.toolbarFill.opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func renderTimelineRow(_ item: AssistantTimelineRenderItem, layout: ChatLayoutMetrics)
        -> some View
    {
        switch item {
        case .timeline(let timelineItem):
            timelineRow(timelineItem, layout: layout)
        case .activityGroup(let group):
            timelineActivityGroupRow(group, layout: layout)
        }
    }

    @ViewBuilder
    private func renderTimelineRowWithScrollAnchors(
        _ item: AssistantTimelineRenderItem,
        layout: ChatLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            if case .activityGroup(let group) = item {
                ForEach(group.items.map(\.id), id: \.self) { anchorID in
                    Color.clear
                        .frame(height: 0)
                        .id(anchorID)
                }
            }

            renderTimelineRow(item, layout: layout)
        }
    }

    private func historyPreservationAnchorID(for item: AssistantTimelineRenderItem) -> String? {
        switch item {
        case .timeline(let timelineItem):
            return timelineItem.id
        case .activityGroup(let group):
            return group.items.first?.id ?? group.id
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: AssistantTimelineItem, layout: ChatLayoutMetrics) -> some View
    {
        switch item.kind {
        case .userMessage:
            timelineUserBubble(
                text: item.text ?? "",
                imageAttachments: item.imageAttachments,
                messageID: item.id,
                layout: layout
            )

        case .assistantProgress:
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: true,
                showsInlineCopyButton: true,
                showsMemoryActions: false,
                layout: layout
            )

        case .assistantFinal:
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: false,
                showsInlineCopyButton: true,
                showsMemoryActions: settings.assistantMemoryEnabled && !item.isStreaming,
                layout: layout
            )

        case .system:
            let isSelectionInsight = isSelectionInsightTimelineItem(item)
            timelineAssistantRow(
                messageID: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                text: item.text ?? "",
                timestamp: item.sortDate,
                title: item.emphasis
                    ? "Needs Attention"
                    : (isSelectionInsight ? "Selection Insight" : "System"),
                isStreaming: item.isStreaming,
                imageAttachments: item.imageAttachments,
                compact: !isSelectionInsight,
                showsInlineCopyButton: true,
                showsMemoryActions: false,
                layout: layout
            )

        case .activity:
            if let activity = item.activity {
                timelineActivityRow(activity, layout: layout)
            }

        case .permission:
            if let request = item.permissionRequest {
                let cardState = assistantPermissionCardState(
                    for: request,
                    pendingRequest: assistant.pendingPermissionRequest,
                    sessionStatus: sessionStatus(forSessionID: request.sessionID)
                )
                HStack(alignment: .top, spacing: 0) {
                    permissionCard(request, state: cardState)
                    Spacer(minLength: layout.leadingReserve)
                }
                .padding(.vertical, 2)
            }

        case .plan:
            if let plan = item.planText {
                HStack(alignment: .top, spacing: 0) {
                    proposedPlanCard(
                        plan,
                        isStreaming: item.isStreaming,
                        showsActions: assistant.proposedPlan == plan
                    )
                    Spacer(minLength: layout.leadingReserve)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func timelineUserBubble(
        text: String,
        imageAttachments: [Data]? = nil,
        messageID: String,
        layout: ChatLayoutMetrics
    ) -> some View {
        HStack {
            Spacer(minLength: layout.leadingReserve)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    copyMessageButton(
                        text: text,
                        helpText: "Copy user message",
                        isVisible: inlineCopyButtonIsVisible(for: messageID)
                    )
                }

                if let images = imageAttachments, !images.isEmpty {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, imageData in
                        if let nsImage = NSImage(data: imageData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: layout.userMediaMaxWidth, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Text(verbatim: text)
                    .font(.system(size: 13.8 * CGFloat(chatTextScale), weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .lineSpacing(2.0)
                    .frame(maxWidth: layout.userBubbleMaxWidth, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.14))
                    )
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .onHover { hovering in
            updateInlineCopyHoverState(for: messageID, hovering: hovering)
        }
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(text)
            }
        }
    }

    private func pendingAssistantResponseRow(layout: ChatLayoutMetrics) -> some View {
        let detail =
            assistant.hudState.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Working on your message"

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    AppIconBadge(
                        symbol: "sparkles",
                        tint: AssistantWindowChrome.neutralAccent,
                        size: 28,
                        symbolSize: 11,
                        isEmphasized: true
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            assistant.hudState.title.isEmpty ? "Thinking" : assistant.hudState.title
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.82))

                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.46))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AssistantTypingDots()
                    .padding(.leading, 38)
            }

            Spacer(minLength: layout.isNarrow ? 8 : 40)
        }
        .padding(.leading, 4)
        .padding(.trailing, layout.assistantTrailingPaddingRegular)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func timelineAssistantRow(
        messageID: String,
        sessionID: String?,
        turnID: String?,
        text: String,
        timestamp: Date,
        title: String,
        isStreaming: Bool,
        imageAttachments: [Data]?,
        compact: Bool,
        showsInlineCopyButton: Bool,
        showsMemoryActions: Bool,
        layout: ChatLayoutMetrics
    ) -> some View {
        let isStandardAssistant = title == "Assistant"
        let isCompactStatusRow = compact && !isStandardAssistant
        let roleTint = assistantRowTint(for: title)
        let roleIcon = assistantRowIcon(for: title)

        let rowContent = HStack(alignment: .top, spacing: isStandardAssistant ? 0 : 10) {
            if !isStandardAssistant {
                if isCompactStatusRow {
                    compactAssistantStatusIcon(symbol: roleIcon, tint: roleTint)
                } else {
                    AppIconBadge(
                        symbol: roleIcon,
                        tint: roleTint,
                        size: compact ? 24 : 28,
                        symbolSize: compact ? 10 : 11,
                        isEmphasized: isStreaming
                    )
                }
            }

            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !isStandardAssistant {
                        Text(title)
                            .font(
                                .system(
                                    size: compact ? 11 : 11.5,
                                    weight: isCompactStatusRow ? .medium : .semibold)
                            )
                            .foregroundStyle(
                                AppVisualTheme.foreground(
                                    isCompactStatusRow ? 0.50 : (compact ? 0.62 : 0.72)))

                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(
                                AppVisualTheme.foreground(
                                    isCompactStatusRow ? 0.20 : (compact ? 0.26 : 0.32)))
                    }

                    Spacer(minLength: 8)

                    if showsInlineCopyButton {
                        copyMessageButton(
                            text: text,
                            helpText: title == "Assistant"
                                ? "Copy assistant message" : "Copy message",
                            isVisible: inlineCopyButtonIsVisible(for: messageID)
                        )
                    }
                }

                AssistantMarkdownText(
                    contentID: messageID,
                    text: text,
                    role: .assistant,
                    isStreaming: isStreaming,
                    preferredMaxWidth: layout.contentMaxWidth,
                    selectionMessageID: text.isEmpty ? nil : messageID,
                    selectionMessageText: text.isEmpty ? nil : text,
                    selectionTracker: text.isEmpty ? nil : selectionTracker
                )
                .opacity(isCompactStatusRow ? 0.76 : (compact ? 0.84 : 1.0))
                .textSelection(.enabled)

                if let imageAttachments, !imageAttachments.isEmpty {
                    CollapsibleImageAttachments(
                        imageAttachments: imageAttachments,
                        maxWidth: min(layout.assistantMediaMaxWidth, compact ? 320 : 520),
                        maxHeight: compact ? 220 : 320
                    )
                }
            }

            Spacer(minLength: 0)
        }

        return
            rowContent
            .padding(.horizontal, isStandardAssistant ? 0 : (compact ? 10 : 14))
            .padding(.vertical, isStandardAssistant ? (compact ? 6 : 10) : (compact ? 6 : 12))
            .background {
                if isStandardAssistant {
                    EmptyView()
                } else if isCompactStatusRow {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.012))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(title == "Needs Attention" ? 0.50 : 0.24))
                                .frame(width: 2)
                                .padding(.vertical, 6)
                                .padding(.leading, 1)
                        }
                } else if compact {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(roleTint.opacity(0.025))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(0.45))
                                .frame(width: 2)
                                .padding(.vertical, 6)
                                .padding(.leading, 1)
                        }
                } else {
                    EmptyView()
                }
            }
            .padding(.leading, isStandardAssistant ? 0 : 0)
            .padding(
                .trailing,
                isStandardAssistant
                    ? (compact
                        ? layout.assistantTrailingPaddingCompact
                        : layout.assistantTrailingPaddingRegular)
                    : layout.assistantTrailingPaddingStatus
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, compact ? 2 : 8)
            .onHover { hovering in
                guard showsInlineCopyButton else { return }
                updateInlineCopyHoverState(for: messageID, hovering: hovering)
            }
            .contextMenu {
                Button("Copy Message") {
                    copyAssistantTextToPasteboard(text)
                }
                if title == "Assistant", !isStreaming {
                    Button("Play Again") {
                        assistant.replayAssistantVoice(
                            text: text,
                            sessionID: sessionID,
                            turnID: turnID,
                            timelineItemID: messageID
                        )
                    }
                }
                if showsMemoryActions {
                    Button("Save as Memory") {
                        assistant.saveAssistantMessageAsMemory(text)
                    }
                    Button("Mark as Unhelpful") {
                        assistant.markAssistantMessageUnhelpful(text)
                    }
                }
            }
    }

    private func isSelectionInsightTimelineItem(_ item: AssistantTimelineItem) -> Bool {
        guard item.kind == .system,
            let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return text.hasPrefix("### Selection Insight")
            || text.hasPrefix("### Selection Q&A")
    }

    private func handleWebViewTextSelection(
        selectedText: String,
        messageID: String,
        parentText: String,
        screenRect: CGRect
    ) {
        guard !selectedText.isEmpty else {
            guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection
            else { return }
            AssistantSelectionActionHUDManager.shared.hide()
            return
        }

        let context = AssistantTextSelectionTracker.SelectionContext(
            messageID: messageID,
            selectedText: selectedText,
            parentMessageText: parentText,
            anchorRectOnScreen: screenRect
        )
        presentSelectionActions(for: context)
    }

    private func presentSelectionActions(
        for selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        AssistantSelectionActionHUDManager.shared.show(
            anchorRect: selection.anchorRectOnScreen,
            onExplain: {
                explainSelectedText(using: selection)
            },
            onAsk: {
                askQuestionAboutSelection(using: selection)
            }
        )
    }

    private func explainSelectedText(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let preview = selectionPreview(for: selection.selectedText)
        AssistantSelectionActionHUDManager.shared.showLoading(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: "Explain Selection"
        )

        Task {
            let result = await MemoryEntryExplanationService.shared.explainSelectedText(
                selection.selectedText,
                parentMessageText: selection.parentMessageText,
                onPartialText: { partialText in
                    Task { @MainActor in
                        self.showSelectionExplanationResult(
                            partialText,
                            for: selection,
                            title: "Explain Selection",
                            preview: preview,
                            isError: false,
                            isStreaming: true
                        )
                    }
                }
            )

            await MainActor.run {
                switch result {
                case .success(let bodyText):
                    showSelectionExplanationResult(
                        bodyText,
                        for: selection,
                        title: "Explain Selection",
                        preview: preview,
                        isError: false,
                        isStreaming: false
                    )
                case .failure(let message):
                    showSelectionExplanationResult(
                        message,
                        for: selection,
                        title: "Explain Selection",
                        preview: preview,
                        isError: true,
                        isStreaming: false
                    )
                }
            }
        }
    }

    private func askQuestionAboutSelection(
        using selection: AssistantTextSelectionTracker.SelectionContext
    ) {
        let preview = selectionPreview(for: selection.selectedText)
        AssistantSelectionActionHUDManager.shared.showQuestionComposer(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            onSubmit: { question in
                submitSelectionQuestion(question, using: selection, preview: preview)
            },
            onCancel: {
                presentSelectionActions(for: selection)
            }
        )
    }

    private func submitSelectionQuestion(
        _ question: String,
        using selection: AssistantTextSelectionTracker.SelectionContext,
        preview: String
    ) {
        AssistantSelectionActionHUDManager.shared.showLoading(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: "Ask About Selection"
        )

        Task {
            let result = await MemoryEntryExplanationService.shared.explainSelectedText(
                selection.selectedText,
                parentMessageText: selection.parentMessageText,
                question: question,
                onPartialText: { partialText in
                    Task { @MainActor in
                        self.showSelectionExplanationResult(
                            partialText,
                            for: selection,
                            title: "Selection Answer",
                            preview: preview,
                            isError: false,
                            isStreaming: true
                        )
                    }
                }
            )

            await MainActor.run {
                switch result {
                case .success(let bodyText):
                    showSelectionExplanationResult(
                        bodyText,
                        for: selection,
                        title: "Selection Answer",
                        preview: preview,
                        isError: false,
                        isStreaming: false
                    )
                case .failure(let message):
                    showSelectionExplanationResult(
                        message,
                        for: selection,
                        title: "Selection Answer",
                        preview: preview,
                        isError: true,
                        isStreaming: false
                    )
                }
            }
        }
    }

    private func selectionPreview(for selectedText: String) -> String {
        let selectionPreview =
            selectedText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectionPreview.count > 180 {
            return String(selectionPreview.prefix(177)) + "..."
        }
        return selectionPreview
    }

    private func showSelectionExplanationResult(
        _ bodyText: String,
        for selection: AssistantTextSelectionTracker.SelectionContext,
        title: String,
        preview: String,
        isError: Bool,
        isStreaming: Bool
    ) {
        let openSettingsAction: (() -> Void)?
        if isError,
            bodyText.localizedCaseInsensitiveContains("connect a provider")
                || bodyText.localizedCaseInsensitiveContains("api key")
                || bodyText.localizedCaseInsensitiveContains("oauth")
        {
            openSettingsAction = {
                NotificationCenter.default.post(
                    name: .openAssistOpenSettings, object: SettingsRoute.gettingStartedHome)
            }
        } else {
            openSettingsAction = nil
        }

        AssistantSelectionActionHUDManager.shared.showResult(
            anchorRect: selection.anchorRectOnScreen,
            selectedPreview: preview,
            title: title,
            bodyText: bodyText,
            isError: isError,
            isStreaming: isStreaming,
            onAsk: isError
                ? nil
                : {
                    askQuestionAboutSelection(using: selection)
                },
            onClose: {
                AssistantSelectionActionHUDManager.shared.hide()
            },
            onOpenSettings: openSettingsAction
        )
    }

    private func compactAssistantStatusIcon(symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 0.55)
                )

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.92))
        }
        .frame(width: 22, height: 22)
    }

    private func assistantRowTint(for title: String) -> Color {
        switch title {
        case "Needs Attention":
            return .orange
        case "System":
            return AssistantWindowChrome.systemTint
        default:
            return AssistantWindowChrome.neutralAccent
        }
    }

    private func assistantRowIcon(for title: String) -> String {
        switch title {
        case "Needs Attention":
            return "exclamationmark.triangle.fill"
        case "System":
            return "server.rack"
        default:
            return "sparkles"
        }
    }

    private func inlineCopyButtonIsVisible(for messageID: String) -> Bool {
        hoveredInlineCopyMessageID == messageID
    }

    private func updateInlineCopyHoverState(for messageID: String, hovering: Bool) {
        if hovering {
            inlineCopyHideWorkItem?.cancel()
            hoveredInlineCopyMessageID = messageID
        } else if hoveredInlineCopyMessageID == messageID {
            inlineCopyHideWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                if hoveredInlineCopyMessageID == messageID {
                    hoveredInlineCopyMessageID = nil
                }
            }
            inlineCopyHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        }
    }

    private func timelineActivityRow(_ activity: AssistantActivityItem, layout: ChatLayoutMetrics)
        -> some View
    {
        let openTargets = activityOpenTargets(for: activity)
        let imagePreviews = assistantImagePreviews(from: openTargets)
        let detailSections = activityDetailSections(from: activity.rawDetails)
        let isExpanded = expandedActivityIDs.contains(activity.id)
        let canExpand = !detailSections.isEmpty || !openTargets.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 2) {
            timelineActivitySummaryLine(
                iconName: activityIconName(activity),
                iconTint: activityIconTint(activity),
                title: activityHeadline(activity, openTargetCount: openTargets.count),
                subtitle: canExpand && !isExpanded
                    ? activitySecondaryText(activity, openTargets: openTargets) : nil,
                statusLabel: activityStatusLabel(activity),
                statusTint: activityStatusTint(activity),
                timestamp: activity.updatedAt,
                disclosureState: canExpand ? (isExpanded ? .expanded : .collapsed) : nil
            ) {
                toggleExpandedActivity(activity.id)
            }

            if isExpanded {
                timelineActivityExpandedDetails(
                    detailSections: detailSections,
                    openTargets: openTargets,
                    imagePreviews: imagePreviews
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, layout.activityLeadingPadding)
        .padding(.trailing, layout.activityTrailingPadding)
        .padding(.vertical, 4)
    }

    private func timelineActivityGroupRow(
        _ group: AssistantTimelineActivityGroup, layout: ChatLayoutMetrics
    ) -> some View {
        let openTargets = activityOpenTargets(for: group)
        let imagePreviews = assistantImagePreviews(from: openTargets)
        let isExpanded = expandedActivityIDs.contains(group.id)
        let canExpand = !group.activities.isEmpty || !openTargets.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 2) {
            timelineActivitySummaryLine(
                iconName: activityGroupIconName(group),
                iconTint: activityGroupIconTint(group),
                title: activityGroupHeadline(group),
                subtitle: canExpand && !isExpanded
                    ? activityGroupSecondaryText(group, openTargets: openTargets) : nil,
                statusLabel: activityGroupStatusLabel(group),
                statusTint: activityGroupStatusTint(group),
                timestamp: group.lastUpdatedAt,
                disclosureState: canExpand ? (isExpanded ? .expanded : .collapsed) : nil
            ) {
                toggleExpandedActivity(group.id)
            }

            if isExpanded {
                timelineActivityGroupExpandedDetails(
                    group,
                    openTargets: openTargets,
                    imagePreviews: imagePreviews
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, layout.activityLeadingPadding)
        .padding(.trailing, layout.activityTrailingPadding)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func timelineActivitySummaryLine(
        iconName: String,
        iconTint: Color,
        title: String,
        subtitle: String?,
        statusLabel: String,
        statusTint: Color,
        timestamp: Date,
        disclosureState: TimelineDisclosureState? = nil,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let line = HStack(alignment: .center, spacing: 8) {
            if let disclosureState {
                timelineDisclosureChevron(expanded: disclosureState == .expanded)
                    .frame(width: 12, height: 12)
            }

            Image(systemName: iconName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 14, height: 14)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.72))
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(statusTint)
                .frame(width: 5, height: 5)

            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusTint.opacity(0.92))

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(AppVisualTheme.foreground(0.26))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let onTap, disclosureState != nil {
            Button(action: onTap) {
                line
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            line
        }
    }

    private func timelineDisclosureChevron(expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppVisualTheme.foreground(0.4))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: expanded)
    }

    private func timelineActivityOpenTargetsList(_ targets: [AssistantActivityOpenTarget])
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(targets.prefix(6))) { target in
                Button {
                    openActivityTarget(target)
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: activityOpenTargetIconName(target))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.94))
                            .frame(width: 14, height: 14)

                        Text(target.label)
                            .font(.system(size: 10.8, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.78))
                            .lineLimit(1)

                        if let detail = target.detail {
                            Text(detail)
                                .font(.system(size: 10.2, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.34))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppVisualTheme.foreground(0.32))
                    }
                    .padding(.vertical, 1)
                }
                .buttonStyle(.plain)
                .help("Open \(target.label)")
            }

            if targets.count > 6 {
                Text("+ \(targets.count - 6) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.28))
                    .padding(.leading, 22)
            }
        }
    }

    private func activityOpenTargets(for activity: AssistantActivityItem)
        -> [AssistantActivityOpenTarget]
    {
        assistantActivityOpenTargets(
            for: activity,
            sessionCWD: sessionWorkingDirectory(for: activity.sessionID)
        )
    }

    private func activityOpenTargets(for group: AssistantTimelineActivityGroup)
        -> [AssistantActivityOpenTarget]
    {
        var results: [AssistantActivityOpenTarget] = []
        var seen = Set<String>()

        for activity in group.activities {
            for target in activityOpenTargets(for: activity) {
                guard seen.insert(target.id).inserted else { continue }
                results.append(target)
            }
        }

        return results
    }

    private func sessionWorkingDirectory(for sessionID: String?) -> String? {
        if let sessionID,
            let cwd = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, sessionID)
            })?.effectiveCWD?.assistantNonEmpty
                ?? assistant.sessions.first(where: {
                    assistantTimelineSessionIDsMatch($0.id, sessionID)
                })?.cwd?.assistantNonEmpty
        {
            return cwd
        }

        if let selectedSessionID = assistant.selectedSessionID,
            let cwd = assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
            })?.effectiveCWD?.assistantNonEmpty
                ?? assistant.sessions.first(where: {
                    assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
                })?.cwd?.assistantNonEmpty
        {
            return cwd
        }

        return nil
    }

    private func toggleExpandedActivity(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedActivityIDs.contains(id) {
                expandedActivityIDs.remove(id)
            } else {
                expandedActivityIDs.insert(id)
            }
        }
    }

    private func activityDetailSections(from rawDetails: String?)
        -> [TimelineActivityDetailSectionData]
    {
        guard
            let trimmed = rawDetails?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .assistantNonEmpty
        else {
            return []
        }

        guard let separatorRange = trimmed.range(of: "\n\n") else {
            return [TimelineActivityDetailSectionData(title: "Details", text: trimmed)]
        }

        let request = String(trimmed[..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let response = String(trimmed[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [TimelineActivityDetailSectionData] = []
        if let request = request.assistantNonEmpty {
            sections.append(TimelineActivityDetailSectionData(title: "Request", text: request))
        }
        if let response = response.assistantNonEmpty {
            sections.append(TimelineActivityDetailSectionData(title: "Response", text: response))
        }

        return sections
    }

    @ViewBuilder
    private func timelineActivityExpandedDetails(
        detailSections: [TimelineActivityDetailSectionData],
        openTargets: [AssistantActivityOpenTarget],
        imagePreviews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(detailSections.enumerated()), id: \.offset) { _, section in
                timelineActivityDetailSection(section)
            }

            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }

            if !imagePreviews.isEmpty {
                timelineActivityImagePreviewSection(imagePreviews)
            }
        }
    }

    private func timelineActivityGroupExpandedDetails(
        _ group: AssistantTimelineActivityGroup,
        openTargets: [AssistantActivityOpenTarget],
        imagePreviews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }

            if !imagePreviews.isEmpty {
                timelineActivityImagePreviewSection(imagePreviews)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                    .textCase(.uppercase)

                ForEach(Array(group.activities.prefix(6).enumerated()), id: \.element.id) {
                    _, activity in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: activityIconName(activity))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(activityIconTint(activity))
                                .frame(width: 14, height: 14)

                            Text(activity.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.66))

                            Text(activityStatusLabel(activity))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(activityStatusTint(activity).opacity(0.88))

                            Spacer(minLength: 0)
                        }

                        Text(
                            activity.rawDetails?
                                .replacingOccurrences(of: "\n", with: " ")
                                .assistantNonEmpty
                                ?? activity.friendlySummary
                        )
                        .font(.system(size: 10.2, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.42))
                        .lineLimit(2)
                        .padding(.leading, 22)
                    }
                }

                if group.activities.count > 6 {
                    Text("+ \(group.activities.count - 6) more steps")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.28))
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func timelineActivityImagePreviewSection(
        _ previews: [AssistantTimelineImagePreview]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screenshots")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.34))
                .textCase(.uppercase)

            ForEach(previews) { preview in
                Button {
                    openActivityTarget(
                        AssistantActivityOpenTarget(
                            kind: .file,
                            label: preview.label,
                            url: preview.url,
                            detail: preview.detail
                        )
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let nsImage = NSImage(data: preview.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 320, maxHeight: 220, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                                )
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(preview.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.72))
                                .lineLimit(1)

                            if let detail = preview.detail {
                                Text(detail)
                                    .font(.system(size: 9.8, weight: .medium))
                                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open \(preview.label)")
            }
        }
    }

    private func timelineActivityDetailSection(_ section: TimelineActivityDetailSectionData)
        -> some View
    {
        let formattedText = assistantFormattedActivityDetailText(section.text)
        let shouldScroll =
            formattedText.count > 420 || formattedText.filter(\.isNewline).count >= 10

        return VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.34))
                .textCase(.uppercase)

            if shouldScroll {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(formattedText)
                        .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppVisualTheme.foreground(0.62))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AssistantWindowChrome.editorFill.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.55)
                        )
                )
                .appScrollbars()
            } else {
                Text(formattedText)
                    .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppVisualTheme.foreground(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AssistantWindowChrome.editorFill.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.55)
                            )
                    )
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.09))
                .frame(width: 2)
        }
    }

    private func openActivityTarget(_ target: AssistantActivityOpenTarget) {
        if target.kind == .file || target.url.isFileURL {
            let fileURL = target.url.isFileURL ? target.url : URL(fileURLWithPath: target.url.path)
            AssistantWorkspaceFileOpener.openFileURL(fileURL)
            return
        }

        NSWorkspace.shared.open(target.url)
    }

    private func activityHeadline(_ activity: AssistantActivityItem, openTargetCount: Int) -> String
    {
        switch activity.kind {
        case .commandExecution:
            return openTargetCount > 0
                ? "Explored \(openTargetCount) file\(openTargetCount == 1 ? "" : "s")"
                : "Explored the workspace"
        case .fileChange:
            return openTargetCount > 0
                ? "Edited \(openTargetCount) file\(openTargetCount == 1 ? "" : "s")"
                : "Edited the workspace"
        case .webSearch:
            return "Searched the web"
        case .browserAutomation:
            return openTargetCount > 0
                ? "Opened \(openTargetCount) link\(openTargetCount == 1 ? "" : "s")"
                : "Used the browser"
        case .mcpToolCall:
            return activity.title
        case .dynamicToolCall:
            return activity.title
        case .subagent:
            return activity.title
        case .reasoning:
            return "Reasoned through the task"
        case .other:
            return activity.title
        }
    }

    private func activitySecondaryText(
        _ activity: AssistantActivityItem,
        openTargets: [AssistantActivityOpenTarget]
    ) -> String? {
        if !openTargets.isEmpty {
            return nil
        }

        if let rawDetails = activity.rawDetails?.assistantNonEmpty {
            return rawDetails.replacingOccurrences(of: "\n", with: " ")
        }

        return activity.friendlySummary
    }

    private func activityGroupHeadline(_ group: AssistantTimelineActivityGroup) -> String {
        let exploredFiles = group.activities
            .filter { $0.kind == .commandExecution }
            .flatMap { activityOpenTargets(for: $0) }
            .filter { $0.kind == .file }
        let editedFiles = group.activities
            .filter { $0.kind == .fileChange }
            .flatMap { activityOpenTargets(for: $0) }
            .filter { $0.kind == .file }
        let searches = group.activities.filter { $0.kind == .webSearch }.count

        var fragments: [String] = []
        if !exploredFiles.isEmpty {
            fragments.append(
                "explored \(exploredFiles.count) file\(exploredFiles.count == 1 ? "" : "s")")
        }
        if !editedFiles.isEmpty {
            fragments.append("edited \(editedFiles.count) file\(editedFiles.count == 1 ? "" : "s")")
        }
        if searches > 0 {
            fragments.append("ran \(searches) search\(searches == 1 ? "" : "es")")
        }

        if fragments.isEmpty {
            return activityGroupTitle(group)
        }

        let joined = fragments.joined(separator: ", ")
        return joined.prefix(1).uppercased() + String(joined.dropFirst())
    }

    private func activityGroupSecondaryText(
        _ group: AssistantTimelineActivityGroup,
        openTargets: [AssistantActivityOpenTarget]
    ) -> String? {
        openTargets.isEmpty ? activityGroupSummary(group) : nil
    }

    private func activityOpenTargetIconName(_ target: AssistantActivityOpenTarget) -> String {
        switch target.kind {
        case .file:
            return "doc.text"
        case .webSearch:
            return "magnifyingglass"
        case .url:
            return "link"
        }
    }

    private var toolActivityStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    toolCallsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    timelineDisclosureChevron(expanded: toolCallsExpanded)
                        .frame(width: 12, height: 12)

                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.4))

                    Text(toolActivitySummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.5))

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if toolCallsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !selectedSessionToolActivity.activeCalls.isEmpty {
                            toolActivitySection(
                                title: "Active", calls: selectedSessionToolActivity.activeCalls)
                        }
                        if !selectedSessionToolActivity.recentCalls.isEmpty {
                            toolActivitySection(
                                title: "Recent", calls: selectedSessionToolActivity.recentCalls)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 18)
                }
                .frame(maxHeight: 200)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    )
                )
            }
        }
        .clipped()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func toolActivitySection(title: String, calls: [AssistantToolCallState]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.35))
                .textCase(.uppercase)

            ForEach(calls) { call in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName(for: call))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconTint(for: call))
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = call.detail?.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                            !detail.isEmpty
                        {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(AppVisualTheme.foreground(0.48))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    Text(statusLabel(for: call))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusTint(for: call))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint(for: call).opacity(0.12))
                        )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var toolActivitySummary: String {
        switch (
            selectedSessionToolActivity.activeCalls.count,
            selectedSessionToolActivity.recentCalls.count
        ) {
        case (let active, let recent) where active > 0 && recent > 0:
            return "\(active) active, \(recent) recent activities"
        case (let active, _) where active > 0:
            return "\(active) active tool\(active == 1 ? "" : "s")"
        case (_, let recent):
            return "\(recent) recent activit\(recent == 1 ? "y" : "ies")"
        }
    }

    private func iconName(for call: AssistantToolCallState) -> String {
        switch call.kind {
        case "webSearch":
            return "globe"
        case "commandExecution":
            return "terminal"
        case "mcpToolCall":
            return "shippingbox"
        case "browserAutomation":
            return "safari"
        case "fileChange":
            return "doc.badge.gearshape"
        case "reasoning":
            return "brain"
        case "dynamicToolCall":
            return "wrench.and.screwdriver"
        default:
            return "gearshape.fill"
        }
    }

    private func statusLabel(for call: AssistantToolCallState) -> String {
        let normalized = call.status.replacingOccurrences(
            of: "([A-Z])", with: " $1", options: .regularExpression)
        return normalized.capitalized
    }

    private func iconTint(for call: AssistantToolCallState) -> Color {
        switch call.kind {
        case "webSearch":
            return .cyan.opacity(0.8)
        case "commandExecution":
            return .green.opacity(0.8)
        case "fileChange":
            return .orange.opacity(0.85)
        default:
            return AppVisualTheme.foreground(0.5)
        }
    }

    private func statusTint(for call: AssistantToolCallState) -> Color {
        switch call.status.lowercased() {
        case "completed":
            return Color.green.opacity(0.78)
        case "failed", "errored":
            return Color.red.opacity(0.78)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityIconName(_ activity: AssistantActivityItem) -> String {
        switch activity.kind {
        case .webSearch:
            return "globe"
        case .commandExecution:
            return "terminal"
        case .mcpToolCall:
            return "shippingbox"
        case .browserAutomation:
            return "safari"
        case .fileChange:
            return "doc.badge.gearshape"
        case .subagent:
            return "person.2.fill"
        case .reasoning:
            return "brain"
        case .dynamicToolCall:
            return "wrench.and.screwdriver"
        case .other:
            return "gearshape.fill"
        }
    }

    private func activityIconTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.kind {
        case .webSearch:
            return .cyan.opacity(0.8)
        case .commandExecution:
            return .green.opacity(0.8)
        case .fileChange:
            return .orange.opacity(0.85)
        case .subagent:
            return .blue.opacity(0.8)
        default:
            return AppVisualTheme.foreground(0.5)
        }
    }

    private func activityStatusLabel(_ activity: AssistantActivityItem) -> String {
        activity.status.rawValue.capitalized
    }

    private func activityStatusTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.status {
        case .completed:
            return Color.green.opacity(0.78)
        case .failed:
            return Color.red.opacity(0.78)
        case .interrupted:
            return Color.orange.opacity(0.78)
        case .waiting:
            return Color.yellow.opacity(0.78)
        case .pending, .running:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupTitle(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "Activity" }

        let uniqueKinds = Set(activities.map(\.kind))
        if uniqueKinds.count == 1 {
            switch first.kind {
            case .commandExecution:
                return activities.count == 1 ? "Command" : "Commands"
            case .fileChange:
                return activities.count == 1 ? "File Change" : "File Changes"
            case .webSearch:
                return activities.count == 1 ? "Search" : "Searches"
            case .browserAutomation:
                return activities.count == 1 ? "Browser Step" : "Browser Steps"
            case .subagent:
                return activities.count == 1 ? "Subagent Step" : "Subagent Steps"
            case .mcpToolCall, .dynamicToolCall:
                return activities.count == 1 ? "Tool Use" : "Tool Uses"
            case .reasoning:
                return "Reasoning"
            case .other:
                return activities.count == 1 ? "Activity" : "Activities"
            }
        }

        return "Activity"
    }

    private func activityGroupSummary(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard !activities.isEmpty else { return "No activity details available." }

        let counts = Dictionary(grouping: activities, by: \.kind).mapValues(\.count)
        var fragments: [String] = []

        if let commands = counts[.commandExecution], commands > 0 {
            fragments.append("\(commands) command\(commands == 1 ? "" : "s")")
        }
        if let fileChanges = counts[.fileChange], fileChanges > 0 {
            fragments.append("\(fileChanges) file change\(fileChanges == 1 ? "" : "s")")
        }
        if let searches = counts[.webSearch], searches > 0 {
            fragments.append("\(searches) search\(searches == 1 ? "" : "es")")
        }
        if let browserSteps = counts[.browserAutomation], browserSteps > 0 {
            fragments.append("\(browserSteps) browser step\(browserSteps == 1 ? "" : "s")")
        }
        if let subagentSteps = counts[.subagent], subagentSteps > 0 {
            fragments.append("\(subagentSteps) subagent step\(subagentSteps == 1 ? "" : "s")")
        }

        let toolUses = (counts[.mcpToolCall] ?? 0) + (counts[.dynamicToolCall] ?? 0)
        if toolUses > 0 {
            fragments.append("\(toolUses) tool use\(toolUses == 1 ? "" : "s")")
        }

        let otherCount = counts[.other] ?? 0
        if otherCount > 0 {
            fragments.append("\(otherCount) other activit\(otherCount == 1 ? "y" : "ies")")
        }

        if fragments.isEmpty {
            return "\(activities.count) activit\(activities.count == 1 ? "y" : "ies")"
        }

        return fragments.prefix(3).joined(separator: ", ")
    }

    private func activityGroupStatusLabel(_ group: AssistantTimelineActivityGroup) -> String {
        if group.activities.contains(where: { $0.status == .failed }) {
            return "Failed"
        }
        if group.activities.contains(where: { $0.status == .interrupted }) {
            return "Interrupted"
        }
        if group.activities.contains(where: { $0.status == .waiting }) {
            return "Waiting"
        }
        if group.activities.contains(where: { $0.status == .running || $0.status == .pending }) {
            return "Running"
        }
        return "Completed"
    }

    private func activityGroupStatusTint(_ group: AssistantTimelineActivityGroup) -> Color {
        switch activityGroupStatusLabel(group) {
        case "Completed":
            return Color.green.opacity(0.78)
        case "Failed":
            return Color.red.opacity(0.78)
        case "Interrupted":
            return Color.orange.opacity(0.82)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupIconName(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "square.stack.3d.up" }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconName(first) : "square.stack.3d.up"
    }

    private func activityGroupIconTint(_ group: AssistantTimelineActivityGroup) -> Color {
        let activities = group.activities
        guard let first = activities.first else { return AppVisualTheme.foreground(0.5) }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconTint(first) : AppVisualTheme.foreground(0.5)
    }

    private func sendCurrentPrompt() {
        userHasScrolledUp = false
        let prompt = assistant.promptDraft
        if let appDelegate = AppDelegate.shared {
            appDelegate.sendAssistantTypedPrompt(prompt)
        } else {
            Task { await assistant.sendPrompt(prompt) }
        }
    }

    private func toggleInteractionMode() {
        assistant.interactionMode = assistant.interactionMode.nextMode
    }

    private func minimizeToCompact() {
        NotificationCenter.default.post(
            name: .openAssistMinimizeAssistantToCompact,
            object: nil
        )
    }

    @ViewBuilder
    private var chatComposerBanners: some View {
        if let blockedReason = assistant.conversationBlockedReason {
            composerStatusBanner(
                symbol: assistant.isLoadingModels ? "hourglass" : "exclamationmark.circle",
                text: blockedReason,
                tint: assistant.isLoadingModels ? AppVisualTheme.foreground(0.50) : .orange
            )
            .padding(.bottom, 6)
        }

        if let suggestion = assistant.modeSwitchSuggestion {
            composerStatusBanner(
                symbol: suggestion.source == .blocked ? "arrow.triangle.branch" : "lightbulb",
                text: suggestion.message,
                tint: suggestion.source == .blocked ? .orange : AppVisualTheme.foreground(0.50)
            ) {
                modeSwitchSuggestionButtons(suggestion)
            }
            .padding(.bottom, 6)
        }

        if let branch = assistant.historyBranchState,
           let bannerText = branch.bannerText {
            composerStatusBanner(
                symbol: branch.kind == .undo
                    ? "arrow.uturn.backward.circle"
                    : (branch.kind == .edit ? "pencil.circle" : "arrow.uturn.backward.circle"),
                text: bannerText,
                tint: AppVisualTheme.accentTint
            ) {
                if assistant.canStepHistoryBranchBackward {
                    Button("Previous message") {
                        Task { await assistant.stepHistoryBranchBackward() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.accentTint.opacity(0.18))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.5)
                            )
                    )
                }

                Button {
                    Task { await assistant.redoUndoneUserMessage() }
                } label: {
                    Image(systemName: "arrow.uturn.forward.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppVisualTheme.foreground(0.92))
                .background(
                    Circle()
                        .fill(AppVisualTheme.accentTint.opacity(0.18))
                        .overlay(
                            Circle()
                                .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.5)
                        )
                )
                .help("Redo the original request")
                .accessibilityLabel("Redo")
            }
            .padding(.bottom, 6)

            if !assistant.historyRestoreItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(assistant.historyRestoreItems) { item in
                            Button("Restore: \(item.title)") {
                                Task { await assistant.restoreHistoryRestoreItem(item.id) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(AppVisualTheme.foreground(0.92))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppVisualTheme.surfaceFill(0.12))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(AppVisualTheme.surfaceStroke(0.12), lineWidth: 0.5)
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func chatComposer(layout: ChatLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chatComposerBanners

            AssistantComposerWebView(
                state: composerWebState,
                accentColor: AppVisualTheme.accentTint,
                onHeightChange: updateComposerMeasuredHeight,
                onCommand: handleComposerWebCommand
            )
            .frame(height: composerWebHeight(for: layout))
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppVisualTheme.surfaceStroke(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 4)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onDrop(of: [.fileURL, .image, .png, .jpeg], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
        // Background provided by unified chatBottomDock container
    }

    private var canSendMessage: Bool {
        canStartConversation && (!trimmedPromptDraft.isEmpty || !assistant.attachments.isEmpty)
    }

    private var trimmedPromptDraft: String {
        assistant.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sessionMemoryIsActive: Bool {
        guard settings.assistantMemoryEnabled else { return false }
        guard
            let message = assistant.memoryStatusMessage?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return false
        }
        return message.lowercased().contains("using")
    }

    private var sessionMemoryStatusLabel: String {
        sessionMemoryIsActive ? "Session memory on" : "Session memory off"
    }

    private var liveVoicePanel: some View {
        VStack(spacing: 0) {
            // Collapsed header – always visible
            HStack(spacing: 8) {
                AssistantStatusBadge(
                    title: "Live Voice Agent",
                    tint: liveVoiceStatusTint,
                    symbol: liveVoiceStatusSymbol
                )

                Text(liveVoiceStatusText)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLiveVoicePanelCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isLiveVoicePanelCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isLiveVoicePanelCollapsed ? "Expand voice controls" : "Collapse voice controls")
            }

            // Expanded controls
            if !isLiveVoicePanelCollapsed {
                HStack(spacing: 8) {
                    if let transcriptStatus = liveVoiceTranscriptStatusText {
                        Text(transcriptStatus)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(0.34))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if assistant.isLiveVoiceSessionActive {
                        if assistant.liveVoiceSessionSnapshot.isSpeaking {
                            Button("Stop") {
                                assistant.stopSpeakingAndResumeListening()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Button("End") {
                            assistant.endLiveVoiceSession()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundStyle(.red.opacity(0.8))
                    } else {
                        Button(
                            assistant.liveVoiceSessionSnapshot.phase == .paused
                                ? "Resume"
                                : "Start"
                        ) {
                            assistant.startLiveVoiceSession()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!assistant.canStartLiveVoiceSession)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                )
        )
    }

    private func topBarTextActionButton(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint.opacity(0.96))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 0.55)
                    )
            )
    }

    @ViewBuilder
    private func composerToolbarGroup<Content: View>(@ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(spacing: 6) {
            content()
        }
    }

    @ViewBuilder
    private func composerStatusBanner<Accessory: View>(
        symbol: String,
        text: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.64))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.12), lineWidth: 0.6)
                )
        )
    }

    @ViewBuilder
    private func modeSwitchSuggestionButtons(_ suggestion: AssistantModeSwitchSuggestion)
        -> some View
    {
        HStack(spacing: 6) {
            ForEach(suggestion.choices) { choice in
                Button(choice.title) {
                    Task { await assistant.applyModeSwitchSuggestion(choice) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            AppVisualTheme.accentTint.opacity(
                                suggestion.source == .blocked ? 0.24 : 0.18)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private var compactRuntimeProviderPicker: some View {
        let helpText = assistant.selectedSessionBackendHelpText?.assistantNonEmpty
        let picker = HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(assistant.selectableAssistantBackends, id: \.self) { backend in
                    compactRuntimeProviderButton(for: backend)
                }
            }
            .padding(2)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.04))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.55)
                    )
            )
            .opacity(assistant.isSelectedSessionBackendPinned ? 0.72 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .animation(
            .spring(response: 0.22, dampingFraction: 0.86), value: assistant.visibleAssistantBackend
        )
        .animation(.easeInOut(duration: 0.18), value: assistant.isSelectedSessionBackendPinned)

        return Group {
            if let helpText {
                picker.help(helpText)
            } else {
                picker
            }
        }
    }

    private func compactRuntimeProviderButton(
        for backend: AssistantRuntimeBackend
    ) -> some View {
        let isSelected = backend == assistant.visibleAssistantBackend
        let selectedTint = AppVisualTheme.accentTint

        return Button {
            assistant.selectAssistantBackend(backend)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? selectedTint.opacity(0.9) : AppVisualTheme.foreground(0.20))
                    .frame(width: 4, height: 4)
                    .shadow(
                        color: isSelected ? selectedTint.opacity(0.22) : .clear,
                        radius: 4,
                        x: 0,
                        y: 0
                    )

                Text(backend.shortDisplayName)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? AppVisualTheme.foreground(0.9)
                            : AppVisualTheme.foreground(0.42)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? AppVisualTheme.surfaceFill(0.10) : .clear)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isSelected
                                    ? selectedTint.opacity(0.16)
                                    : AppVisualTheme.surfaceStroke(0.0),
                                lineWidth: 0.55
                            )
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(assistant.isSelectedSessionBackendPinned)
    }

    private var supportedEfforts: [AssistantReasoningEffort] {
        guard let selectedModel = assistant.selectedModel else {
            return AssistantReasoningEffort.allCases
        }
        let efforts = selectedModel.supportedReasoningEfforts.compactMap {
            AssistantReasoningEffort(rawValue: $0)
        }
        if efforts.isEmpty, assistant.visibleAssistantBackend == .copilot {
            return [assistant.reasoningEffort]
        }
        return efforts.isEmpty ? AssistantReasoningEffort.allCases : efforts
    }

    private var reasoningSelectionDisabled: Bool {
        guard let selectedModel = assistant.selectedModel else { return true }
        return assistant.visibleAssistantBackend == .copilot
            && selectedModel.supportedReasoningEfforts.isEmpty
    }

    private var runtimeDotColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return .green
        case .checking, .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private var chatWebRuntimePanel: AssistantChatWebRuntimePanel? {
        let detail = assistant.runtimeHealth.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        let filteredDetail: String?
        if let detail, !detail.lowercased().contains("failed to load rollout") {
            filteredDetail = detail
        } else {
            filteredDetail = nil
        }

        return AssistantChatWebRuntimePanel(
            tone: runtimePanelTone,
            statusSummary: assistant.runtimeHealth.summary,
            statusDetail: filteredDetail,
            accountSummary: assistant.accountSnapshot.isLoggedIn
                ? assistant.accountSnapshot.summary : nil,
            backendHelpText: assistant.selectedSessionBackendHelpText,
            backends: assistant.selectableAssistantBackends.map { backend in
                AssistantChatWebRuntimeBackendOption(
                    id: backend.rawValue,
                    label: backend.shortDisplayName,
                    isSelected: backend == assistant.visibleAssistantBackend,
                    isDisabled: assistant.isSelectedSessionBackendPinned
                )
            },
            setupButtonTitle: canChat ? nil : "Open Setup"
        )
    }

    private var runtimePanelTone: String {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return "ready"
        case .checking, .connecting:
            return "connecting"
        case .failed:
            return "failed"
        default:
            return "idle"
        }
    }

    private var runtimeIndicatorColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active:
            return Color.green.opacity(0.92)
        case .checking, .connecting:
            return Color.orange.opacity(0.92)
        case .failed:
            return Color.red.opacity(0.92)
        default:
            return AppVisualTheme.foreground(0.42)
        }
    }

    private func permissionCard(
        _ request: AssistantPermissionRequest, state: AssistantPermissionCardState
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.cardTitle)
                    .font(.headline)
                Spacer()
                AssistantStatusBadge(title: state.badgeTitle, tint: permissionBadgeTint(for: state))
            }

            Text(request.toolTitle)
                .font(.callout.weight(.semibold))
            if let rationale = request.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }

            if let summary = request.rawPayloadSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppVisualTheme.mutedText)
                    .lineLimit(4)
            }

            switch state {
            case .waitingForInput where request.hasStructuredUserInput:
                AssistantStructuredUserInputView(
                    request: request,
                    accent: .orange,
                    secondaryText: AppVisualTheme.mutedText,
                    fieldBackground: AppVisualTheme.foreground(0.04),
                    submitTitle: "Submit Answers",
                    cancelTitle: "Cancel Request"
                ) { answers in
                    Task { await assistant.resolvePermission(answers: answers) }
                } onCancel: {
                    Task { await assistant.cancelPermissionRequest() }
                }

            case .waitingForApproval, .waitingForInput:
                ForEach(request.options) { option in
                    if option.isDefault {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let toolKind = request.toolKind, !toolKind.isEmpty, toolKind != "modeSwitch",
                    toolKind != "userInput", toolKind != "browserLogin"
                {
                    Button("Always Allow") {
                        assistant.alwaysAllowToolKind(toolKind)
                        let sessionOption =
                            request.options.first(where: { $0.id == "acceptForSession" })
                            ?? request.options.first(where: { $0.isDefault })
                        if let optionID = sessionOption?.id {
                            Task { await assistant.resolvePermission(optionID: optionID) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Button("Cancel Request") {
                    Task { await assistant.cancelPermissionRequest() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .completed:
                Text(
                    "This approval prompt is part of the session history. It only means the request flow finished, not that the tool succeeded."
                )
                .font(.caption)
                .foregroundStyle(AppVisualTheme.mutedText)

            case .notActive:
                Text("This request is no longer active in the live session.")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
        }
        .padding(16)
        .appThemedSurface(
            cornerRadius: 10,
            tint: permissionSurfaceTint(for: state),
            strokeOpacity: 0.16,
            tintOpacity: 0.045
        )
    }

    private func permissionBadgeTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return AppVisualTheme.foreground(0.45)
        case .notActive:
            return AppVisualTheme.foreground(0.45)
        }
    }

    private func permissionSurfaceTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return .green
        case .notActive:
            return AppVisualTheme.primaryText
        }
    }

    private func proposedPlanCard(_ plan: String, isStreaming: Bool, showsActions: Bool)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.55))
                Text("Proposed Plan")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                Spacer()
                if showsActions {
                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppVisualTheme.foreground(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                AssistantMarkdownText(
                    contentID:
                        "proposed-plan-\(assistant.selectedSessionID ?? "session")-\(plan.hashValue)",
                    text: plan,
                    role: .assistant,
                    isStreaming: isStreaming,
                    selectionMessageID: "proposed-plan-\(assistant.selectedSessionID ?? "session")",
                    selectionMessageText: plan,
                    selectionTracker: selectionTracker
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            if plan.count > 400 {
                Text("Scroll to view the full plan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.3))
            }

            HStack(spacing: 10) {
                Button {
                    copyAssistantTextToPasteboard(plan)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy Plan")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppVisualTheme.foreground(0.86))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.08))
                    )
                }
                .buttonStyle(.plain)

                if showsActions {
                    Button {
                        Task { await assistant.executePlan() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Execute Plan")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppVisualTheme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppVisualTheme.accentTint)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(assistant.hasActiveTurn)
                    .opacity(assistant.hasActiveTurn ? 0.55 : 1.0)

                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if assistant.hasActiveTurn && showsActions {
                Text("Wait for the plan to finish before executing it.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                )
        )
    }

    private func badgeTint(for availability: AssistantRuntimeAvailability) -> Color {
        switch availability {
        case .ready, .active:
            return .green
        case .checking, .connecting:
            return AppVisualTheme.accentTint
        case .installRequired, .loginRequired:
            return .orange
        case .failed:
            return .red
        case .idle, .unavailable:
            return .secondary
        }
    }

    private func refreshEverything(refreshPermissions: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let permissions = refreshPermissions ? currentPermissionSnapshot() : assistant.permissions
        await assistant.refreshEnvironment(permissions: permissions)
        await assistant.refreshSessions()
    }

    private func currentPermissionSnapshot() -> AssistantPermissionSnapshot {
        let snapshot = PermissionCenter.snapshot(using: settings)
        return AssistantPermissionSnapshot(
            accessibility: snapshot.accessibilityGranted ? .granted : .missing,
            screenRecording: snapshot.screenRecordingGranted ? .granted : .missing,
            microphone: snapshot.microphoneGranted ? .granted : .missing,
            speechRecognition: snapshot.speechRecognitionGranted
                || !snapshot.speechRecognitionRequired ? .granted : .missing,
            appleEvents: snapshot.appleEventsKnown
                ? (snapshot.appleEventsGranted ? .granted : .missing)
                : .unknown,
            fullDiskAccess: snapshot.fullDiskAccessKnown
                ? (snapshot.fullDiskAccessGranted ? .granted : .missing)
                : .unknown
        )
    }

    private func scrollToLatestMessage(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard canScrollToLatestVisibleContent else {
            pendingScrollToLatestWorkItem?.cancel()
            return
        }
        pendingScrollToLatestWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
        guard let workItem else { return }
        pendingScrollToLatestWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: - Attachments

    private func threadSkillChip(_ state: AssistantThreadSkillState) -> some View {
        AssistantThreadSkillChip(
            state: state,
            onRemove: {
                assistant.detachSkill(state.skillName)
            },
            onRepair: {
                assistant.repairMissingSkillBindings()
                selectedSidebarPane = .skills
            }
        )
    }

    private func attachmentChip(_ attachment: AssistantAttachment) -> some View {
        HStack(spacing: 8) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Button {
                    previewAttachment = attachment
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppVisualTheme.accentTint.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Image(systemName: "doc.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint.opacity(0.95))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.76))
                    .lineLimit(1)
                Text(attachment.isImage ? "Image attachment" : "File attachment")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
            }
            Button {
                assistant.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.45))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(AppVisualTheme.surfaceFill(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.6)
                )
        )
    }

    private func openFilePicker() {
        AssistantAttachmentSupport.openFilePicker { attachments in
            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        }
    }

    private func openImagePicker() {
        AssistantAttachmentSupport.openFilePicker(
            allowedContentTypes: AssistantAttachmentSupport.imageContentTypes
        ) { attachments in
            guard !attachments.isEmpty else { return }
            assistant.attachments.append(contentsOf: attachments)
        }
    }

    private func openSkillFolderImportPanel() {
        let panel = NSOpenPanel()
        panel.prompt = "Import Skill"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the folder that contains SKILL.md."

        if panel.runModal() == .OK, let url = panel.url {
            assistant.importSkill(fromFolderURL: url)
        }
    }

    private func confirmDeleteSkill(_ skill: AssistantSkillDescriptor) {
        let alert = NSAlert()
        alert.messageText = "Delete skill?"
        alert.informativeText =
            "This removes “\(skill.displayName)” from ~/.codex/skills. Thread bindings will stay, but they will show as missing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            assistant.deleteSkill(skill)
        }
    }

    private func trySkillFromLibrary(_ skill: AssistantSkillDescriptor, prompt: String) {
        Task { @MainActor in
            // Always start a fresh thread so the user's current conversation is preserved.
            await assistant.startNewSession()

            if assistant.canAttachSkillsToSelectedThread,
                !assistant.isSkillAttachedToSelectedThread(skill)
            {
                assistant.attachSkill(skill)
            }

            assistant.promptDraft = prompt
            selectedSidebarPane = .threads
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        AssistantAttachmentSupport.handleDrop(providers) { attachment in
            assistant.attachments.append(attachment)
        }
    }
}

// MARK: - Collapsible Image Attachments

private struct CollapsibleImageAttachments: View {
    let imageAttachments: [Data]
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var isExpanded = false

    private var label: String {
        imageAttachments.count == 1
            ? "Show screenshot" : "Show \(imageAttachments.count) screenshots"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
                        .frame(width: 10)

                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))

                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.50))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(imageAttachments.enumerated()), id: \.offset) { _, imageData in
                    if let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                            )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }
}
