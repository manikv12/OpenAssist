import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private let assistantComposerTextHorizontalInset: CGFloat = 12
private let assistantComposerTextVerticalInset: CGFloat = 7
private let assistantComposerLineFragmentPadding: CGFloat = 4
private let assistantComposerMinTextHeight: CGFloat = 44
private let assistantComposerMaxTextHeight: CGFloat = 88

private enum AssistantWindowChrome {
    static let canvasTop = Color(red: 0.055, green: 0.060, blue: 0.072)
    static let canvasBottom = Color(red: 0.032, green: 0.035, blue: 0.043)
    static let shellTop = Color(red: 0.090, green: 0.096, blue: 0.112)
    static let shellBottom = Color(red: 0.072, green: 0.077, blue: 0.092)
    static let sidebarTop = Color(red: 0.082, green: 0.087, blue: 0.101)
    static let sidebarBottom = Color(red: 0.064, green: 0.068, blue: 0.080)
    static let contentTop = Color(red: 0.098, green: 0.104, blue: 0.120)
    static let contentBottom = Color(red: 0.078, green: 0.083, blue: 0.098)
    static let elevatedPanel = Color(red: 0.108, green: 0.114, blue: 0.131)
    static let messagePanel = Color(red: 0.112, green: 0.118, blue: 0.136)
    static let userBubble = Color(red: 0.122, green: 0.128, blue: 0.146)
    static let userBubbleBorder = Color(red: 0.285, green: 0.365, blue: 0.485).opacity(0.60)
    static let editorFill = Color(red: 0.080, green: 0.085, blue: 0.099)
    static let toolbarFill = Color(red: 0.102, green: 0.108, blue: 0.124)
    static let buttonFill = Color.white.opacity(0.055)
    static let buttonEmphasis = Color(red: 0.145, green: 0.165, blue: 0.208)
    static let border = Color.white.opacity(0.08)
    static let strongBorder = Color.white.opacity(0.13)
    static let neutralAccent = Color(red: 0.46, green: 0.58, blue: 0.74)
    static let systemTint = Color(red: 0.52, green: 0.64, blue: 0.78)
}

private enum TimelineDisclosureState {
    case collapsed
    case expanded
}

private struct TimelineActivityDetailSectionData {
    let title: String
    let text: String
}

func assistantFormattedActivityDetailText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }
    return assistantPrettyPrintedActivityDetailJSON(trimmed) ?? trimmed
}

private func assistantPrettyPrintedActivityDetailJSON(
    _ text: String,
    nestingDepth: Int = 0
) -> String? {
    guard nestingDepth < 3,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return nil
    }

    if let nestedJSONString = object as? String {
        let nestedTrimmed = nestedJSONString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nestedTrimmed.isEmpty else { return nestedJSONString }
        return assistantPrettyPrintedActivityDetailJSON(
            nestedTrimmed,
            nestingDepth: nestingDepth + 1
        ) ?? nestedTrimmed
    }

    guard JSONSerialization.isValidJSONObject(object),
          let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
          ),
          let prettyText = String(data: prettyData, encoding: .utf8) else {
        return nil
    }

    return prettyText
}


struct AssistantTimelineActivityGroup: Identifiable, Equatable {
    let items: [AssistantTimelineItem]

    var id: String {
        let firstID = items.first?.id ?? UUID().uuidString
        let lastID = items.last?.id ?? firstID
        return "activity-group-\(firstID)-\(lastID)"
    }

    var activities: [AssistantActivityItem] {
        items.compactMap(\.activity)
    }

    var sortDate: Date {
        items.first?.sortDate ?? .distantPast
    }

    var lastUpdatedAt: Date {
        items.map(\.lastUpdatedAt).max() ?? sortDate
    }
}

enum AssistantTimelineRenderItem: Identifiable, Equatable {
    case timeline(AssistantTimelineItem)
    case activityGroup(AssistantTimelineActivityGroup)

    var id: String {
        switch self {
        case .timeline(let item):
            return item.id
        case .activityGroup(let group):
            return group.id
        }
    }

    var lastUpdatedAt: Date {
        switch self {
        case .timeline(let item):
            return item.lastUpdatedAt
        case .activityGroup(let group):
            return group.lastUpdatedAt
        }
    }
}

func buildAssistantTimelineRenderItems(from items: [AssistantTimelineItem]) -> [AssistantTimelineRenderItem] {
    var renderItems: [AssistantTimelineRenderItem] = []
    var activityBuffer: [AssistantTimelineItem] = []

    func flushActivityBuffer() {
        guard !activityBuffer.isEmpty else { return }
        if activityBuffer.count == 1, let single = activityBuffer.first {
            renderItems.append(.timeline(single))
        } else {
            renderItems.append(.activityGroup(AssistantTimelineActivityGroup(items: activityBuffer)))
        }
        activityBuffer.removeAll(keepingCapacity: true)
    }

    for item in items {
        if item.kind == .activity, item.activity != nil {
            activityBuffer.append(item)
        } else {
            flushActivityBuffer()
            renderItems.append(.timeline(item))
        }
    }

    flushActivityBuffer()
    return renderItems
}

func assistantTimelineVisibleWindow(
    from items: [AssistantTimelineRenderItem],
    visibleLimit: Int
) -> [AssistantTimelineRenderItem] {
    guard !items.isEmpty else { return [] }

    let normalizedLimit = max(1, visibleLimit)
    guard items.count > normalizedLimit else { return items }
    return Array(items.suffix(normalizedLimit))
}

func assistantTimelineNextVisibleLimit(
    currentLimit: Int,
    totalCount: Int,
    batchSize: Int
) -> Int {
    guard totalCount > 0 else { return 0 }

    let normalizedCurrent = max(0, currentLimit)
    let normalizedBatch = max(1, batchSize)
    return min(totalCount, max(1, normalizedCurrent + normalizedBatch))
}

private func assistantTimelineSessionIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          !lhs.isEmpty,
          !rhs.isEmpty else {
        return false
    }

    return lhs.caseInsensitiveCompare(rhs) == .orderedSame
}

struct AssistantWindowView: View {
    private static let initialVisibleHistoryLimit = 28
    private static let historyBatchSize = 16
    private static let autoScrollThreshold: CGFloat = 24
    private static let manualScrollFollowPause: TimeInterval = 0.85
    private static let nearBottomThreshold: CGFloat = 80
    private static let loadOlderThreshold: CGFloat = 140

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var assistant: AssistantStore

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingDeleteSession: AssistantSessionSummary?
    @State private var showingDeleteAllConfirmation = false
    @State private var showSessionInstructions = false
    @State private var userHasScrolledUp = false
    @State private var autoScrollPinnedToBottom = true
    @State private var lastManualChatScrollAt: Date = .distantPast
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit
    @State private var chatViewportHeight: CGFloat = 0
    @State private var isLoadingOlderHistory = false
    @State private var hoveredInlineCopyMessageID: String?
    @State private var inlineCopyHideWorkItem: DispatchWorkItem?
    @State private var previewAttachment: AssistantAttachment?
    @AppStorage("assistantSidebarCollapsed") private var isSidebarCollapsed = false
    @AppStorage("assistantRuntimeExpanded") private var isRuntimeExpanded = true
    @AppStorage("assistantChatTextScale") private var chatTextScale: Double = 1.0

    /// Uses the pre-computed render items from AssistantStore (rebuilt only when
    /// timelineItems changes, not on every @Published update).
    private var allRenderItems: [AssistantTimelineRenderItem] {
        assistant.isTransitioningSession ? [] : assistant.cachedRenderItems
    }

    private var visibleRenderItems: [AssistantTimelineRenderItem] {
        assistantTimelineVisibleWindow(
            from: allRenderItems,
            visibleLimit: visibleHistoryLimit
        )
    }

    private var hiddenRenderItemCount: Int {
        max(0, allRenderItems.count - visibleRenderItems.count)
    }

    private var timelineLastUpdatedAt: Date {
        allRenderItems.last?.lastUpdatedAt ?? .distantPast
    }

    private var shouldAutoFollowLatestMessage: Bool {
        autoScrollPinnedToBottom
            && Date().timeIntervalSince(lastManualChatScrollAt) >= Self.manualScrollFollowPause
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
        return "Message assistant..."
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

    private var activeSessionTitle: String {
        guard let selectedSessionID = assistant.selectedSessionID else {
            return "No session selected"
        }
        return assistant.sessions.first(where: { $0.id == selectedSessionID })?.title ?? "Active session"
    }

    private var assistantSplitBackground: some View {
        AppSplitChromeBackground(
            leadingPaneFraction: 0.28,
            leadingPaneMaxWidth: 280,
            leadingPaneWidth: 260,
            leadingTint: AppVisualTheme.sidebarTint,
            trailingTint: .black,
            accent: AppVisualTheme.accentTint,
            leadingPaneTransparent: true
        )
    }

    var body: some View {
        ZStack {
            assistantSplitBackground

            HStack(spacing: 0) {
                if !isSidebarCollapsed {
                    sidebar

                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }

                chatDetail
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .overlay(alignment: .topLeading) {
                if isSidebarCollapsed {
                    collapsedSidebarRevealButton
                        .padding(.leading, 12)
                        .padding(.top, 12)
                }
            }
        }
        .onAppear {
            Task { await refreshEverything(refreshPermissions: true) }
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
        .alert("Delete all Open Assist sessions?", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                Task { await assistant.deleteAllOwnedSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved assistant sessions created in Open Assist.")
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
                                .foregroundStyle(.white.opacity(0.6))
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)

                    Text("Recent conversations and saved work")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarCollapsed = true
                        }
                    } label: {
                        topBarIconButton(symbol: "sidebar.left")
                    }
                    .buttonStyle(.plain)
                    .help("Hide sessions sidebar")

                    Button {
                        guard !isRefreshing else { return }
                        Task { await refreshEverything() }
                    } label: {
                        topBarIconButton(symbol: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)

                    Button {
                        Task { await assistant.startNewSession() }
                    } label: {
                        topBarIconButton(symbol: "plus", emphasized: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStartConversation)
                }
            }
            .padding(.bottom, 4)

            if !assistant.sessions.isEmpty {
                Text("\(assistant.sessions.count) saved session\(assistant.sessions.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .padding(.horizontal, 2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if assistant.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No sessions yet")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))

                            Text("Your recent assistant threads will appear here once you start chatting.")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .appThemedSurface(
                            cornerRadius: 10,
                            tint: AppVisualTheme.baseTint,
                            strokeOpacity: 0.12,
                            tintOpacity: 0.015
                        )
                        .padding(.top, 6)
                    } else {
                        ForEach(assistant.sessions.prefix(assistant.visibleSessionsLimit)) { session in
                            Button {
                                guard session.isLocalSession else { return }
                                Task { await assistant.openSession(session) }
                            } label: {
                                AssistantSessionRow(session: session, isSelected: assistant.selectedSessionID == session.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    presentRenameSessionPrompt(for: session)
                                } label: {
                                    Label("Rename Session", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    pendingDeleteSession = session
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            }
                        }
                        
                        if assistant.sessions.count > assistant.visibleSessionsLimit {
                            Button {
                                assistant.loadMoreSessions()
                            } label: {
                                Text("Load More Sessions")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .appScrollbars()

            Spacer(minLength: 0)

            if !assistant.sessions.isEmpty {
                Button {
                    showingDeleteAllConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))

                        Text("Delete All")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AssistantWindowChrome.buttonFill)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var collapsedSidebarRevealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isSidebarCollapsed = false
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AssistantWindowChrome.toolbarFill.opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.55)
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Show sessions sidebar")
    }

    private var chatDetail: some View {
        VStack(spacing: 0) {
            chatTopBar

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ScrollTopOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).minY
                                )
                        }
                        .frame(height: 0)

                        if hiddenRenderItemCount > 0 && !assistant.isTransitioningSession {
                            historyWindowNotice
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        }

                        if assistant.isTransitioningSession {
                            sessionTransitionPlaceholder
                        } else if visibleRenderItems.isEmpty {
                            chatEmptyState
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(visibleRenderItems) { item in
                                    renderTimelineRow(item)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                        }

                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ScrollBottomOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                        }
                        .frame(height: 0)
                        .id("bottomAnchor")
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(ScrollTopOffsetKey.self) { topOffset in
                        loadOlderHistoryIfNeeded(topOffset: topOffset, with: proxy)
                    }
                    .onPreferenceChange(ScrollBottomOffsetKey.self) { bottomOffset in
                        updateUserScrollState(bottomOffset: bottomOffset)
                    }
                    .background(
                        ChatScrollInteractionMonitor {
                            lastManualChatScrollAt = Date()
                        }
                    )
                    .appScrollbars()

                    if !autoScrollPinnedToBottom && !visibleRenderItems.isEmpty {
                        jumpToLatestButton {
                            jumpToLatestMessage(with: proxy)
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 18)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(
                    Color.clear
                )
                .background(Color.clear)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollViewportHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ScrollViewportHeightKey.self) { viewportHeight in
                    chatViewportHeight = viewportHeight
                }
                .onAppear {
                    resetVisibleHistoryWindow()
                    scrollToLatestMessage(with: proxy, animated: false)
                }
                .onChange(of: assistant.isTransitioningSession) { transitioning in
                    if transitioning {
                        // Reset scroll state immediately when session switch starts
                        resetVisibleHistoryWindow()
                    } else {
                        // Content is ready — jump to bottom without animation
                        DispatchQueue.main.async {
                            scrollToLatestMessage(with: proxy, animated: false)
                        }
                    }
                }
                .onChange(of: timelineLastUpdatedAt) { _ in
                    guard !assistant.isTransitioningSession else { return }
                    if shouldAutoFollowLatestMessage {
                        scrollToLatestMessage(with: proxy, animated: !isAgentBusy)
                    }
                }
            }

            chatBottomDock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.leading, 6)
    }

    private var chatBottomDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.6)

            chatComposer

            chatStatusBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var chatTopBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(activeSessionTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            
            Spacer()
            
            HStack(spacing: 8) {
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

                if assistant.selectedSessionID != nil {
                    Button {
                        minimizeToOrb()
                    } label: {
                        topBarIconButton(symbol: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .help("Continue in Orb")
                }

                Button {
                    NotificationCenter.default.post(name: .openAssistOpenAssistantSetup, object: nil)
                } label: {
                    topBarIconButton(symbol: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Open setup")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            AssistantWindowChrome.toolbarFill
                .opacity(0.92)
        )
        .overlay(
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5),
            alignment: .bottom
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
    }
    private func topBarIconButton(symbol: String, emphasized: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(emphasized ? 0.94 : 0.72))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(emphasized ? AssistantWindowChrome.buttonEmphasis : AssistantWindowChrome.buttonFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                emphasized ? AssistantWindowChrome.strongBorder : AssistantWindowChrome.border,
                                lineWidth: 0.6
                            )
                    )
            )
            .shadow(
                color: Color.black.opacity(emphasized ? 0.22 : 0.14),
                radius: emphasized ? 8 : 5,
                x: 0,
                y: 3
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var chatStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runtimeDotColor)
                .frame(width: 7, height: 7)
                .shadow(color: runtimeDotColor.opacity(0.50), radius: 4, x: 0, y: 0)

            Text(runtimeStatusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))

            if !assistant.rateLimits.isEmpty {
                statusBarRateLimits
            }

            Spacer()

            if assistant.accountSnapshot.isLoggedIn {
                Text(assistant.accountSnapshot.summary)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBarRateLimits: some View {
        HStack(spacing: 10) {
            if let primary = assistant.rateLimits.primary {
                statusBarRateLimitInline(window: primary)
            }
            if let secondary = assistant.rateLimits.secondary {
                statusBarRateLimitInline(window: secondary)
            }
        }
    }

    private func statusBarRateLimitInline(window: RateLimitWindow) -> some View {
        let isHigh = window.usedPercent > 80
        let percentColor: Color = isHigh ? .red.opacity(0.85) : .white.opacity(0.55)

        return HStack(spacing: 3) {
            Text(window.windowLabel)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.36))
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

    private var historyWindowNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.message")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.92))

            Text("Older chat history is hidden for speed. Scroll up to load more.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
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
            .foregroundStyle(.white.opacity(0.95))
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

    private func copyMessageButton(text: String, helpText: String, isVisible: Bool = true) -> some View {
        Button {
            copyAssistantTextToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(isVisible ? 0.56 : 0.22))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isVisible ? 0.045 : 0.001))
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func resetVisibleHistoryWindow() {
        visibleHistoryLimit = Self.initialVisibleHistoryLimit
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        isLoadingOlderHistory = false
        expandedActivityIDs.removeAll()
    }

    private func updateUserScrollState(bottomOffset: CGFloat) {
        guard !assistant.isTransitioningSession, chatViewportHeight > 0 else { return }

        let distanceFromBottom = max(0, bottomOffset - chatViewportHeight)
        autoScrollPinnedToBottom = distanceFromBottom <= Self.autoScrollThreshold
        userHasScrolledUp = distanceFromBottom > Self.nearBottomThreshold
    }

    private func loadOlderHistoryIfNeeded(topOffset: CGFloat, with proxy: ScrollViewProxy) {
        guard !assistant.isTransitioningSession,
              userHasScrolledUp,
              hiddenRenderItemCount > 0,
              topOffset > -Self.loadOlderThreshold,
              !isLoadingOlderHistory,
              let anchorID = visibleRenderItems.first?.id else {
            return
        }

        let nextLimit = assistantTimelineNextVisibleLimit(
            currentLimit: visibleHistoryLimit,
            totalCount: allRenderItems.count,
            batchSize: Self.historyBatchSize
        )
        guard nextLimit > visibleHistoryLimit else { return }

        isLoadingOlderHistory = true
        visibleHistoryLimit = nextLimit
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
            isLoadingOlderHistory = false
        }
    }

    private func jumpToLatestMessage(with proxy: ScrollViewProxy) {
        userHasScrolledUp = false
        autoScrollPinnedToBottom = true
        scrollToLatestMessage(with: proxy)
    }

    private var chatEmptyState: some View {
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
                    .foregroundStyle(.white.opacity(0.92))

                Text(emptyStateMessage)
                    .font(.system(size: 14.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(maxWidth: 440)

                if !canChat {
                    Button("Open Settings") {
                        NotificationCenter.default.post(name: .openAssistOpenSettings, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 36)
            .frame(maxWidth: 520)
            .appThemedSurface(
                cornerRadius: 14,
                tint: AppVisualTheme.baseTint,
                strokeOpacity: 0.13,
                tintOpacity: 0.02
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private var sessionTransitionPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.5))
            Text("Loading session")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderTimelineRow(_ item: AssistantTimelineRenderItem) -> some View {
        switch item {
        case .timeline(let timelineItem):
            timelineRow(timelineItem)
        case .activityGroup(let group):
            timelineActivityGroupRow(group)
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: AssistantTimelineItem) -> some View {
        switch item.kind {
        case .userMessage:
            timelineUserBubble(
                text: item.text ?? "",
                imageAttachments: item.imageAttachments,
                messageID: item.id
            )

        case .assistantProgress:
            timelineAssistantRow(
                messageID: item.id,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                compact: true,
                showsInlineCopyButton: true,
                showsMemoryActions: false
            )

        case .assistantFinal:
            timelineAssistantRow(
                messageID: item.id,
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                isStreaming: item.isStreaming,
                compact: false,
                showsInlineCopyButton: true,
                showsMemoryActions: settings.assistantMemoryEnabled && !item.isStreaming
            )

        case .system:
            timelineAssistantRow(
                messageID: item.id,
                text: item.text ?? "",
                timestamp: item.sortDate,
                title: item.emphasis ? "Needs Attention" : "System",
                isStreaming: false,
                compact: true,
                showsInlineCopyButton: true,
                showsMemoryActions: false
            )

        case .activity:
            if let activity = item.activity {
                timelineActivityRow(activity)
            }

        case .permission:
            if let request = item.permissionRequest {
                let sessionStatus = assistant.sessions.first {
                    assistantTimelineSessionIDsMatch($0.id, request.sessionID)
                }?.status
                let cardState = assistantPermissionCardState(
                    for: request,
                    pendingRequest: assistant.pendingPermissionRequest,
                    sessionStatus: sessionStatus
                )
                HStack(alignment: .top, spacing: 0) {
                    permissionCard(request, state: cardState)
                    Spacer(minLength: 80)
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
                    Spacer(minLength: 80)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func timelineUserBubble(
        text: String,
        imageAttachments: [Data]? = nil,
        messageID: String
    ) -> some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 4) {
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
                                .frame(maxWidth: 280, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Text(verbatim: text)
                    .font(.system(size: 14 * CGFloat(chatTextScale), weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AssistantWindowChrome.userBubble)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AssistantWindowChrome.userBubbleBorder, lineWidth: 0.5)
                            )
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .onHover { hovering in
            updateInlineCopyHoverState(for: messageID, hovering: hovering)
        }
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(text)
            }
        }
    }

    private func timelineAssistantRow(
        messageID: String,
        text: String,
        timestamp: Date,
        title: String,
        isStreaming: Bool,
        compact: Bool,
        showsInlineCopyButton: Bool,
        showsMemoryActions: Bool
    ) -> some View {
        let isStandardAssistant = title == "Assistant"
        let isCompactStatusRow = compact && !isStandardAssistant
        let roleTint = assistantRowTint(for: title)
        let roleIcon = assistantRowIcon(for: title)

        let rowContent = HStack(alignment: .top, spacing: isStandardAssistant ? 0 : 12) {
            if !isStandardAssistant {
                if isCompactStatusRow {
                    compactAssistantStatusIcon(symbol: roleIcon, tint: roleTint)
                } else {
                    AppIconBadge(
                        symbol: roleIcon,
                        tint: roleTint,
                        size: compact ? 26 : 32,
                        symbolSize: compact ? 10 : 12,
                        isEmphasized: isStreaming
                    )
                }
            }

            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !isStandardAssistant {
                        Text(title)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: isCompactStatusRow ? .medium : .semibold))
                            .foregroundStyle(.white.opacity(isCompactStatusRow ? 0.68 : (compact ? 0.78 : 0.88)))
                        
                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(isCompactStatusRow ? 0.26 : (compact ? 0.38 : 0.48)))
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
                    text: text,
                    role: .assistant,
                    isStreaming: isStreaming
                )
                .opacity(isCompactStatusRow ? 0.78 : (compact ? 0.84 : 1.0))
                .textSelection(.enabled)
            }

            Spacer(minLength: 40)
        }

        return rowContent
            .padding(.horizontal, isStandardAssistant ? 0 : (compact ? 12 : 16))
            .padding(.vertical, isStandardAssistant ? (compact ? 4 : 8) : (compact ? 8 : 16))
            .background {
                if isStandardAssistant {
                    EmptyView()
                } else if isCompactStatusRow {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.015))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(roleTint.opacity(title == "Needs Attention" ? 0.22 : 0.12), lineWidth: 0.55)
                        )
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(title == "Needs Attention" ? 0.52 : 0.28))
                                .frame(width: 2)
                                .padding(.vertical, 8)
                                .padding(.leading, 1)
                        }
                } else if compact {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(roleTint.opacity(0.035))
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(roleTint.opacity(0.55))
                                .frame(width: 2)
                                .padding(.vertical, 8)
                                .padding(.leading, 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AssistantWindowChrome.messagePanel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AssistantWindowChrome.border, lineWidth: 0.5)
                        )
                }
            }
            .padding(.leading, isStandardAssistant ? 20 : 0)
            .padding(.trailing, isStandardAssistant ? (compact ? 120 : 180) : (compact ? 60 : 40))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, compact ? 2 : 6)
            .onHover { hovering in
                guard showsInlineCopyButton else { return }
                updateInlineCopyHoverState(for: messageID, hovering: hovering)
            }
            .contextMenu {
                Button("Copy Message") {
                    copyAssistantTextToPasteboard(text)
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

    private func timelineActivityRow(_ activity: AssistantActivityItem) -> some View {
        let openTargets = activityOpenTargets(for: activity)
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
                    openTargets: openTargets
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 44)
        .padding(.trailing, 60)
        .padding(.vertical, 4)
    }

    private func timelineActivityGroupRow(_ group: AssistantTimelineActivityGroup) -> some View {
        let openTargets = activityOpenTargets(for: group)
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
                timelineActivityGroupExpandedDetails(group, openTargets: openTargets)
                    .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 44)
        .padding(.trailing, 60)
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
                Image(systemName: disclosureState == .expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(width: 9, height: 9)
            }

            Image(systemName: iconName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 14, height: 14)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(statusTint)
                .frame(width: 5, height: 5)

            Text(statusLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(statusTint.opacity(0.92))

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.26))
        }

        if let onTap, disclosureState != nil {
            Button(action: onTap) {
                line
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            line
        }
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
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)

                        if let detail = target.detail {
                            Text(detail)
                                .font(.system(size: 10.2, weight: .medium))
                                .foregroundStyle(.white.opacity(0.34))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.32))
                    }
                    .padding(.vertical, 1)
                }
                .buttonStyle(.plain)
                .help("Open \(target.label)")
            }

            if targets.count > 6 {
                Text("+ \(targets.count - 6) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
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
           })?.cwd?.assistantNonEmpty {
            return cwd
        }

        if let selectedSessionID = assistant.selectedSessionID,
           let cwd = assistant.sessions.first(where: {
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
        openTargets: [AssistantActivityOpenTarget]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(detailSections.enumerated()), id: \.offset) { _, section in
                timelineActivityDetailSection(section)
            }

            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }
        }
    }

    private func timelineActivityGroupExpandedDetails(
        _ group: AssistantTimelineActivityGroup,
        openTargets: [AssistantActivityOpenTarget]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !openTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .textCase(.uppercase)

                    timelineActivityOpenTargetsList(openTargets)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
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
                                .foregroundStyle(.white.opacity(0.66))

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
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(2)
                        .padding(.leading, 22)
                    }
                }

                if group.activities.count > 6 {
                    Text("+ \(group.activities.count - 6) more steps")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func timelineActivityDetailSection(_ section: TimelineActivityDetailSectionData) -> some View {
        let formattedText = assistantFormattedActivityDetailText(section.text)
        let shouldScroll = formattedText.count > 420 || formattedText.filter(\.isNewline).count >= 10

        return VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
                .textCase(.uppercase)

            if shouldScroll {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(formattedText)
                        .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
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
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.55)
                        )
                )
                .appScrollbars()
            } else {
                Text(formattedText)
                    .font(.system(size: 10.3, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AssistantWindowChrome.editorFill.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 0.55)
                            )
                    )
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.09))
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    toolCallsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(toolCallsExpanded ? 90 : 0))
                        .frame(width: 10)

                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))

                    Text(toolActivitySummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if toolCallsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !assistant.toolCalls.isEmpty {
                            toolActivitySection(title: "Active", calls: assistant.toolCalls)
                        }
                        if !assistant.recentToolCalls.isEmpty {
                            toolActivitySection(title: "Recent", calls: assistant.recentToolCalls)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 18)
                }
                .frame(maxHeight: 200)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.55)
                )
        )
    }

    @ViewBuilder
    private func toolActivitySection(title: String, calls: [AssistantToolCallState]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
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
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    Text(statusLabel(for: call))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
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
        switch (assistant.toolCalls.count, assistant.recentToolCalls.count) {
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
            return .white.opacity(0.5)
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
            return .white.opacity(0.5)
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
        guard let first = activities.first else { return .white.opacity(0.5) }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconTint(first) : .white.opacity(0.5)
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

    private func minimizeToOrb() {
        NotificationCenter.default.post(name: .openAssistMinimizeAssistantToOrb, object: nil)
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blockedReason = assistant.conversationBlockedReason {
                composerStatusBanner(
                    symbol: assistant.isLoadingModels ? "hourglass" : "exclamationmark.circle",
                    text: blockedReason,
                    tint: assistant.isLoadingModels ? .white.opacity(0.50) : .orange
                )
                .padding(.bottom, 6)
            }

            if let suggestion = assistant.modeSwitchSuggestion {
                composerStatusBanner(
                    symbol: suggestion.source == .blocked ? "arrow.triangle.branch" : "lightbulb",
                    text: suggestion.message,
                    tint: suggestion.source == .blocked ? .orange : .white.opacity(0.50)
                ) {
                    modeSwitchSuggestionButtons(suggestion)
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
                            .foregroundStyle(.white.opacity(0.36))
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

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.6)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                HStack(alignment: .center, spacing: 10) {
                    composerToolbarGroup {
                        Button { openFilePicker() } label: {
                            Image(systemName: "paperclip")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Attach files or images")

                        if !assistant.attachments.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("\(assistant.attachments.count)")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.82))
                        }

                        AssistantModePicker(selection: assistant.interactionMode) { mode in
                            assistant.interactionMode = mode
                        }

                        // Session memory indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(sessionMemoryIsActive ? Color.green : Color.red)
                                .frame(width: 5, height: 5)

                            Text(sessionMemoryIsActive ? "Memory" : "No memory")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.56))
                                .lineLimit(1)

                            if !assistant.pendingMemorySuggestions.isEmpty {
                                Button("Review") {
                                    assistant.openMemorySuggestionReview()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                    }

                    Spacer(minLength: 4)

                    composerToolbarGroup {
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
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.68))
                                Text(assistant.selectedModelSummary)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.64))
                                if !assistant.visibleModels.isEmpty {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.28))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(assistant.visibleModels.isEmpty)

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
                            Text(assistant.reasoningEffort.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(assistant.selectedModel == nil)

                        Menu {
                            Button {
                                assistant.fastModeEnabled = false
                            } label: {
                                HStack {
                                    Text("Standard")
                                    if !assistant.fastModeEnabled {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Button {
                                assistant.fastModeEnabled = true
                            } label: {
                                HStack {
                                    Text("Fast")
                                    if assistant.fastModeEnabled {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: assistant.fastModeEnabled ? "bolt.fill" : "speedometer")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.68))
                                Text(assistant.fastModeEnabled ? "Fast" : "Standard")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.58))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.28))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(assistant.selectedModel == nil)
                        .help("Choose service tier for the chat session.")

                        ContextUsageCircle(usage: assistant.tokenUsage)
                    }

                    composerToolbarGroup {
                        if isAgentBusy {
                            Button {
                                Task { await assistant.cancelActiveTurn() }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(Color.red.opacity(0.62))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Stop the current turn")
                        } else {
                            AssistantPushToTalkButton(
                                isListening: isVoiceCapturing,
                                level: CGFloat(assistant.voiceCaptureLevel),
                                isEnabled: settings.assistantVoiceTaskEntryEnabled
                            ) { isPressed in
                                if isPressed {
                                    NotificationCenter.default.post(name: .openAssistStartAssistantVoiceCapture, object: nil)
                                } else if isVoiceCapturing {
                                    NotificationCenter.default.post(name: .openAssistStopAssistantVoiceCapture, object: nil)
                                }
                            }

                            Button { sendCurrentPrompt() } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(
                                                canSendMessage
                                                    ? AppVisualTheme.accentTint
                                                    : Color.white.opacity(0.12)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSendMessage || isVoiceCapturing)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .onDrop(of: [.fileURL, .image, .png, .jpeg], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AssistantWindowChrome.elevatedPanel.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AssistantWindowChrome.strongBorder, lineWidth: 0.65)
                )
        )
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

    @ViewBuilder
    private func composerToolbarGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AssistantWindowChrome.toolbarFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.5)
                )
        )
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
                .foregroundStyle(.white.opacity(0.64))
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
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.accentTint.opacity(suggestion.source == .blocked ? 0.24 : 0.18))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
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
                        .foregroundStyle(.white.opacity(0.80))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.30))
                        .rotationEffect(.degrees(isRuntimeExpanded ? 90 : 0))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isRuntimeExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistant.runtimeHealth.summary)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                    if let detail = assistant.runtimeHealth.detail, !detail.isEmpty,
                       !detail.lowercased().contains("failed to load rollout") {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    if assistant.accountSnapshot.isLoggedIn {
                        HStack(spacing: 5) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                            Text(assistant.accountSnapshot.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
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
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
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

                if let toolKind = request.toolKind, !toolKind.isEmpty, toolKind != "modeSwitch" {
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
                Text("This request is part of the session history. The task finished after it.")
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
            return .green.opacity(0.78)
        case .notActive:
            return .white.opacity(0.45)
        }
    }

    private func permissionSurfaceTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return .green
        case .notActive:
            return .white
        }
    }

    private func proposedPlanCard(_ plan: String, isStreaming: Bool, showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Proposed Plan")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                Spacer()
                if showsActions {
                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                AssistantMarkdownText(text: plan, role: .assistant, isStreaming: isStreaming)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            if plan.count > 400 {
                Text("Scroll to view the full plan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }

                if showsActions {
                    HStack(spacing: 10) {
                        Button {
                            Task { await assistant.executePlan() }
                        } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Execute Plan")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
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
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                if assistant.hasActiveTurn {
                    Text("Wait for the plan to finish before executing it.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
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
            microphone: snapshot.microphoneGranted ? .granted : .missing,
            speechRecognition: snapshot.speechRecognitionGranted || !snapshot.speechRecognitionRequired ? .granted : .missing,
            appleEvents: .unknown,
            fullDiskAccess: .unknown
        )
    }

    private func scrollToLatestMessage(with proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
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
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                Text(attachment.isImage ? "Image attachment" : "File attachment")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Button {
                assistant.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.6)
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

private struct AssistantMemorySuggestionReviewSheet: View {
    @ObservedObject var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Suggestions")
                        .font(.system(size: 18, weight: .bold))
                    Text("Review these lessons before they become long-term assistant memory.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            if assistant.pendingMemorySuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No memory suggestions waiting for review.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When the assistant finds a useful rule or a repeated mistake, it will show up here for review.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.pendingMemorySuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(suggestion.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(suggestion.kind.label)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(suggestion.memoryType.label)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(AppVisualTheme.accentTint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(AppVisualTheme.accentTint.opacity(0.12))
                                        )
                                }

                                Text(suggestion.summary)
                                    .font(.system(size: 13, weight: .medium))

                                Text(suggestion.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let sourceExcerpt = suggestion.sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !sourceExcerpt.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Source")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(sourceExcerpt)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.white.opacity(0.04))
                                    )
                                }

                                HStack(spacing: 8) {
                                    Button("Ignore") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.ignoreMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Lesson") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.acceptMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(AppChromeBackground())
    }
}

private struct AssistantSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool

    private var relativeTimestamp: String? {
        guard let updatedAt = session.updatedAt ?? session.createdAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))

        switch seconds {
        case 0..<60:
            return "now"
        case 60..<(60 * 60):
            return "\(max(1, seconds / 60))m"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(max(1, seconds / (60 * 60)))h"
        case (60 * 60 * 24)..<(60 * 60 * 24 * 7):
            return "\(max(1, seconds / (60 * 60 * 24)))d"
        case (60 * 60 * 24 * 7)..<(60 * 60 * 24 * 30):
            return "\(max(1, seconds / (60 * 60 * 24 * 7)))w"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: updatedAt)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                isSelected
                    ? LinearGradient(
                        colors: [
                            Color.white.opacity(0.13),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [
                            Color.white.opacity(0.02),
                            Color.white.opacity(0.01)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
            )
    }

    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(
                isSelected
                    ? Color.white.opacity(0.12)
                    : Color.white.opacity(0.035),
                lineWidth: isSelected ? 0.8 : 0.45
            )
    }

    private var titleColor: Color {
        isSelected ? .white.opacity(0.98) : .white.opacity(0.88)
    }

    private var subtitleColor: Color {
        isSelected ? .white.opacity(0.60) : .white.opacity(0.44)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let relativeTimestamp {
                    Text(relativeTimestamp)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(isSelected ? .white.opacity(0.54) : .white.opacity(0.34))
                        .lineLimit(1)
                }
            }

            Text(session.subtitle)
                .font(.system(size: 11.4, weight: .medium))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(rowStroke)
        .shadow(
            color: Color.black.opacity(isSelected ? 0.22 : 0.06),
            radius: isSelected ? 10 : 4,
            x: 0,
            y: isSelected ? 6 : 2
        )
    }
}


private struct AssistantStatusBadge: View {
    let title: String
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.95))
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                )
        )
    }
}

private struct AssistantTopBarActionButton: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint.opacity(0.94))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                )
        )
    }
}

private struct AssistantChatBubble: View {
    let message: AssistantChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantRow
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    )
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 8)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: roleIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.tint)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(message.tint.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.roleLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                AssistantMarkdownText(text: message.text, role: message.role, isStreaming: message.isStreaming)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.clear)
        .padding(.trailing, 40)
    }

    private var roleIcon: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .permission: return "lock.shield.fill"
        case .system: return "server.rack"
        default: return "bubble.left.fill"
        }
    }
}

private struct AssistantMarkdownText: View {
    let text: String
    let role: AssistantTranscriptRole
    var isStreaming: Bool = false
    @AppStorage("assistantChatTextScale") private var textScale: Double = 1.0

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * CGFloat(textScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            renderedText
            if isStreaming {
                StreamingCursor()
            }
        }
    }

    @ViewBuilder
    private var renderedText: some View {
        switch AssistantTextRenderingPolicy.style(for: text, isStreaming: isStreaming) {
        case .plain:
            Text(verbatim: text)
                .font(.system(size: scaled(14), weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .markdown:
            Markdown(text)
                .markdownTheme(assistantTheme)
                .markdownCodeSyntaxHighlighter(.plainText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    let scheme = url.scheme?.lowercased() ?? ""

                    // Allow normal web links
                    if scheme == "http" || scheme == "https" {
                        NSWorkspace.shared.open(url)
                        return .handled
                    }

                    // Try opening file-like paths in VS Code if installed
                    let path = url.path
                    if scheme == "file" || scheme.isEmpty,
                       !path.isEmpty {
                        let vscodeURL = URL(string: "vscode://file\(path)")
                        if let vscodeURL,
                           NSWorkspace.shared.urlForApplication(toOpen: vscodeURL) != nil {
                            NSWorkspace.shared.open(vscodeURL)
                            return .handled
                        }
                    }

                    return .discarded
                })
        }
    }

    private var assistantTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.95))
                FontSize(scaled(14))
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(19))
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.96))
                    }
                    .markdownMargin(top: 16, bottom: 10)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(17))
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.94))
                    }
                    .markdownMargin(top: 14, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(15))
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .strong {
                FontWeight(.bold)
                ForegroundColor(.white.opacity(0.96))
            }
            .emphasis {
                FontStyle(.italic)
                ForegroundColor(.white.opacity(0.85))
            }
            .link {
                ForegroundColor(AppVisualTheme.accentTint)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(scaled(13))
                ForegroundColor(Color(red: 0.75, green: 0.85, blue: 1.0))
                BackgroundColor(Color(red: 0.12, green: 0.13, blue: 0.18))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(self.scaled(13))
                            ForegroundColor(.white.opacity(0.85))
                        }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 8, bottom: 8)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AppVisualTheme.accentTint.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.72))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 10)
            }
    }
}

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(visible ? 0.7 : 0.0))
            .frame(width: 2, height: 16)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

// MARK: - Session Instructions Popover

private struct SessionInstructionsPopover: View {
    @Binding var instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Session Instructions")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("These instructions apply only to this session. They are combined with your global instructions from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor).opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.8)
                        )
                )

            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text("Active for this session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        instructions = ""
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

@MainActor
private struct AssistantChatMessage: Identifiable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let timestamp: Date
    let emphasis: Bool
    let isStreaming: Bool

    var roleLabel: String {
        switch role {
        case .assistant: return "Assistant"
        case .user: return "You"
        case .permission: return "Permission"
        case .error: return "Error"
        case .status: return "Status"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    var tint: Color {
        switch role {
        case .assistant:
            return AppVisualTheme.accentTint
        case .user:
            return AppVisualTheme.baseTint
        case .permission:
            return .orange
        case .error:
            return .red
        case .status, .system, .tool:
            return Color(red: 0.42, green: 0.76, blue: 0.95)
        }
    }

    var alignment: HorizontalAlignment {
        switch role {
        case .user:
            return .trailing
        default:
            return .leading
        }
    }

    var fillOpacity: Double {
        switch role {
        case .user:
            return 0.16
        case .assistant:
            return 0.11
        case .error:
            return 0.13
        default:
            return 0.09
        }
    }

    var strokeOpacity: Double {
        emphasis ? 0.34 : 0.22
    }

    static func grouped(from entries: [AssistantTranscriptEntry]) -> [AssistantChatMessage] {
        entries.compactMap { entry in
            guard let text = entry.text.assistantNonEmpty else { return nil }
            return AssistantChatMessage(
                id: entry.id,
                role: entry.role,
                text: text,
                timestamp: entry.createdAt,
                emphasis: entry.emphasis,
                isStreaming: entry.isStreaming
            )
        }
    }
}

enum AssistantTextRenderingStyle {
    case plain
    case markdown
}

enum AssistantTextRenderingPolicy {
    static func style(for text: String, isStreaming: Bool) -> AssistantTextRenderingStyle {
        if isStreaming {
            return .plain
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        if normalized.contains("```") || normalized.contains("`") {
            return .markdown
        }

        if normalized.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil {
            return .markdown
        }

        if normalized.range(of: #"(^|[\s])(\*\*|__|~~)[^\n]+(\*\*|__|~~)(?=$|[\s])"#, options: [.regularExpression]) != nil {
            return .markdown
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#")
                || line.hasPrefix("> ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("|") {
                return .markdown
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return .markdown
            }
        }

        return .plain
    }
}

enum AssistantVisibleTextSanitizer {
    static func clean(_ rawValue: String?) -> String? {
        guard var text = rawValue?.replacingOccurrences(of: "\r\n", with: "\n").assistantNonEmpty else {
            return nil
        }

        text = removingAnalysisBlocks(from: text)

        if let closingRange = text.range(of: "</analysis>", options: [.caseInsensitive]) {
            let prefix = text[..<closingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = text[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            text = preferredVisibleSlice(prefix: String(prefix), suffix: String(suffix))
        }

        if let openingRange = text.range(of: "<analysis>", options: [.caseInsensitive]) {
            text = String(text[..<openingRange.lowerBound])
        }

        text = text
            .removingAssistantAttachmentPlaceholders()
            .replacingOccurrences(of: "<analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "<proposed_plan>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</proposed_plan>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.assistantNonEmpty
    }

    private static func removingAnalysisBlocks(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<analysis\b[^>]*>[\s\S]*?</analysis>"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredVisibleSlice(prefix: String, suffix: String) -> String {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeInternalScratchpad(normalizedSuffix), !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        if !normalizedSuffix.isEmpty && normalizedPrefix.isEmpty {
            return normalizedSuffix
        }

        if !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        return normalizedSuffix
    }

    private static func looksLikeInternalScratchpad(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "need ",
            "let's ",
            "wait:",
            "maybe ",
            "we should ",
            "i should ",
            "final answer",
            "output final",
            "plan-only",
            "ensure "
        ]
        return markers.contains(where: lowered.contains)
    }
}

private struct AssistantMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case codeBlock(language: String?, code: String)
    }

    let id: Int
    let kind: Kind

    static func parse(from text: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var currentMarkdown: [String] = []
        var insideCodeBlock = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var nextIndex = 0

        func flushMarkdown() {
            let value = currentMarkdown.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .markdown(value)))
                nextIndex += 1
            }
            currentMarkdown.removeAll()
        }

        func flushCodeBlock() {
            let value = codeLines.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .codeBlock(language: codeLanguage, code: value)))
                nextIndex += 1
            }
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if insideCodeBlock {
                    flushCodeBlock()
                    insideCodeBlock = false
                } else {
                    flushMarkdown()
                    insideCodeBlock = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if insideCodeBlock {
                codeLines.append(line)
            } else {
                currentMarkdown.append(line)
            }
        }

        if insideCodeBlock {
            flushCodeBlock()
        } else {
            flushMarkdown()
        }

        if segments.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                segments.append(AssistantMarkdownSegment(id: 0, kind: .markdown(fallback)))
            }
        }

        return segments
    }
}

private struct ChatScrollInteractionMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll

        DispatchQueue.main.async {
            guard let hostView = nsView.superview else { return }
            context.coordinator.attachIfNeeded(to: hostView)
        }
    }

    final class Coordinator {
        var onUserScroll: () -> Void
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit {
            removeObservers()
        }

        func attachIfNeeded(to hostView: NSView) {
            guard let scrollView = findScrollView(in: hostView) else { return }
            guard observedScrollView !== scrollView else { return }

            removeObservers()
            observedScrollView = scrollView

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            observedScrollView = nil
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            for subview in view.subviews {
                if let scrollView = findScrollView(in: subview) {
                    return scrollView
                }
            }

            return nil
        }
    }
}

// MARK: - Composer Text View (Enter to send, Shift+Enter for newline)

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(
            width: assistantComposerTextHorizontalInset,
            height: assistantComposerTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = assistantComposerLineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if let textView = textView as? SubmittableTextView {
            textView.onSubmit = onSubmit
            textView.onToggleMode = onToggleMode
            textView.onPasteAttachment = onPasteAttachment
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    override func paste(_ sender: Any?) {
        if let attachment = AssistantAttachmentSupport.attachment(fromPasteboard: NSPasteboard.general) {
            onPasteAttachment?(attachment)
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)
        let isTab = event.keyCode == 48

        if isReturn && !isShift {
            onSubmit?()
            return
        }
        if isTab && isShift {
            onToggleMode?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Context Usage Bar

private struct ContextUsageBar: View {
    let fraction: Double

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
    }
}

// MARK: - Context Usage Circle

private struct ContextUsageCircle: View {
    let usage: TokenUsageSnapshot

    private var fraction: Double {
        usage.contextUsageFraction ?? 0
    }

    private var ringColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    private var percentText: String {
        "\(Int(round(fraction * 100)))%"
    }

    private var tooltipText: String {
        let pct = Int(round(fraction * 100))
        return "Context window: \(pct)% full\n\(usage.contextSummary) tokens used"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentText)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(ringColor.opacity(0.9))
        }
        .frame(width: 22, height: 22)
        .help(tooltipText)
    }
}

// MARK: - Rate Limits View

private struct RateLimitsView: View {
    let limits: AccountRateLimits
    var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
            if let primary = limits.primary {
                rateLimitRow(window: primary, label: primary.windowLabel.isEmpty ? "Usage" : primary.windowLabel)
            }
            if let secondary = limits.secondary {
                rateLimitRow(window: secondary, label: secondary.windowLabel.isEmpty ? "Limit" : secondary.windowLabel)
            }
        }
    }

    private func rateLimitRow(window: RateLimitWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
                Text("\(window.usedPercent)% used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(window.usedPercent > 80 ? .red.opacity(0.8) : .white.opacity(0.45))
                if isExpanded, let resets = window.resetsInLabel {
                    Text("resets \(resets)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            ContextUsageBar(fraction: Double(window.usedPercent) / 100.0)
                .frame(height: isExpanded ? 3 : 2)
        }
        .help(!isExpanded && window.resetsInLabel != nil ? "Resets \(window.resetsInLabel!)" : "")
    }
}

// MARK: - Subagent Strip

private struct SubagentStrip: View {
    let subagents: [SubagentState]

    private var activeAgents: [SubagentState] {
        subagents.filter { $0.status.isActive }
    }

    private var completedCount: Int {
        subagents.filter { !$0.status.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Text("\(activeAgents.count) active agent\(activeAgents.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                if completedCount > 0 {
                    Text("· \(completedCount) done")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
            }

            ForEach(activeAgents) { agent in
                HStack(spacing: 6) {
                    Image(systemName: agent.status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(agentTint(agent.status))
                    Text(agent.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                    if let prompt = agent.prompt?.prefix(50), !prompt.isEmpty {
                        Text(String(prompt))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.30))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(agent.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(agentTint(agent.status).opacity(0.7))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func agentTint(_ status: SubagentStatus) -> Color {
        switch status {
        case .spawning, .running: return .blue
        case .waiting: return .orange
        case .completed: return .green
        case .errored: return .red
        case .closed: return .gray
        }
    }
}

// MARK: - Scroll tracking

private struct ScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
