import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AssistantSidebarPane {
    case threads
    case automations
}

private struct AssistantProjectIconOption: Identifiable {
    let title: String
    let symbol: String

    var id: String { symbol }
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
        .init(title: "Brain", symbol: "brain")
    ]

    private struct ChatLayoutMetrics {
        let windowWidth: CGFloat
        let sidebarWidth: CGFloat
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

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingDeleteSession: AssistantSessionSummary?
    @State private var pendingDeleteProject: AssistantProject?
    @State private var showSessionInstructions = false
    @State private var userHasScrolledUp = false
    @State private var autoScrollPinnedToBottom = true
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit
    @State private var chatViewportHeight: CGFloat = 0
    @State private var isLoadingOlderHistory = false
    @State private var hoveredInlineCopyMessageID: String?
    @State private var inlineCopyHideWorkItem: DispatchWorkItem?
    @State private var previewAttachment: AssistantAttachment?
    @State private var chatScrollTracking = AssistantChatScrollTracking()
    @State private var selectedSidebarPane: AssistantSidebarPane = .threads
    @State private var pendingScrollToLatestWorkItem: DispatchWorkItem?
    @State private var suppressNextTimelineAutoScrollAnimation = true
    @State private var isLiveVoicePanelCollapsed = false
    @State private var isPreservingHistoryScrollPosition = false
    @State private var cachedVisibleRenderItems: [AssistantTimelineRenderItem] = []
    @StateObject private var selectionTracker = AssistantTextSelectionTracker.shared
    @AppStorage("assistantSidebarCollapsed") private var isSidebarCollapsed = false
    @AppStorage("assistantSidebarProjectsExpanded") private var areProjectsExpanded = true
    @AppStorage("assistantSidebarThreadsExpanded") private var areThreadsExpanded = true
    @AppStorage("assistantRuntimeExpanded") private var isRuntimeExpanded = true
    @AppStorage("assistantChatTextScale") private var chatTextScale: Double = 1.0

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
            sessionStatusByNormalizedID: sessionStatusByNormalizedID
        )
        return visibleRenderItems.flatMap {
            AssistantChatWebMessage.from(
                renderItem: $0,
                historyActions: historyActions,
                renderContext: renderContext
            )
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
                await assistant.loadMoreHistoryForSelectedSession()
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

    private func sessionStatus(forSessionID sessionID: String?) -> AssistantSessionStatus? {
        guard let sid = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !sid.isEmpty else { return nil }
        return sessionStatusByNormalizedID[sid]
    }

    private var shouldAutoFollowLatestMessage: Bool {
        autoScrollPinnedToBottom
            && !userHasScrolledUp
            && !isPreservingHistoryScrollPosition
            && Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt) >= Self.manualScrollFollowPause
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

    private func sidebarScaled(_ value: CGFloat) -> CGFloat {
        value * sidebarTextScale
    }

    private func scaledSidebarWidth(for safeWindowWidth: CGFloat, outerPadding: CGFloat) -> CGFloat {
        let baseSidebarWidth = min(260.0, max(210.0, safeWindowWidth * 0.22))
        let expandedSidebarWidth = baseSidebarWidth * max(1.0, sidebarTextScale)
        let maxSidebarWidth = max(210.0, safeWindowWidth - (outerPadding * 2) - 320.0 - 0.5)
        return min(expandedSidebarWidth, maxSidebarWidth)
    }

    private func sidebarActivityState(for session: AssistantSessionSummary) -> AssistantSessionRow.ActivityState {
        assistantSidebarActivityState(
            forSessionID: session.id,
            selectedSessionID: assistant.selectedSessionID,
            activeRuntimeSessionID: assistant.activeRuntimeSessionID,
            sessionStatus: session.status,
            hasPendingPermissionRequest: assistant.pendingPermissionRequest != nil,
            hudPhase: assistant.hudState.phase,
            isTransitioningSession: assistant.isTransitioningSession,
            isLiveVoiceSessionActive: assistant.isLiveVoiceSessionActive,
            hasActiveTurn: assistant.hasActiveTurn
        )
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
                ? "Models will appear here when Codex is ready."
                : "Select a model to start chatting..."
        }
        return "Ask for follow-up changes"
    }

    private var emptyStateMessage: String {
        if !settings.assistantBetaEnabled {
            return "Enable the assistant in Settings, then come back here."
        }
        if !canChat {
            return "Open Setup to connect to Codex, then come back to chat."
        }
        return assistant.conversationBlockedReason ?? "Send a message to start a conversation with the assistant."
    }

    private var activeSessionSummary: AssistantSessionSummary? {
        guard let selectedSessionID = assistant.selectedSessionID else { return nil }
        return assistant.sessions.first(where: { assistantTimelineSessionIDsMatch($0.id, selectedSessionID) })
    }

    private var activeSessionProject: AssistantProject? {
        guard let projectID = activeSessionSummary?.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return assistant.projects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    private var activeSessionTitle: String {
        activeSessionSummary?.title ?? "No session selected"
    }

    private var visibleSidebarSessionCount: Int {
        assistant.visibleSidebarSessions.count
    }

    private var projectThreadCountByProjectID: [String: Int] {
        assistant.sessions.reduce(into: [:]) { result, session in
            guard let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return
            }
            result[projectID, default: 0] += 1
        }
    }

    private func chatLayoutMetrics(for windowWidth: CGFloat) -> ChatLayoutMetrics {
        let safeWindowWidth = max(windowWidth, 640)
        let outerPadding = safeWindowWidth < 900 ? 2.0 : 4.0
        let sidebarWidth = scaledSidebarWidth(for: safeWindowWidth, outerPadding: outerPadding)
        let visibleSidebarWidth = isSidebarCollapsed ? 0.0 : sidebarWidth
        let detailWidth = max(320.0, safeWindowWidth - visibleSidebarWidth - (outerPadding * 2) - (isSidebarCollapsed ? 0.0 : 0.5))
        let isNarrow = detailWidth < 760
        let isMedium = detailWidth < 1080
        let timelineHorizontalPadding = isNarrow ? 16.0 : (isMedium ? 24.0 : 32.0)
        let maxColumnWidth = isNarrow ? detailWidth - (timelineHorizontalPadding * 2) : min(780.0, detailWidth * 0.82)
        let contentMaxWidth = max(280.0, min(detailWidth - (timelineHorizontalPadding * 2), maxColumnWidth))
        let topBarMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 8 : 28))
        let composerMaxWidth = min(detailWidth - 16, contentMaxWidth + (isNarrow ? 0 : 18))
        let userBubbleMaxWidth = min(contentMaxWidth * (isNarrow ? 0.96 : 0.80), isNarrow ? 540.0 : 640.0)
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
            leadingPaneFraction: min(0.32, max(0.20, layout.sidebarWidth / max(layout.windowWidth, 1))),
            leadingPaneMaxWidth: 280,
            leadingPaneWidth: layout.sidebarWidth,
            leadingTint: AppVisualTheme.sidebarTint,
            trailingTint: AppVisualTheme.windowBackground,
            accent: AppVisualTheme.accentTint,
            leadingPaneTransparent: true
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = chatLayoutMetrics(for: proxy.size.width)

            ZStack {
                if !isSidebarCollapsed {
                    assistantSplitBackground(layout: layout)
                } else {
                    AppVisualTheme.windowBackground
                        .ignoresSafeArea()
                }

                HStack(spacing: 0) {
                    if !isSidebarCollapsed {
                        sidebar(layout: layout)

                        Rectangle()
                            .fill(AppVisualTheme.surfaceFill(0.06))
                            .frame(width: 0.5)
                            .frame(maxHeight: .infinity)
                    }

                    detailPane(layout: layout)
                }
                .padding(.horizontal, layout.outerPadding)
                .padding(.bottom, 4)
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
            "Delete this Open Assist session?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteSession = nil
                    }
                }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await assistant.deleteSession(session.id) }
                pendingDeleteSession = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: { session in
            Text("This removes the saved Open Assist thread “\(session.title)”.")
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
            Text("This removes the Open Assist project “\(project.name)”. Threads will stay saved, but they will no longer belong to this project.")
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
        .sheet(isPresented: $assistant.showMemoryInspector, onDismiss: {
            assistant.dismissMemoryInspector()
        }) {
            AssistantMemoryInspectorSheet(assistant: assistant)
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
                guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection else {
                    return
                }
                AssistantSelectionActionHUDManager.shared.hide()
                return
            }

            presentSelectionActions(for: context)
        }
        .onChange(of: assistant.selectedSessionID) { newSessionID in
            guard newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            selectionTracker.clearSelection()
            AssistantSelectionActionHUDManager.shared.hide()
            selectedSidebarPane = .threads
            resetVisibleHistoryWindow()
            suppressNextTimelineAutoScrollAnimation = true
        }
    }

    private func sidebar(layout: ChatLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // New thread button
            Button {
                selectedSidebarPane = .threads
                Task { await assistant.startNewSession() }
            } label: {
                HStack(spacing: sidebarScaled(8)) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: sidebarScaled(12), weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.70))
                    Text("New thread")
                        .font(.system(size: sidebarScaled(13), weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.82))
                    Spacer()
                }
                .padding(.horizontal, sidebarScaled(10))
                .padding(.vertical, sidebarScaled(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canStartConversation)
            .padding(.bottom, sidebarScaled(8))

            // Sidebar actions
            VStack(alignment: .leading, spacing: sidebarScaled(2)) {
                sidebarNavButton(
                    symbol: "clock",
                    label: "Automations",
                    isSelected: selectedSidebarPane == .automations
                ) {
                    selectedSidebarPane = .automations
                }
                sidebarNavItem(symbol: "gearshape.2", label: "Skills")
            }
            .padding(.bottom, sidebarScaled(12))

            Rectangle()
                .fill(AssistantWindowChrome.sidebarDivider)
                .frame(height: 0.5)
                .padding(.horizontal, sidebarScaled(4))
                .padding(.bottom, sidebarScaled(12))

            if !assistant.sessions.isEmpty {
            }

            // Sidebar content controls
            HStack(alignment: .center, spacing: 0) {
                Spacer()

                HStack(spacing: sidebarScaled(4)) {
                    Button {
                        guard !isRefreshing else { return }
                        Task { await refreshEverything() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: sidebarScaled(10), weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.34))
                            .frame(width: sidebarScaled(22), height: sidebarScaled(22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarCollapsed = true
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: sidebarScaled(10), weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.34))
                            .frame(width: sidebarScaled(22), height: sidebarScaled(22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, sidebarScaled(6))
            .padding(.bottom, sidebarScaled(8))

            ScrollView {
                VStack(alignment: .leading, spacing: sidebarScaled(8)) {
                    VStack(alignment: .leading, spacing: sidebarScaled(4)) {
                        HStack(spacing: sidebarScaled(8)) {
                            Text("Projects")
                                .font(.system(size: sidebarScaled(12.5), weight: .bold))
                                .foregroundStyle(AppVisualTheme.foreground(0.82))

                            Spacer()

                            if assistant.selectedProjectFilterID != nil {
                                Button("Clear") {
                                    selectedSidebarPane = .threads
                                    Task { await assistant.selectProjectFilter(nil) }
                                }
                                .font(.system(size: sidebarScaled(10.5), weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.62))
                                .buttonStyle(.plain)
                                .help("Show all threads again")
                            }

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    areProjectsExpanded.toggle()
                                }
                            } label: {
                                Image(systemName: areProjectsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: sidebarScaled(9), weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.52))
                                    .frame(width: sidebarScaled(18), height: sidebarScaled(18))
                            }
                            .buttonStyle(.plain)
                            .help(areProjectsExpanded ? "Collapse projects" : "Expand projects")

                            Button {
                                presentCreateProjectPrompt()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: sidebarScaled(10), weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.48))
                                    .frame(width: sidebarScaled(18), height: sidebarScaled(18))
                            }
                            .buttonStyle(.plain)
                            .help("Create project")
                        }
                    }

                    if areProjectsExpanded {
                        if assistant.projects.isEmpty {
                            Text("No projects yet")
                                .font(.system(size: sidebarScaled(12), weight: .regular))
                                .foregroundStyle(AppVisualTheme.foreground(0.34))
                                .padding(.horizontal, sidebarScaled(10))
                                .padding(.top, sidebarScaled(4))
                        } else {
                            ForEach(assistant.projects) { project in
                                Button {
                                    selectedSidebarPane = .threads
                                    Task { await assistant.selectProjectFilter(project.id) }
                                } label: {
                                    AssistantProjectFilterRow(
                                        title: project.name,
                                        subtitle: "\(projectThreadCountByProjectID[project.id.lowercased(), default: 0]) threads",
                                        isSelected: assistant.selectedProjectFilterID?.caseInsensitiveCompare(project.id) == .orderedSame,
                                        symbol: project.displayIconSymbolName,
                                        folderMissing: project.linkedFolderPath != nil
                                            && !FileManager.default.fileExists(atPath: project.linkedFolderPath ?? ""),
                                        textScale: sidebarTextScale
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { projectContextMenu(for: project) }
                            }
                        }
                    }

                    Rectangle()
                        .fill(AssistantWindowChrome.sidebarDivider)
                        .frame(height: 0.5)
                        .padding(.vertical, sidebarScaled(4))

                    VStack(alignment: .leading, spacing: sidebarScaled(4)) {
                        HStack(spacing: sidebarScaled(8)) {
                            Text("Threads")
                                .font(.system(size: sidebarScaled(12.5), weight: .bold))
                                .foregroundStyle(AppVisualTheme.foreground(0.82))

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    areThreadsExpanded.toggle()
                                }
                            } label: {
                                Image(systemName: areThreadsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: sidebarScaled(9), weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.52))
                                    .frame(width: sidebarScaled(18), height: sidebarScaled(18))
                            }
                            .buttonStyle(.plain)
                            .help(areThreadsExpanded ? "Collapse threads" : "Expand threads")
                        }

                        if areThreadsExpanded {
                            if visibleSidebarSessionCount == 0 {
                                Text(assistant.selectedProjectFilterID == nil ? "No threads yet" : "No threads in this project yet")
                                    .font(.system(size: sidebarScaled(12), weight: .regular))
                                    .foregroundStyle(AppVisualTheme.foreground(0.34))
                                    .padding(.horizontal, sidebarScaled(10))
                                    .padding(.vertical, sidebarScaled(16))
                            } else {
                                ForEach(assistant.visibleSidebarSessions.prefix(assistant.visibleSessionsLimit)) { session in
                                    Button {
                                        guard session.isLocalSession else { return }
                                        selectedSidebarPane = .threads
                                        Task { await assistant.openSession(session) }
                                    } label: {
                                        AssistantSessionRow(
                                            session: session,
                                            isSelected: assistant.selectedSessionID == session.id,
                                            activityState: sidebarActivityState(for: session),
                                            textScale: sidebarTextScale
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { threadContextMenu(for: session) }
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.985))
                                    ))
                                }

                                if visibleSidebarSessionCount > assistant.visibleSessionsLimit {
                                    Button {
                                        assistant.loadMoreSessions()
                                    } label: {
                                        Text("Load more")
                                            .font(.system(size: sidebarScaled(11), weight: .medium))
                                            .foregroundStyle(AppVisualTheme.foreground(0.44))
                                            .padding(.vertical, sidebarScaled(6))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, sidebarScaled(2))
                                }
                            }
                        }
                    }
                    .animation(
                        .spring(response: 0.26, dampingFraction: 0.86),
                        value: assistant.visibleSidebarSessions.map {
                            let updatedAt = $0.updatedAt ?? $0.createdAt ?? .distantPast
                            return "\($0.id)|\($0.title)|\(updatedAt.timeIntervalSince1970)"
                        }
                    )
                }
                .padding(.horizontal, sidebarScaled(4))
            }
            .appScrollbars()

            Spacer(minLength: 0)

            Rectangle()
                .fill(AssistantWindowChrome.sidebarDivider)
                .frame(height: 0.5)
                .padding(.horizontal, sidebarScaled(4))
                .padding(.bottom, sidebarScaled(8))

            // Settings button at bottom
            Button {
                NotificationCenter.default.post(name: .openAssistOpenAssistantSetup, object: nil)
            } label: {
                HStack(spacing: sidebarScaled(8)) {
                    Image(systemName: "gearshape")
                        .font(.system(size: sidebarScaled(12), weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.50))
                    Text("Settings")
                        .font(.system(size: sidebarScaled(13), weight: .regular))
                        .foregroundStyle(AppVisualTheme.foreground(0.60))
                    Spacer()
                }
                .padding(.horizontal, sidebarScaled(10))
                .padding(.vertical, sidebarScaled(6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, sidebarScaled(10))
        .padding(.vertical, sidebarScaled(12))
        .frame(width: layout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func detailPane(layout: ChatLayoutMetrics) -> some View {
        switch selectedSidebarPane {
        case .threads:
            chatDetail(layout: layout)
        case .automations:
            automationDetail
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
                    .foregroundStyle(isSelected ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.44))
                    .frame(width: sidebarScaled(16))
                Text(label)
                    .font(.system(size: sidebarScaled(13), weight: .regular))
                    .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.88) : AppVisualTheme.foreground(0.60))
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
           selectedSession.projectID?.caseInsensitiveCompare(project.id) != .orderedSame {
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
            Label(project.linkedFolderPath == nil ? "Link Folder" : "Change Folder", systemImage: "folder")
        }

        if project.linkedFolderPath != nil {
            Button {
                assistant.updateProjectLinkedFolder(project.id, path: nil)
            } label: {
                Label("Remove Folder Link", systemImage: "folder.badge.minus")
            }
        }

        Divider()

        Button(role: .destructive) {
            pendingDeleteProject = project
        } label: {
            Label("Delete Project", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func threadContextMenu(for session: AssistantSessionSummary) -> some View {
        Button {
            assistant.inspectMemory(for: session)
        } label: {
            Label("View Memory", systemImage: "brain")
        }

        Divider()

        Button {
            presentRenameSessionPrompt(for: session)
        } label: {
            Label("Rename Session", systemImage: "pencil")
        }

        Divider()

        if !assistant.projects.isEmpty {
            Menu {
                ForEach(assistant.projects) { project in
                    let isCurrentProject = session.projectID?.caseInsensitiveCompare(project.id) == .orderedSame
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

        Button(role: .destructive) {
            pendingDeleteSession = session
        } label: {
            Label("Delete Session", systemImage: "trash")
        }
    }


    private func chatDetail(layout: ChatLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            chatTopBar(layout: layout)

            AssistantChatWebView(
                messages: chatWebMessages,
                showTypingIndicator: shouldShowPendingAssistantPlaceholder,
                typingTitle: assistant.hudState.title.isEmpty ? "Thinking" : assistant.hudState.title,
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
                onUndoMessage: { anchorID in
                    Task { await assistant.undoUserMessage(anchorID: anchorID) }
                },
                onEditMessage: { anchorID in
                    Task { await assistant.beginEditLastUserMessage(anchorID: anchorID) }
                },
                onTextSelected: { selectedText, messageID, parentText, screenRect in
                    handleWebViewTextSelection(
                        selectedText: selectedText,
                        messageID: messageID,
                        parentText: parentText,
                        screenRect: screenRect
                    )
                }
            )
            .frame(maxHeight: .infinity)
            .onAppear {
                resetVisibleHistoryWindow()
            }
            .onChange(of: assistant.selectedSessionID) { newSessionID in
                guard newSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return
                }
                resetVisibleHistoryWindow()
            }

            chatBottomDock(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    AssistantWindowChrome.contentTop,
                    AssistantWindowChrome.contentBottom
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
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automations")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.88))
                    Text("Create recurring assistant jobs and manage them here.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppVisualTheme.foreground(0.46))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(
                Rectangle()
                    .fill(AppVisualTheme.surfaceFill(0.06))
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
                    AssistantWindowChrome.contentBottom
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
                if hasToolActivity || toolCallsExpanded {
                    toolActivityStrip
                        .opacity(hasToolActivity ? 1 : 0)
                        .frame(height: hasToolActivity ? nil : 0)
                        .clipped()
                }

                chatComposer
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
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, layout.timelineHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func chatTopBarTitleCluster(layout: ChatLayoutMetrics) -> some View {
        HStack(spacing: 10) {
            Text(activeSessionTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.88))
                .lineLimit(1)

            if let project = activeSessionProject {
                AssistantStatusBadge(
                    title: project.name,
                    tint: AppVisualTheme.accentTint,
                    symbol: project.displayIconSymbolName
                )
            } else if let projectName = activeSessionSummary?.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                AssistantStatusBadge(
                    title: projectName,
                    tint: AppVisualTheme.accentTint,
                    symbol: "folder"
                )
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
        let sideControlWidth: CGFloat = 100
        let titleHorizontalPadding: CGFloat = 16
        let trafficLightClearance: CGFloat = 52

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if isSidebarCollapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarCollapsed = false
                        }
                    } label: {
                        topBarIconButton(symbol: "sidebar.right")
                    }
                    .buttonStyle(.plain)
                    .help("Show sessions sidebar")
                }
            }
            .padding(.leading, isSidebarCollapsed ? trafficLightClearance : 0)
            .frame(width: sideControlWidth, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // Runtime connection indicator
                HStack(spacing: 3) {
                    Circle()
                        .fill(runtimeDotColor)
                        .frame(width: 5, height: 5)
                    Text(runtimeStatusLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.38))
                }
                .help(runtimeStatusLabel)

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
                    if !assistant.pendingMemorySuggestions.isEmpty {
                        assistant.openMemorySuggestionReview()
                    }
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(sessionMemoryIsActive ? Color.green.opacity(0.85) : AppVisualTheme.foreground(0.28))
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(AppVisualTheme.surfaceFill(0.04))
                        )
                }
                .buttonStyle(.plain)
                .help(sessionMemoryIsActive ? "Memory active\(assistant.pendingMemorySuggestions.isEmpty ? "" : " · tap to review suggestions")" : "Memory off")
                .disabled(assistant.pendingMemorySuggestions.isEmpty)

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
                    AssistantWindowChrome.contentBottom
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
    private func topBarIconButton(symbol: String, emphasized: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(emphasized ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.50))
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
                if let primary = bucket.primary {
                    statusBarRateLimitInline(
                        window: primary,
                        bucketLabel: assistant.selectedRateLimitBucketLabel
                    )
                }
                if let secondary = bucket.secondary {
                    statusBarRateLimitInline(
                        window: secondary,
                        bucketLabel: assistant.selectedRateLimitBucketLabel
                    )
                }
            }
        }
    }

    private func statusBarRateLimitInline(window: RateLimitWindow, bucketLabel: String?) -> some View {
        let isHigh = window.usedPercent > 80
        let percentColor: Color = isHigh ? .red.opacity(0.85) : AppVisualTheme.accentTint.opacity(0.75)
        let baseLabel = window.windowLabel.isEmpty ? "Usage" : window.windowLabel
        let label = [bucketLabel, baseLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: " ")

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
        alert.informativeText = "Choose a friendly name for this thread. It will stay the same until you rename it again."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await assistant.renameSession(session.id, to: proposedTitle) }
    }

    private func presentCreateProjectPrompt() {
        presentProjectNamePrompt(
            title: "Create Project",
            message: "Give this project a simple name. You can link a local folder after you create it.",
            confirmTitle: "Create",
            initialValue: assistant.selectedProjectFilter?.name ?? ""
        ) { proposedName in
            assistant.createProject(name: proposedName)
        }
    }

    private func presentRenameProjectPrompt(for project: AssistantProject) {
        presentProjectNamePrompt(
            title: "Rename Project",
            message: "Choose the new name for this project. Its threads and memory will stay attached.",
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
        alert.informativeText = "Type an SF Symbol name, like folder.fill or star.fill. Leave it blank to use the default icon."
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
            errorAlert.informativeText = "That symbol name was not found. Try folder.fill, star.fill, or pick one of the preset icons."
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
        if let linkedFolderPath = project.linkedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
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

    private func copyMessageButton(text: String, helpText: String, isVisible: Bool = true) -> some View {
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
        let hasRecentManualScrollIntent = Date().timeIntervalSince(chatScrollTracking.lastManualScrollAt) <= Self.manualLoadOlderPause
        guard !assistant.isTransitioningSession,
              hasRecentManualScrollIntent,
              canLoadOlderHistory,
              topOffset > -Self.loadOlderThreshold,
              !isLoadingOlderHistory else {
            return
        }

        loadOlderHistoryBatch(with: proxy)
    }

    private func loadOlderHistoryBatch(with proxy: ScrollViewProxy) {
        guard !assistant.isTransitioningSession,
              !isLoadingOlderHistory,
              let anchorID = visibleRenderItems.first.flatMap(historyPreservationAnchorID(for:)) else {
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
                        NotificationCenter.default.post(name: .openAssistOpenSettings, object: nil)
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
    private func renderTimelineRow(_ item: AssistantTimelineRenderItem, layout: ChatLayoutMetrics) -> some View {
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
    private func timelineRow(_ item: AssistantTimelineItem, layout: ChatLayoutMetrics) -> some View {
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
        let detail = assistant.hudState.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
                        Text(assistant.hudState.title.isEmpty ? "Thinking" : assistant.hudState.title)
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
                            .font(.system(size: compact ? 11 : 11.5, weight: isCompactStatusRow ? .medium : .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(isCompactStatusRow ? 0.50 : (compact ? 0.62 : 0.72)))

                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(isCompactStatusRow ? 0.20 : (compact ? 0.26 : 0.32)))
                    }

                    Spacer(minLength: 8)

                    if showsInlineCopyButton {
                        copyMessageButton(
                            text: text,
                            helpText: title == "Assistant" ? "Copy assistant message" : "Copy message",
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

        return rowContent
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
                    ? (compact ? layout.assistantTrailingPaddingCompact : layout.assistantTrailingPaddingRegular)
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
              let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
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
            guard !AssistantSelectionActionHUDManager.shared.retainsPresentationWithoutSelection else { return }
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

    private func presentSelectionActions(for selection: AssistantTextSelectionTracker.SelectionContext) {
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

    private func explainSelectedText(using selection: AssistantTextSelectionTracker.SelectionContext) {
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

    private func askQuestionAboutSelection(using selection: AssistantTextSelectionTracker.SelectionContext) {
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
        let selectionPreview = selectedText
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
            || bodyText.localizedCaseInsensitiveContains("oauth") {
            openSettingsAction = {
                NotificationCenter.default.post(name: .openAssistOpenSettings, object: nil)
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
            onAsk: isError ? nil : {
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

    private func timelineActivityRow(_ activity: AssistantActivityItem, layout: ChatLayoutMetrics) -> some View {
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
                subtitle: canExpand && !isExpanded ? activitySecondaryText(activity, openTargets: openTargets) : nil,
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

    private func timelineActivityGroupRow(_ group: AssistantTimelineActivityGroup, layout: ChatLayoutMetrics) -> some View {
        let openTargets = activityOpenTargets(for: group)
        let imagePreviews = assistantImagePreviews(from: openTargets)
        let isExpanded = expandedActivityIDs.contains(group.id)
        let canExpand = !group.activities.isEmpty || !openTargets.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 8 : 2) {
            timelineActivitySummaryLine(
                iconName: activityGroupIconName(group),
                iconTint: activityGroupIconTint(group),
                title: activityGroupHeadline(group),
                subtitle: canExpand && !isExpanded ? activityGroupSecondaryText(group, openTargets: openTargets) : nil,
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

    private func timelineActivityOpenTargetsList(_ targets: [AssistantActivityOpenTarget]) -> some View {
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

    private func activityOpenTargets(for activity: AssistantActivityItem) -> [AssistantActivityOpenTarget] {
        assistantActivityOpenTargets(
            for: activity,
            sessionCWD: sessionWorkingDirectory(for: activity.sessionID)
        )
    }

    private func activityOpenTargets(for group: AssistantTimelineActivityGroup) -> [AssistantActivityOpenTarget] {
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
            })?.cwd?.assistantNonEmpty {
            return cwd
        }

        if let selectedSessionID = assistant.selectedSessionID,
           let cwd = assistant.sessions.first(where: {
               assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
           })?.effectiveCWD?.assistantNonEmpty
            ?? assistant.sessions.first(where: {
                assistantTimelineSessionIDsMatch($0.id, selectedSessionID)
            })?.cwd?.assistantNonEmpty {
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

    private func activityDetailSections(from rawDetails: String?) -> [TimelineActivityDetailSectionData] {
        guard let trimmed = rawDetails?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty else {
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

                ForEach(Array(group.activities.prefix(6).enumerated()), id: \.element.id) { _, activity in
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

    private func timelineActivityDetailSection(_ section: TimelineActivityDetailSectionData) -> some View {
        let formattedText = assistantFormattedActivityDetailText(section.text)
        let shouldScroll = formattedText.count > 420 || formattedText.filter(\.isNewline).count >= 10

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
            let vscodeURL = URL(string: "vscode://file\(fileURL.path)")
            if let vscodeURL,
               NSWorkspace.shared.urlForApplication(toOpen: vscodeURL) != nil {
                NSWorkspace.shared.open(vscodeURL)
                return
            }
            NSWorkspace.shared.open(fileURL)
            return
        }

        NSWorkspace.shared.open(target.url)
    }

    private func activityHeadline(_ activity: AssistantActivityItem, openTargetCount: Int) -> String {
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
            fragments.append("explored \(exploredFiles.count) file\(exploredFiles.count == 1 ? "" : "s")")
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
                            toolActivitySection(title: "Active", calls: selectedSessionToolActivity.activeCalls)
                        }
                        if !selectedSessionToolActivity.recentCalls.isEmpty {
                            toolActivitySection(title: "Recent", calls: selectedSessionToolActivity.recentCalls)
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

                        if let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !detail.isEmpty {
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
        switch (selectedSessionToolActivity.activeCalls.count, selectedSessionToolActivity.recentCalls.count) {
        case let (active, recent) where active > 0 && recent > 0:
            return "\(active) active, \(recent) recent activities"
        case let (active, _) where active > 0:
            return "\(active) active tool\(active == 1 ? "" : "s")"
        case let (_, recent):
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
        let normalized = call.status.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
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

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let bannerText = assistant.historyMutationState?.bannerText {
                composerStatusBanner(
                    symbol: "pencil.circle",
                    text: bannerText,
                    tint: AppVisualTheme.accentTint
                ) {
                    Button("Cancel") {
                        Task { await assistant.cancelPendingHistoryEdit() }
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
                .padding(.bottom, 6)
            }


            // Attachment chips above composer
            if !assistant.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(assistant.attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.bottom, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                if isVoiceCapturing {
                    HStack {
                        AssistantStatusBadge(title: "Listening", tint: .orange, symbol: "mic.fill")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }

                ZStack(alignment: .topLeading) {
                    if trimmedPromptDraft.isEmpty {
                        Text(composerPlaceholder)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(0.36))
                            .padding(.leading, assistantComposerTextHorizontalInset + assistantComposerLineFragmentPadding)
                            .padding(.top, assistantComposerTextVerticalInset)
                            .allowsHitTesting(false)
                    }

                    ComposerTextView(
                        text: $assistant.promptDraft,
                        isEnabled: settings.assistantBetaEnabled && !isVoiceCapturing,
                        onSubmit: { sendCurrentPrompt() },
                        onToggleMode: { toggleInteractionMode() },
                        onPasteAttachment: { attachment in
                            assistant.attachments.append(attachment)
                        }
                    )
                    .frame(minHeight: assistantComposerMinTextHeight, maxHeight: assistantComposerMaxTextHeight)
                }
                .padding(.horizontal, 16)
                .padding(.top, isVoiceCapturing ? 9 : 10)

                HStack(alignment: .center, spacing: 8) {
                    // Attachment
                    Button { openFilePicker() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(assistant.attachments.isEmpty ? 0.45 : 0.80))
                    }
                    .buttonStyle(.plain)
                    .help("Attach files or images")

                    if !assistant.attachments.isEmpty {
                        Text("\(assistant.attachments.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.70))
                    }

                    // Mode picker (moved from status bar)
                    AssistantModePicker(selection: assistant.interactionMode) { mode in
                        assistant.interactionMode = mode
                    }

                    // Model picker
                    Menu {
                        ForEach(assistant.visibleModels) { model in
                            Button {
                                assistant.chooseModel(model.id)
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                    if model.id == assistant.selectedModelID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.50))
                            Text(assistant.selectedModelSummary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.70))
                            if !assistant.visibleModels.isEmpty {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.38))
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(assistant.visibleModels.isEmpty)

                    // Reasoning effort
                    Menu {
                        ForEach(supportedEfforts, id: \.self) { effort in
                            Button {
                                assistant.reasoningEffort = effort
                            } label: {
                                HStack {
                                    Text(effort.label)
                                    if effort == assistant.reasoningEffort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(assistant.reasoningEffort.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.60))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.32))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(assistant.selectedModel == nil)

                    Spacer(minLength: 4)

                    // Action buttons
                    if isAgentBusy {
                        Button {
                            Task { await assistant.cancelActiveTurn() }
                        } label: {
                            AssistantToolbarCircleButtonLabel(
                                symbol: "stop.fill",
                                tint: AppVisualTheme.primaryText,
                                size: 28,
                                emphasized: true
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Stop the current turn")
                    } else {
                        if assistant.assistantVoicePlaybackActive {
                            Button {
                                assistant.stopAssistantVoicePlayback()
                            } label: {
                                AssistantToolbarCircleButtonLabel(
                                    symbol: "speaker.slash.fill",
                                    tint: .orange,
                                    size: 24,
                                    emphasized: true
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Stop assistant speech")
                        }

                        AssistantPushToTalkButton(
                            isListening: isVoiceCapturing,
                            level: CGFloat(assistant.voiceCaptureLevel),
                            isEnabled: settings.assistantVoiceTaskEntryEnabled,
                            size: 26
                        ) { isPressed in
                            if isPressed {
                                NotificationCenter.default.post(name: .openAssistStartAssistantVoiceCapture, object: nil)
                            } else if isVoiceCapturing {
                                NotificationCenter.default.post(name: .openAssistStopAssistantVoiceCapture, object: nil)
                            }
                        }

                        Button { sendCurrentPrompt() } label: {
                            AssistantToolbarCircleButtonLabel(
                                symbol: "arrow.up",
                                tint: AppVisualTheme.accentTint,
                                size: 28,
                                isEnabled: canSendMessage && !isVoiceCapturing,
                                emphasized: canSendMessage && !isVoiceCapturing
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSendMessage || isVoiceCapturing)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
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
        guard let message = assistant.memoryStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
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
                .help(isLiveVoicePanelCollapsed ? "Expand voice controls" : "Collapse voice controls")
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

    @ViewBuilder
    private func composerToolbarGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
    private func modeSwitchSuggestionButtons(_ suggestion: AssistantModeSwitchSuggestion) -> some View {
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
                        .fill(AppVisualTheme.accentTint.opacity(suggestion.source == .blocked ? 0.24 : 0.18))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private var supportedEfforts: [AssistantReasoningEffort] {
        guard let selectedModel = assistant.selectedModel else {
            return AssistantReasoningEffort.allCases
        }
        let efforts = selectedModel.supportedReasoningEfforts.compactMap { AssistantReasoningEffort(rawValue: $0) }
        return efforts.isEmpty ? AssistantReasoningEffort.allCases : efforts
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isRuntimeExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(runtimeDotColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: runtimeDotColor.opacity(0.4), radius: 2)
                    Text("Runtime")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.80))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.30))
                        .rotationEffect(.degrees(isRuntimeExpanded ? 90 : 0))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isRuntimeExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistant.runtimeHealth.summary)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.70))
                    if let detail = assistant.runtimeHealth.detail, !detail.isEmpty,
                       !detail.lowercased().contains("failed to load rollout") {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(AppVisualTheme.foreground(0.50))
                    }
                    if assistant.accountSnapshot.isLoggedIn {
                        HStack(spacing: 5) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppVisualTheme.foreground(0.45))
                            Text(assistant.accountSnapshot.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(AppVisualTheme.foreground(0.55))
                        }
                    }
                }
                .padding(.leading, 13)
            }

            if !assistant.rateLimits.isEmpty {
                RateLimitsView(limits: assistant.rateLimits, isExpanded: isRuntimeExpanded)
            }

            if isRuntimeExpanded && !canChat {
                Button("Open Settings") {
                    NotificationCenter.default.post(name: .openAssistOpenSettings, object: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 13)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .allowsHitTesting(!isRefreshing)
    }

    private var runtimeDotColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return .green
        case .checking, .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private func permissionCard(_ request: AssistantPermissionRequest, state: AssistantPermissionCardState) -> some View {
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

                if let toolKind = request.toolKind, !toolKind.isEmpty, toolKind != "modeSwitch", toolKind != "userInput" {
                    Button("Always Allow") {
                        assistant.alwaysAllowToolKind(toolKind)
                        let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
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
                Text("This approval prompt is part of the session history. It only means the request flow finished, not that the tool succeeded.")
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

    private func proposedPlanCard(_ plan: String, isStreaming: Bool, showsActions: Bool) -> some View {
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
                    contentID: "proposed-plan-\(assistant.selectedSessionID ?? "session")-\(plan.hashValue)",
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
            speechRecognition: snapshot.speechRecognitionGranted || !snapshot.speechRecognitionRequired ? .granted : .missing,
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
        imageAttachments.count == 1 ? "Show screenshot" : "Show \(imageAttachments.count) screenshots"
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
