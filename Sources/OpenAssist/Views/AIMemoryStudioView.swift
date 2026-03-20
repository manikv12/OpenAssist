import AppKit
import SwiftUI

struct AIMemoryStudioView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var assistant = AssistantStore.shared
    @StateObject private var promptRewriteConversationStore = PromptRewriteConversationStore.shared
    @StateObject private var localAISetupService = LocalAISetupService.shared

    @State private var detectedMemoryProviders: [MemoryIndexingSettingsService.Provider] = []
    @State private var detectedMemorySourceFolders: [MemoryIndexingSettingsService.SourceFolder] = []

    @State private var memoryProviderFilterQuery = ""
    @State private var memoryFolderFilterQuery = ""
    @State private var memoryShowSelectedProvidersOnly = false
    @State private var memoryShowSelectedFoldersOnly = false
    @State private var memoryFoldersOnlyEnabledProviders = true

    @State private var memoryBrowserQuery = ""
    @State private var memoryBrowserSelectedProviderID = "all"
    @State private var memoryBrowserSelectedFolderID = "all"
    @State private var memoryBrowserIncludePlanContent = false
    @State private var memoryBrowserHighSignalOnly = true
    @State private var memoryDetailShowLowSignal = false
    @State private var memoryBrowserEntries: [MemoryIndexedEntry] = []
    @State private var memoryBrowserUnfilteredEntryCount = 0

    @State private var promptRewriteOpenAIKeyVisible = false
    @State private var promptRewriteShowManualAPIKey = false
    @State private var oauthBusyProviderRawValue: String?
    @State private var oauthStatusMessage: String?
    @State private var oauthConnectedProviders: [String: Bool] = [:]
    @State private var promptRewriteAvailableModels: [PromptRewriteModelOption] = []
    @State private var promptRewriteModelsLoading = false
    @State private var promptRewriteModelStatusMessage: String?
    @State private var promptRewriteModelRequestToken = UUID()
    @State private var openAIDeviceUserCode: String?
    @State private var openAIDeviceVerificationURL: URL?
    @State private var showLocalModelDeleteConfirmation = false

    @State private var memoryActionMessage: String?
    @State private var isMemoryIndexingInProgress = false
    @State private var memoryIndexingProgressSummary: String?
    @State private var memoryIndexingProgressDetail: String?
    @State private var selectedMemoryBrowserEntry: MemoryIndexedEntry?
    @State private var relatedMemoryEntries: [MemoryIndexedEntry] = []
    @State private var relatedMemoryEntriesHiddenCount = 0
    @State private var issueTimelineEntries: [MemoryIndexedEntry] = []
    @State private var issueTimelineEntriesHiddenCount = 0
    @State private var memoryInspectionExplanation: String?
    @State private var memoryInspectionStatusMessage: String?
    @State private var isMemoryInspectionBusy = false
    @State private var showMemoryDetailSheet = false
    @State private var memoryAnalytics = MemoryIndexingSettingsService.MemoryAnalyticsSnapshot(
        overview: MemoryIndexingSettingsService.MemoryAnalyticsOverview(
            repeatedMistakesAvoided: 0,
            invalidationRate: 0,
            fixSuccessRate: 0,
            totalTrackedAttempts: 0
        ),
        rows: []
    )
    @State private var showingProvidersSheet = false
    @State private var showingSourceFoldersSheet = false
    @State private var selectedStudioPage: StudioPage = .dashboard
    @State private var conversationContextDetails: [PromptRewriteConversationContextDetail] = []
    @State private var selectedConversationContextID = ""
    @State private var conversationContextSearchQuery = ""
    @State private var conversationActionMessage: String?
    @State private var conversationPatternStats: [MemoryPatternStats] = []
    @State private var selectedConversationPatternKey = ""
    @State private var conversationPatternOccurrences: [MemoryPatternOccurrence] = []
    @State private var expiredConversationHandoffCount = 0
    @State private var lastConversationHandoffSummaryMethod = "fallback"
    @State private var lastConversationPromotionDecisionSummary = "No promotion decision yet."
    @State private var showConversationContextInspectSheet = false
    @State private var showConversationContextInspectFullscreen = false
    @State private var inspectedConversationContextID = ""
    @State private var shouldRestoreAIMemoryStudioWindowAfterFullscreenInspector = false
    @State private var showConversationContextMappingsSheet = false
    @State private var contextMappingRows: [ContextMappingRow] = []
    @State private var isContextMappingsLoading = false
    @State private var contextMappingsLoadRequestToken = UUID()
    @State private var contextMappingMutatingRowID: String?
    @State private var lastContextMappingMutation: ContextMappingMutation?
    @State private var contextOverrideSourceContextID = ""
    @State private var contextOverrideTargetContextID = ""
    @State private var contextOverrideAxisRawValue = "project"
    @State private var contextOverrideDecisionRawValue = "linked"
    @State private var isContextOverrideSaving = false
    @State private var memoryBrowserRefreshWorkItem: DispatchWorkItem?

    private enum StudioPage: String, CaseIterable, Identifiable {
        case dashboard
        case models
        case conversationMemory
        case memorySources
        case sourceFolders
        case browser
        case actions
        case assistantSetup
        case assistantVoice
        case assistantMemory
        case assistantInstructions
        case assistantLimits
        case assistantSessions

        var id: Self { self }

        var title: String {
            switch self {
            case .dashboard:
                return "Overview"
            case .models:
                return "Provider & Models"
            case .conversationMemory:
                return "Conversation Memory"
            case .memorySources:
                return "Memory Sources"
            case .sourceFolders:
                return "Source Folders"
            case .browser:
                return "Memory Browser"
            case .actions:
                return "Maintenance"
            case .assistantSetup:
                return "Setup"
            case .assistantVoice:
                return "Voice"
            case .assistantMemory:
                return "Memory"
            case .assistantInstructions:
                return "Custom Instructions"
            case .assistantLimits:
                return "Limits"
            case .assistantSessions:
                return "Recent Sessions"
            }
        }

        var subtitle: String {
            switch self {
            case .dashboard:
                return "Big-picture status and quick actions."
            case .models:
                return "Connect provider securely and choose the prompt model."
            case .conversationMemory:
                return "Per-screen context history, size, and compaction."
            case .memorySources:
                return "Manage detected providers and enabled sources."
            case .sourceFolders:
                return "Review source folder inclusion rules."
            case .browser:
                return "Browse indexed memories by filters."
            case .actions:
                return "Rescan, rebuild, and cleanup controls."
            case .assistantSetup:
                return "Enable, model, account, and browser automation."
            case .assistantVoice:
                return "Assistant reply speech, Hume voice setup, fallback, and health."
            case .assistantMemory:
                return "Thread memory, long-term lessons, and review controls."
            case .assistantInstructions:
                return "Persistent instructions sent to every assistant session."
            case .assistantLimits:
                return "Tool call and repeated command safety limits."
            case .assistantSessions:
                return "Saved Codex sessions in Open Assist."
            }
        }

        var iconName: String {
            switch self {
            case .dashboard:
                return "square.grid.2x2"
            case .models:
                return "cpu.fill"
            case .conversationMemory:
                return "text.bubble"
            case .memorySources:
                return "square.stack.3d.up"
            case .sourceFolders:
                return "folder.badge.gearshape"
            case .browser:
                return "magnifyingglass.circle"
            case .actions:
                return AssistantChromeSymbol.action
            case .assistantSetup:
                return "sparkles.rectangle.stack.fill"
            case .assistantVoice:
                return "speaker.wave.3.fill"
            case .assistantMemory:
                return "brain.head.profile"
            case .assistantInstructions:
                return "text.quote"
            case .assistantLimits:
                return "gauge.with.dots.needle.33percent"
            case .assistantSessions:
                return "clock.arrow.circlepath"
            }
        }

        var tint: Color {
            switch self {
            case .dashboard:
                return Color(red: 0.23, green: 0.72, blue: 0.58)
            case .models:
                return Color(red: 0.30, green: 0.65, blue: 0.93)
            case .conversationMemory:
                return Color(red: 0.58, green: 0.62, blue: 0.94)
            case .memorySources:
                return Color(red: 0.33, green: 0.73, blue: 0.42)
            case .sourceFolders:
                return Color(red: 0.25, green: 0.66, blue: 0.84)
            case .browser:
                return Color(red: 0.92, green: 0.49, blue: 0.34)
            case .actions:
                return Color(red: 0.90, green: 0.70, blue: 0.26)
            case .assistantSetup:
                return Color(red: 0.22, green: 0.70, blue: 1.00)
            case .assistantVoice:
                return Color(red: 0.23, green: 0.72, blue: 0.58)
            case .assistantMemory:
                return Color(red: 0.46, green: 0.79, blue: 0.66)
            case .assistantInstructions:
                return Color(red: 0.72, green: 0.56, blue: 0.88)
            case .assistantLimits:
                return Color(red: 0.90, green: 0.70, blue: 0.26)
            case .assistantSessions:
                return Color(red: 0.84, green: 0.52, blue: 0.28)
            }
        }

        var isAssistantPage: Bool {
            switch self {
            case .assistantSetup, .assistantVoice, .assistantMemory, .assistantInstructions, .assistantLimits, .assistantSessions:
                return true
            default:
                return false
            }
        }
    }

    private enum LocalAIWizardStep: String, CaseIterable, Identifiable {
        case selectModel
        case installRuntime
        case downloadModel
        case verify
        case done

        var id: String { rawValue }

        var title: String {
            switch self {
            case .selectModel:
                return "Select Model"
            case .installRuntime:
                return "Install Runtime"
            case .downloadModel:
                return "Download Model"
            case .verify:
                return "Verify"
            case .done:
                return "Done"
            }
        }
    }

    private enum ConversationContextInspectorPresentation {
        case sheet
        case fullscreen

        var payloadEditorMinHeight: CGFloat {
            switch self {
            case .sheet:
                return 220
            case .fullscreen:
                return 360
            }
        }

        var turnsViewportHeight: CGFloat {
            switch self {
            case .sheet:
                return 330
            case .fullscreen:
                return 540
            }
        }
    }

    fileprivate final class WeakWindowReference {
        weak var window: NSWindow?
    }

    private struct ContextMappingRow: Identifiable, Equatable {
        let id: String
        let mappingTypeRawValue: String
        let appPairKey: String
        let subjectLabel: String
        let subjectKey: String
        let contextScopeKey: String?
        let canonicalKey: String?
        var decisionRawValue: String
        let source: ConversationContextMappingSource
        let updatedAt: Date

        var normalizedDecisionValue: String {
            let lowered = decisionRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "link" || lowered == "linked" {
                return "linked"
            }
            return "separate"
        }

        var normalizedMappingTypeValue: String {
            let lowered = mappingTypeRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.hasPrefix("alias:") {
                return "alias"
            }
            if lowered == "person" {
                return "person"
            }
            return "project"
        }

        var mappingRuleType: ConversationDisambiguationRuleType? {
            let lowered = mappingTypeRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch lowered {
            case "person":
                return .person
            case "project":
                return .project
            default:
                return nil
            }
        }

        var normalizedDecision: ConversationDisambiguationDecision {
            normalizedDecisionValue == "linked" ? .link : .separate
        }

        var supportsDecisionMutation: Bool {
            mappingRuleType != nil
        }

        var mappingTypeDisplay: String {
            if mappingTypeRawValue.hasPrefix("alias:") {
                return "Alias"
            }
            return normalizedMappingTypeValue.capitalized
        }

        var decisionDisplay: String {
            normalizedDecisionValue == "linked" ? "Linked" : "Separate"
        }

        var sourceDisplay: String {
            source.rawValue.uppercased()
        }

        var subjectDisplay: String {
            let normalizedLabel = subjectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedLabel.isEmpty ? subjectKey : normalizedLabel
        }
    }

    private struct ContextMappingMutation {
        enum Kind {
            case decisionChange
            case remove
        }

        let kind: Kind
        let snapshot: ContextMappingRow
    }

    private let memoryIndexingSettingsService = MemoryIndexingSettingsService.shared
    private let studioSidebarWidth: CGFloat = 244
    private let aiCorePages: [StudioPage] = [.dashboard, .models, .conversationMemory]
    private let aiStudioWindowReference = WeakWindowReference()

    var body: some View {
        ZStack {
            studioBackground
            HStack(spacing: 0) {
                studioSidebar

                Rectangle()
                    .fill(AppVisualTheme.surfaceFill(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        studioPageContent
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(10)

            if showConversationContextInspectFullscreen {
                conversationContextInspectFullscreenCover
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .appScrollbars()
        .tint(AppVisualTheme.accentTint)
        .background(
            AIMemoryStudioWindowAccessor(windowReference: aiStudioWindowReference)
        )
        .sheet(isPresented: $showingProvidersSheet) {
            providersSelectionSheet
        }
        .sheet(isPresented: $showingSourceFoldersSheet) {
            sourceFoldersSelectionSheet
        }
        .sheet(isPresented: $showConversationContextInspectSheet) {
            conversationContextInspectSheet
        }
        .sheet(isPresented: $showConversationContextMappingsSheet) {
            conversationContextMappingsSheet
        }
        .sheet(isPresented: $showMemoryDetailSheet) {
            memoryDetailSheet
        }
        .confirmationDialog(
            "Delete Local Model?",
            isPresented: $showLocalModelDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                localAISetupService.deleteSelectedModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected model from local runtime storage on this Mac.")
        }
        .onAppear {
            sanitizeSelectedStudioPage()
            prepare()
        }
        .onChange(of: promptRewriteConversationStore.contextSummaries) { _ in
            refreshConversationContextDetails()
        }
        .onChange(of: assistantSetupStage) { _ in
            sanitizeSelectedStudioPage()
        }
        .onChange(of: selectedStudioPage) { newValue in
            if newValue == .conversationMemory {
                refreshConversationContextDetails()
            }
        }
        .onChange(of: showConversationContextInspectSheet) { isPresented in
            if !isPresented {
                clearInspectedConversationContextIfNeeded()
            }
        }
        .onChange(of: showConversationContextInspectFullscreen) { isPresented in
            if !isPresented {
                clearInspectedConversationContextIfNeeded()
            }
        }
        .onChange(of: showConversationContextMappingsSheet) { isPresented in
            if isPresented {
                syncContextOverrideSelections()
                loadContextMappings(showStatusMessage: false)
            }
        }
        .onChange(of: localAISetupService.setupState) { newValue in
            if newValue == .ready {
                refreshPromptRewriteModels(showMessage: true)
            }
        }
        .onChange(of: settings.promptRewriteProviderModeRawValue) { _ in
            handlePromptRewriteProviderChanged()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MemoryIndexingSettingsService.indexingDidProgressNotification
            )
        ) { notification in
            handleMemoryIndexingProgress(notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MemoryIndexingSettingsService.indexingDidFinishNotification
            )
        ) { notification in
            handleMemoryIndexingCompletion(notification)
        }
        .onChange(of: memoryDetailShowLowSignal) { _ in
            guard let selectedMemoryBrowserEntry else { return }
            refreshMemoryDetailContext(for: selectedMemoryBrowserEntry)
        }
        .onDisappear {
            memoryBrowserRefreshWorkItem?.cancel()
            memoryBrowserRefreshWorkItem = nil
        }
    }

    private var studioBackground: some View {
        AppSplitChromeBackground(
            leadingPaneFraction: 0.31,
            leadingPaneMaxWidth: studioSidebarWidth + 26,
            leadingPaneWidth: studioSidebarWidth + 10,
            leadingTint: AppVisualTheme.sidebarTint,
            trailingTint: .black,
            accent: AppVisualTheme.accentTint,
            leadingPaneTransparent: true
        )
    }

    private var studioSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                NotificationCenter.default.post(name: .openAssistOpenSettings, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.bold))
                    Text("Settings")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(AppVisualTheme.mutedText)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Studio")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                Text(selectedStudioPage.subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.44))
                    .lineLimit(2)
            }

            VStack(spacing: 6) {
                sidebarMetricRow(label: "Assistant", value: promptAssistantStateLabel, tint: promptAssistantStateTint)
                sidebarMetricRow(
                    label: "Providers",
                    value: "\(connectedModelProviderCount)/\(PromptRewriteProviderMode.allCases.count)",
                    tint: AppVisualTheme.accentTint
                )
                sidebarMetricRow(
                    label: "Contexts",
                    value: "\(conversationContextDetails.count)",
                    tint: AppVisualTheme.accentTint
                )
                if isMemoryFeatureEnabled {
                    sidebarMetricRow(
                        label: "Folders",
                        value: "\(enabledSourceFolderCount)/\(totalSourceFoldersForEnabledProvidersCount)",
                        tint: AppVisualTheme.accentTint
                    )
                    sidebarMetricRow(
                        label: "Visible",
                        value: "\(memoryBrowserVisibleCount)",
                        tint: AppVisualTheme.accentTint
                    )
                } else {
                    sidebarMetricRow(
                        label: "Model",
                        value: settings.promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? settings.promptRewriteProviderMode.defaultModel
                            : settings.promptRewriteOpenAIModel,
                        tint: AppVisualTheme.accentTint
                    )
                }
            }

            Divider()
                .overlay(AppVisualTheme.surfaceStroke(0.08))

            Text("Workspace")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 3) {
                ForEach(availableStudioPages) { page in
                    Button {
                        selectedStudioPage = page
                    } label: {
                        studioPageRow(for: page)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .overlay(AppVisualTheme.surfaceStroke(0.08))

            Text("Assistant")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 3) {
                ForEach(assistantStudioPages) { page in
                    Button {
                        selectedStudioPage = page
                    } label: {
                        studioPageRow(for: page)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: studioSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sidebarMetricRow(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.40))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(AppVisualTheme.foreground(0.70))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.03))
        )
    }

    @ViewBuilder
    private func studioPageRow(for page: StudioPage) -> some View {
        let isSelected = selectedStudioPage == page

        HStack(spacing: 10) {
            Image(systemName: page.iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? page.tint.opacity(0.85) : AppVisualTheme.foreground(0.40))
                .frame(width: 20, height: 20)

            Text(page.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.92) : AppVisualTheme.foreground(0.68))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AppVisualTheme.foreground(0.07) : Color.clear)
        )
    }

    @ViewBuilder
    private var studioPageContent: some View {
        switch selectedStudioPage {
        case .dashboard:
            studioOverviewPage
        case .models:
            studioModelPage
        case .conversationMemory:
            studioConversationMemoryPage
        case .memorySources:
            if isMemoryFeatureEnabled { studioProvidersPage } else { studioOverviewPage }
        case .sourceFolders:
            if isMemoryFeatureEnabled { studioSourceFoldersPage } else { studioOverviewPage }
        case .browser:
            if isMemoryFeatureEnabled { studioBrowserPage } else { studioOverviewPage }
        case .actions:
            if isMemoryFeatureEnabled { studioActionsPage } else { studioOverviewPage }
        case .assistantSetup:
            studioAssistantSetupPage
        case .assistantVoice:
            studioAssistantVoicePage
        case .assistantMemory:
            studioAssistantMemoryPage
        case .assistantInstructions:
            studioAssistantInstructionsPage
        case .assistantLimits:
            studioAssistantLimitsPage
        case .assistantSessions:
            studioAssistantSessionsPage
        }
    }

    private var studioOverviewPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: isMemoryFeatureEnabled ? "AI Memory Assistant" : "AI Prompt Assistant",
                subtitle: isMemoryFeatureEnabled
                    ? "Toggle assistant-level prompt behavior."
                    : "Toggle prompt correction and formatting behavior.",
                symbol: "brain.head.profile",
                tint: promptAssistantStateTint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable AI prompt correction", isOn: $settings.promptRewriteEnabled)
                    if isMemoryFeatureEnabled {
                        Toggle("Enable AI memory assistant", isOn: $settings.memoryIndexingEnabled)
                    }
                    Toggle("Auto-insert high-confidence AI suggestions", isOn: $settings.promptRewriteAutoInsertEnabled)
                        .disabled(!settings.promptRewriteEnabled)
                    Toggle("Always convert AI suggestion to Markdown", isOn: $settings.promptRewriteAlwaysConvertToMarkdown)
                        .disabled(!settings.promptRewriteEnabled)

                    Divider()
                        .padding(.vertical, 2)

                    Text("For conversation mapping, shared history, and per-context controls, use Conversation Memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Conversation Memory") {
                        selectedStudioPage = .conversationMemory
                    }
                    .buttonStyle(.bordered)

                    Text(isMemoryFeatureEnabled
                         ? "Turn this off if you only want manual control via maintenance actions."
                         : "Prompt correction works without memory indexing in this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isMemoryFeatureEnabled {
                settingsCard(
                    title: "Memory Analytics",
                    subtitle: "Repeated mistakes avoided, invalidation rate, and fix success by provider/project.",
                    symbol: "chart.line.uptrend.xyaxis",
                    tint: AppVisualTheme.accentTint
                ) {
                HStack(spacing: 8) {
                    metricPill(
                        label: "Avoided",
                        value: "\(memoryAnalytics.overview.repeatedMistakesAvoided)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Invalidation",
                        value: percentLabel(memoryAnalytics.overview.invalidationRate),
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Fix Success",
                        value: percentLabel(memoryAnalytics.overview.fixSuccessRate),
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Tracked",
                        value: "\(memoryAnalytics.overview.totalTrackedAttempts)",
                        tint: AppVisualTheme.accentTint
                    )
                }

                if memoryAnalytics.rows.isEmpty {
                    Text("No tracked issue attempts yet. Memories with issue_key/outcome metadata will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Provider / Project")
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Attempts")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 58, alignment: .trailing)
                            Text("Invalid")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 48, alignment: .trailing)
                            Text("Success")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 56, alignment: .trailing)
                        }
                        .foregroundStyle(.tertiary)

                        ForEach(memoryAnalytics.rows.prefix(8)) { row in
                            HStack(spacing: 8) {
                                Text("\(row.providerName) / \(row.projectName)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(row.totalAttempts)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 58, alignment: .trailing)
                                Text("\(row.invalidatedCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(row.invalidatedCount > 0 ? AppVisualTheme.accentTint : .secondary)
                                    .frame(width: 48, alignment: .trailing)
                                Text(percentLabel(row.successRate))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(row.successRate >= 0.6 ? AppVisualTheme.accentTint : .secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            }

            if let memoryActionMessage {
                Text(memoryActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
    }

    private var studioModelPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerConnectionCard
            if settings.promptRewriteProviderMode == .ollama {
                localAISetupCard
            }
            promptModelConfigCard
        }
    }

    private var studioProvidersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Detected Source Providers",
                subtitle: "Choose which source apps/folders can feed the memory index.",
                symbol: "square.stack.3d.up",
                tint: AppVisualTheme.accentTint
            ) {
                if detectedMemoryProviders.isEmpty {
                    emptyStateRow(
                        title: "No source providers detected",
                        message: "Run a rescan to discover source providers.",
                        systemImage: "tray"
                    )
                } else {
                    HStack {
                        Text("\(enabledSourceProviderCount) of \(detectedMemoryProviders.count) source providers enabled")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Providers…") {
                            showingProvidersSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !memoryProviderFilterQuery.isEmpty || memoryShowSelectedProvidersOnly {
                        HStack {
                            TextField("Filter providers", text: $memoryProviderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedProvidersOnly)
                                .toggleStyle(.checkbox)
                        }
                    } else {
                        HStack {
                            Text("Tip")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Use \"Manage Providers…\" to enable or disable source providers in bulk.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !detectedMemoryProviders.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredMemoryProviders) { provider in
                                    Toggle(isOn: Binding(
                                        get: { settings.isMemoryProviderEnabled(provider.id) },
                                        set: { isEnabled in
                                            settings.setMemoryProviderEnabled(provider.id, enabled: isEnabled)
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(provider.name)
                                                .font(.callout.weight(.medium))
                                            Text(provider.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(maxHeight: 350)
                    }
                }
            }
        }
    }

    private var studioSourceFoldersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Detected Source Folders",
                subtitle: "Tune which folders are used to build memory index.",
                symbol: "folder.badge.gearshape",
                tint: AppVisualTheme.accentTint
            ) {
                if detectedMemorySourceFolders.isEmpty {
                    emptyStateRow(
                        title: "No source folders detected",
                        message: "Open settings sources or run a rescan to discover source folders.",
                        systemImage: "tray"
                    )
                } else {
                    HStack {
                        Text("\(enabledSourceFolderCount) of \(totalSourceFoldersForEnabledProvidersCount) folders selected for enabled source providers")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Folders…") {
                            showingSourceFoldersSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !memoryFolderFilterQuery.isEmpty || memoryShowSelectedFoldersOnly || !memoryFoldersOnlyEnabledProviders {
                        HStack(spacing: 8) {
                            TextField("Filter source folders", text: $memoryFolderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedFoldersOnly)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                            Toggle("Only enabled source providers", isOn: $memoryFoldersOnlyEnabledProviders)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                                .help("Only enabled source providers")
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredMemorySourceFolders.isEmpty ? detectedMemorySourceFolders : filteredMemorySourceFolders) { folder in
                                Toggle(isOn: Binding(
                                    get: { settings.isMemorySourceFolderEnabled(folder.id) },
                                    set: { isEnabled in
                                        settings.setMemorySourceFolderEnabled(folder.id, enabled: isEnabled)
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.name)
                                            .font(.callout.weight(.medium))
                                        Text(folder.path)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(maxHeight: 350)
                }
            }
        }
    }

    private var studioBrowserPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            memoryBrowserCard
        }
    }

    private var studioConversationMemoryPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            conversationMemoryOverviewCard
            conversationContextListCard
            conversationContextMappingsCard
            conversationLongTermPatternsCard
        }
    }

    private var conversationMemoryOverviewCard: some View {
        settingsCard(
            title: "Conversation Memory",
            subtitle: "Per-screen rewrite buckets with compaction-aware history.",
            symbol: "text.bubble",
            tint: AppVisualTheme.accentTint
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Enable conversation-aware rewrite history (app + screen)",
                    isOn: $settings.promptRewriteConversationHistoryEnabled
                )
                .disabled(!settings.promptRewriteEnabled)

                Toggle(
                    "Share coding conversation history across apps when project matches",
                    isOn: $settings.promptRewriteCrossIDEConversationSharingEnabled
                )
                .disabled(!settings.promptRewriteConversationHistoryEnabled || !settings.promptRewriteEnabled)

                if let crossIDEConversationSharingOverrideHint {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                            .font(.caption2)
                        Text(crossIDEConversationSharingOverrideHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Enabled by default: coding apps (Codex, Antigravity, VS Code, Cursor, Xcode, JetBrains) reuse one conversation bucket per project. Disable to keep coding history app-isolated."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    metricPill(
                        label: "Contexts",
                        value: "\(conversationContextDetails.count)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Turns",
                        value: "\(totalConversationExchangeTurnCount)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Est. Tokens",
                        value: "\(totalConversationEstimatedTokenCount)",
                        tint: AppVisualTheme.accentTint
                    )
                }

                HStack(spacing: 8) {
                    metricPill(
                        label: "Expired Handoffs",
                        value: "\(expiredConversationHandoffCount)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Last Method",
                        value: lastConversationHandoffSummaryMethod.uppercased(),
                        tint: AppVisualTheme.accentTint
                    )
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text("Last archive status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastConversationPromotionDecisionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }

                HStack {
                    Text("Current timeout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.promptRewriteConversationTimeoutMinutes.rounded())) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $settings.promptRewriteConversationTimeoutMinutes,
                    in: 2...240,
                    step: 1
                )
                .disabled(!settings.promptRewriteConversationHistoryEnabled || !settings.promptRewriteEnabled)

                HStack {
                    Text("Turns kept in active prompt window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(settings.promptRewriteConversationTurnLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Stepper(
                        "\(settings.promptRewriteConversationTurnLimit)",
                        value: $settings.promptRewriteConversationTurnLimit,
                        in: 1...50
                    )
                    .labelsHidden()
                }
                .disabled(!settings.promptRewriteConversationHistoryEnabled || !settings.promptRewriteEnabled)

                HStack {
                    Text("History source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(
                        "History source",
                        selection: promptRewriteConversationContextSelection
                    ) {
                        Text("Automatic (current app/screen)").tag("auto")
                        ForEach(promptRewriteConversationStore.contextSummaries.prefix(24)) { summary in
                            Text("\(summary.displayName) • \(summary.turnCount) turns")
                                .tag(summary.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 360)
                }
                .disabled(!settings.promptRewriteConversationHistoryEnabled || !settings.promptRewriteEnabled)

                HStack(spacing: 8) {
                    Button("Start New Current Conversation") {
                        startNewPromptRewriteConversation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.promptRewriteConversationHistoryEnabled || !settings.promptRewriteEnabled)

                    Button("Clear All Conversation History", role: .destructive) {
                        promptRewriteConversationStore.clearAll()
                        settings.promptRewriteConversationPinnedContextID = ""
                        conversationActionMessage = "Cleared all conversation history."
                        refreshConversationContextDetails()
                    }
                    .buttonStyle(.bordered)
                    .disabled(conversationContextDetails.isEmpty)
                }

                Text("Storage: SQLite (`memory.sqlite3`) for conversation threads + turns. JSON below is an inspector snapshot view.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let conversationActionMessage {
                    Text(conversationActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var conversationContextListCard: some View {
        settingsCard(
            title: "Context Buckets",
            subtitle: "Inspect each screen-specific conversation and run compaction on demand.",
            symbol: "rectangle.stack.person.crop",
            tint: AppVisualTheme.accentTint
        ) {
            HStack(spacing: 8) {
                TextField("Filter by app, screen, or field", text: $conversationContextSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        refreshConversationContextDetails()
                    }

                Button("Refresh") {
                    refreshConversationContextDetails()
                }
                .buttonStyle(.bordered)

                Button("Compact All") {
                    compactAllConversationContexts()
                }
                .buttonStyle(.borderedProminent)
                .disabled(conversationContextDetails.isEmpty)
            }

            if filteredConversationContextDetails.isEmpty {
                emptyStateRow(
                    title: "No conversation contexts",
                    message: "Start rewriting prompts in different screens to build context buckets, then compact from here.",
                    systemImage: "tray"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredConversationContextDetails) { detail in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(detail.context.displayName)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    if !settings.isPromptRewriteConversationHistoryEnabled(forContextID: detail.id) {
                                        memoryEntryBadge("History Off", tint: Color.orange)
                                    }
                                    Text(detail.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }

                                HStack(spacing: 8) {
                                    metricPill(
                                        label: "Turns",
                                        value: "\(detail.exchangeTurnCount)",
                                        tint: AppVisualTheme.accentTint
                                    )
                                    metricPill(
                                        label: "Est. Tokens",
                                        value: "\(detail.estimatedTokenCount)",
                                        tint: AppVisualTheme.accentTint
                                    )
                                    Spacer(minLength: 0)
                                }

                                Toggle(
                                    "Use history for AI tips",
                                    isOn: promptRewriteConversationHistoryBinding(for: detail.id)
                                )
                                .toggleStyle(.switch)
                                .font(.caption)

                                HStack(spacing: 8) {
                                    Button("Inspect") {
                                        openConversationContextInspector(for: detail.id)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Full Screen") {
                                        openConversationContextInspectorFullScreen(for: detail.id)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Compact") {
                                        compactConversationContext(id: detail.id)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Clear", role: .destructive) {
                                        clearConversationContext(id: detail.id)
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppVisualTheme.adaptiveMaterialFill())
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        selectedConversationContextID == detail.id
                                            ? AppVisualTheme.accentTint.opacity(0.24)
                                            : Color.primary.opacity(0.08),
                                        lineWidth: 0.7
                                    )
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var conversationContextMappingsCard: some View {
        settingsCard(
            title: "Context Overrides",
            subtitle: "Manage manual project/person link decisions for shared conversation context.",
            symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
            tint: AppVisualTheme.accentTint
        ) {
            Text("Review project/person overrides, switch decisions between linked vs separate, and remove stale records.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                metricPill(
                    label: "Overrides",
                    value: "\(contextMappingRows.count)",
                    tint: AppVisualTheme.accentTint
                )
                metricPill(
                    label: "Project",
                    value: "\(contextMappingRows.filter { $0.normalizedMappingTypeValue == "project" }.count)",
                    tint: AppVisualTheme.accentTint
                )
                metricPill(
                    label: "Person",
                    value: "\(contextMappingRows.filter { $0.normalizedMappingTypeValue == "person" }.count)",
                    tint: AppVisualTheme.accentTint
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Open Context Overrides") {
                    showConversationContextMappingsSheet = true
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh Cached Count") {
                    loadContextMappings(showStatusMessage: true)
                }
                .buttonStyle(.bordered)
                .disabled(isContextMappingsLoading)

                if isContextMappingsLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var conversationLongTermPatternsCard: some View {
        settingsCard(
            title: "Long-term Memory Promotions",
            subtitle: "Track promoted conversation patterns, repeats, and manual quality signals.",
            symbol: "brain.filled.head.profile",
            tint: AppVisualTheme.accentTint
        ) {
            HStack(spacing: 8) {
                metricPill(
                    label: "Patterns",
                    value: "\(conversationPatternStats.count)",
                    tint: AppVisualTheme.accentTint
                )
                metricPill(
                    label: "Repeating",
                    value: "\(conversationPatternStats.filter { $0.isRepeating }.count)",
                    tint: AppVisualTheme.accentTint
                )
                metricPill(
                    label: "Good",
                    value: "\(conversationPatternStats.reduce(0) { $0 + $1.goodRepeatCount })",
                    tint: AppVisualTheme.accentTint
                )
                metricPill(
                    label: "Bad",
                    value: "\(conversationPatternStats.reduce(0) { $0 + $1.badRepeatCount })",
                    tint: AppVisualTheme.accentTint
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Refresh Patterns") {
                    refreshConversationPatternStats()
                }
                .buttonStyle(.borderedProminent)

                Button("Purge Expired") {
                    purgeExpiredConversationPatterns()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }

            if conversationPatternStats.isEmpty {
                emptyStateRow(
                    title: "No promoted patterns yet",
                    message: "Patterns appear here after conversation compaction/timeout is promoted into long-term memory.",
                    systemImage: "tray"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(conversationPatternStats.prefix(80)) { pattern in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(pattern.appName)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    if pattern.isRepeating {
                                        memoryEntryBadge("Repeating", tint: AppVisualTheme.accentTint)
                                    }
                                    Text(pattern.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }

                                Text(pattern.surfaceLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    metricPill(
                                        label: "Seen",
                                        value: "\(pattern.occurrenceCount)",
                                        tint: AppVisualTheme.accentTint
                                    )
                                    metricPill(
                                        label: "Good",
                                        value: "\(pattern.goodRepeatCount)",
                                        tint: AppVisualTheme.accentTint
                                    )
                                    metricPill(
                                        label: "Bad",
                                        value: "\(pattern.badRepeatCount)",
                                        tint: AppVisualTheme.accentTint
                                    )
                                    metricPill(
                                        label: "Confidence",
                                        value: String(format: "%.2f", pattern.confidence),
                                        tint: AppVisualTheme.accentTint
                                    )
                                    Spacer(minLength: 0)
                                }

                                HStack(spacing: 8) {
                                    Button("Inspect") {
                                        selectedConversationPatternKey = pattern.patternKey
                                        refreshConversationPatternOccurrences(patternKey: pattern.patternKey)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Mark Good") {
                                        markConversationPattern(pattern.patternKey, outcome: .good)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Mark Bad") {
                                        markConversationPattern(pattern.patternKey, outcome: .bad)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Delete Pattern", role: .destructive) {
                                        deleteConversationPattern(pattern.patternKey)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if selectedConversationPatternKey == pattern.patternKey,
                                   !conversationPatternOccurrences.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Occurrences")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(conversationPatternOccurrences.prefix(6)) { occurrence in
                                            HStack(spacing: 8) {
                                                Text(occurrence.outcome.rawValue.capitalized)
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 52, alignment: .leading)
                                                Text(occurrence.trigger.rawValue)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.tertiary)
                                                Spacer()
                                                Text(occurrence.eventTimestamp.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .monospacedDigit()
                                            }
                                        }
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(AppVisualTheme.adaptiveMaterialFill())
                                    )
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppVisualTheme.adaptiveMaterialFill())
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        selectedConversationPatternKey == pattern.patternKey
                                            ? AppVisualTheme.accentTint.opacity(0.24)
                                            : Color.primary.opacity(0.08),
                                        lineWidth: 0.7
                                    )
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 420)
            }
        }
    }

    @ViewBuilder
    private var conversationContextInspectSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inspect Context")
                            .font(.headline)
                        if let detail = inspectedConversationContextDetail {
                            Text(detail.context.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(detail.context.providerContextLabel)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if let detail = inspectedConversationContextDetail {
                        memoryEntryBadge(detail.context.appName, tint: AppVisualTheme.accentTint)
                    }
                    if let detail = inspectedConversationContextDetail {
                        Button("Open Full Screen") {
                            openConversationContextInspectorFullScreen(for: detail.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Done") {
                        showConversationContextInspectSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                ScrollView {
                    if let detail = inspectedConversationContextDetail {
                        conversationContextInspectorContent(detail, presentation: .sheet)
                            .padding(18)
                    } else {
                        emptyStateRow(
                            title: "Context unavailable",
                            message: "This context may have been cleared. Close this dialog and inspect another context.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .padding(18)
                    }
                }
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.16)
            .padding(10)
        }
        .frame(width: 860, height: 700)
    }

    @ViewBuilder
    private var conversationContextInspectFullscreenCover: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inspect Context")
                            .font(.title3.weight(.semibold))
                        Text("Full-screen view for larger JSON and longer conversation history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let detail = inspectedConversationContextDetail {
                            Text(detail.context.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(detail.context.providerContextLabel)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if let detail = inspectedConversationContextDetail {
                        memoryEntryBadge(detail.context.appName, tint: AppVisualTheme.accentTint)
                    }

                    Button("Back to AI Studio") {
                        closeConversationContextInspectorFullScreen()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                ScrollView {
                    if let detail = inspectedConversationContextDetail {
                        conversationContextInspectorContent(detail, presentation: .fullscreen)
                            .padding(24)
                    } else {
                        emptyStateRow(
                            title: "Context unavailable",
                            message: "This context may have been cleared. Go back to AI Studio and inspect another context.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .appThemedSurface(cornerRadius: 24, strokeOpacity: 0.18)
            .padding(18)
        }
        .ignoresSafeArea()
        .appScrollbars()
    }

    @ViewBuilder
    private var conversationContextMappingsSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context Overrides")
                            .font(.headline)
                        Text("Manual project/person link rules for app pairs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isContextMappingsLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("Refresh") {
                        loadContextMappings(showStatusMessage: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isContextMappingsLoading)

                    Button("Undo Recent Change") {
                        undoLastContextMappingMutation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(lastContextMappingMutation == nil || contextMappingMutatingRowID != nil)

                    Button("Done") {
                        showConversationContextMappingsSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                VStack(alignment: .leading, spacing: 12) {
                    contextOverrideComposer

                    if isContextMappingsLoading, contextMappingRows.isEmpty {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Loading context overrides...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if contextMappingRows.isEmpty {
                        emptyStateRow(
                            title: "No context overrides",
                            message: "Add an override above, or wait for project/person clarification decisions to create one automatically.",
                            systemImage: "tray"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            contextMappingsTableHeader
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(contextMappingRows) { row in
                                        contextMappingsRow(row)
                                    }
                                }
                                .padding(.trailing, 2)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.16)
            .padding(10)
        }
        .frame(width: 980, height: 650)
    }

    private var contextMappingsTableHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Type")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text("App Pair")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)

            Text("Subject")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)

            Text("Decision")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text("Source")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            Text("Updated")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 125, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var contextOverrideComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create Override")
                .font(.subheadline.weight(.semibold))

            if contextOverrideContextOptions.isEmpty {
                Text("No contexts available yet. Use prompt rewrite in at least two contexts, then create an override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("Type", selection: $contextOverrideAxisRawValue) {
                        Text("Project").tag("project")
                        Text("Person").tag("person")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)

                    Picker("Decision", selection: $contextOverrideDecisionRawValue) {
                        Text("Linked").tag("linked")
                        Text("Separate").tag("separate")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Picker("From Context", selection: $contextOverrideSourceContextID) {
                        ForEach(contextOverrideContextOptions) { detail in
                            Text(detail.context.displayName).tag(detail.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("To Context", selection: $contextOverrideTargetContextID) {
                        ForEach(contextOverrideContextOptions) { detail in
                            Text(detail.context.displayName).tag(detail.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 8) {
                    Button("Create Override") {
                        createContextOverride()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreateContextOverride || isContextOverrideSaving)

                    if isContextOverrideSaving {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func contextMappingsRow(_ row: ContextMappingRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.mappingTypeDisplay)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 70, alignment: .leading)

            Text(row.appPairKey)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.subjectDisplay)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subjectKey)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 240, alignment: .leading)

            Picker("Decision", selection: contextMappingDecisionBinding(for: row.id)) {
                Text("Linked").tag("linked")
                Text("Separate").tag("separate")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120, alignment: .leading)
            .disabled(contextMappingMutatingRowID == row.id || !row.supportsDecisionMutation)

            Text(row.sourceDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            Text(row.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 125, alignment: .leading)

            Spacer(minLength: 0)

            Button(role: .destructive) {
                removeContextMapping(row.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(contextMappingMutatingRowID == row.id)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func conversationContextInspectorContent(
        _ detail: PromptRewriteConversationContextDetail,
        presentation: ConversationContextInspectorPresentation
    ) -> some View {
        let payload = formattedConversationContextPayload(for: detail.id)
        let exchangeTurns = detail.turns.filter { !$0.isSummary }

        return VStack(alignment: .leading, spacing: 14) {
            inspectorSection(
                title: "Context Health",
                subtitle: "Snapshot metrics and maintenance actions."
            ) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    metricPill(
                        label: "Turns",
                        value: "\(detail.exchangeTurnCount)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Characters",
                        value: "\(detail.estimatedCharacterCount)",
                        tint: AppVisualTheme.accentTint
                    )
                    metricPill(
                        label: "Est. Tokens",
                        value: "\(detail.estimatedTokenCount)",
                        tint: AppVisualTheme.accentTint
                    )
                }

                HStack(spacing: 10) {
                    Button("Compact Context") {
                        compactConversationContext(id: detail.id)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clear Context", role: .destructive) {
                        clearConversationContext(id: detail.id)
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }

                Toggle(
                    "Use history for AI tips in this context",
                    isOn: promptRewriteConversationHistoryBinding(for: detail.id)
                )
                .toggleStyle(.switch)
                .font(.caption)

                Text("When off, AI tips still run, but this context's conversation history is excluded from prompt generation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            inspectorSection(
                title: payload.isJSON ? "Context Snapshot (JSON View)" : "Context Snapshot",
                subtitle: payload.isJSON
                    ? "Formatted for readability."
                    : "Raw content shown because JSON parsing failed."
            ) {
                jsonPayloadEditor(
                    text: payload.text,
                    minHeight: presentation.payloadEditorMinHeight
                )

                if !payload.isJSON {
                    Text("Could not parse the payload as JSON. Showing raw content.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            inspectorSection(
                title: "Conversation Turns",
                subtitle: "Full exchange timeline."
            ) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(exchangeTurns.enumerated()), id: \.offset) { _, turn in
                            conversationTurnRow(turn)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: presentation.turnsViewportHeight)
            }
        }
    }

    private func inspectorSection<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let subtitle,
               !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func conversationTurnRow(_ turn: PromptRewriteConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                memoryEntryBadge("Exchange", tint: AppVisualTheme.accentTint)
                Spacer()
                Text(turn.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text("User")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(turn.userText)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Assistant")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(turn.assistantText)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }

    private func jsonPayloadEditor(text: String, minHeight: CGFloat) -> some View {
        TextEditor(text: .constant(text))
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .textSelection(.enabled)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppVisualTheme.adaptiveMaterialFill())
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                    )
            )
    }

    private var studioActionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            memoryActionsCard
        }
    }

    private var memoryBrowserCard: some View {
        settingsCard(
            title: "Memory Browser",
            subtitle: "List and search indexed memories by provider and folder.",
            symbol: "magnifyingglass.circle",
            tint: AppVisualTheme.accentTint
        ) {
            HStack(spacing: 8) {
                TextField("Search indexed memories", text: $memoryBrowserQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        refreshMemoryBrowser()
                    }

                Button("Search") {
                    refreshMemoryBrowser()
                }
                .buttonStyle(.borderedProminent)

                Button("Reload") {
                    refreshMemoryBrowser()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Picker("Provider", selection: $memoryBrowserSelectedProviderID) {
                    Text("All providers").tag("all")
                    ForEach(memoryBrowserProviderOptions) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Picker("Folder", selection: $memoryBrowserSelectedFolderID) {
                    Text("All folders").tag("all")
                    ForEach(memoryBrowserFolderOptions) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Include plan entries", isOn: $memoryBrowserIncludePlanContent)
                    .toggleStyle(.checkbox)
                Toggle("High-signal only", isOn: $memoryBrowserHighSignalOnly)
                    .toggleStyle(.checkbox)
            }
            .onChange(of: memoryBrowserSelectedProviderID) { _ in
                normalizeMemoryBrowserSelections()
                scheduleMemoryBrowserRefresh()
            }
            .onChange(of: memoryBrowserSelectedFolderID) { _ in
                scheduleMemoryBrowserRefresh()
            }
            .onChange(of: memoryBrowserIncludePlanContent) { _ in
                scheduleMemoryBrowserRefresh()
            }
            .onChange(of: memoryBrowserHighSignalOnly) { _ in
                scheduleMemoryBrowserRefresh()
            }

            if memoryBrowserEntries.isEmpty {
                if memoryBrowserHighSignalOnly, memoryBrowserUnfilteredEntryCount > 0 {
                    emptyStateRow(
                        title: "All matches hidden by High-signal filter",
                        message: "\(memoryBrowserUnfilteredEntryCount) indexed memories matched. Disable “High-signal only” to view them.",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } else {
                    emptyStateRow(
                        title: "No indexed memories matched",
                        message: "Try broadening your search, toggling filters, or rebuilding the index.",
                        systemImage: "tray"
                    )
                }
            } else {
                HStack {
                    Text("Showing \(memoryBrowserVisibleCount) of \(memoryBrowserEntries.count) memory cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if memoryBrowserEntries.count > memoryBrowserVisibleCount {
                        Text("Refine search to narrow results")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(memoryBrowserEntries.prefix(80)) { entry in
                            Button {
                                selectMemoryBrowserEntry(entry)
                            } label: {
                                memoryBrowserEntryRow(
                                    entry,
                                    isSelected: selectedMemoryBrowserEntry?.id == entry.id
                                )
                            }
                            .buttonStyle(.plain)
                            .onTapGesture(count: 2) {
                                selectMemoryBrowserEntry(entry)
                                showMemoryDetailSheet = true
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 460)

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Double-click a memory to view details and ask AI about it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppVisualTheme.adaptiveMaterialFill())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                )

                if memoryBrowserHighSignalOnly, memoryBrowserUnfilteredEntryCount > memoryBrowserEntries.count {
                    Text("High-signal filter is hiding \(memoryBrowserUnfilteredEntryCount - memoryBrowserEntries.count) entry(ies).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var memoryActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Indexing",
                subtitle: "Rescan sources or rebuild the memory index.",
                symbol: "arrow.triangle.2.circlepath",
                tint: AppVisualTheme.accentTint
            ) {
                HStack(spacing: 8) {
                    Button("Rescan") {
                        rescanMemorySources(showMessage: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isMemoryIndexingInProgress)

                    Button("Rebuild Index") {
                        guard !settings.memoryEnabledProviderIDs.isEmpty else {
                            memoryActionMessage = "Enable at least one source provider before rebuilding the index."
                            return
                        }
                        isMemoryIndexingInProgress = true
                        memoryIndexingProgressSummary = "Preparing incremental rebuild..."
                        memoryIndexingProgressDetail = nil
                        memoryIndexingSettingsService.rebuildIndex(
                            enabledProviderIDs: settings.memoryEnabledProviderIDs,
                            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs
                        )
                        memoryActionMessage = "Started incremental rebuild (new/changed files only)."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled || isMemoryIndexingInProgress)

                    Button("Run Quality Cleanup") {
                        runQualityMaintenance()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMemoryIndexingInProgress)

                    Button("Stop", role: .destructive) {
                        stopMemoryIndexing()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isMemoryIndexingInProgress)
                }

                if isMemoryIndexingInProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Memory indexing in progress...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let memoryIndexingProgressSummary {
                            Text(memoryIndexingProgressSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let memoryIndexingProgressDetail {
                            Text(memoryIndexingProgressDetail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if let memoryActionMessage {
                    Text(memoryActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            settingsCard(
                title: "Danger Zone",
                subtitle: "Destructive actions that clear stored data.",
                symbol: "exclamationmark.triangle",
                tint: .red
            ) {
                HStack(spacing: 8) {
                    Button("Clear + Rebuild From Start", role: .destructive) {
                        guard !settings.memoryEnabledProviderIDs.isEmpty else {
                            memoryActionMessage = "Enable at least one source provider before rebuilding from scratch."
                            return
                        }
                        isMemoryIndexingInProgress = true
                        memoryIndexingProgressSummary = "Clearing indexed memory data..."
                        memoryIndexingProgressDetail = nil
                        memoryIndexingSettingsService.rebuildIndexFromScratch(
                            enabledProviderIDs: settings.memoryEnabledProviderIDs,
                            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs
                        )
                        memoryActionMessage = "Started full rebuild from scratch."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled || isMemoryIndexingInProgress)

                    Button("Clear Memories", role: .destructive) {
                        memoryIndexingSettingsService.clearMemories()
                        memoryActionMessage = "Cleared indexed memories."
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Archive", role: .destructive) {
                        memoryIndexingSettingsService.clearArchive()
                        memoryActionMessage = "Cleared archived memory entries."
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var connectedModelProviderCount: Int {
        PromptRewriteProviderMode.allCases.filter { mode in
            settings.isPromptRewriteProviderConnected(mode)
        }.count
    }

    private var isMemoryFeatureEnabled: Bool {
        FeatureFlags.aiMemoryEnabled
    }

    private var availableStudioPages: [StudioPage] {
        let base = isMemoryFeatureEnabled ? StudioPage.allCases : aiCorePages
        return base.filter { !$0.isAssistantPage }
    }

    private var assistantSetupStage: AIStudioAssistantSetupStage {
        AIStudioAssistantDisclosure.setupStage(
            environmentState: assistant.environment.state,
            assistantEnabled: settings.assistantBetaEnabled
        )
    }

    private var shouldShowAssistantAdvancedPages: Bool {
        AIStudioAssistantDisclosure.showsAdvancedPages(
            environmentState: assistant.environment.state,
            assistantEnabled: settings.assistantBetaEnabled
        )
    }

    private var assistantStudioPages: [StudioPage] {
        var pages: [StudioPage] = [.assistantSetup]
        if shouldShowAssistantAdvancedPages {
            pages.append(contentsOf: [.assistantVoice, .assistantMemory, .assistantInstructions, .assistantLimits, .assistantSessions])
        }
        return pages
    }

    private var enabledSourceProviderCount: Int {
        detectedMemoryProviders.filter { settings.isMemoryProviderEnabled($0.id) }.count
    }

    private var sourceFoldersForEnabledProviders: [MemoryIndexingSettingsService.SourceFolder] {
        let enabledProviderIDs = Set(
            settings.memoryEnabledProviderIDs.map { providerID in
                providerID.lowercased()
            }
        )
        guard !enabledProviderIDs.isEmpty else { return [] }
        return detectedMemorySourceFolders.filter { folder in
            enabledProviderIDs.contains(folder.providerID.lowercased())
        }
    }

    private var totalSourceFoldersForEnabledProvidersCount: Int {
        sourceFoldersForEnabledProviders.count
    }

    private var enabledSourceFolderCount: Int {
        sourceFoldersForEnabledProviders.filter { settings.isMemorySourceFolderEnabled($0.id) }.count
    }

    private var promptAssistantStateLabel: String {
        settings.promptRewriteEnabled ? "Enabled" : "Paused"
    }

    private var promptAssistantStateTint: Color {
        settings.promptRewriteEnabled ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.58)
    }

    private var crossIDEConversationSharingResolution: FeatureFlags.CrossIDEConversationSharingResolution {
        FeatureFlags.crossIDEConversationSharingResolution()
    }

    private var crossIDEConversationSharingOverrideHint: String? {
        guard crossIDEConversationSharingResolution.source == .env else {
            return nil
        }

        let runtimeState = crossIDEConversationSharingResolution.enabled ? "Enabled" : "Disabled"
        let savedSettingState = settings.promptRewriteCrossIDEConversationSharingEnabled ? "On" : "Off"
        return "Environment override (`OPENASSIST_FEATURE_CROSS_IDE_CONVERSATION_SHARING`) is active. Effective runtime: \(runtimeState). Saved toggle preference: \(savedSettingState), so this toggle may differ from runtime."
    }

    private var memoryBrowserVisibleCount: Int {
        min(memoryBrowserEntries.count, 80)
    }

    private var normalizedConversationContextQuery: String {
        conversationContextSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var filteredConversationContextDetails: [PromptRewriteConversationContextDetail] {
        let query = normalizedConversationContextQuery
        guard !query.isEmpty else {
            return conversationContextDetails
        }

        return conversationContextDetails.filter { detail in
            let haystack = [
                detail.context.displayName,
                detail.context.appName,
                detail.context.screenLabel,
                detail.context.fieldLabel,
                detail.context.projectLabel ?? "",
                detail.context.identityLabel ?? ""
            ]
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var selectedConversationContextDetail: PromptRewriteConversationContextDetail? {
        guard !selectedConversationContextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return conversationContextDetails.first { $0.id == selectedConversationContextID }
    }

    private var inspectedConversationContextDetail: PromptRewriteConversationContextDetail? {
        let normalizedID = inspectedConversationContextID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return nil
        }
        return conversationContextDetails.first { $0.id == normalizedID }
    }

    private var promptRewriteConversationContextSelection: Binding<String> {
        Binding(
            get: {
                let pinned = settings.promptRewriteConversationPinnedContextID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pinned.isEmpty, promptRewriteConversationStore.hasContext(id: pinned) else {
                    return "auto"
                }
                return pinned
            },
            set: { selected in
                if selected == "auto" {
                    settings.promptRewriteConversationPinnedContextID = ""
                } else {
                    settings.promptRewriteConversationPinnedContextID = selected
                }
            }
        )
    }

    private func promptRewriteConversationHistoryBinding(for contextID: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.isPromptRewriteConversationHistoryEnabled(forContextID: contextID)
            },
            set: { isEnabled in
                settings.setPromptRewriteConversationHistoryEnabled(isEnabled, forContextID: contextID)
                let state = isEnabled ? "ON" : "OFF"
                conversationActionMessage = "Context history for AI tips is now \(state) for \(contextID)."
            }
        )
    }

    private var totalConversationExchangeTurnCount: Int {
        conversationContextDetails.reduce(0) { $0 + $1.exchangeTurnCount }
    }

    private var totalConversationEstimatedTokenCount: Int {
        conversationContextDetails.reduce(0) { $0 + $1.estimatedTokenCount }
    }

    @ViewBuilder
    private func metricPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func emptyStateRow(title: String, message: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func memoryBrowserEntryRow(
        _ entry: MemoryIndexedEntry,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title.isEmpty ? "Untitled memory" : entry.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.isPlanContent {
                    memoryEntryBadge("Plan", tint: AppVisualTheme.accentTint)
                }
                memoryEntryBadge(entry.provider.displayName, tint: AppVisualTheme.accentTint)
            }

            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if entry.projectName != nil || entry.repositoryName != nil {
                HStack(spacing: 8) {
                    if let projectName = entry.projectName,
                       !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(projectName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let repositoryName = entry.repositoryName,
                       !repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(repositoryName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.sourceRootPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(entry.eventTimestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.adaptiveMaterialFill())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? AppVisualTheme.accentTint.opacity(0.22) : Color.primary.opacity(0.07),
                    lineWidth: 0.7
                )
        )
    }

    @ViewBuilder
    private var memoryDetailSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                if let entry = selectedMemoryBrowserEntry {
                    HStack {
                        Text("Memory Detail")
                            .font(.headline)
                        Spacer()
                        memoryEntryBadge(entry.provider.displayName, tint: AppVisualTheme.accentTint)
                        if entry.isPlanContent {
                            memoryEntryBadge("Plan", tint: AppVisualTheme.accentTint)
                        }
                        Button("Done") {
                            showMemoryDetailSheet = false
                        }
                    }
                    .padding()
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.title.isEmpty ? "Untitled memory" : entry.title)
                                .font(.title3.weight(.semibold))

                            Text(entry.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Toggle("Show lower-signal related entries", isOn: $memoryDetailShowLowSignal)
                                .toggleStyle(.checkbox)
                                .font(.caption)

                            Divider()

                            Text("What this memory stores")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(presentableMemoryText(entry.detail))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppVisualTheme.adaptiveMaterialFill())
                            )

                            if entry.outcomeStatus != nil || entry.attemptNumber != nil || entry.issueKey != nil {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let status = entry.outcomeStatus,
                                       !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Outcome: \(status.replacingOccurrences(of: "_", with: " ").capitalized)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let attemptNumber = entry.attemptNumber {
                                        if let attemptCount = entry.attemptCount, attemptCount > 0 {
                                            Text("Attempts: \(attemptNumber)/\(attemptCount)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("Attempt: \(attemptNumber)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if let evidence = entry.outcomeEvidence,
                                       !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Evidence: \(evidence)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    if let fixSummary = entry.fixSummary,
                                       !fixSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Fix summary: \(fixSummary)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    if let validationState = entry.validationState,
                                       !validationState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Validation: \(validationState.replacingOccurrences(of: "_", with: " ").capitalized)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let invalidatedByAttempt = entry.invalidatedByAttempt {
                                        Text("Invalidated by attempt: \(invalidatedByAttempt)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let issueKey = entry.issueKey,
                                       !issueKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Issue key: \(issueKey)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }

                            if !relatedMemoryEntries.isEmpty {
                                Divider()
                                Text("Related Memories")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(relatedMemoryEntries.prefix(6)) { related in
                                        Button {
                                            selectMemoryBrowserEntry(related)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(related.title.isEmpty ? "Untitled memory" : related.title)
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                if let relationType = related.relationType,
                                                   !relationType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                    Text(relationType.replacingOccurrences(of: "_", with: " "))
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                }
                                                if let confidence = related.relationConfidence {
                                                    Text("\(Int((confidence * 100).rounded()))%")
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.vertical, 2)
                                    }
                                }
                                if !memoryDetailShowLowSignal, relatedMemoryEntriesHiddenCount > 0 {
                                    Text("\(relatedMemoryEntriesHiddenCount) related entr\(relatedMemoryEntriesHiddenCount == 1 ? "y is" : "ies are") hidden by high-signal filtering.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !issueTimelineEntries.isEmpty {
                                Divider()
                                Text("Issue Timeline")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(issueTimelineEntries.prefix(10)) { timelineEntry in
                                        Button {
                                            selectMemoryBrowserEntry(timelineEntry)
                                        } label: {
                                            HStack(spacing: 8) {
                                                Text("Attempt \(timelineEntry.attemptNumber ?? 0)")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.tertiary)
                                                    .frame(width: 68, alignment: .leading)
                                                Text(timelineEntry.outcomeStatus?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 92, alignment: .leading)
                                                Text(timelineEntry.summary)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.vertical, 2)
                                    }
                                }
                                if !memoryDetailShowLowSignal, issueTimelineEntriesHiddenCount > 0 {
                                    Text("\(issueTimelineEntriesHiddenCount) timeline entr\(issueTimelineEntriesHiddenCount == 1 ? "y is" : "ies are") hidden by high-signal filtering.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(entry.sourceRootPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }

                            if entry.projectName != nil || entry.repositoryName != nil {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let projectName = entry.projectName,
                                       !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Project: \(projectName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let repositoryName = entry.repositoryName,
                                       !repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Repository: \(repositoryName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if !entry.sourceFileRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(entry.sourceFileRelativePath)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                            }

                            Text("Occurred: \(entry.eventTimestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()

                            Divider()

                            HStack(spacing: 8) {
                                Button("Ask AI About This Memory") {
                                    explainMemoryEntryWithAI(entry)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isMemoryInspectionBusy)

                                if isMemoryInspectionBusy {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }

                            if let memoryInspectionStatusMessage {
                                Text(memoryInspectionStatusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let memoryInspectionExplanation {
                                Text("AI Explanation")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Text(memoryInspectionExplanation)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(AppVisualTheme.adaptiveMaterialFill())
                                )
                            }
                        }
                        .padding()
                    }
                } else {
                    Text("No memory selected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 540, height: 520)
    }

    @ViewBuilder
    private func memoryEntryBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppVisualTheme.foreground(0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.22), lineWidth: 0.7)
                    )
            )
    }

    @ViewBuilder
    private var providerConnectionCard: some View {
        settingsCard(
            title: "Provider Authentication",
            subtitle: "Connect each provider securely before configuring models.",
            symbol: "bolt.badge.a",
            tint: AppVisualTheme.accentTint
        ) {
            let mode = settings.promptRewriteProviderMode

            providerModeSection

            Divider()

            authStateSummary(for: mode)

            Divider()

            providerAuthenticationSection(for: mode)

            if let oauthStatusMessage {
                Text(oauthStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var localAISetupCard: some View {
        settingsCard(
            title: "Local AI Setup (No Account Needed)",
            subtitle: "Pick a model and let Open Assist install runtime + model automatically.",
            symbol: "shippingbox.fill",
            tint: AppVisualTheme.accentTint
        ) {
            let selectedModelBinding = Binding(
                get: { localAISetupService.selectedModelID },
                set: { localAISetupService.selectedModelID = $0 }
            )

            Text("This guided flow sets up local prompt correction and memory extraction without API keys or OAuth.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Model", selection: selectedModelBinding) {
                ForEach(localAISetupService.modelOptions) { option in
                    let label = "\(option.displayName) • \(option.sizeLabel) • \(option.performanceLabel)"
                    Text(label).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 440, alignment: .leading)

            HStack(spacing: 8) {
                Button(localAISetupService.isRefreshingWebsiteCatalog ? "Fetching Website Models..." : "Fetch Latest from Website") {
                    localAISetupService.refreshModelCatalogFromWebsite()
                }
                .buttonStyle(.bordered)
                .disabled(localAISetupService.isRefreshingWebsiteCatalog || localAISetupService.setupState.isBusy)

                if localAISetupService.isRefreshingWebsiteCatalog {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let websiteCatalogStatusMessage = localAISetupService.websiteCatalogStatusMessage {
                Text(websiteCatalogStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let selected = localAISetupService.modelOption(for: localAISetupService.selectedModelID) {
                HStack(spacing: 8) {
                    if selected.isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppVisualTheme.accentTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppVisualTheme.accentTint.opacity(0.12))
                            )
                    }
                    Text(selected.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(LocalAIWizardStep.allCases) { step in
                    localAIWizardStepRow(step)
                }
            }
            .padding(.top, 4)

            if let progress = localAISetupService.setupState.progressValue {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(localAISetupService.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if localAISetupService.setupState.isBusy {
                    Button("Cancel") {
                        localAISetupService.cancel()
                    }
                    .buttonStyle(.bordered)
                } else {
                    if localAIShouldShowInstallButton {
                        Button("Install Selected Model") {
                            localAISetupService.startSetup(modelID: localAISetupService.selectedModelID)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    switch localAISetupService.setupState {
                    case .failed:
                        Button("Retry") {
                            localAISetupService.retry()
                        }
                        .buttonStyle(.bordered)
                    case .ready:
                        Button("Repair Local AI") {
                            localAISetupService.repair()
                        }
                        .buttonStyle(.bordered)
                    default:
                        if localAISetupService.runtimeDetection.installed {
                            Button("Repair Local AI") {
                                localAISetupService.repair()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Button("Refresh Status") {
                    localAISetupService.refreshStatus()
                }
                .buttonStyle(.bordered)
            }

            if !localAISetupService.installedModelIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installed Models")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    ForEach(localAISetupService.installedModelIDs, id: \.self) { modelID in
                        HStack(spacing: 8) {
                            Text(modelID)
                                .font(.caption2.monospaced())
                            
                            Spacer()
                            
                            if !localAISetupService.setupState.isBusy {
                                Button {
                                    localAISetupService.selectedModelID = modelID
                                    showLocalModelDeleteConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help("Uninstall model")
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppVisualTheme.adaptiveMaterialFill())
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var promptModelConfigCard: some View {
        let mode = settings.promptRewriteProviderMode

        settingsCard(
            title: "Prompt Model",
            subtitle: "Choose model and endpoint used by prompt rewrite.",
            symbol: "cpu.fill",
            tint: AppVisualTheme.accentTint
        ) {
            HStack(spacing: 8) {
                Text("\(mode.displayName) Model Catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if promptRewriteModelsLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button("Reload Models") {
                    refreshPromptRewriteModels(showMessage: true)
                }
                .buttonStyle(.bordered)
                .disabled(promptRewriteModelsLoading)
            }

            if !promptRewriteModelPickerOptions.isEmpty {
                Picker("Detected model", selection: $settings.promptRewriteOpenAIModel) {
                    ForEach(promptRewriteModelPickerOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 420, alignment: .leading)
            }

            TextField("Model (e.g. \(mode.defaultModel))", text: $settings.promptRewriteOpenAIModel)
                .textFieldStyle(.roundedBorder)
            Text("Pick a detected model, or type a custom model ID.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Base URL", text: $settings.promptRewriteOpenAIBaseURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Rewrite request timeout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(settings.promptRewriteRequestTimeoutSeconds.rounded())) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: $settings.promptRewriteRequestTimeoutSeconds,
                in: 3...120,
                step: 1
            )

            Text("Applies to all models/providers. Increase this if local models are timing out on slower Macs.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Always convert generated suggestions to Markdown", isOn: $settings.promptRewriteAlwaysConvertToMarkdown)

            Button("Use \(mode.displayName) Defaults") {
                settings.applyPromptRewriteProviderDefaultsIfNeeded(force: true)
                refreshPromptRewriteModels(showMessage: true)
            }
            .buttonStyle(.bordered)

            if let promptRewriteModelStatusMessage {
                Text(promptRewriteModelStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if mode == .ollama, localAISetupService.setupState != .ready {
                Text("Local runtime is not ready yet. Use Local AI Setup above to install or repair runtime + model.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Model settings are persisted for this provider only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Changes save automatically as you edit. No Save button is required.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var providerModeSection: some View {
        Picker("Rewrite provider", selection: $settings.promptRewriteProviderModeRawValue) {
            ForEach(PromptRewriteProviderMode.allCases) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)

        let mode = settings.promptRewriteProviderMode
        Text(mode.helpText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func authStateSummary(for mode: PromptRewriteProviderMode) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(promptRewriteAuthStateTint(for: mode))
                    .frame(width: 8, height: 8)
                Text(promptRewriteAuthStateLabel(for: mode))
                    .font(.callout)
                    .fontWeight(.medium)
            }

            if mode == .ollama {
                Text(localAISetupService.runtimeDetection.isHealthy
                     ? "Local runtime is reachable on this Mac."
                     : "Local runtime is not ready yet. Use Local AI Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Your credentials are stored in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func providerAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode.supportsOAuthSignIn {
                oauthAuthenticationSection(for: mode)
            } else if mode.requiresAPIKey {
                apiKeyAuthenticationSection(for: mode)
            } else if mode == .ollama {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local AI does not require API keys or OAuth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if localAISetupService.setupState == .ready {
                        Text("Runtime and model are ready for local prompt correction.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Open Local AI Setup") {
                            selectedStudioPage = .models
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("This provider does not require authentication details in Open Assist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func oauthAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let isConnected = oauthConnectedProviders[mode.rawValue] ?? false

            HStack(spacing: 8) {
                Image(systemName: isConnected ? "checkmark.shield.fill" : "key.slash.fill")
                    .foregroundStyle(isConnected ? AppVisualTheme.accentTint : AppVisualTheme.baseTint)
                Text(isConnected ? "OAuth session is active." : "OAuth session is inactive.")
                    .font(.callout)
                Spacer()
                if oauthBusyProviderRawValue == mode.rawValue {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button(isConnected ? "Reconnect OAuth" : "Connect OAuth") {
                    connectOAuth(for: mode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(oauthBusyProviderRawValue == mode.rawValue)

                if isConnected {
                    Button("Disconnect") {
                        disconnectOAuth(for: mode)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let plan = mode.oauthPlanLabel {
                Text("OAuth uses your \(plan) subscription, similar to OpenCode provider login.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if mode == .openAI,
               let deviceCode = openAIDeviceUserCode,
               let verificationURL = openAIDeviceVerificationURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI Device Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(deviceCode)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Code") {
                            copyToPasteboard(deviceCode)
                            oauthStatusMessage = "Device code copied. Enter it on the OpenAI page."
                        }
                        .buttonStyle(.bordered)
                        Button("Open Page") {
                            _ = NSWorkspace.shared.open(verificationURL)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Enter this code on the OpenAI device page to complete sign-in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppVisualTheme.adaptiveMaterialFill())
                )
            }

            DisclosureGroup("Use API key instead (optional)", isExpanded: $promptRewriteShowManualAPIKey) {
                apiKeyField(for: mode)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func apiKeyAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This provider uses API key authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)

            apiKeyField(for: mode)
        }
    }

    private func promptRewriteAuthStateLabel(for mode: PromptRewriteProviderMode) -> String {
        if mode.supportsOAuthSignIn {
            let isConnected = oauthConnectedProviders[mode.rawValue] ?? false
            let hasKey = !settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isConnected && hasKey {
                return "OAuth + API key"
            }
            return isConnected ? "OAuth connected" : "OAuth not connected"
        }

        if mode.requiresAPIKey {
            let hasKey = !settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasKey ? "API key configured" : "API key missing"
        }

        if mode == .ollama {
            if localAISetupService.runtimeDetection.isHealthy {
                return "Local AI ready"
            }
            if localAISetupService.runtimeDetection.installed {
                return "Runtime needs repair"
            }
            return "Runtime not installed"
        }

        return "No credentials required"
    }

    private func promptRewriteAuthStateTint(for mode: PromptRewriteProviderMode) -> Color {
        switch promptRewriteAuthStateLabel(for: mode) {
        case "OAuth connected", "OAuth + API key", "API key configured", "Local AI ready":
            return AppVisualTheme.accentTint
        case "API key missing", "OAuth not connected", "Runtime needs repair", "Runtime not installed":
            return AppVisualTheme.baseTint
        default:
            return AppVisualTheme.foreground(0.58)
        }
    }

    @ViewBuilder
    private func localAIWizardStepRow(_ step: LocalAIWizardStep) -> some View {
        let completed = localAIWizardStepCompleted(step)
        let active = localAIWizardStepActive(step)

        HStack(spacing: 8) {
            Image(systemName: completed ? "checkmark.circle.fill" : (active ? "circle.dashed.inset.filled" : "circle"))
                .foregroundStyle(
                    completed
                        ? AppVisualTheme.accentTint
                        : (active ? AppVisualTheme.baseTint : AppVisualTheme.foreground(0.45))
                )
                .font(.caption)
            Text(step.title)
                .font(.caption)
                .foregroundStyle(active || completed ? .primary : .secondary)
            Spacer(minLength: 0)
            if active {
                Text("In progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if completed {
                Text("Done")
                    .font(.caption2)
                    .foregroundStyle(AppVisualTheme.accentTint)
            }
        }
    }

    private func localAIWizardStepCompleted(_ step: LocalAIWizardStep) -> Bool {
        switch step {
        case .selectModel:
            return !localAISetupService.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .installRuntime:
            return localAISetupService.runtimeDetection.installed
        case .downloadModel:
            return localAISelectedModelInstalled
        case .verify:
            return localAISetupService.runtimeDetection.isHealthy && localAISelectedModelInstalled
        case .done:
            return localAISetupService.setupState == .ready
        }
    }

    private func localAIWizardStepActive(_ step: LocalAIWizardStep) -> Bool {
        switch (step, localAISetupService.setupState) {
        case (.installRuntime, .installingRuntime):
            return true
        case (.downloadModel, .downloadingModel):
            return true
        case (.verify, .verifying):
            return true
        default:
            return false
        }
    }

    private var localAISelectedModelInstalled: Bool {
        let selected = localAISetupService.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }
        return localAISetupService.installedModelIDs.contains { installed in
            let normalizedInstalled = installed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedSelected = selected.lowercased()
            if normalizedInstalled == normalizedSelected { return true }
            if normalizedInstalled.hasPrefix(normalizedSelected + ":") { return true }
            if normalizedSelected.hasPrefix(normalizedInstalled + ":") { return true }
            return false
        }
    }

    private var localAIShouldShowInstallButton: Bool {
        guard !localAISetupService.setupState.isBusy else { return false }

        let selected = localAISetupService.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }

        let selectedModelAlreadyReady = localAISetupService.runtimeDetection.isHealthy
            && localAISelectedModelInstalled
        return !selectedModelAlreadyReady
    }

    private var localAICanDeleteSelectedModel: Bool {
        guard !localAISetupService.setupState.isBusy else { return false }
        guard localAISetupService.runtimeDetection.installed else { return false }
        return localAISelectedModelInstalled
    }

    @ViewBuilder
    private func apiKeyField(for mode: PromptRewriteProviderMode) -> some View {
        HStack(spacing: 8) {
            if promptRewriteOpenAIKeyVisible {
                TextField("\(mode.displayName) API key", text: $settings.promptRewriteOpenAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } else {
                SecureField("\(mode.displayName) API key", text: $settings.promptRewriteOpenAIAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Show", isOn: $promptRewriteOpenAIKeyVisible)
                .toggleStyle(.checkbox)
                .fixedSize()

            Button {
                copyToPasteboard(settings.promptRewriteOpenAIAPIKey)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy API key to clipboard")
            .disabled(settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var providersSelectionSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack {
                    Text("Manage Detected Source Providers")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showingProvidersSheet = false
                    }
                }
                .padding()
                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    if detectedMemoryProviders.isEmpty {
                        Text("No source providers detected yet. Click Rescan to detect source providers.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        HStack(spacing: 8) {
                            TextField("Filter providers", text: $memoryProviderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedProvidersOnly)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                        }

                        HStack(spacing: 8) {
                            Button("Select All Visible") {
                                setMemoryProvidersEnabled(filteredMemoryProviders, enabled: true)
                            }
                            .buttonStyle(.bordered)
                            .disabled(filteredMemoryProviders.isEmpty)

                            Button("Clear Visible") {
                                setMemoryProvidersEnabled(filteredMemoryProviders, enabled: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(filteredMemoryProviders.isEmpty)
                        }

                        if filteredMemoryProviders.isEmpty {
                            Text("No source providers match the current filters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(filteredMemoryProviders) { provider in
                                        Toggle(isOn: Binding(
                                            get: { settings.isMemoryProviderEnabled(provider.id) },
                                            set: { isEnabled in
                                                settings.setMemoryProviderEnabled(provider.id, enabled: isEnabled)
                                            }
                                        )) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(provider.name)
                                                    .font(.callout.weight(.medium))
                                                Text(provider.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(.trailing)
                            }
                        }
                    }
                }
                .padding()
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 450, height: 500)
    }

    @ViewBuilder
    private var sourceFoldersSelectionSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack {
                    Text("Manage Detected Source Folders")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showingSourceFoldersSheet = false
                    }
                }
                .padding()
                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    if detectedMemorySourceFolders.isEmpty {
                        Text("No source folders detected yet. Click Rescan to find folders.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        HStack(spacing: 8) {
                            TextField("Filter source folders", text: $memoryFolderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedFoldersOnly)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                            Toggle("Only enabled source providers", isOn: $memoryFoldersOnlyEnabledProviders)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                                .help("Only enabled source providers")
                        }

                        HStack(spacing: 8) {
                            Button("Select All Visible") {
                                setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: true)
                            }
                            .buttonStyle(.bordered)
                            .disabled(filteredMemorySourceFolders.isEmpty)

                            Button("Clear Visible") {
                                setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(filteredMemorySourceFolders.isEmpty)
                        }

                        if filteredMemorySourceFolders.isEmpty {
                            Text("No source folders match the current filters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(filteredMemorySourceFolders) { folder in
                                        Toggle(isOn: Binding(
                                            get: { settings.isMemorySourceFolderEnabled(folder.id) },
                                            set: { isEnabled in
                                                settings.setMemorySourceFolderEnabled(folder.id, enabled: isEnabled)
                                            }
                                        )) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(folder.name)
                                                    .font(.callout.weight(.medium))
                                                Text(folder.path)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                    }
                                }
                                .padding(.trailing)
                            }
                        }
                    }
                }
                .padding()
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 550, height: 500)
    }

    private func prepare() {
        refreshOAuthConnectionState()
        refreshPromptRewriteModels(showMessage: false)
        localAISetupService.refreshStatus()
        refreshConversationContextDetails()
        refreshConversationPatternStats()
        guard isMemoryFeatureEnabled else { return }
        refreshMemoryAnalytics()
        if settings.memoryProviderCatalogAutoUpdate {
            rescanMemorySources(showMessage: false)
            return
        }
        if settings.memoryDetectedProviderIDs.isEmpty && settings.memoryDetectedSourceFolderIDs.isEmpty {
            rescanMemorySources(showMessage: false)
            return
        }
        hydrateMemorySourcesFromSavedSettings()
        normalizeMemoryBrowserSelections()
        refreshMemoryBrowser()
    }

    private func refreshConversationContextDetails() {
        let details = promptRewriteConversationStore.contextDetails(
            timeoutMinutes: settings.promptRewriteConversationTimeoutMinutes
        )
        conversationContextDetails = details
        refreshConversationArchiveDiagnostics()
        sanitizePinnedConversationContextSelection()

        let normalizedInspectedID = inspectedConversationContextID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedInspectedID.isEmpty,
           !details.contains(where: { $0.id == normalizedInspectedID }) {
            inspectedConversationContextID = ""
            showConversationContextInspectSheet = false
            dismissConversationContextInspectorFullScreen()
        }

        if details.contains(where: { $0.id == selectedConversationContextID }) {
            syncContextOverrideSelections()
            return
        }

        if let first = details.first {
            selectedConversationContextID = first.id
        } else {
            selectedConversationContextID = ""
        }
        syncContextOverrideSelections()
    }

    private func refreshConversationPatternStats() {
        Task {
            let patterns = await ConversationMemoryPromotionService.shared.fetchPatternStats(limit: 300)
            await MainActor.run {
                conversationPatternStats = patterns
                let selectedKey = selectedConversationPatternKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedKey.isEmpty || !patterns.contains(where: { $0.patternKey == selectedKey }) {
                    selectedConversationPatternKey = patterns.first?.patternKey ?? ""
                }
            }
            let key = await MainActor.run {
                selectedConversationPatternKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !key.isEmpty {
                refreshConversationPatternOccurrences(patternKey: key)
            }
        }
    }

    private func refreshConversationPatternOccurrences(patternKey: String) {
        let normalizedKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            conversationPatternOccurrences = []
            return
        }

        Task {
            let occurrences = await ConversationMemoryPromotionService.shared.fetchPatternOccurrences(
                patternKey: normalizedKey,
                limit: 120
            )
            await MainActor.run {
                conversationPatternOccurrences = occurrences
            }
        }
    }

    private func markConversationPattern(_ patternKey: String, outcome: MemoryPatternOutcome) {
        let normalizedKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }

        Task {
            let succeeded = await ConversationMemoryPromotionService.shared.markPatternOutcome(
                patternKey: normalizedKey,
                outcome: outcome,
                trigger: .manualPin,
                reason: "Manually marked from AI Studio."
            )
            await MainActor.run {
                conversationActionMessage = succeeded
                    ? "Marked pattern as \(outcome.rawValue)."
                    : "Could not mark pattern outcome."
            }
            refreshConversationPatternStats()
        }
    }

    private func deleteConversationPattern(_ patternKey: String) {
        let normalizedKey = patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }

        Task {
            let succeeded = await ConversationMemoryPromotionService.shared.deletePattern(patternKey: normalizedKey)
            await MainActor.run {
                conversationActionMessage = succeeded
                    ? "Deleted long-term memory pattern."
                    : "Could not delete pattern."
            }
            refreshConversationPatternStats()
        }
    }

    private func purgeExpiredConversationPatterns() {
        Task {
            let result = await ConversationMemoryPromotionService.shared.purgeExpiredRetention()
            await MainActor.run {
                conversationActionMessage = "Retention purge removed \(result.cardsDeleted) cards, \(result.lessonsDeleted) lessons, \(result.patternsDeleted) patterns, \(result.occurrencesDeleted) occurrences."
            }
            refreshConversationPatternStats()
        }
    }

    private func sanitizePinnedConversationContextSelection() {
        let pinned = settings.promptRewriteConversationPinnedContextID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinned.isEmpty else { return }
        if !promptRewriteConversationStore.hasContext(id: pinned) {
            settings.promptRewriteConversationPinnedContextID = ""
        }
    }

    private func startNewPromptRewriteConversation() {
        let pinned = settings.promptRewriteConversationPinnedContextID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty, promptRewriteConversationStore.hasContext(id: pinned) {
            promptRewriteConversationStore.clearContext(id: pinned)
            settings.promptRewriteConversationPinnedContextID = ""
            conversationActionMessage = "Started a new conversation by clearing the pinned context."
            refreshConversationContextDetails()
            return
        }

        let fallbackApp = NSWorkspace.shared.frontmostApplication
        let context = PromptRewriteConversationContextResolver.captureCurrentContext(
            fallbackApp: fallbackApp
        )
        promptRewriteConversationStore.clearContext(id: context.id)
        conversationActionMessage = "Started a new conversation for the current app/screen context."
        refreshConversationContextDetails()
    }

    private func openConversationContextInspector(for id: String) {
        selectedConversationContextID = id
        inspectedConversationContextID = id
        showConversationContextInspectSheet = true

        if let detail = conversationContextDetails.first(where: { $0.id == id }) {
            conversationActionMessage = "Inspecting context \(detail.context.displayName)."
        } else {
            conversationActionMessage = "Inspecting context \(id)."
        }
    }

    private func openConversationContextInspectorFullScreen(for id: String) {
        selectedConversationContextID = id
        inspectedConversationContextID = id
        showConversationContextInspectSheet = false

        let hostWindow = aiStudioWindowReference.window
        let windowWasAlreadyFullscreen = hostWindow?.styleMask.contains(.fullScreen) ?? false
        shouldRestoreAIMemoryStudioWindowAfterFullscreenInspector = hostWindow != nil && !windowWasAlreadyFullscreen
        showConversationContextInspectFullscreen = true

        if let hostWindow, !windowWasAlreadyFullscreen {
            hostWindow.toggleFullScreen(nil)
        }

        if let detail = conversationContextDetails.first(where: { $0.id == id }) {
            conversationActionMessage = "Opened full-screen inspector for \(detail.context.displayName)."
        } else {
            conversationActionMessage = "Opened full-screen inspector for \(id)."
        }
    }

    private func closeConversationContextInspectorFullScreen() {
        dismissConversationContextInspectorFullScreen()
    }

    private func compactConversationContext(id: String) {
        guard let report = promptRewriteConversationStore.compactContext(
            id: id,
            keepRecentTurns: settings.promptRewriteConversationTurnLimit
        ) else {
            conversationActionMessage = "No older turns were available to compact for this context."
            refreshConversationContextDetails()
            return
        }

        conversationActionMessage = "Compacted \(report.compactedTurnCount) turn(s) in context \(report.contextID). Turns: \(report.previousTurnCount) -> \(report.newTurnCount)."
        selectedConversationContextID = id
        refreshConversationContextDetails()
    }

    private func compactAllConversationContexts() {
        let reports = promptRewriteConversationStore.compactAllContexts(
            keepRecentTurns: settings.promptRewriteConversationTurnLimit
        )
        guard !reports.isEmpty else {
            conversationActionMessage = "No contexts needed compaction."
            refreshConversationContextDetails()
            return
        }

        let compactedTurns = reports.reduce(0) { $0 + $1.compactedTurnCount }
        conversationActionMessage = "Compacted \(compactedTurns) turn(s) across \(reports.count) context(s)."
        refreshConversationContextDetails()
    }

    private func clearConversationContext(id: String) {
        promptRewriteConversationStore.clearContext(id: id)
        if settings.promptRewriteConversationPinnedContextID == id {
            settings.promptRewriteConversationPinnedContextID = ""
        }
        if inspectedConversationContextID == id {
            inspectedConversationContextID = ""
            showConversationContextInspectSheet = false
            dismissConversationContextInspectorFullScreen()
        }
        conversationActionMessage = "Cleared conversation context \(id)."
        refreshConversationContextDetails()
    }

    private var contextOverrideContextOptions: [PromptRewriteConversationContextDetail] {
        conversationContextDetails.sorted { lhs, rhs in
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private var canCreateContextOverride: Bool {
        guard let source = contextOverrideContextOptions.first(where: { $0.id == contextOverrideSourceContextID }),
              let target = contextOverrideContextOptions.first(where: { $0.id == contextOverrideTargetContextID }),
              source.id != target.id else {
            return false
        }
        let mappingType: ConversationDisambiguationRuleType = contextOverrideAxisRawValue == "person" ? .person : .project
        let sourceKey = normalizedContextOverrideKey(contextOverrideKey(for: source.context, type: mappingType))
        let targetKey = normalizedContextOverrideKey(contextOverrideKey(for: target.context, type: mappingType))
        let sourceBundle = normalizedContextOverrideKey(source.context.bundleIdentifier)
        let targetBundle = normalizedContextOverrideKey(target.context.bundleIdentifier)
        guard !sourceKey.isEmpty, !targetKey.isEmpty, !sourceBundle.isEmpty, !targetBundle.isEmpty else {
            return false
        }
        return true
    }

    private func clearInspectedConversationContextIfNeeded() {
        if !showConversationContextInspectSheet && !showConversationContextInspectFullscreen {
            inspectedConversationContextID = ""
        }
    }

    private func dismissConversationContextInspectorFullScreen() {
        let wasPresented = showConversationContextInspectFullscreen
        showConversationContextInspectFullscreen = false

        guard wasPresented else { return }
        DispatchQueue.main.async {
            handleConversationContextFullscreenDismissed()
        }
    }

    private func handleConversationContextFullscreenDismissed() {
        let shouldRestoreWindow = shouldRestoreAIMemoryStudioWindowAfterFullscreenInspector
        shouldRestoreAIMemoryStudioWindowAfterFullscreenInspector = false

        guard shouldRestoreWindow,
              let hostWindow = aiStudioWindowReference.window,
              hostWindow.styleMask.contains(.fullScreen) else {
            aiStudioWindowReference.window?.makeKeyAndOrderFront(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            hostWindow.toggleFullScreen(nil)
            hostWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func syncContextOverrideSelections() {
        let options = contextOverrideContextOptions
        guard !options.isEmpty else {
            contextOverrideSourceContextID = ""
            contextOverrideTargetContextID = ""
            return
        }

        if !options.contains(where: { $0.id == contextOverrideSourceContextID }) {
            contextOverrideSourceContextID = options[0].id
        }

        if !options.contains(where: { $0.id == contextOverrideTargetContextID }) || contextOverrideTargetContextID == contextOverrideSourceContextID {
            contextOverrideTargetContextID = options.first(where: { $0.id != contextOverrideSourceContextID })?.id ?? options[0].id
        }
    }

    @MainActor
    private func createContextOverride() {
        guard !isContextOverrideSaving else { return }
        guard let source = contextOverrideContextOptions.first(where: { $0.id == contextOverrideSourceContextID }),
              let target = contextOverrideContextOptions.first(where: { $0.id == contextOverrideTargetContextID }),
              source.id != target.id else {
            conversationActionMessage = "Choose two different contexts to create an override."
            return
        }

        let mappingType: ConversationDisambiguationRuleType = contextOverrideAxisRawValue == "person" ? .person : .project
        let decision: ConversationDisambiguationDecision =
            normalizeContextMappingDecision(contextOverrideDecisionRawValue) == "linked" ? .link : .separate

        let sourceKey = normalizedContextOverrideKey(contextOverrideKey(for: source.context, type: mappingType))
        let targetKey = normalizedContextOverrideKey(contextOverrideKey(for: target.context, type: mappingType))
        let sourceBundle = normalizedContextOverrideKey(source.context.bundleIdentifier)
        let targetBundle = normalizedContextOverrideKey(target.context.bundleIdentifier)

        guard !sourceKey.isEmpty, !targetKey.isEmpty, !sourceBundle.isEmpty, !targetBundle.isEmpty else {
            conversationActionMessage = "Selected contexts are missing required project/person metadata."
            return
        }

        let appPairKey = contextOverrideAppPairKey(sourceBundle, targetBundle)
        guard !appPairKey.isEmpty else {
            conversationActionMessage = "Could not derive app pair for the selected contexts."
            return
        }

        let subjectKey = normalizedContextOverrideLabel(
            contextOverrideSubjectLabel(for: source.context, type: mappingType),
            fallbackKey: sourceKey
        )
        guard !subjectKey.isEmpty else {
            conversationActionMessage = "Could not derive subject key for this override."
            return
        }

        // Mark saving as in progress on the main actor
        isContextOverrideSaving = true

        let shouldCreateAlias = (decision == .link && sourceKey != targetKey)
        let aliasType = mappingType == .project ? "project" : "identity"
        let axisLabel = mappingType == .project ? "project" : "person"
        let statusMessage = "Created \(axisLabel) override (\(decision == .link ? "linked" : "separate"))."
        let canonicalKey = (decision == .link ? targetKey : nil)

        Task.detached { [promptRewriteConversationStore] in
            // Perform the potentially blocking persistence work off the main actor
            await promptRewriteConversationStore.upsertContextMappingDecision(
                mappingType: mappingType,
                appPairKey: appPairKey,
                subjectKey: subjectKey,
                contextScopeKey: targetKey,
                decision: decision,
                canonicalKey: canonicalKey,
                source: .manual
            )

            if shouldCreateAlias {
                _ = Self.persistContextTagAlias(
                    aliasType: aliasType,
                    aliasKey: sourceKey,
                    canonicalKey: targetKey
                )
            }

            // Once persistence is complete, update UI-related state on the main actor
            await MainActor.run {
                isContextOverrideSaving = false
                conversationActionMessage = statusMessage
                loadContextMappings(showStatusMessage: false)
            }
        }
    }

    private func contextOverrideKey(
        for context: PromptRewriteConversationContext,
        type: ConversationDisambiguationRuleType
    ) -> String {
        switch type {
        case .project:
            return context.projectKey ?? ""
        case .person:
            return context.identityKey ?? ""
        }
    }

    private func contextOverrideSubjectLabel(
        for context: PromptRewriteConversationContext,
        type: ConversationDisambiguationRuleType
    ) -> String {
        switch type {
        case .project:
            return context.projectLabel ?? ""
        case .person:
            return context.identityLabel ?? ""
        }
    }

    private func contextMappingDecisionBinding(for rowID: String) -> Binding<String> {
        Binding(
            get: {
                contextMappingRows.first(where: { $0.id == rowID })?.normalizedDecisionValue ?? "separate"
            },
            set: { updatedDecision in
                Task { @MainActor in
                    await Task.yield()
                    updateContextMappingDecision(for: rowID, decisionRawValue: updatedDecision)
                }
            }
        )
    }

    @MainActor
    private func loadContextMappings(showStatusMessage: Bool) {
        isContextMappingsLoading = true
        let requestToken = UUID()
        contextMappingsLoadRequestToken = requestToken

        Task {
            let rows = await Task.detached(priority: .userInitiated) {
                Self.fetchContextMappingRowsForDisplay(limit: 400)
            }.value

            guard contextMappingsLoadRequestToken == requestToken else { return }

            contextMappingRows = rows
            isContextMappingsLoading = false
            if showStatusMessage {
                conversationActionMessage = rows.isEmpty
                    ? "No context overrides found."
                    : "Loaded \(rows.count) context override(s)."
            }
        }
    }

    @MainActor
    private func updateContextMappingDecision(for rowID: String, decisionRawValue: String) {
        guard contextMappingMutatingRowID == nil else { return }
        guard let index = contextMappingRows.firstIndex(where: { $0.id == rowID }) else {
            return
        }

        let previous = contextMappingRows[index]
        let normalizedDecision = normalizeContextMappingDecision(decisionRawValue)
        guard previous.normalizedDecisionValue != normalizedDecision else { return }

        contextMappingRows[index].decisionRawValue = normalizedDecision
        contextMappingMutatingRowID = rowID

        guard let mappingType = previous.mappingRuleType else {
            if let rollbackIndex = contextMappingRows.firstIndex(where: { $0.id == rowID }) {
                contextMappingRows[rollbackIndex].decisionRawValue = previous.decisionRawValue
            }
            contextMappingMutatingRowID = nil
            conversationActionMessage = "Alias mappings are fixed to linked."
            return
        }

        let normalizedCanonicalKey = previous.canonicalKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if previous.normalizedDecisionValue == "separate",
           normalizedDecision == "linked",
           normalizedCanonicalKey.isEmpty {
            if let rollbackIndex = contextMappingRows.firstIndex(where: { $0.id == rowID }) {
                contextMappingRows[rollbackIndex].decisionRawValue = previous.decisionRawValue
            }
            contextMappingMutatingRowID = nil
            conversationActionMessage = "Cannot switch to linked without a canonical target."
            return
        }

        let decision: ConversationDisambiguationDecision = normalizedDecision == "linked" ? .link : .separate
        Task {
            let didPersist = await Task.detached(priority: .userInitiated) {
                Self.persistContextMappingDecision(
                    rowID: previous.id,
                    mappingType: mappingType,
                    appPairKey: previous.appPairKey,
                    subjectKey: previous.subjectKey,
                    contextScopeKey: previous.contextScopeKey,
                    decision: decision,
                    canonicalKey: previous.canonicalKey
                )
            }.value

            guard let rollbackIndex = contextMappingRows.firstIndex(where: { $0.id == rowID }) else {
                contextMappingMutatingRowID = nil
                return
            }

            guard didPersist else {
                contextMappingRows[rollbackIndex].decisionRawValue = previous.decisionRawValue
                contextMappingMutatingRowID = nil
                conversationActionMessage = "Failed to update mapping decision."
                return
            }

            lastContextMappingMutation = ContextMappingMutation(
                kind: .decisionChange,
                snapshot: previous
            )
            contextMappingMutatingRowID = nil
            conversationActionMessage = "Updated mapping decision to \(normalizedDecision == "linked" ? "linked" : "separate")."
            loadContextMappings(showStatusMessage: false)
        }
    }

    private func removeContextMapping(_ rowID: String) {
        guard let row = contextMappingRows.first(where: { $0.id == rowID }) else { return }
        contextMappingMutatingRowID = rowID

        promptRewriteConversationStore.removeContextMapping(id: row.id)
        lastContextMappingMutation = ContextMappingMutation(
            kind: .remove,
            snapshot: row
        )
        contextMappingMutatingRowID = nil
        conversationActionMessage = "Removed context mapping."
        loadContextMappings(showStatusMessage: false)
    }

    private func undoLastContextMappingMutation() {
        guard let mutation = lastContextMappingMutation else { return }
        contextMappingMutatingRowID = mutation.snapshot.id

        guard let mappingType = mutation.snapshot.mappingRuleType else {
            contextMappingMutatingRowID = nil
            conversationActionMessage = "Undo is only available for project/person mappings."
            return
        }

        promptRewriteConversationStore.upsertContextMappingDecision(
            mappingType: mappingType,
            appPairKey: mutation.snapshot.appPairKey,
            subjectKey: mutation.snapshot.subjectKey,
            contextScopeKey: mutation.snapshot.contextScopeKey,
            decision: mutation.snapshot.normalizedDecision,
            canonicalKey: mutation.snapshot.canonicalKey,
            source: mutation.snapshot.source
        )
        contextMappingMutatingRowID = nil
        lastContextMappingMutation = nil
        conversationActionMessage = "Undid recent context mapping change."
        loadContextMappings(showStatusMessage: false)
    }

    nonisolated private static func fetchContextMappingRowsForDisplay(limit: Int = 400) -> [ContextMappingRow] {
        guard let store = try? MemorySQLiteStore() else {
            return []
        }

        let normalizedLimit = max(1, min(limit, 2_000))
        let rules = (try? store.fetchConversationDisambiguationRules(limit: normalizedLimit)) ?? []
        let aliases = (try? store.fetchConversationTagAliases(limit: normalizedLimit)) ?? []

        var rows = rules.map { rule in
            contextMappingRow(from: ConversationContextMappingRow(
                id: rule.id,
                mappingType: rule.ruleType.rawValue,
                appPairKey: rule.appPairKey,
                subjectKey: rule.subjectKey,
                contextScopeKey: rule.contextScopeKey,
                decision: rule.decision,
                canonicalKey: rule.canonicalKey,
                source: contextMappingSource(forRuleID: rule.id),
                updatedAt: rule.updatedAt
            ))
        }

        rows.append(contentsOf: aliases.map { alias in
            contextMappingRow(from: ConversationContextMappingRow(
                id: tagAliasMappingID(aliasType: alias.aliasType, aliasKey: alias.aliasKey),
                mappingType: "alias:\(alias.aliasType)",
                appPairKey: "global",
                subjectKey: alias.aliasKey,
                contextScopeKey: nil,
                decision: .link,
                canonicalKey: alias.canonicalKey,
                source: .legacy,
                updatedAt: alias.updatedAt
            ))
        })

        rows.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
        if rows.count > normalizedLimit {
            rows = Array(rows.prefix(normalizedLimit))
        }
        return rows
    }

    nonisolated private static func persistContextMappingDecision(
        rowID: String,
        mappingType: ConversationDisambiguationRuleType,
        appPairKey: String,
        subjectKey: String,
        contextScopeKey: String?,
        decision: ConversationDisambiguationDecision,
        canonicalKey: String?
    ) -> Bool {
        guard let store = try? MemorySQLiteStore() else {
            return false
        }

        let existing = try? store.fetchConversationDisambiguationRule(
            ruleType: mappingType,
            appPairKey: appPairKey,
            subjectKey: subjectKey,
            contextScopeKey: contextScopeKey
        )
        if let existing,
           existing.id.caseInsensitiveCompare(rowID) != .orderedSame {
            try? store.deleteConversationDisambiguationRule(id: existing.id)
        }

        let canonicalForWrite: String?
        if decision == .link {
            let normalized = canonicalKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            canonicalForWrite = normalized.isEmpty ? nil : normalized
        } else {
            canonicalForWrite = nil
        }

        let now = Date()
        let record = ConversationDisambiguationRuleRecord(
            id: rowID,
            ruleType: mappingType,
            appPairKey: appPairKey,
            subjectKey: subjectKey,
            contextScopeKey: contextScopeKey,
            decision: decision,
            canonicalKey: canonicalForWrite,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        do {
            try store.upsertConversationDisambiguationRule(record)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func contextMappingSource(forRuleID ruleID: String) -> ConversationContextMappingSource {
        let normalizedID = ruleID.lowercased()
        if normalizedID.hasPrefix("map-manual-") {
            return .manual
        }
        if normalizedID.hasPrefix("map-ai-") {
            return .ai
        }
        if normalizedID.hasPrefix("map-deterministic-") {
            return .deterministic
        }
        return .legacy
    }

    nonisolated private static func tagAliasMappingID(aliasType: String, aliasKey: String) -> String {
        let encodedAliasType = Data(aliasType.utf8).base64EncodedString()
        let encodedAliasKey = Data(aliasKey.utf8).base64EncodedString()
        return "tag-alias|\(encodedAliasType)|\(encodedAliasKey)"
    }

    nonisolated private static func contextMappingRow(from rawMapping: ConversationContextMappingRow) -> ContextMappingRow {
        ContextMappingRow(
            id: rawMapping.id,
            mappingTypeRawValue: rawMapping.mappingType,
            appPairKey: rawMapping.appPairKey,
            subjectLabel: "",
            subjectKey: rawMapping.subjectKey,
            contextScopeKey: rawMapping.contextScopeKey,
            canonicalKey: rawMapping.canonicalKey,
            decisionRawValue: rawMapping.decision.rawValue,
            source: rawMapping.source,
            updatedAt: rawMapping.updatedAt
        )
    }

    private func normalizeContextMappingDecision(_ rawValue: String) -> String {
        let lowered = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "link" || lowered == "linked" {
            return "linked"
        }
        return "separate"
    }

    private func contextOverrideAppPairKey(_ lhs: String, _ rhs: String) -> String {
        let candidates = [lhs, rhs]
            .map(normalizedContextOverrideKey)
            .filter { !$0.isEmpty }
            .sorted()
        if candidates.count >= 2 {
            return "\(candidates[0])|\(candidates[1])"
        }
        return candidates.first ?? ""
    }

    private func normalizedContextOverrideLabel(_ label: String, fallbackKey: String) -> String {
        let fromLabel = normalizedContextOverrideLabelValue(label)
        if !fromLabel.isEmpty {
            return fromLabel
        }
        let split = fallbackKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let fallback = split.count == 2 ? String(split[1]) : fallbackKey
        let readable = fallback
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return normalizedContextOverrideLabelValue(readable)
    }

    private func normalizedContextOverrideLabelValue(_ value: String) -> String {
        let collapsed = collapsedWhitespaceForContextOverride(value).lowercased()
        guard !collapsed.isEmpty else {
            return ""
        }
        let alphanumericOnly = collapsed.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedWhitespaceForContextOverride(alphanumericOnly)
    }

    private func normalizedContextOverrideKey(_ value: String) -> String {
        collapsedWhitespaceForContextOverride(value).lowercased()
    }

    private func collapsedWhitespaceForContextOverride(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func persistContextTagAlias(
        aliasType: String,
        aliasKey: String,
        canonicalKey: String
    ) -> Bool {
        guard let store = try? MemorySQLiteStore() else {
            return false
        }
        do {
            try store.upsertConversationTagAlias(
                aliasType: aliasType,
                aliasKey: aliasKey,
                canonicalKey: canonicalKey
            )
            return true
        } catch {
            return false
        }
    }

    private func sanitizeSelectedStudioPage() {
        let allValid = availableStudioPages + assistantStudioPages
        if !allValid.contains(selectedStudioPage) {
            selectedStudioPage = .dashboard
        }
    }

    private func connectOAuth(for mode: PromptRewriteProviderMode) {
        guard mode.supportsOAuthSignIn else { return }
        oauthBusyProviderRawValue = mode.rawValue
        oauthStatusMessage = "Starting \(mode.displayName) OAuth sign-in..."

        Task {
            do {
                switch mode {
                case .openAI:
                    let context = try await PromptRewriteProviderOAuthService.shared.beginOpenAIDeviceAuthorization()
                    await MainActor.run {
                        openAIDeviceUserCode = context.userCode
                        openAIDeviceVerificationURL = context.verificationURL
                        copyToPasteboard(context.userCode)
                        oauthStatusMessage = "Enter code \(context.userCode) on the OpenAI page. Code copied to clipboard."
                        _ = NSWorkspace.shared.open(context.verificationURL)
                    }
                    _ = try await PromptRewriteProviderOAuthService.shared.completeOpenAIDeviceAuthorization(context)
                case .anthropic:
                    let context = try await PromptRewriteProviderOAuthService.shared.beginAnthropicAuthorization()
                    await MainActor.run {
                        _ = NSWorkspace.shared.open(context.authorizationURL)
                    }
                    guard let codeInput = await MainActor.run(body: {
                        presentOAuthCodePrompt(
                            providerName: mode.displayName,
                            instructions: context.instructions
                        )
                    }) else {
                        throw PromptRewriteProviderOAuthError.canceledByUser
                    }
                    _ = try await PromptRewriteProviderOAuthService.shared.completeAnthropicAuthorization(
                        context,
                        codeInput: codeInput
                    )
                case .google, .openRouter, .groq, .ollama:
                    throw PromptRewriteProviderOAuthError.unsupportedProvider
                }

                await MainActor.run {
                    oauthBusyProviderRawValue = nil
                    oauthStatusMessage = "\(mode.displayName) OAuth connected."
                    resetOpenAIDeviceCodeState()
                    refreshOAuthConnectionState()
                    refreshPromptRewriteModels(showMessage: true)
                }
            } catch {
                await MainActor.run {
                    oauthBusyProviderRawValue = nil
                    resetOpenAIDeviceCodeState()
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    oauthStatusMessage = detail.isEmpty
                        ? "\(mode.displayName) OAuth sign-in failed."
                        : "\(mode.displayName) OAuth sign-in failed: \(detail)"
                    refreshOAuthConnectionState()
                }
            }
        }
    }

    private func disconnectOAuth(for mode: PromptRewriteProviderMode) {
        settings.clearPromptRewriteOAuthSession(for: mode)
        resetOpenAIDeviceCodeState()
        refreshOAuthConnectionState()
        oauthStatusMessage = "\(mode.displayName) OAuth disconnected."
        refreshPromptRewriteModels(showMessage: true)
    }

    private func refreshOAuthConnectionState() {
        var next: [String: Bool] = [:]
        for mode in PromptRewriteProviderMode.allCases where mode.supportsOAuthSignIn {
            next[mode.rawValue] = settings.hasPromptRewriteOAuthSession(for: mode)
        }
        oauthConnectedProviders = next
    }

    private func handlePromptRewriteProviderChanged() {
        promptRewriteShowManualAPIKey = false
        oauthStatusMessage = nil
        promptRewriteModelStatusMessage = nil
        promptRewriteAvailableModels = []
        resetOpenAIDeviceCodeState()
        
        if settings.promptRewriteProviderMode == .ollama {
            localAISetupService.ensureRuntimeReadyForCurrentConfiguration()
        } else {
            localAISetupService.refreshStatus()
        }
        
        refreshPromptRewriteModels(showMessage: false)
    }

    private func refreshPromptRewriteModels(showMessage: Bool) {
        let mode = settings.promptRewriteProviderMode
        if mode == .openAI,
           settings.hasPromptRewriteOAuthSession(for: .openAI),
           !settings.hasPromptRewriteAPIKey(for: .openAI) {
            let normalizedBaseURL = settings.promptRewriteOpenAIBaseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let oauthDefaultBaseURL = PromptRewriteProviderMode.openAI.defaultBaseURL
            if normalizedBaseURL.caseInsensitiveCompare(oauthDefaultBaseURL) != .orderedSame {
                settings.promptRewriteOpenAIBaseURL = oauthDefaultBaseURL
            }

            let normalizedModel = settings.promptRewriteOpenAIModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !PromptRewriteModelCatalogService.isOpenAIOAuthCompatibleModelID(normalizedModel) {
                settings.promptRewriteOpenAIModel = PromptRewriteModelCatalogService.defaultOpenAIOAuthModelID
            }
        }

        let requestToken = UUID()
        let baseURL = settings.promptRewriteOpenAIBaseURL
        let apiKey = settings.promptRewriteOpenAIAPIKey

        promptRewriteModelRequestToken = requestToken
        promptRewriteModelsLoading = true
        if showMessage {
            promptRewriteModelStatusMessage = "Loading \(mode.displayName) models..."
        }

        Task {
            let result = await PromptRewriteModelCatalogService.shared.fetchModels(
                providerMode: mode,
                baseURL: baseURL,
                apiKey: apiKey
            )
            await MainActor.run {
                guard requestToken == promptRewriteModelRequestToken else { return }
                promptRewriteModelsLoading = false

                let currentModel = settings.promptRewriteOpenAIModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let currentModelExistsInCatalog = result.models.contains { option in
                    option.id.caseInsensitiveCompare(currentModel) == .orderedSame
                }
                if result.models.isEmpty, !currentModel.isEmpty {
                    promptRewriteAvailableModels = [
                        PromptRewriteModelOption(
                            id: currentModel,
                            displayName: currentModel
                        )
                    ]
                } else {
                    promptRewriteAvailableModels = result.models
                }

                let preferredDefaultModelID = result.models.first(where: { option in
                    option.id.caseInsensitiveCompare(mode.defaultModel) == .orderedSame
                })?.id

                if currentModel.isEmpty {
                    if let preferredDefaultModelID {
                        settings.promptRewriteOpenAIModel = preferredDefaultModelID
                    } else if let firstModel = result.models.first {
                        settings.promptRewriteOpenAIModel = firstModel.id
                    }
                } else if mode == .openAI,
                          settings.hasPromptRewriteOAuthSession(for: .openAI),
                          !settings.hasPromptRewriteAPIKey(for: .openAI),
                          (!currentModelExistsInCatalog
                           || !PromptRewriteModelCatalogService.isOpenAIOAuthCompatibleModelID(currentModel)) {
                    if let preferredModelID = PromptRewriteModelCatalogService.preferredOpenAIOAuthModelID(
                        in: result.models
                    ) {
                        settings.promptRewriteOpenAIModel = preferredModelID
                    } else if let firstModel = result.models.first {
                        settings.promptRewriteOpenAIModel = firstModel.id
                    }
                } else if !currentModel.isEmpty,
                          !currentModelExistsInCatalog,
                          let firstModel = result.models.first {
                    settings.promptRewriteOpenAIModel = preferredDefaultModelID ?? firstModel.id
                }

                if showMessage || result.source == .fallback {
                    promptRewriteModelStatusMessage = result.message
                } else if let resultMessage = result.message,
                          resultMessage.localizedCaseInsensitiveContains("loaded") {
                    promptRewriteModelStatusMessage = resultMessage
                }
            }
        }
    }

    private func presentOAuthCodePrompt(providerName: String, instructions: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 24))
        field.placeholderString = "Paste code or callback URL"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(providerName) OAuth Sign-In"
        alert.informativeText = "\(instructions)\nPaste the code (or callback URL) below."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        return value
    }

    private func hydrateMemorySourcesFromSavedSettings() {
        let providerLookup = Dictionary(
            uniqueKeysWithValues: memoryIndexingSettingsService.detectedProviders().map { ($0.id, $0) }
        )
        detectedMemoryProviders = settings.memoryDetectedProviderIDs.map { providerID in
            providerLookup[providerID] ?? MemoryIndexingSettingsService.Provider(
                id: providerID,
                name: providerDisplayName(from: providerID),
                detail: "Previously detected provider.",
                sourceCount: 0
            )
        }

        detectedMemorySourceFolders = settings.memoryDetectedSourceFolderIDs.map { folderPath in
            let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            let fallbackName = folderURL.lastPathComponent.isEmpty ? folderPath : folderURL.lastPathComponent
            return MemoryIndexingSettingsService.SourceFolder(
                id: folderPath,
                name: fallbackName,
                path: folderPath,
                providerID: inferredProviderID(forFolderPath: folderPath)
            )
        }
    }

    private func resetOpenAIDeviceCodeState() {
        openAIDeviceUserCode = nil
        openAIDeviceVerificationURL = nil
    }

    private func copyToPasteboard(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func inferredProviderID(forFolderPath folderPath: String) -> String {
        let normalizedPath = folderPath.lowercased()
        let candidates = Array(
            Set(settings.memoryDetectedProviderIDs + detectedMemoryProviders.map(\.id))
        )
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .sorted()

        if let directMatch = candidates.first(where: { normalizedPath.contains($0) }) {
            return directMatch
        }

        if normalizedPath.contains("codex") { return MemoryProviderKind.codex.rawValue }
        if normalizedPath.contains("opencode") { return MemoryProviderKind.opencode.rawValue }
        if normalizedPath.contains("claude") || normalizedPath.contains("claw") { return MemoryProviderKind.claude.rawValue }
        if normalizedPath.contains("copilot") { return MemoryProviderKind.copilot.rawValue }
        if normalizedPath.contains("cursor") { return MemoryProviderKind.cursor.rawValue }
        if normalizedPath.contains("kimi") { return MemoryProviderKind.kimi.rawValue }
        if normalizedPath.contains("gemini") || normalizedPath.contains("gmini") { return MemoryProviderKind.gemini.rawValue }
        if normalizedPath.contains("windsurf") { return MemoryProviderKind.windsurf.rawValue }
        if normalizedPath.contains("codeium") { return MemoryProviderKind.codeium.rawValue }

        return MemoryProviderKind.unknown.rawValue
    }

    private func providerDisplayName(from providerID: String) -> String {
        providerID
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                let first = token.prefix(1).uppercased()
                let remainder = String(token.dropFirst())
                return first + remainder
            }
            .joined(separator: " ")
    }

    private var promptRewriteModelPickerOptions: [PromptRewriteModelOption] {
        let currentModel = settings.promptRewriteOpenAIModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var options = promptRewriteAvailableModels
        if !currentModel.isEmpty,
           !options.contains(where: { option in
               option.id.caseInsensitiveCompare(currentModel) == .orderedSame
           }) {
            options.insert(
                PromptRewriteModelOption(
                    id: currentModel,
                    displayName: "Current: \(currentModel)"
                ),
                at: 0
            )
        }
        return options
    }

    private var filteredMemoryProviders: [MemoryIndexingSettingsService.Provider] {
        var providers = detectedMemoryProviders
        if memoryShowSelectedProvidersOnly {
            providers = providers.filter { provider in
                settings.isMemoryProviderEnabled(provider.id)
            }
        }

        let query = normalizedMemoryFilter(memoryProviderFilterQuery)
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            matchesMemoryFilter(query, in: provider.name)
                || matchesMemoryFilter(query, in: provider.detail)
                || matchesMemoryFilter(query, in: provider.id)
        }
    }

    private var filteredMemorySourceFolders: [MemoryIndexingSettingsService.SourceFolder] {
        var folders = detectedMemorySourceFolders
        if memoryFoldersOnlyEnabledProviders {
            folders = folders.filter { folder in
                settings.isMemoryProviderEnabled(folder.providerID)
            }
        }
        if memoryShowSelectedFoldersOnly {
            folders = folders.filter { folder in
                settings.isMemorySourceFolderEnabled(folder.id)
            }
        }

        let query = normalizedMemoryFilter(memoryFolderFilterQuery)
        guard !query.isEmpty else { return folders }
        return folders.filter { folder in
            matchesMemoryFilter(query, in: folder.name)
                || matchesMemoryFilter(query, in: folder.path)
                || matchesMemoryFilter(query, in: providerDisplayName(from: folder.providerID))
                || matchesMemoryFilter(query, in: folder.providerID)
        }
    }

    private var memoryBrowserProviderOptions: [MemoryIndexingSettingsService.Provider] {
        detectedMemoryProviders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var memoryBrowserFolderOptions: [MemoryIndexingSettingsService.SourceFolder] {
        let providerID = normalizedMemoryBrowserProviderID
        return detectedMemorySourceFolders
            .filter { folder in
                guard let providerID else { return true }
                return folder.providerID == providerID
            }
            .sorted { lhs, rhs in
                if lhs.providerID != rhs.providerID {
                    return lhs.providerID.localizedCaseInsensitiveCompare(rhs.providerID) == .orderedAscending
                }
                if lhs.name != rhs.name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
    }

    private var normalizedMemoryBrowserProviderID: String? {
        let trimmedProviderID = memoryBrowserSelectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, trimmedProviderID != "all" else {
            return nil
        }
        return trimmedProviderID
    }

    private var normalizedMemoryBrowserFolderID: String? {
        let trimmedFolderID = memoryBrowserSelectedFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolderID.isEmpty, trimmedFolderID != "all" else {
            return nil
        }
        return trimmedFolderID
    }

    private func normalizeMemoryBrowserSelections() {
        let providerIDs = Set(memoryBrowserProviderOptions.map(\.id))
        let selectedProviderID = memoryBrowserSelectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedProviderID != "all", !providerIDs.contains(selectedProviderID) {
            memoryBrowserSelectedProviderID = "all"
        }

        let folderIDs = Set(memoryBrowserFolderOptions.map(\.id))
        let selectedFolderID = memoryBrowserSelectedFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedFolderID != "all", !folderIDs.contains(selectedFolderID) {
            memoryBrowserSelectedFolderID = "all"
        }
    }

    private func scheduleMemoryBrowserRefresh(delay: TimeInterval = 0.12) {
        memoryBrowserRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            refreshMemoryBrowser()
            memoryBrowserRefreshWorkItem = nil
        }
        memoryBrowserRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func refreshMemoryBrowser() {
        memoryBrowserRefreshWorkItem?.cancel()
        memoryBrowserRefreshWorkItem = nil

        let entries = memoryIndexingSettingsService.browseIndexedMemories(
            query: memoryBrowserQuery,
            providerID: normalizedMemoryBrowserProviderID,
            sourceFolderID: normalizedMemoryBrowserFolderID,
            includePlanContent: memoryBrowserIncludePlanContent,
            limit: 200
        )
        memoryBrowserUnfilteredEntryCount = entries.count
        if memoryBrowserHighSignalOnly {
            memoryBrowserEntries = entries.filter(isHighSignalMemoryEntry)
        } else {
            memoryBrowserEntries = entries
        }

        if let selectedMemoryBrowserEntry,
           let updatedSelection = memoryBrowserEntries.first(where: { $0.id == selectedMemoryBrowserEntry.id }) {
            self.selectedMemoryBrowserEntry = updatedSelection
            refreshMemoryDetailContext(for: updatedSelection)
        } else {
            selectedMemoryBrowserEntry = memoryBrowserEntries.first
            if let first = memoryBrowserEntries.first {
                refreshMemoryDetailContext(for: first)
            } else {
                relatedMemoryEntries = []
                relatedMemoryEntriesHiddenCount = 0
                issueTimelineEntries = []
                issueTimelineEntriesHiddenCount = 0
            }
        }
    }

    private func selectMemoryBrowserEntry(_ entry: MemoryIndexedEntry) {
        selectedMemoryBrowserEntry = entry
        memoryInspectionExplanation = nil
        memoryInspectionStatusMessage = nil
        refreshMemoryDetailContext(for: entry)
    }

    private func refreshMemoryDetailContext(for entry: MemoryIndexedEntry) {
        let relatedEntries = memoryIndexingSettingsService.browseRelatedMemories(
            forCardID: entry.id,
            includePlanContent: memoryBrowserIncludePlanContent,
            limit: 8
        )
        if memoryDetailShowLowSignal {
            relatedMemoryEntries = relatedEntries
            relatedMemoryEntriesHiddenCount = 0
        } else {
            relatedMemoryEntries = relatedEntries.filter(isHighSignalMemoryEntry)
            relatedMemoryEntriesHiddenCount = max(0, relatedEntries.count - relatedMemoryEntries.count)
        }

        if let issueKey = entry.issueKey, !issueKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let timelineEntries = memoryIndexingSettingsService.browseIssueTimeline(
                issueKey: issueKey,
                providerID: entry.provider.rawValue,
                includePlanContent: memoryBrowserIncludePlanContent,
                limit: 24
            )
            if memoryDetailShowLowSignal {
                issueTimelineEntries = timelineEntries
                issueTimelineEntriesHiddenCount = 0
            } else {
                issueTimelineEntries = timelineEntries.filter(isHighSignalMemoryEntry)
                issueTimelineEntriesHiddenCount = max(0, timelineEntries.count - issueTimelineEntries.count)
            }
        } else {
            issueTimelineEntries = []
            issueTimelineEntriesHiddenCount = 0
        }
    }

    private func explainMemoryEntryWithAI(_ entry: MemoryIndexedEntry) {
        guard !isMemoryInspectionBusy else { return }
        isMemoryInspectionBusy = true
        memoryInspectionStatusMessage = "Asking \(settings.promptRewriteProviderMode.displayName) to explain this memory..."
        memoryInspectionExplanation = nil

        Task {
            let result = await MemoryEntryExplanationService.shared.explain(
                entry: entry,
                onPartialText: { partialText in
                    Task { @MainActor in
                        let normalized = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else { return }
                        memoryInspectionStatusMessage = "Streaming AI explanation..."
                        memoryInspectionExplanation = normalized
                    }
                }
            )
            await MainActor.run {
                isMemoryInspectionBusy = false
                switch result {
                case .success(let explanation):
                    memoryInspectionStatusMessage = "AI explanation ready."
                    memoryInspectionExplanation = explanation
                case .failure(let message):
                    memoryInspectionStatusMessage = message
                    memoryInspectionExplanation = nil
                }
            }
        }
    }

    private func isHighSignalMemoryEntry(_ entry: MemoryIndexedEntry) -> Bool {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == "workspace" || title == "storage" || title == "state" {
            return false
        }

        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedLower = "\(entry.title) \(entry.summary) \(entry.detail)".lowercased()
        if containsRewriteSignal(combinedLower) {
            return true
        }
        let rewriteNeedles = ["rewrite", "prompt fix", "corrected prompt", "suggested", "improved prompt", "correction"]
        if rewriteNeedles.contains(where: combinedLower.contains) {
            return true
        }
        let outcomeStatus = entry.outcomeStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let validationState = entry.validationState?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let outcomeEvidence = entry.outcomeEvidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fixSummary = entry.fixSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let issueKey = entry.issueKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasEvidence = !outcomeEvidence.isEmpty || !fixSummary.isEmpty
        let hasIssueContext = hasMeaningfulIssueKey(issueKey)

        if (outcomeStatus == "responded" || outcomeStatus == "attempted"),
           validationState == "unvalidated",
           !hasEvidence,
           !hasIssueContext {
            return false
        }
        if validationState == "unvalidated",
           !hasEvidence,
           !hasIssueContext,
           (entry.attemptNumber ?? 0) <= 1 {
            return false
        }

        if detail.hasPrefix("{") && detail.hasSuffix("}") {
            if !detail.contains("->"),
               !detail.localizedCaseInsensitiveContains("prompt"),
               !detail.localizedCaseInsensitiveContains("rewrite"),
               !detail.localizedCaseInsensitiveContains("response") {
                return false
            }
        }

        let combined = "\(entry.summary) \(entry.detail)"
        let alphaWords = combined.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains(where: \.isLetter)
        }
        return alphaWords.count >= 5
    }

    private func containsRewriteSignal(_ value: String) -> Bool {
        let lower = value.lowercased()
        let rewriteSignals = ["->", "=>", "→", "rewrite", "prompt fix", "correction", "suggested"]
        return rewriteSignals.contains(where: lower.contains)
    }

    private func hasMeaningfulIssueKey(_ issueKey: String) -> Bool {
        let normalized = issueKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized != "issue-hi"
            && normalized != "issue-hello"
            && normalized != "issue-hey"
    }

    private struct ConversationArchiveDiagnosticsSnapshot {
        let expiredCount: Int
        let lastSummaryMethod: String
        let lastPromotionDecisionSummary: String

        static let empty = ConversationArchiveDiagnosticsSnapshot(
            expiredCount: 0,
            lastSummaryMethod: "fallback",
            lastPromotionDecisionSummary: "No promotion decision yet."
        )
    }

    private func refreshConversationArchiveDiagnostics() {
        let snapshot = loadConversationArchiveDiagnosticsSnapshot()
        expiredConversationHandoffCount = snapshot.expiredCount
        lastConversationHandoffSummaryMethod = snapshot.lastSummaryMethod
        lastConversationPromotionDecisionSummary = snapshot.lastPromotionDecisionSummary
    }

    private func loadConversationArchiveDiagnosticsSnapshot() -> ConversationArchiveDiagnosticsSnapshot {
        do {
            let store = try MemorySQLiteStore()
            let diagnostics = try store.fetchExpiredConversationContextDiagnostics()
            return ConversationArchiveDiagnosticsSnapshot(
                expiredCount: max(0, diagnostics.totalCount),
                lastSummaryMethod: diagnostics.lastSummaryMethod.rawValue,
                lastPromotionDecisionSummary: diagnostics.lastPromotionDecisionSummary
            )
        } catch {
            return .empty
        }
    }

    private func purgeExpiredConversationContextArchiveMaintenance() -> (
        expiredDeleted: Int,
        retentionDeleted: Int,
        rowLimitDeleted: Int,
        rawSizeDeleted: Int
    )? {
        do {
            let store = try MemorySQLiteStore()
            return try store.purgeExpiredConversationContextArchive()
        } catch {
            return nil
        }
    }

    private func runQualityMaintenance() {
        let result = memoryIndexingSettingsService.runQualityMaintenance()
        let archivePurgeResult = purgeExpiredConversationContextArchiveMaintenance()
        let archiveDeletedCount = (archivePurgeResult?.expiredDeleted ?? 0)
            + (archivePurgeResult?.retentionDeleted ?? 0)
            + (archivePurgeResult?.rowLimitDeleted ?? 0)
            + (archivePurgeResult?.rawSizeDeleted ?? 0)

        var message = result.message
        if let archivePurgeResult {
            message += " Expired handoff archive purge: deleted \(archivePurgeResult.expiredDeleted) expired, \(archivePurgeResult.retentionDeleted) by retention, \(archivePurgeResult.rowLimitDeleted) by row cap, \(archivePurgeResult.rawSizeDeleted) by raw-byte cap."
        }
        memoryActionMessage = message

        refreshConversationArchiveDiagnostics()
        if result.didRun || archiveDeletedCount > 0 {
            refreshMemoryBrowser()
            refreshMemoryAnalytics()
        }
    }

    private func setMemoryProvidersEnabled(_ providers: [MemoryIndexingSettingsService.Provider], enabled: Bool) {
        for provider in providers {
            settings.setMemoryProviderEnabled(provider.id, enabled: enabled)
        }
    }

    private func setMemorySourceFoldersEnabled(_ folders: [MemoryIndexingSettingsService.SourceFolder], enabled: Bool) {
        for folder in folders {
            settings.setMemorySourceFolderEnabled(folder.id, enabled: enabled)
        }
    }

    private func normalizedMemoryFilter(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func refreshMemoryAnalytics() {
        memoryAnalytics = memoryIndexingSettingsService.fetchMemoryAnalytics(limit: 2000)
    }

    private func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formattedConversationContextPayload(for id: String) -> (text: String, isJSON: Bool) {
        let rawPayload = promptRewriteConversationStore.serializedContextJSON(id: id) ?? "{}"

        if let formatted = prettyPrintedJSON(rawPayload) {
            return (formatted, true)
        }

        let unescapedPayload = presentableMemoryText(rawPayload)
        if unescapedPayload != rawPayload,
           let formatted = prettyPrintedJSON(unescapedPayload) {
            return (formatted, true)
        }

        return (unescapedPayload, false)
    }

    private func prettyPrintedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let prettyText = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return prettyText
    }

    private func presentableMemoryText(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: "\\r\\n", with: "\n")
        value = value.replacingOccurrences(of: "\\n", with: "\n")
        value = value.replacingOccurrences(of: "\\t", with: "\t")
        return value
    }

    private func matchesMemoryFilter(_ normalizedQuery: String, in value: String) -> Bool {
        value.lowercased().contains(normalizedQuery)
    }

    private func rescanMemorySources(showMessage: Bool) {
        let result = memoryIndexingSettingsService.rescan(
            enabledProviderIDs: settings.memoryEnabledProviderIDs,
            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs,
            runIndexing: settings.memoryIndexingEnabled
        )
        detectedMemoryProviders = result.providers
        detectedMemorySourceFolders = result.sourceFolders

        settings.updateDetectedMemoryProviders(result.providers.map(\.id))
        settings.updateDetectedMemorySourceFolders(result.sourceFolders.map(\.id))
        normalizeMemoryBrowserSelections()
        refreshMemoryBrowser()
        refreshMemoryAnalytics()

        if result.indexQueued {
            isMemoryIndexingInProgress = true
            memoryIndexingProgressSummary = "Preparing indexing run..."
            memoryIndexingProgressDetail = nil
            guard showMessage else { return }
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued \(result.queuedSourceCount) selected source(s) for indexing in the background."
        } else if showMessage {
            memoryIndexingProgressSummary = nil
            memoryIndexingProgressDetail = nil
            if !FeatureFlags.aiMemoryEnabled {
                memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. AI memory feature flag is disabled, so no sources were queued."
            } else if !settings.memoryIndexingEnabled {
                memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Assistant is paused, so no sources were queued."
            } else if settings.memoryEnabledProviderIDs.isEmpty {
                memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Enable at least one source provider to queue indexing."
            } else if !settings.memoryEnabledSourceFolderIDs.isEmpty && totalSourceFoldersForEnabledProvidersCount == 0 {
                memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. No selected source folders matched enabled providers, so nothing was queued."
            } else {
                memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued 0 selected sources for indexing."
            }
        }
    }

    private func stopMemoryIndexing() {
        guard memoryIndexingSettingsService.cancelIndexing() else { return }
        isMemoryIndexingInProgress = false
        memoryIndexingProgressSummary = nil
        memoryIndexingProgressDetail = nil
        memoryActionMessage = "Indexing cancelled."
    }

    private func handleMemoryIndexingProgress(_ notification: Notification) {
        isMemoryIndexingInProgress = true
        let userInfo = notification.userInfo ?? [:]
        let totalSources = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.totalSources] as? Int ?? 0
        let discoveredSources = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.discoveredSources] as? Int ?? 0
        let indexedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedFiles] as? Int ?? 0
        let skippedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.skippedFiles] as? Int ?? 0
        let indexedCards = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedCards] as? Int ?? 0
        let indexedLessons = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedLessons] as? Int ?? 0
        let indexedRewrites = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedRewriteSuggestions] as? Int ?? 0
        let failureCount = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.failureCount] as? Int ?? 0

        let currentSource = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.currentSourceDisplayName] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFilePath = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.currentFilePath] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var summaryParts: [String] = []
        if totalSources > 0 {
            summaryParts.append("Sources \(min(discoveredSources, totalSources))/\(totalSources)")
        }
        summaryParts.append("Files \(indexedFiles) indexed")
        if skippedFiles > 0 {
            summaryParts.append("\(skippedFiles) skipped")
        }
        summaryParts.append("Cards \(indexedCards)")
        if indexedLessons > 0 || indexedRewrites > 0 {
            summaryParts.append("Lessons \(indexedLessons)")
            summaryParts.append("Rewrites \(indexedRewrites)")
        }
        if failureCount > 0 {
            summaryParts.append("Issues \(failureCount)")
        }
        memoryIndexingProgressSummary = summaryParts.joined(separator: " • ")

        if let currentSource, !currentSource.isEmpty {
            if let currentFilePath, !currentFilePath.isEmpty {
                memoryIndexingProgressDetail = "\(currentSource) • \(currentFilePath)"
            } else {
                memoryIndexingProgressDetail = currentSource
            }
        } else {
            memoryIndexingProgressDetail = nil
        }
    }

    private func handleMemoryIndexingCompletion(_ notification: Notification) {
        isMemoryIndexingInProgress = false
        memoryIndexingProgressSummary = nil
        memoryIndexingProgressDetail = nil
        let userInfo = notification.userInfo ?? [:]
        let isRebuild = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.rebuild] as? Bool ?? false
        let wasCancelled = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.cancelled] as? Bool ?? false
        let indexedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedFiles] as? Int ?? 0
        let skippedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.skippedFiles] as? Int ?? 0
        let indexedCards = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedCards] as? Int ?? 0
        let indexedRewrites = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedRewriteSuggestions] as? Int ?? 0
        let failureCount = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.failureCount] as? Int ?? 0
        let firstFailure = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.firstFailure] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actionLabel = isRebuild ? "Rebuild" : "Indexing"
        if wasCancelled {
            memoryActionMessage = "\(actionLabel) cancelled. Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards before stopping."
            refreshMemoryBrowser()
            return
        }

        if failureCount > 0 {
            if let firstFailure, !firstFailure.isEmpty {
                let truncatedFailure = firstFailure.count > 120 ? String(firstFailure.prefix(120)) + "..." : firstFailure
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards. First issue: \(truncatedFailure)"
            } else {
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards."
            }
            refreshMemoryBrowser()
            return
        }

        if indexedFiles > 0 && indexedCards == 0 {
            memoryActionMessage = "\(actionLabel) finished. Indexed \(indexedFiles) files but produced 0 memory cards. This usually means the scanned files did not contain parseable memory events."
            refreshMemoryBrowser()
            return
        }

        memoryActionMessage = "\(actionLabel) finished. Indexed \(indexedFiles) files, skipped \(skippedFiles), produced \(indexedCards) cards, and generated \(indexedRewrites) rewrite suggestion(s)."
        refreshMemoryBrowser()
        refreshMemoryAnalytics()
    }

    // MARK: - Assistant Memory Page

    private var studioAssistantMemoryPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Assistant Memory",
                subtitle: "Short-term file memory for the current Codex thread, plus reviewed long-term lessons.",
                symbol: "brain.head.profile",
                tint: Color(red: 0.46, green: 0.79, blue: 0.66)
            ) {
                Toggle("Enable assistant memory", isOn: $settings.assistantMemoryEnabled)

                if settings.assistantMemoryEnabled {
                    Toggle("Review before saving long-term memory", isOn: $settings.assistantMemoryReviewEnabled)

                    Stepper(value: $settings.assistantMemorySummaryMaxChars, in: 400...4000, step: 200) {
                        HStack {
                            Text("Memory summary size")
                            Spacer()
                            Text("\(settings.assistantMemorySummaryMaxChars) chars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let memoryStatusMessage = assistant.memoryStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !memoryStatusMessage.isEmpty {
                        Text(memoryStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Assistant memory stays separate from voice-to-text memory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Button("Open Current Memory File") {
                            assistant.openCurrentMemoryFile()
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Current Task Memory") {
                            assistant.resetCurrentTaskMemory()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Review Memory Suggestions") {
                            assistant.openMemorySuggestionReview()
                            NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                        }
                        .buttonStyle(.bordered)

                        Button("Clear This Thread Memory", role: .destructive) {
                            assistant.clearCurrentThreadMemory()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("Turn this on when you want the assistant to keep a small working memory for the current Codex thread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Assistant Instructions Page

    private var studioAssistantInstructionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Custom Instructions",
                subtitle: "These instructions are sent to every new assistant session. Use them to set coding style, preferred tools, personality, or any rules.",
                symbol: "text.quote",
                tint: Color(red: 0.72, green: 0.56, blue: 0.88)
            ) {
                TextEditor(text: $settings.assistantCustomInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120, maxHeight: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppVisualTheme.surfaceFill(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.8)
                            )
                    )

                if !settings.assistantCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                        Text("Instructions will be applied to the next new session.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Assistant Setup Page

    private var studioAssistantSetupPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Assistant",
                subtitle: "Codex-powered personal assistant with voice task entry.",
                symbol: "sparkles.rectangle.stack.fill",
                tint: Color(red: 0.22, green: 0.70, blue: 1.00)
            ) {
                let environment = assistant.environment

                if assistant.accountSnapshot.isLoggedIn {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(assistant.accountSnapshot.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                switch assistantSetupStage {
                case .installCodex:
                    Text(environment.installHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Install Codex") {
                            assistant.runPreferredInstallCommand()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Codex Docs") {
                            assistant.openInstallDocs()
                        }
                        .buttonStyle(.bordered)
                    }

                case .signIn:
                    Text(environment.installHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Sign In with ChatGPT") {
                            assistant.runLoginCommand()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Codex Docs") {
                            assistant.openInstallDocs()
                        }
                        .buttonStyle(.bordered)
                    }

                case .enableAssistant:
                    Toggle("Enable assistant", isOn: $settings.assistantBetaEnabled)

                    Text("Turn this on to reveal voice task entry, compact mode, browser automation, memory controls, and session tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .configureAssistant:
                    Toggle("Enable assistant", isOn: $settings.assistantBetaEnabled)

                    if !settings.assistantBetaWarningAcknowledged {
                        Text("This assistant can read files, continue Codex threads, and guide bigger tasks. Review the assistant window before using it for important work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("I understand") {
                            settings.assistantBetaWarningAcknowledged = true
                        }
                        .buttonStyle(.bordered)
                    }

                    Toggle("Enable voice task entry", isOn: $settings.assistantVoiceTaskEntryEnabled)

                    Toggle("Show compact assistant", isOn: $settings.assistantFloatingHUDEnabled)

                    if settings.assistantFloatingHUDEnabled {
                        Toggle(
                            "Use notch style",
                            isOn: Binding(
                                get: { settings.assistantCompactPresentationStyle == .notch },
                                set: { wantsNotch in
                                    settings.assistantCompactPresentationStyle = wantsNotch ? .notch : .orb
                                }
                            )
                        )

                        Text("Turn this on to show the compact assistant at the top notch area. Turn it off to use the floating orb instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if settings.assistantCompactPresentationStyle == .notch {
                            Picker(
                                "Notch hover delay",
                                selection: Binding(
                                    get: { settings.assistantNotchHoverDelay },
                                    set: { settings.assistantNotchHoverDelay = $0 }
                                )
                            ) {
                                ForEach(AssistantNotchHoverDelay.allCases) { delay in
                                    Text(delay.displayName).tag(delay)
                                }
                            }

                            Text("Choose how long the pointer should stay near the notch before the compact assistant appears.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if assistant.visibleModels.isEmpty {
                        Text(
                            assistant.isLoadingModels
                                ? "Loading assistant models..."
                                : "No assistant models are available yet."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Model",
                            selection: Binding(
                                get: { assistant.selectedModelID ?? "" },
                                set: { assistant.chooseModel($0) }
                            )
                        ) {
                            Text("Select a model").tag("")
                            ForEach(assistant.visibleModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Open Assistant") {
                            NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .needsAttention:
                    Text(environment.installHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if assistant.installGuidance.codexDetected {
                            Button("Sign In with ChatGPT") {
                                assistant.runLoginCommand()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Install Codex") {
                                assistant.runPreferredInstallCommand()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Codex Docs") {
                            assistant.openInstallDocs()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if shouldShowAssistantAdvancedPages {
                BrowserAutomationSettingsView(settings: settings)
            }
        }
        .onAppear {
            assistant.refreshAll()
        }
    }

    // MARK: - Assistant Voice Page

    private var studioAssistantVoicePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Assistant Voice",
                subtitle: "Speak only final assistant replies. Hume Octave is the cloud voice option, with macOS as the reliability fallback.",
                symbol: "speaker.wave.3.fill",
                tint: StudioPage.assistantVoice.tint
            ) {
                Toggle("Enable assistant reply voice output", isOn: $settings.assistantVoiceOutputEnabled)

                Picker(
                    "Voice engine",
                    selection: Binding(
                        get: { settings.assistantVoiceEngine },
                        set: { settings.assistantVoiceEngine = $0 }
                    )
                ) {
                    ForEach(AssistantSpeechEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if settings.assistantVoiceEngine == .humeOctave {
                    SecureField("Hume API key", text: $settings.assistantHumeAPIKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Hume Secret key", text: $settings.assistantHumeSecretKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Your Hume keys stay in your macOS Keychain.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Voice source",
                        selection: Binding(
                            get: { settings.assistantHumeVoiceSource },
                            set: { settings.assistantHumeVoiceSource = $0 }
                        )
                    ) {
                        ForEach(AssistantHumeVoiceSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    Picker(
                        "Hume voice",
                        selection: Binding(
                            get: { settings.assistantHumeVoiceID },
                            set: { selectedID in
                                if let voice = assistant.assistantHumeVoiceOptions.first(where: { $0.id == selectedID }) {
                                    assistant.selectAssistantHumeVoice(voice)
                                } else {
                                    settings.assistantHumeVoiceID = selectedID
                                }
                            }
                        )
                    ) {
                        if settings.assistantHumeVoiceID.isEmpty {
                            Text("Select a Hume voice").tag("")
                        }
                        ForEach(assistant.assistantHumeVoiceOptions) { voice in
                            Text(voice.displayLabel).tag(voice.id)
                        }
                    }
                    .disabled(assistant.assistantHumeVoiceOptions.isEmpty)

                    Text("Selected voice: \(assistant.assistantSelectedHumeVoiceSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Fallback to macOS voice if Hume fails", isOn: $settings.assistantTTSFallbackToMacOS)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Voice health")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(assistant.assistantVoiceHealth.statusLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(assistantVoiceHealthColor(assistant.assistantVoiceHealth))
                    }

                    Text(assistant.assistantVoiceHealth.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("macOS voice")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("macOS voice", selection: $settings.assistantTTSFallbackVoiceIdentifier) {
                        ForEach(assistant.assistantFallbackVoiceOptions) { voice in
                            Text(voice.displayLabel).tag(voice.id)
                        }
                    }
                    .frame(width: 280)
                    .pickerStyle(.menu)
                }

                Toggle(
                    "Stop current speech when a newer final reply arrives",
                    isOn: $settings.assistantInterruptCurrentSpeechOnNewReply
                )

                HStack(spacing: 8) {
                    Button("Refresh Health") {
                        Task {
                            await assistant.refreshAssistantVoiceHealth()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(assistant.isRefreshingAssistantVoiceHealth)

                    if settings.assistantVoiceEngine == .humeOctave {
                        Button("Refresh Voices") {
                            Task {
                                await assistant.refreshAssistantHumeVoices()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(assistant.isRefreshingAssistantHumeVoices)

                        if assistant.assistantVoicePlaybackActive {
                            Button("Stop Speaking") {
                                assistant.stopAssistantVoicePlayback()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if assistant.assistantVoiceLegacyCleanupAvailable {
                        Button("Remove Old Local TADA Data", role: .destructive) {
                            Task {
                                await assistant.removeLegacyAssistantVoiceData()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(assistant.isRemovingAssistantVoiceInstallation)
                    }

                    Button("Test Voice Output") {
                        Task {
                            await assistant.testAssistantVoiceOutput()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.isTestingAssistantVoice)
                }

                if let statusMessage = assistant.assistantVoiceStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(
            id: settings.assistantVoiceEngineRawValue
                + settings.assistantHumeVoiceID
                + settings.assistantHumeVoiceSourceRawValue
                + settings.assistantHumeAPIKey
        ) {
            await assistant.refreshAssistantVoiceHealth()
            if settings.assistantVoiceEngine == .humeOctave,
               assistant.assistantHumeVoiceOptions.isEmpty,
               settings.assistantHumeAPIKey.nonEmpty != nil {
                await assistant.refreshAssistantHumeVoices()
            }
        }
    }

    // MARK: - Assistant Limits Page

    private var studioAssistantLimitsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Agent Turn Limit",
                subtitle: "Maximum number of tool calls the agent can make in a single turn before it is automatically stopped. Set to 0 for unlimited.",
                symbol: "gauge.with.dots.needle.33percent",
                tint: Color(red: 0.90, green: 0.70, blue: 0.26)
            ) {
                HStack(spacing: 12) {
                    TextField(
                        "Max tool calls",
                        value: $settings.assistantMaxToolCallsPerTurn,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    Text("\(settings.assistantMaxToolCallsPerTurn == 0 ? "Unlimited" : "\(settings.assistantMaxToolCallsPerTurn) tool calls")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset") {
                        settings.assistantMaxToolCallsPerTurn = 75
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            settingsCard(
                title: "Repeated Command Limit",
                subtitle: "Maximum number of times the same terminal command can repeat back-to-back in a single turn before it is automatically stopped. Set to 0 for unlimited.",
                symbol: "arrow.trianglehead.2.clockwise",
                tint: Color(red: 0.90, green: 0.70, blue: 0.26)
            ) {
                HStack(spacing: 12) {
                    TextField(
                        "Max repeats",
                        value: $settings.assistantMaxRepeatedCommandAttemptsPerTurn,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    Text(
                        settings.assistantMaxRepeatedCommandAttemptsPerTurn == 0
                            ? "Unlimited"
                            : "\(settings.assistantMaxRepeatedCommandAttemptsPerTurn) attempts"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset") {
                        settings.assistantMaxRepeatedCommandAttemptsPerTurn = 3
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Assistant Sessions Page

    private var studioAssistantSessionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if assistant.sessions.isEmpty {
                settingsCard(
                    title: "Recent Sessions",
                    subtitle: "No sessions saved yet.",
                    symbol: "clock.arrow.circlepath",
                    tint: Color(red: 0.84, green: 0.52, blue: 0.28)
                ) {
                    Text("Sessions will appear here once you start using the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                settingsCard(
                    title: "Recent Sessions",
                    subtitle: "\(assistant.sessions.count) session\(assistant.sessions.count == 1 ? "" : "s") saved in Open Assist.",
                    symbol: "clock.arrow.circlepath",
                    tint: Color(red: 0.84, green: 0.52, blue: 0.28)
                ) {
                    ForEach(assistant.sessions) { session in
                        HStack(alignment: .top, spacing: 10) {
                            AppIconBadge(
                                symbol: assistantSessionBadgeSymbol(for: session.source),
                                tint: assistantSessionBadgeTint(for: session.source),
                                size: 22,
                                symbolSize: 10,
                                isEmphasized: assistant.selectedSessionID == session.id
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                                    .lineLimit(1)
                                Text(session.detail.isEmpty ? (session.cwd ?? "") : session.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    Button("Open Assistant Window") {
                        NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(!settings.assistantBetaEnabled)
                }
            }
        }
    }

    private func assistantSessionBadgeSymbol(for source: AssistantSessionSource) -> String {
        switch source {
        case .cli:
            return "terminal.fill"
        case .vscode:
            return "chevron.left.forwardslash.chevron.right"
        case .appServer:
            return "sparkles"
        case .other:
            return "tray.full.fill"
        }
    }

    private func assistantVoiceHealthColor(_ health: AssistantSpeechHealth) -> Color {
        switch health.state {
        case .healthy:
            return Color.green.opacity(0.92)
        case .degraded:
            return Color.orange.opacity(0.92)
        case .unavailable:
            return Color.red.opacity(0.92)
        case .unknown:
            return .secondary
        }
    }

    private func assistantSessionBadgeTint(for source: AssistantSessionSource) -> Color {
        switch source {
        case .cli:
            return AppVisualTheme.baseTint
        case .vscode:
            return AppVisualTheme.accentTint
        case .appServer:
            return .green
        case .other:
            return .orange
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                AppIconBadge(
                    symbol: symbol,
                    tint: tint,
                    size: 28,
                    symbolSize: 12
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.96))

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AppVisualTheme.mutedText)
                    }
                }

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(16)
        .appThemedSurface(
            cornerRadius: 12,
            tint: tint,
            strokeOpacity: 0.16,
            tintOpacity: 0.035
        )
    }
}

private struct AIMemoryStudioWindowAccessor: NSViewRepresentable {
    let windowReference: AIMemoryStudioView.WeakWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindowReference(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindowReference(from: nsView)
    }

    private func updateWindowReference(from view: NSView) {
        DispatchQueue.main.async {
            windowReference.window = view.window
        }
    }
}
