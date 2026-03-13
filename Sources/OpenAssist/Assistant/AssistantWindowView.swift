import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantWindowView: View {
    private static let initialVisibleHistoryLimit = 28
    private static let historyBatchSize = 16
    private static let autoScrollThreshold: CGFloat = 24
    private static let manualScrollFollowPause: TimeInterval = 0.85
    private static let manualLoadOlderPause: TimeInterval = 0.75
    private static let nearBottomThreshold: CGFloat = 80
    private static let loadOlderThreshold: CGFloat = 140

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var assistant: AssistantStore

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingDeleteSession: AssistantSessionSummary?
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
        assistant.cachedRenderItems
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

    private var shouldShowHumeConversationPanel: Bool {
        settings.assistantBetaEnabled
            && (settings.assistantVoiceEngine == .humeOctave || assistant.isHumeConversationConnected)
    }

    private var humeConversationStatusText: String {
        let snapshot = assistant.assistantHumeConversationSnapshot
        if let error = snapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }

        switch snapshot.phase {
        case .disconnected:
            return assistant.canStartHumeConversationMode
                ? "Ready to start a live Hume conversation."
                : "Add Hume keys and choose a Hume voice in AI Studio > Voice first."
        case .connecting:
            return "Connecting live voice conversation..."
        case .connected:
            return snapshot.isMicrophoneMuted
                ? "Connected. Mic is muted."
                : "Connected. Speak any time."
        case .speaking:
            return snapshot.isMicrophoneMuted
                ? "Assistant is speaking. Mic is muted."
                : "Assistant is speaking. You can interrupt by talking."
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
                            historyWindowNotice {
                                loadOlderHistoryBatch(with: proxy)
                            }
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        }

                        if assistant.isTransitioningSession {
                            if visibleRenderItems.isEmpty {
                                sessionTransitionPlaceholder
                            }
                        }

                        if !assistant.isTransitioningSession && visibleRenderItems.isEmpty {
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

                    if assistant.isTransitioningSession {
                        sessionTransitionOverlay
                            .padding(.top, 16)
                    }

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
            
            HStack(spacing: 4) {
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
                        minimizeToCompact()
                    } label: {
                        topBarIconButton(symbol: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .help("Continue in Compact View")
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
        AssistantGlyphBadge(
            symbol: symbol,
            tint: emphasized ? AppVisualTheme.accentTint : .white,
            side: 26,
            cornerRadius: 8,
            fillOpacity: emphasized ? 0.16 : 0.08,
            strokeOpacity: emphasized ? 0.24 : 0.12,
            symbolScale: 0.44,
            symbolWeight: .medium
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func historyWindowNotice(action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.message")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AssistantWindowChrome.neutralAccent.opacity(0.92))

            Text("Older chat history is hidden for speed. Use Load more to show older messages.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Button(action: action) {
                Text("Load more")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AssistantWindowChrome.buttonEmphasis.opacity(0.68))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.55)
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
        let hasRecentManualScrollIntent = Date().timeIntervalSince(lastManualChatScrollAt) <= Self.manualLoadOlderPause
        guard !assistant.isTransitioningSession,
              hasRecentManualScrollIntent,
              hiddenRenderItemCount > 0,
              topOffset > -Self.loadOlderThreshold,
              !isLoadingOlderHistory else {
            return
        }

        loadOlderHistoryBatch(with: proxy)
    }

    private func loadOlderHistoryBatch(with proxy: ScrollViewProxy) {
        guard !assistant.isTransitioningSession,
              hiddenRenderItemCount > 0,
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

    private var sessionTransitionOverlay: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.72))

            Text("Loading this chat…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.80))
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
                sessionID: item.sessionID,
                turnID: item.turnID,
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
                sessionID: item.sessionID,
                turnID: item.turnID,
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
                sessionID: item.sessionID,
                turnID: item.turnID,
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
        sessionID: String?,
        turnID: String?,
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

            if shouldShowHumeConversationPanel {
                humeConversationPanel
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
                            AssistantToolbarCircleButtonLabel(
                                symbol: AssistantChromeSymbol.attachment,
                                tint: AppVisualTheme.accentTint,
                                size: 24,
                                emphasized: !assistant.attachments.isEmpty
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Attach files or images")

                        if !assistant.attachments.isEmpty {
                            HStack(spacing: 6) {
                                AssistantGlyphBadge(
                                    symbol: AssistantChromeSymbol.attachmentCount,
                                    tint: AppVisualTheme.accentTint,
                                    side: 16,
                                    fillOpacity: 0.14,
                                    strokeOpacity: 0.22,
                                    symbolScale: 0.48
                                )
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
                            HStack(spacing: 6) {
                                AssistantGlyphBadge(
                                    symbol: AssistantChromeSymbol.model,
                                    tint: AppVisualTheme.accentTint,
                                    side: 18,
                                    fillOpacity: 0.14,
                                    strokeOpacity: 0.22,
                                    symbolScale: 0.48
                                )
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
                            HStack(spacing: 6) {
                                AssistantGlyphBadge(
                                    symbol: AssistantChromeSymbol.reasoning,
                                    tint: AssistantWindowChrome.neutralAccent,
                                    side: 18,
                                    fillOpacity: 0.10,
                                    strokeOpacity: 0.18,
                                    symbolScale: 0.50
                                )
                                Text(assistant.reasoningEffort.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.58))
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
                            HStack(spacing: 6) {
                                AssistantGlyphBadge(
                                    symbol: assistant.fastModeEnabled
                                        ? AssistantChromeSymbol.speedFast
                                        : AssistantChromeSymbol.speedStandard,
                                    tint: assistant.fastModeEnabled
                                        ? AppVisualTheme.accentTint
                                        : AssistantWindowChrome.neutralAccent,
                                    side: 18,
                                    fillOpacity: assistant.fastModeEnabled ? 0.14 : 0.10,
                                    strokeOpacity: assistant.fastModeEnabled ? 0.22 : 0.18,
                                    symbolScale: 0.48
                                )
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
                                AssistantToolbarCircleButtonLabel(
                                    symbol: "stop.fill",
                                    tint: .red,
                                    size: 24,
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
                                isEnabled: settings.assistantVoiceTaskEntryEnabled
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
                                    size: 24,
                                    isEnabled: canSendMessage && !isVoiceCapturing,
                                    emphasized: canSendMessage && !isVoiceCapturing
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

    private var humeConversationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                AssistantStatusBadge(
                    title: "Hume Conversation",
                    tint: assistant.isHumeConversationConnected ? .green : .cyan,
                    symbol: assistant.assistantHumeConversationSnapshot.phase == .speaking
                        ? "waveform"
                        : "person.wave.2.fill"
                )

                Text(humeConversationStatusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if assistant.isHumeConversationConnected {
                    Button(assistant.assistantHumeConversationSnapshot.isMicrophoneMuted ? "Unmute Mic" : "Mute Mic") {
                        assistant.toggleHumeConversationMicrophoneMute()
                    }
                    .buttonStyle(.bordered)

                    Button("Stop Speaking") {
                        Task { await assistant.stopHumeConversationSpeaking() }
                    }
                    .buttonStyle(.bordered)

                    Button("End Conversation", role: .destructive) {
                        Task { await assistant.endHumeConversation() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start Conversation") {
                        Task { await assistant.startHumeConversation() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!assistant.canStartHumeConversationMode)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
        )
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
            case .waitingForInput where request.hasStructuredUserInput:
                AssistantStructuredUserInputView(
                    request: request,
                    accent: .orange,
                    secondaryText: AppVisualTheme.mutedText,
                    fieldBackground: Color.white.opacity(0.04),
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
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
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
            }

            if assistant.hasActiveTurn && showsActions {
                Text("Wait for the plan to finish before executing it.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
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
