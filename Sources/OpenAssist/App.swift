import AppKit
import AVFoundation
import Combine
import Sparkle
import Speech
import SwiftUI

extension Notification.Name {
    static let openAssistOpenAIMemoryStudio = Notification.Name("OpenAssist.openAIMemoryStudio")
    static let openAssistOpenSettings = Notification.Name("OpenAssist.openSettings")
    static let openAssistOpenAssistant = Notification.Name("OpenAssist.openAssistant")
    static let openAssistOpenAssistantSetup = Notification.Name("OpenAssist.openAssistantSetup")
    static let openAssistStartAssistantVoiceCapture = Notification.Name("OpenAssist.startAssistantVoiceCapture")
    static let openAssistStopAssistantVoiceCapture = Notification.Name("OpenAssist.stopAssistantVoiceCapture")
    static let openAssistStartCompactVoiceCapture = Notification.Name("OpenAssist.startCompactVoiceCapture")
    static let openAssistStopCompactVoiceCapture = Notification.Name("OpenAssist.stopCompactVoiceCapture")
    static let openAssistMinimizeAssistantToCompact = Notification.Name("OpenAssist.minimizeAssistantToCompact")
    static let openAssistStartOrbVoiceCapture = Notification.Name("OpenAssist.startOrbVoiceCapture")
    static let openAssistStopOrbVoiceCapture = Notification.Name("OpenAssist.stopOrbVoiceCapture")
    static let openAssistAssistantZoomIn = Notification.Name("OpenAssist.assistantZoomIn")
    static let openAssistAssistantZoomOut = Notification.Name("OpenAssist.assistantZoomOut")
    static let openAssistAssistantZoomReset = Notification.Name("OpenAssist.assistantZoomReset")
    static let openAssistMinimizeAssistantToOrb = Notification.Name("OpenAssist.minimizeAssistantToOrb")
    static let openAssistRunScheduledJob = Notification.Name("OpenAssist.runScheduledJob")
    static let openAssistSwitchToSession = Notification.Name("OpenAssist.switchToSession")
}

@MainActor
final class UpdateCheckStatusStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(message: String)
    }

    static let shared = UpdateCheckStatusStore()

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?

    var isChecking: Bool {
        if case .checking = state {
            return true
        }
        return false
    }

    private init() {}

    func beginCheck() {
        state = .checking
    }

    func markUpToDate() {
        state = .upToDate
        lastCheckedAt = Date()
    }

    func markUpdateAvailable(version: String) {
        state = .updateAvailable(version: version)
        lastCheckedAt = Date()
    }

    func markFailed(message: String) {
        state = .failed(message: message)
        lastCheckedAt = Date()
    }
}

private struct PromptRewriteAIMappingCandidate {
    let prompt: ConversationClarificationPrompt
    let candidateKey: String
    let candidateLabel: String
    let candidateBundleIdentifier: String
    let confidence: Double
}

private enum PromptRewriteAIMappingEvaluator {
    private enum ClarificationAxis {
        case project
        case person

        var aliasType: String {
            switch self {
            case .project:
                return "project"
            case .person:
                return "identity"
            }
        }

        var ruleType: ConversationDisambiguationRuleType {
            switch self {
            case .project:
                return .project
            case .person:
                return .person
            }
        }
    }

    private enum ClarificationRuleResolution {
        case link(canonicalKey: String?)
        case keepSeparate
    }

    private struct ClarificationRankedCandidate {
        let candidate: ConversationClarificationCandidate
        let isExact: Bool
    }

    private static let maxStoredContexts = 24
    private static let sqliteStartupThreadScanMultiplier = 4
    private static let sqliteStartupThreadScanHardLimit = 120
    private static let clarificationSimilarityThreshold = 0.92
    private static let clarificationCandidateLimit = 3

    static func evaluate(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> PromptRewriteAIMappingCandidate? {
        guard FeatureFlags.conversationTupleSQLiteEnabled else {
            return nil
        }
        guard let store = try? MemorySQLiteStore() else {
            return nil
        }

        let tagInferenceService = ConversationTagInferenceService.shared
        let inferredTags = canonicalizedTags(
            tagInferenceService.inferTags(
                capturedContext: capturedContext,
                userText: userText
            ),
            store: store
        )
        let currentTupleKey = tagInferenceService.tupleKey(
            capturedContext: capturedContext,
            tags: inferredTags
        )
        let normalizedCurrentBundle = normalizedClarificationBundle(currentTupleKey.bundleID)
        guard !normalizedCurrentBundle.isEmpty else {
            return nil
        }

        let scanLimit = min(
            sqliteStartupThreadScanHardLimit,
            max(maxStoredContexts, maxStoredContexts * sqliteStartupThreadScanMultiplier)
        )
        let allThreads = (try? store.fetchConversationThreads(limit: scanLimit)) ?? []
        guard !allThreads.isEmpty else {
            return nil
        }

        let crossAppThreads = allThreads.filter { thread in
            normalizedClarificationBundle(thread.bundleID) != normalizedCurrentBundle
        }
        guard !crossAppThreads.isEmpty else {
            return nil
        }

        let currentIdentityType = normalizedClarificationIdentityType(inferredTags.identityType)
        if currentIdentityType == "person",
           let prompt = clarificationPrompt(
               axis: .person,
               currentKey: inferredTags.identityKey,
               currentLabel: inferredTags.identityLabel,
               currentBundleIdentifier: normalizedCurrentBundle,
               threads: crossAppThreads,
               store: store
           ) {
            return candidate(from: prompt)
        }

        if isMeaningfulProjectClarificationKey(inferredTags.projectKey),
           let prompt = clarificationPrompt(
               axis: .project,
               currentKey: inferredTags.projectKey,
               currentLabel: inferredTags.projectLabel,
               currentBundleIdentifier: normalizedCurrentBundle,
               threads: crossAppThreads,
               store: store
           ) {
            return candidate(from: prompt)
        }

        return nil
    }

    private static func candidate(from prompt: ConversationClarificationPrompt) -> PromptRewriteAIMappingCandidate? {
        guard let primary = prompt.primaryCandidate else {
            return nil
        }
        return PromptRewriteAIMappingCandidate(
            prompt: prompt,
            candidateKey: primary.canonicalKey,
            candidateLabel: primary.label,
            candidateBundleIdentifier: primary.bundleIdentifier,
            confidence: max(0, min(1, primary.similarity))
        )
    }

    private static func canonicalizedTags(
        _ tags: ConversationTupleTags,
        store: MemorySQLiteStore
    ) -> ConversationTupleTags {
        let normalizedProjectKey = tags.projectKey.lowercased()
        let normalizedIdentityKey = tags.identityKey.lowercased()

        var canonicalProject = normalizedProjectKey
        if let resolved = try? store.resolveConversationTagAlias(
            aliasType: "project",
            aliasKey: normalizedProjectKey
        ),
           !resolved.isEmpty {
            canonicalProject = resolved
        }

        var canonicalIdentity = normalizedIdentityKey
        if let resolved = try? store.resolveConversationTagAlias(
            aliasType: "identity",
            aliasKey: normalizedIdentityKey
        ),
           !resolved.isEmpty {
            canonicalIdentity = resolved
        }

        if canonicalProject != normalizedProjectKey {
            try? store.upsertConversationTagAlias(
                aliasType: "project",
                aliasKey: normalizedProjectKey,
                canonicalKey: canonicalProject
            )
        }
        if canonicalIdentity != normalizedIdentityKey {
            try? store.upsertConversationTagAlias(
                aliasType: "identity",
                aliasKey: normalizedIdentityKey,
                canonicalKey: canonicalIdentity
            )
        }

        return ConversationTupleTags(
            projectKey: canonicalProject,
            projectLabel: tags.projectLabel,
            identityKey: canonicalIdentity,
            identityType: tags.identityType,
            identityLabel: tags.identityLabel,
            people: tags.people,
            nativeThreadKey: tags.nativeThreadKey
        )
    }

    private static func clarificationPrompt(
        axis: ClarificationAxis,
        currentKey: String,
        currentLabel: String,
        currentBundleIdentifier: String,
        threads: [ConversationThreadRecord],
        store: MemorySQLiteStore
    ) -> ConversationClarificationPrompt? {
        let normalizedCurrentKey = normalizedClarificationKey(currentKey)
        guard !normalizedCurrentKey.isEmpty else {
            return nil
        }
        let normalizedCurrentLabel = comparableClarificationLabel(
            label: currentLabel,
            fallbackKey: normalizedCurrentKey
        )
        guard !normalizedCurrentLabel.isEmpty else {
            return nil
        }
        let subjectKey = normalizedClarificationKey(normalizedCurrentLabel)
        guard !subjectKey.isEmpty else {
            return nil
        }

        var rankedByCanonicalKey: [String: ClarificationRankedCandidate] = [:]
        var shouldSuppressPrompt = false

        for thread in threads {
            guard let (candidateKey, candidateLabel) = clarificationCandidateParts(
                for: axis,
                thread: thread
            ) else {
                continue
            }

            let normalizedCandidateKey = normalizedClarificationKey(candidateKey)
            guard !normalizedCandidateKey.isEmpty else {
                continue
            }
            let canonicalCandidateKey = resolvedClarificationAliasKey(
                aliasType: axis.aliasType,
                key: normalizedCandidateKey,
                store: store
            )
            guard !canonicalCandidateKey.isEmpty,
                  canonicalCandidateKey != normalizedCurrentKey else {
                continue
            }

            if let existingRule = clarificationRuleResolution(
                axis: axis,
                currentBundleIdentifier: currentBundleIdentifier,
                subjectKey: subjectKey,
                currentKey: normalizedCurrentKey,
                candidateKey: canonicalCandidateKey,
                candidateBundleIdentifier: thread.bundleID,
                store: store
            ) {
                switch existingRule {
                case .keepSeparate:
                    continue
                case let .link(canonicalKey):
                    let resolvedCanonicalKey = normalizedClarificationKey(canonicalKey ?? canonicalCandidateKey)
                    guard !resolvedCanonicalKey.isEmpty else {
                        continue
                    }
                    try? store.upsertConversationTagAlias(
                        aliasType: axis.aliasType,
                        aliasKey: normalizedCurrentKey,
                        canonicalKey: resolvedCanonicalKey
                    )
                    shouldSuppressPrompt = true
                    continue
                }
            }

            let normalizedCandidateLabel = comparableClarificationLabel(
                label: candidateLabel,
                fallbackKey: canonicalCandidateKey
            )
            guard !normalizedCandidateLabel.isEmpty else {
                continue
            }

            let isExact = normalizedCandidateLabel == normalizedCurrentLabel
            let similarity = isExact
                ? 1
                : normalizedClarificationSimilarity(
                    normalizedCurrentLabel,
                    normalizedCandidateLabel
                )
            guard isExact || similarity >= clarificationSimilarityThreshold else {
                continue
            }

            let rankedCandidate = ClarificationRankedCandidate(
                candidate: ConversationClarificationCandidate(
                    canonicalKey: canonicalCandidateKey,
                    label: collapsedWhitespace(candidateLabel),
                    appName: collapsedWhitespace(thread.appName),
                    bundleIdentifier: normalizedClarificationBundle(thread.bundleID),
                    similarity: similarity,
                    lastActivityAt: thread.lastActivityAt
                ),
                isExact: isExact
            )

            if let existing = rankedByCanonicalKey[canonicalCandidateKey] {
                if shouldReplaceClarificationCandidate(existing, with: rankedCandidate) {
                    rankedByCanonicalKey[canonicalCandidateKey] = rankedCandidate
                }
            } else {
                rankedByCanonicalKey[canonicalCandidateKey] = rankedCandidate
            }
        }

        if shouldSuppressPrompt {
            return nil
        }

        let ranked = rankedByCanonicalKey.values.sorted { lhs, rhs in
            if lhs.isExact != rhs.isExact {
                return lhs.isExact && !rhs.isExact
            }
            if lhs.candidate.similarity != rhs.candidate.similarity {
                return lhs.candidate.similarity > rhs.candidate.similarity
            }
            if lhs.candidate.lastActivityAt != rhs.candidate.lastActivityAt {
                return lhs.candidate.lastActivityAt > rhs.candidate.lastActivityAt
            }
            return lhs.candidate.label.localizedCaseInsensitiveCompare(rhs.candidate.label) == .orderedAscending
        }
        guard !ranked.isEmpty else {
            return nil
        }

        let exactMatches = ranked.filter(\.isExact)
        let selected: [ClarificationRankedCandidate]
        let kind: ConversationClarificationKind
        if !exactMatches.isEmpty {
            selected = Array(exactMatches.prefix(clarificationCandidateLimit))
            kind = axis == .project ? .projectExact : .personExact
        } else {
            selected = Array(ranked.prefix(clarificationCandidateLimit))
            kind = axis == .project ? .projectAmbiguous : .personAmbiguous
        }

        let displayLabel = collapsedWhitespace(currentLabel)

        return ConversationClarificationPrompt(
            kind: kind,
            currentKey: normalizedCurrentKey,
            currentLabel: displayLabel.isEmpty
                ? readableClarificationLabel(from: normalizedCurrentKey)
                : displayLabel,
            currentBundleIdentifier: currentBundleIdentifier,
            subjectKey: subjectKey,
            candidates: selected.map(\.candidate)
        )
    }

    private static func clarificationCandidateParts(
        for axis: ClarificationAxis,
        thread: ConversationThreadRecord
    ) -> (key: String, label: String)? {
        switch axis {
        case .project:
            guard isMeaningfulProjectClarificationKey(thread.projectKey) else {
                return nil
            }
            return (thread.projectKey, thread.projectLabel)
        case .person:
            guard normalizedClarificationIdentityType(thread.identityType) == "person" else {
                return nil
            }
            guard isMeaningfulPersonClarificationKey(thread.identityKey) else {
                return nil
            }
            return (thread.identityKey, thread.identityLabel)
        }
    }

    private static func shouldReplaceClarificationCandidate(
        _ existing: ClarificationRankedCandidate,
        with candidate: ClarificationRankedCandidate
    ) -> Bool {
        if existing.isExact != candidate.isExact {
            return candidate.isExact
        }
        if existing.candidate.similarity != candidate.candidate.similarity {
            return candidate.candidate.similarity > existing.candidate.similarity
        }
        return candidate.candidate.lastActivityAt > existing.candidate.lastActivityAt
    }

    private static func clarificationRuleResolution(
        axis: ClarificationAxis,
        currentBundleIdentifier: String,
        subjectKey: String,
        currentKey: String,
        candidateKey: String,
        candidateBundleIdentifier: String,
        store: MemorySQLiteStore
    ) -> ClarificationRuleResolution? {
        let appPairKey = store.conversationDisambiguationAppPairKey(
            normalizedClarificationBundle(currentBundleIdentifier),
            normalizedClarificationBundle(candidateBundleIdentifier)
        )
        let normalizedSubjectKey = normalizedClarificationKey(subjectKey)
        let normalizedCandidateKey = normalizedClarificationKey(candidateKey)
        guard !appPairKey.isEmpty, !normalizedSubjectKey.isEmpty else {
            return nil
        }

        let scopedRule = try? store.fetchConversationDisambiguationRule(
            ruleType: axis.ruleType,
            appPairKey: appPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: normalizedCandidateKey
        )
        if let scopedRule {
            switch scopedRule.decision {
            case .separate:
                return .keepSeparate
            case .link:
                return .link(canonicalKey: scopedRule.canonicalKey)
            }
        }

        let broadRule = try? store.fetchConversationDisambiguationRule(
            ruleType: axis.ruleType,
            appPairKey: appPairKey,
            subjectKey: normalizedSubjectKey,
            contextScopeKey: nil
        )
        if let broadRule {
            switch broadRule.decision {
            case .separate:
                return .keepSeparate
            case .link:
                return .link(canonicalKey: broadRule.canonicalKey)
            }
        }

        if let resolvedAlias = try? store.resolveConversationTagAlias(
            aliasType: axis.aliasType,
            aliasKey: currentKey
        ),
           normalizedClarificationKey(resolvedAlias) == candidateKey {
            return .link(canonicalKey: candidateKey)
        }

        return nil
    }

    private static func resolvedClarificationAliasKey(
        aliasType: String,
        key: String,
        store: MemorySQLiteStore
    ) -> String {
        let normalized = normalizedClarificationKey(key)
        guard !normalized.isEmpty else {
            return ""
        }
        if let resolved = try? store.resolveConversationTagAlias(aliasType: aliasType, aliasKey: normalized),
           !resolved.isEmpty {
            return normalizedClarificationKey(resolved)
        }
        return normalized
    }

    private static func normalizedClarificationKey(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private static func normalizedClarificationBundle(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private static func normalizedClarificationIdentityType(_ value: String) -> String {
        collapsedWhitespace(value).lowercased()
    }

    private static func comparableClarificationLabel(label: String, fallbackKey: String) -> String {
        let fromLabel = normalizedClarificationLabel(label)
        if !fromLabel.isEmpty {
            return fromLabel
        }
        return normalizedClarificationLabel(readableClarificationLabel(from: fallbackKey))
    }

    private static func normalizedClarificationLabel(_ value: String) -> String {
        let collapsed = collapsedWhitespace(value).lowercased()
        guard !collapsed.isEmpty else {
            return ""
        }
        let alphanumericOnly = collapsed.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedWhitespace(alphanumericOnly)
    }

    private static func readableClarificationLabel(from key: String) -> String {
        let split = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let fallback = split.count == 2 ? String(split[1]) : key
        let separated = fallback
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let normalized = collapsedWhitespace(separated)
        return normalized.isEmpty ? key : normalized
    }

    private static func isMeaningfulProjectClarificationKey(_ projectKey: String) -> Bool {
        let normalized = normalizedClarificationKey(projectKey)
        guard normalized.hasPrefix("project:") else {
            return false
        }
        let value = String(normalized.dropFirst("project:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return false
        }
        let blockedValues: Set<String> = [
            "unknown",
            "unknown-project",
            "current-screen",
            "focused-input",
            "automation-folder",
            "automation-folders"
        ]
        if blockedValues.contains(value) || value.hasPrefix("unknown-") {
            return false
        }
        return true
    }

    private static func isMeaningfulPersonClarificationKey(_ identityKey: String) -> Bool {
        let normalized = normalizedClarificationKey(identityKey)
        guard normalized.hasPrefix("person:") else {
            return false
        }
        let value = String(normalized.dropFirst("person:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "unknown" {
            return false
        }
        return true
    }

    private static func normalizedClarificationSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        if lhs == rhs {
            return 1
        }
        let editDistanceSimilarity = normalizedLevenshteinSimilarity(lhs, rhs)
        let tokenSimilarity = tokenOverlapSimilarity(lhs, rhs)
        return max(editDistanceSimilarity, tokenSimilarity)
    }

    private static func normalizedLevenshteinSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        guard !lhsCharacters.isEmpty, !rhsCharacters.isEmpty else {
            return 0
        }

        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for lhsIndex in 1...lhsCharacters.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhsCharacters.count {
                let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = Swift.min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        let maxLength = max(lhsCharacters.count, rhsCharacters.count)
        guard maxLength > 0 else {
            return 0
        }
        let distance = previous[rhsCharacters.count]
        return max(0, 1 - (Double(distance) / Double(maxLength)))
    }

    private static func tokenOverlapSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
            return 0
        }
        let unionCount = lhsTokens.union(rhsTokens).count
        guard unionCount > 0 else {
            return 0
        }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(unionCount)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        MemoryTextNormalizer.collapsedWhitespace(value)
    }
}

@main
struct OpenAssistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .openAssistAssistantZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .openAssistAssistantZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .openAssistAssistantZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?

    private enum UpdateCheckFallback {
        static let timeoutSeconds: TimeInterval = 8
        static let latestReleaseURLString = "https://github.com/manikv12/OpenAssist/releases/latest"
    }

    private enum PasteLastTranscriptShortcut {
        static let keyCode: UInt16 = 9 // V
        static let modifiers: NSEvent.ModifierFlags = [.command, .option]
    }

    private(set) lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()
    private let updateCheckStatusStore = UpdateCheckStatusStore.shared

    private let transcriber = SpeechTranscriber()
    private let whisperModelManager = WhisperModelManager.shared
    private let settings = SettingsStore.shared
    private let automationAPICoordinator = AutomationAPICoordinator.shared
    private let telegramRemoteCoordinator = TelegramRemoteCoordinator.shared
    private let adaptiveCorrectionStore = AdaptiveCorrectionStore.shared
    private let promptRewriteService = PromptRewriteService.shared
    private let assistantVoiceDraftRefinementService = AssistantVoiceDraftRefinementService()
    private let promptRewriteConversationStore = PromptRewriteConversationStore.shared
    private let conversationContextResolverV2 = ConversationContextResolverV2()
    private let postInsertCorrectionMonitor = PostInsertCorrectionMonitor()
    private let waveform = WaveformHUDManager()
    private let assistantController = AssistantFeatureController.shared
    private var hotkeyManager: HoldToTalkManager?
    private var continuousToggleHotkeyManager: OneShotHotkeyManager?
    private var assistantLiveVoiceHotkeyManager: HoldToTalkManager?
    private var pasteLastTranscriptHotkeyManager: OneShotHotkeyManager?
    private let transcriptHistory = TranscriptHistoryStore.shared
    private var windowCoordinator: AppWindowCoordinator?
    private var assistantCompactHUD: AssistantCompactPresenter?
    private var liveVoiceCoordinator: AssistantLiveVoiceCoordinator?
    private var isAssistantWindowVisible = false

    private var statusItem: NSStatusItem?
    private let statusBarViewModel = StatusBarViewModel()
    private var popover: NSPopover?
    private var accessibilityTrustObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var aiStudioRequestObserver: NSObjectProtocol?
    private var settingsRequestObserver: NSObjectProtocol?
    private var assistantRequestObserver: NSObjectProtocol?
    private var assistantSetupRequestObserver: NSObjectProtocol?
    private var assistantStartVoiceCaptureObserver: NSObjectProtocol?
    private var assistantStopVoiceCaptureObserver: NSObjectProtocol?
    private var assistantMinimizeToCompactObserver: NSObjectProtocol?
    private var scheduledJobRequestObserver: NSObjectProtocol?
    private var scheduledJobInFlightID: String?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var adaptiveCorrectionObserver: AnyCancellable?
    private var assistantHUDObserver: AnyCancellable?
    private var assistantPermissionObserver: AnyCancellable?
    private var permissionsReady = false
    private var didRequestStartupPermissionPrompt = false
    private var lastExternalApplication: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var currentAudioLevel: Float = 0
    private var isDictating = false
    private var dictationInputMode: DictationInputMode = .idle
    private var statusIconAnimationTimer: DispatchSourceTimer?
    private var statusIconAnimationPhase: Double = 0
    private var lastStatusIconRenderState: StatusIconRenderState?
    private var statusIconCache: [StatusIconRenderState: NSImage] = [:]
    private var hasScheduledPermissionRestart = false
    private var pendingUpdateCheckFallbackWorkItem: DispatchWorkItem?
    private var settingsApplyWorkItem: DispatchWorkItem?
    private var lastAppliedSettingsSnapshot: SettingsApplySnapshot?
    private var lastAudioSetupHUDAlertAt: Date?
    private var assistantVoiceCaptureActive = false
    private var compactVoiceCaptureActive = false
    private var liveVoiceCaptureActive = false
    private var assistantVoiceSilenceStart: Date?
    private var assistantVoiceHasSpoken = false
    private var assistantVoiceBaselineNoise: Float = 0
    private var assistantVoiceBaselineSamples: [Float] = []
    private var assistantVoiceBaselineCalibrated = false

    private enum AssistantVoiceStopMode {
        case silenceAutoStop
        case manualRelease
    }

    private struct StatusIconRenderState: Hashable {
        private static let bucketCount = 12

        let isRecording: Bool
        let bucket: Int

        init(isRecording: Bool, level: Float, animationPhase: Double) {
            self.isRecording = isRecording

            if isRecording {
                let normalizedLevel = max(0, min(1, level))
                let waveMotion = Float((sin(animationPhase) + 1) * 0.5)
                let idlePulse = 0.30 + (0.40 * waveMotion)
                let animatedLevel = max(normalizedLevel, idlePulse)
                let rawBucket = Int((animatedLevel * Float(Self.bucketCount)).rounded())
                self.bucket = min(max(0, rawBucket), Self.bucketCount)
            } else {
                let idleBucket = Int((0.45 * Double(Self.bucketCount)).rounded())
                self.bucket = min(max(0, idleBucket), Self.bucketCount)
            }
        }

        var variableValue: Double {
            if isRecording {
                return max(0.30, Double(bucket) / Double(Self.bucketCount))
            }
            return 0.45
        }
    }

    private var assistantVoiceStopMode: AssistantVoiceStopMode = .silenceAutoStop
    private var compactVoiceStopMode: AssistantVoiceStopMode = .manualRelease

    private enum PromptRewriteFailureChoice {
        case retry
        case insertOriginal
        case close
    }

    private enum PromptRewriteRetrievalOutcome {
        case suggestion(PromptRewriteSuggestion?)
        case bypassed
    }

    private struct PromptRewriteSessionContext {
        let conversationContext: PromptRewriteConversationContext
        let insertionHUDContext: PromptRewriteInsertionHUDContext
    }

    private struct PromptRewriteInsertionResolution {
        let insertionText: String
        let conversationContext: PromptRewriteConversationContext?
        let insertionHUDContext: PromptRewriteInsertionHUDContext
        // Preserve user-requested original text (for example Esc in rewrite HUD)
        // without applying adaptive correction post-processing.
        let preserveInsertionText: Bool
        // When users explicitly request original text (for example Esc in preview),
        // briefly re-activate the target app before paste so focus is restored.
        let forceTargetRefocusBeforeInsert: Bool

        init(
            insertionText: String,
            conversationContext: PromptRewriteConversationContext?,
            insertionHUDContext: PromptRewriteInsertionHUDContext,
            preserveInsertionText: Bool = false,
            forceTargetRefocusBeforeInsert: Bool = false
        ) {
            self.insertionText = insertionText
            self.conversationContext = conversationContext
            self.insertionHUDContext = insertionHUDContext
            self.preserveInsertionText = preserveInsertionText
            self.forceTargetRefocusBeforeInsert = forceTargetRefocusBeforeInsert
        }
    }

    private struct PromptRewriteLoadingNarrative {
        let transcript: String
        let aiSuggestionsEnabled: Bool
        let aiGenerationSummary: String
        let aiRuntimeSummary: String?

        func displayState(
            step: String,
            partialPreviewText: String? = nil,
            isStreamingPreviewActive: Bool = false
        ) -> PromptRewriteLoadingDisplayState {
            PromptRewriteLoadingDisplayState(
                transcription: transcript,
                currentStep: step,
                aiSuggestionsEnabled: aiSuggestionsEnabled,
                aiGenerationSummary: aiGenerationSummary,
                aiRuntimeSummary: aiRuntimeSummary,
                partialPreviewText: partialPreviewText,
                isStreamingPreviewActive: isStreamingPreviewActive
            )
        }
    }

    private struct SettingsApplySnapshot: Equatable {
        let autoDetectMicrophone: Bool
        let selectedMicrophoneUID: String
        let shortcutKeyCode: UInt16
        let shortcutModifiers: UInt
        let continuousToggleShortcutKeyCode: UInt16
        let continuousToggleShortcutModifiers: UInt
        let assistantLiveVoiceShortcutKeyCode: UInt16
        let assistantLiveVoiceShortcutModifiers: UInt
        let muteSystemSoundsWhileHoldingShortcut: Bool
        let transcriptionEngineRawValue: String
        let cloudTranscriptionProviderRawValue: String
        let cloudTranscriptionModel: String
        let cloudTranscriptionBaseURL: String
        let cloudTranscriptionRequestTimeoutSeconds: Double
        let cloudTranscriptionAPIKey: String
        let selectedWhisperModelID: String
        let whisperUseCoreML: Bool
        let whisperAutoUnloadIdleContextEnabled: Bool
        let whisperIdleContextUnloadSeconds: Double
        let adaptiveCorrectionsEnabled: Bool
        let enableContextualBias: Bool
        let keepTextAcrossPauses: Bool
        let recognitionModeRawValue: String
        let autoPunctuation: Bool
        let finalizeDelaySeconds: Double
        let customContextPhrases: String
        let assistantBetaEnabled: Bool
    }

    private static let promptRewriteAutoInsertMinimumConfidence: Double = 0.85
    private static let settingsApplyDebounceSeconds: TimeInterval = 0.14
    private static let deterministicMappingHighConfidenceThreshold: Double = 0.94
    private static let aiMappingHighConfidenceThreshold: Double = 0.90
    private static let aiMappingTimeoutSeconds: TimeInterval = 0.25
    private static let localAIRuntimeShutdownTimeoutSeconds: TimeInterval = 1.5

    private enum DictationFeedbackCue: CaseIterable {
        case startListening
        case stopListening
        case processing
        case pasted
        case correctionLearned

        // Keep nonisolated defaults local so this enum can be used from non-main contexts
        // without reading @MainActor-isolated state from SettingsStore.
        private static let defaultStartSoundName = "Ping"
        private static let defaultStopSoundName = "Glass"
        private static let defaultProcessingSoundName = "Ping"
        private static let defaultPastedSoundName = "Pop"
        private static let defaultCorrectionLearnedSoundName = "Purr"

        var systemSoundName: String {
            switch self {
            case .startListening, .processing:
                return Self.defaultStartSoundName
            case .stopListening:
                return Self.defaultStopSoundName
            case .pasted:
                return Self.defaultPastedSoundName
            case .correctionLearned:
                return Self.defaultCorrectionLearnedSoundName
            }
        }

        @MainActor func resolvedSystemSoundName(settings: SettingsStore) -> String {
            switch self {
            case .startListening:
                return Self.resolveSoundName(settings.dictationStartSoundName, fallback: Self.startingFallback)
            case .stopListening:
                return Self.resolveSoundName(settings.dictationStopSoundName, fallback: Self.stopFallback)
            case .processing:
                return Self.resolveSoundName(settings.dictationProcessingSoundName, fallback: Self.processingFallback)
            case .pasted:
                return Self.resolveSoundName(settings.dictationPastedSoundName, fallback: Self.pastedFallback)
            case .correctionLearned:
                return Self.resolveSoundName(settings.dictationCorrectionLearnedSoundName, fallback: Self.correctionLearnedFallback)
            }
        }

        @MainActor static func resolveSoundName(_ selected: String, fallback: String) -> String {
            if selected == SettingsStore.noDictationSoundName {
                return ""
            }
            return SettingsStore.dictationStartSoundOptions.contains(selected)
                ? selected
                : fallback
        }

        private static var startingFallback: String {
            Self.defaultStartSoundName
        }

        private static var stopFallback: String {
            Self.defaultStopSoundName
        }

        private static var processingFallback: String {
            Self.defaultProcessingSoundName
        }

        private static var pastedFallback: String {
            Self.defaultPastedSoundName
        }

        private static var correctionLearnedFallback: String {
            Self.defaultCorrectionLearnedSoundName
        }

        var volumeMultiplier: Float {
            switch self {
            case .startListening:
                return 0.7
            default:
                return 1
            }
        }
    }

    private var dictationFeedbackSounds: [DictationFeedbackCue: NSSound] {
        var sounds: [DictationFeedbackCue: NSSound] = [:]
        for cue in DictationFeedbackCue.allCases {
            let soundName = cue.resolvedSystemSoundName(settings: settings)
            guard !soundName.isEmpty else { continue }
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sounds[cue] = sound
            }
        }
        return sounds
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        CrashReporter.install()
        NSApp.setActivationPolicy(.accessory)
        _ = updaterController

        // Set app icon programmatically to bypass macOS automatic icon margin
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }

        setupStatusBar()
        assistantCompactHUD = AssistantCompactHUDManager(
            controller: assistantController,
            settings: settings,
            style: settings.assistantCompactPresentationStyle
        )
        liveVoiceCoordinator = AssistantLiveVoiceCoordinator(
            store: assistantController,
            startCapture: { [weak self] in
                self?.beginLiveVoiceCapture() ?? false
            },
            stopCapture: { [weak self] in
                self?.stopLiveVoiceCapture()
            },
            cancelCapture: { [weak self] in
                self?.cancelLiveVoiceCapture()
            }
        )
        assistantController.onStartLiveVoiceSession = { [weak self] surface in
            self?.liveVoiceCoordinator?.startLiveVoiceSession(surface: surface)
        }
        assistantController.onEndLiveVoiceSession = { [weak self] in
            self?.liveVoiceCoordinator?.endLiveVoiceSession()
        }
        assistantController.onStopLiveVoiceSpeaking = { [weak self] in
            self?.liveVoiceCoordinator?.stopSpeakingAndResumeListening()
        }
        syncAssistantCompactVisibility()
        assistantHUDObserver = assistantController.$hudState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuState()
            }
        assistantPermissionObserver = assistantController.$pendingPermissionRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuState()
            }

        windowCoordinator = AppWindowCoordinator(
            settings: settings,
            transcriptHistory: transcriptHistory,
            onStatusUpdate: { [weak self] status in
                self?.setUIStatus(status)
            },
            onInsertText: { [weak self] text in
                self?.insertText(text)
            }
        )
        windowCoordinator?.onAssistantWindowVisibilityChanged = { [weak self] isVisible in
            self?.isAssistantWindowVisible = isVisible
            self?.syncAssistantCompactVisibility()
        }
        settings.refreshMicrophones(notifyChange: false)
        syncWhisperModelSelectionIfNeeded()
        observeAdaptiveCorrectionChanges()
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        applyRecognitionSettingsToTranscriber()
        transcriber.applyWhisperSettings(
            selectedModelID: settings.selectedWhisperModelID,
            useCoreML: settings.whisperUseCoreML
        )
        transcriber.applyWhisperContextRetentionSettings(
            autoUnloadIdleContext: settings.whisperAutoUnloadIdleContextEnabled,
            idleContextUnloadDelaySeconds: settings.whisperIdleContextUnloadSeconds
        )
        transcriber.applyCloudTranscriptionSettings(
            provider: settings.cloudTranscriptionProvider,
            model: settings.cloudTranscriptionModel,
            baseURL: settings.cloudTranscriptionBaseURL,
            apiKey: settings.cloudTranscriptionAPIKey,
            requestTimeoutSeconds: settings.cloudTranscriptionRequestTimeoutSeconds
        )
        transcriber.setTranscriptionEngine(settings.transcriptionEngine)
        lastAppliedSettingsSnapshot = currentSettingsApplySnapshot()

        postInsertCorrectionMonitor.onCorrectionDetected = { [weak self] result in
            Task { @MainActor in
                self?.handleLearnedCorrection(
                    from: result.originalText,
                    correctedText: result.correctedText,
                    insertedText: result.insertedText
                )
            }
        }

        transcriber.onStatusUpdate = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                let presentation = TranscriberStatusInterpreter.interpret(message)

                switch presentation {
                case .persistent(let status):
                    if status == .finalizing {
                        self.playDictationFeedbackSound(.processing)
                    }
                    self.setUIStatus(status)

                case .transientFailure(let failureMessage):
                    self.waveform.flashEvent(
                        message: failureMessage,
                        symbolName: "exclamationmark.triangle.fill",
                        duration: 3.2
                    )
                    if !self.isDictating {
                        self.setUIStatus(.ready)
                    }
                }
            }
        }

        transcriber.onHUDAlert = { [weak self] alert in
            Task { @MainActor in
                guard let self else { return }
                switch alert {
                case .whisperStalled:
                    self.waveform.flashEvent(
                        message: "Whisper stalled and was reset. Retry now.",
                        symbolName: "exclamationmark.triangle.fill",
                        duration: 3.0
                    )
                case .whisperFailed:
                    self.waveform.flashEvent(
                        message: "Whisper failed. Check model and Core ML settings.",
                        symbolName: "xmark.octagon.fill",
                        duration: 2.4
                    )
                case .micFallbackToDefault:
                    self.waveform.flashEvent(
                        message: "Selected mic failed. Using default mic now.",
                        symbolName: "mic.slash.fill",
                        duration: 3.0
                    )
                case .micUnavailable:
                    let now = Date()
                    if let lastShown = self.lastAudioSetupHUDAlertAt,
                       now.timeIntervalSince(lastShown) < 2.0 {
                        return
                    }
                    self.lastAudioSetupHUDAlertAt = now
                    self.waveform.flashEvent(
                        message: "Microphone unavailable. Check macOS Sound Input, then retry.",
                        symbolName: "mic.slash.fill",
                        duration: 3.0
                    )
                }
            }
        }

        transcriber.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.currentAudioLevel = max(0, min(1, level))
                self.waveform.updateLevel(level)
                if self.liveVoiceCaptureActive {
                    self.assistantController.updateVoiceCaptureLevel(0)
                    self.assistantCompactHUD?.updateLevel(level)
                    self.evaluateLiveVoiceSilence(level: level)
                } else if self.assistantVoiceCaptureActive {
                    self.assistantController.updateVoiceCaptureLevel(level)
                    self.assistantCompactHUD?.updateLevel(level)
                    self.evaluateAssistantVoiceSilence(level: level)
                } else if self.compactVoiceCaptureActive {
                    self.assistantController.updateVoiceCaptureLevel(0)
                    self.assistantCompactHUD?.updateLevel(level)
                    self.evaluateCompactVoiceSilence(level: level)
                } else {
                    self.assistantController.updateVoiceCaptureLevel(0)
                    self.assistantCompactHUD?.updateLevel(0)
                }
                self.updateMenuState()
            }
        }

        transcriber.onRecordingStateChange = { [weak self] isRecording in
            Task { @MainActor in
                self?.isDictating = isRecording
                if !isRecording {
                    self?.currentAudioLevel = 0
                    self?.assistantController.updateVoiceCaptureLevel(0)
                    if let currentMode = self?.dictationInputMode {
                        self?.dictationInputMode = DictationInputModeStateMachine.onRecordingEnded(currentMode)
                    }
                    self?.stopStatusIconAnimation()
                    self?.updateMenuState()
                } else {
                    self?.startStatusIconAnimation()
                    self?.updateMenuState()
                }
            }
        }

        transcriber.onAudioWaveformBins = { [weak self] bins in
            Task { @MainActor in
                self?.waveform.updateBars(bins)
            }
        }

        transcriber.onFinalText = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                await self.handleFinalTranscript(text)
            }
        }

        settings.onChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleApplySettingsChanges()
            }
        }

        automationAPICoordinator.applySettings(settings)
        telegramRemoteCoordinator.applySettings(settings)
        assistantController.onTurnCompletion = { [weak self] status in
            Task { @MainActor in
                await self?.finishScheduledJobIfNeeded(status)
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }
            Task { @MainActor in
                self?.lastExternalApplication = app
            }
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
        }

        accessibilityTrustObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.accessibilityTrustDidBecomeGrantedNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.schedulePermissionRestartIfNeeded()
                self?.updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
            }
        }

        aiStudioRequestObserver = NotificationCenter.default.addObserver(
            forName: .openAssistOpenAIMemoryStudio,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowCoordinator?.openAIMemoryStudioWindow()
            }
        }

        settingsRequestObserver = NotificationCenter.default.addObserver(
            forName: .openAssistOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowCoordinator?.openSettingsWindow()
            }
        }

        assistantRequestObserver = NotificationCenter.default.addObserver(
            forName: .openAssistOpenAssistant,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openAssistantWindow()
            }
        }

        assistantSetupRequestObserver = NotificationCenter.default.addObserver(
            forName: .openAssistOpenAssistantSetup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openAssistantWindow()
                self?.windowCoordinator?.openSettingsWindow()
            }
        }

        scheduledJobRequestObserver = NotificationCenter.default.addObserver(
            forName: .openAssistRunScheduledJob,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let jobID = notification.userInfo?["jobID"] as? String,
                  let prompt = notification.userInfo?["prompt"] as? String else { return }
            let modelID = notification.userInfo?["preferredModelID"] as? String
            let effortRaw = notification.userInfo?["reasoningEffort"] as? String
            Task { @MainActor in
                await self?.runScheduledJob(
                    jobID: jobID,
                    prompt: prompt,
                    preferredModelID: modelID,
                    reasoningEffortRawValue: effortRaw
                )
            }
        }

        JobQueueCoordinator.shared.start()

        NotificationCenter.default.addObserver(
            forName: .openAssistSwitchToSession,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?["sessionID"] as? String else { return }
            Task { @MainActor in
                self?.openAssistantWindow()
                guard let self else { return }

                if let matchingSession = self.assistantController.sessions.first(where: {
                    $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(sessionID.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) {
                    await self.assistantController.openSession(matchingSession)
                } else {
                    self.assistantController.selectedSessionID = sessionID
                }
            }
        }

        assistantStartVoiceCaptureObserver = NotificationCenter.default.addObserver(
            forName: .openAssistStartAssistantVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginAssistantVoiceTaskCapture(stopMode: .manualRelease)
            }
        }

        assistantStopVoiceCaptureObserver = NotificationCenter.default.addObserver(
            forName: .openAssistStopAssistantVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAssistantVoiceCapture()
            }
        }

        assistantMinimizeToCompactObserver = NotificationCenter.default.addObserver(
            forName: .openAssistMinimizeAssistantToCompact,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.minimizeAssistantToCompact()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openAssistStartCompactVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginCompactVoiceCapture()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openAssistStopCompactVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopCompactVoiceCapture()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openAssistMinimizeAssistantToOrb,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.minimizeAssistantToCompact()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openAssistStartOrbVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginCompactVoiceCapture()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openAssistStopOrbVoiceCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopCompactVoiceCapture()
            }
        }

        startMemoryPressureMonitoring()
        updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)

        Task { @MainActor in
            LocalAISetupService.shared.ensureRuntimeReadyForCurrentConfiguration()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // --- Synchronous cleanup (instant) ---
        if let accessibilityTrustObserver {
            NotificationCenter.default.removeObserver(accessibilityTrustObserver)
            self.accessibilityTrustObserver = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        if let aiStudioRequestObserver {
            NotificationCenter.default.removeObserver(aiStudioRequestObserver)
            self.aiStudioRequestObserver = nil
        }
        if let settingsRequestObserver {
            NotificationCenter.default.removeObserver(settingsRequestObserver)
            self.settingsRequestObserver = nil
        }
        if let assistantRequestObserver {
            NotificationCenter.default.removeObserver(assistantRequestObserver)
            self.assistantRequestObserver = nil
        }
        if let assistantSetupRequestObserver {
            NotificationCenter.default.removeObserver(assistantSetupRequestObserver)
            self.assistantSetupRequestObserver = nil
        }
        if let assistantStartVoiceCaptureObserver {
            NotificationCenter.default.removeObserver(assistantStartVoiceCaptureObserver)
            self.assistantStartVoiceCaptureObserver = nil
        }
        if let assistantStopVoiceCaptureObserver {
            NotificationCenter.default.removeObserver(assistantStopVoiceCaptureObserver)
            self.assistantStopVoiceCaptureObserver = nil
        }
        if let assistantMinimizeToCompactObserver {
            NotificationCenter.default.removeObserver(assistantMinimizeToCompactObserver)
            self.assistantMinimizeToCompactObserver = nil
        }
        stopMemoryPressureMonitoring()
        settingsApplyWorkItem?.cancel()
        settingsApplyWorkItem = nil
        settings.onChange = nil
        automationAPICoordinator.stop()
        telegramRemoteCoordinator.stop()
        adaptiveCorrectionObserver?.cancel()
        adaptiveCorrectionObserver = nil
        assistantHUDObserver?.cancel()
        assistantHUDObserver = nil
        assistantPermissionObserver?.cancel()
        assistantPermissionObserver = nil
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = nil
        assistantLiveVoiceHotkeyManager?.stop()
        assistantLiveVoiceHotkeyManager = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        stopStatusIconAnimation()
        transcriber.stopRecording(emitFinalText: false)
        postInsertCorrectionMonitor.stopMonitoring(commitSession: false)
        assistantCompactHUD?.hide()
        waveform.hide()
        windowCoordinator?.closeAllWindows()
        windowCoordinator = nil
        isDictating = false
        dictationInputMode = .idle

        // --- Async cleanup with safety-net timeout ---
        // Using .terminateLater avoids blocking the main thread with semaphores,
        // which previously caused deadlocks when stop() dispatched back to main.
        let safetyNet = DispatchWorkItem { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }

        // Safety net: force-quit after 1 second even if stops haven't returned
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: safetyNet)

        Task.detached(priority: .userInitiated) {
            async let assistantStop: Void = AssistantStore.shared.runtime.stop()
            async let runtimeStop: Void = LocalAIRuntimeManager.shared.stop()
            _ = await (assistantStop, runtimeStop)
            DispatchQueue.main.async { [weak sender] in
                safetyNet.cancel()
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleMemoryPressureEvent(source.data)
        }
        source.resume()
        memoryPressureSource = source
    }

    private func stopMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    private func handleMemoryPressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
        let isCritical = event.contains(.critical)
        let levelDescription = isCritical ? "critical" : "warning"
        let beforeCount = promptRewriteConversationStore.contextDetails().count

        if isCritical {
            CrashReporter.logWarning(
                "Memory pressure event level=\(levelDescription); trimming caches aggressively."
            )
        } else {
            CrashReporter.logInfo(
                "Memory pressure event level=\(levelDescription); trimming caches."
            )
        }

        transcriber.trimMemoryUsage(aggressive: isCritical)
        promptRewriteConversationStore.trimMemoryUsage(aggressive: isCritical)
        if isCritical {
            URLCache.shared.removeAllCachedResponses()
        }

        let afterCount = promptRewriteConversationStore.contextDetails().count
        CrashReporter.logInfo(
            "Memory trim completed level=\(levelDescription) contexts=\(beforeCount)->\(afterCount)"
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updatePermissionGate(openOnboardingIfNeeded: true)
    }

    func checkForUpdatesFromSettings() {
        let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let buildVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let feedURLRaw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURLRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let feedURL = URL(string: feedURLRaw) else {
            let message = "Update feed URL is missing or invalid."
            updateCheckStatusStore.markFailed(message: message)
            setUIStatus(.message(message))
            waveform.flashEvent(message: message, symbolName: "exclamationmark.triangle.fill")
            CrashReporter.logError("Update check blocked: invalid feed URL")
            return
        }

        let updater = updaterController.updater
        guard updater.canCheckForUpdates else {
            let message = "An update check is already in progress."
            updateCheckStatusStore.markFailed(message: message)
            setUIStatus(.message(message))
            waveform.flashEvent(message: message, symbolName: "arrow.triangle.2.circlepath.circle.fill")
            CrashReporter.logWarning(
                "Update check blocked: updater busy version=\(shortVersion) build=\(buildVersion)"
            )
            return
        }

        cancelPendingUpdateCheckFallback()
        updateCheckStatusStore.beginCheck()
        CrashReporter.logInfo(
            "Update check started version=\(shortVersion) build=\(buildVersion) feed=\(feedURL.absoluteString)"
        )

        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.updateCheckStatusStore.isChecking else { return }

            let message = "Update check timed out. Opening Releases page."
            self.updateCheckStatusStore.markFailed(message: message)
            self.setUIStatus(.message(message))
            self.waveform.flashEvent(
                message: "Couldn't open update window. Opening Releases.",
                symbolName: "arrow.up.right.square.fill"
            )
            if let url = URL(string: UpdateCheckFallback.latestReleaseURLString) {
                NSWorkspace.shared.open(url)
            }
            self.pendingUpdateCheckFallbackWorkItem = nil
            NSApp.setActivationPolicy(.accessory)
            CrashReporter.logWarning(
                "Update check timed out after \(Int(UpdateCheckFallback.timeoutSeconds))s feed=\(feedURL.absoluteString)"
            )
        }
        pendingUpdateCheckFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + UpdateCheckFallback.timeoutSeconds,
            execute: fallbackWorkItem
        )

        // LSUIElement apps must temporarily activate to show Sparkle's update window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        CrashReporter.logInfo("Update check dispatched to Sparkle")
        updaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        cancelPendingUpdateCheckFallback()
        CrashReporter.logInfo(
            "Update check found valid update version=\(item.displayVersionString) build=\(item.versionString)"
        )
        updateCheckStatusStore.markUpdateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        cancelPendingUpdateCheckFallback()
        CrashReporter.logInfo("Update check completed with no update available")
        updateCheckStatusStore.markUpToDate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        cancelPendingUpdateCheckFallback()
        if isSparkleNoUpdateFoundError(error) {
            CrashReporter.logInfo("Update check aborted with no-update-found status (up to date)")
            updateCheckStatusStore.markUpToDate()
            return
        }
        let message = readableUpdateErrorMessage(error)
        CrashReporter.logError("Update check aborted: \(message)")
        updateCheckStatusStore.markFailed(message: message)
        setUIStatus(.message(message))
        waveform.flashEvent(message: message, symbolName: "exclamationmark.triangle.fill")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        cancelPendingUpdateCheckFallback()

        // Restore LSUIElement (accessory) mode after Sparkle's update UI is dismissed
        NSApp.setActivationPolicy(.accessory)

        guard updateCheckStatusStore.isChecking else { return }

        if let error {
            if isSparkleNoUpdateFoundError(error) {
                CrashReporter.logInfo("Update check finished with no-update-found status (up to date)")
                updateCheckStatusStore.markUpToDate()
            } else {
                let message = readableUpdateErrorMessage(error)
                CrashReporter.logError("Update check finished with error: \(message)")
                updateCheckStatusStore.markFailed(message: message)
                setUIStatus(.message(message))
                waveform.flashEvent(message: message, symbolName: "exclamationmark.triangle.fill")
            }
        } else {
            CrashReporter.logInfo("Update check finished successfully with no update available")
            updateCheckStatusStore.markUpToDate()
        }
    }

    private func isSparkleNoUpdateFoundError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        // Sparkle uses domain "SUSparkleErrorDomain" with code 5001 for SPUNoUpdateFoundError
        if nsError.domain == "SUSparkleErrorDomain" && nsError.code == 5001 {
            return true
        }
        // Fallback: detect by message content
        let desc = nsError.localizedDescription.lowercased()
        return desc.contains("up to date") || desc.contains("no update")
    }

    private func cancelPendingUpdateCheckFallback() {
        pendingUpdateCheckFallbackWorkItem?.cancel()
        pendingUpdateCheckFallbackWorkItem = nil
    }

    private func readableUpdateErrorMessage(_ error: any Error) -> String {
        let nsError = error as NSError
        if let failureReason = nsError.localizedFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !failureReason.isEmpty {
            return failureReason
        }
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Unknown update error." : description
    }

    private func currentPermissionSnapshot() -> PermissionCenter.Snapshot {
        PermissionCenter.snapshot(using: settings, includeExtendedPermissions: false)
    }

    private func updatePermissionGate(openOnboardingIfNeeded: Bool, reconfigureHotkeysIfReady: Bool = false) {
        let hadAccessibilityPermission = settings.accessibilityTrusted
        let snapshot = currentPermissionSnapshot()
        let wasReady = permissionsReady
        permissionsReady = snapshot.allRequiredGranted

        if permissionsReady {
            transcriber.requestPermissions(promptIfNeeded: false)
            if !hadAccessibilityPermission && snapshot.accessibilityGranted {
                schedulePermissionRestartIfNeeded()
            }
            windowCoordinator?.closePermissionOnboardingWindow()
            if !wasReady || reconfigureHotkeysIfReady {
                applyHotkeyMode()
                configurePasteLastTranscriptHotkey()
            }
            if !isDictating {
                setUIStatus(.ready)
            }
        } else {
            stopPermissionDependentFeatures()
            setUIStatus(.message(permissionGateMessage(for: snapshot)))
            if openOnboardingIfNeeded {
                windowCoordinator?.openPermissionOnboardingWindow(onComplete: { [weak self] in
                    Task { @MainActor in
                        self?.updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
                    }
                })
                requestStartupPermissionPromptIfNeeded()
            }
        }

        updateMenuState()
    }

    private func schedulePermissionRestartIfNeeded() {
        guard !hasScheduledPermissionRestart else { return }
        hasScheduledPermissionRestart = true

        let appURL = Bundle.main.bundleURL

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                CrashReporter.logError("Restart after permission grant failed: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func stopPermissionDependentFeatures() {
        if isDictating {
            transcriber.stopRecording(emitFinalText: false)
        }
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        assistantLiveVoiceHotkeyManager?.stop()
        assistantLiveVoiceHotkeyManager = nil
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = nil
        isDictating = false
        dictationInputMode = .idle
        currentAudioLevel = 0
        waveform.hide()
        stopStatusIconAnimation()
    }

    private func permissionGateMessage(for snapshot: PermissionCenter.Snapshot) -> String {
        var missingPermissions: [String] = []
        if !snapshot.accessibilityGranted {
            missingPermissions.append("Accessibility")
        }
        if !snapshot.microphoneGranted {
            missingPermissions.append("Microphone")
        }
        if snapshot.speechRecognitionRequired && !snapshot.speechRecognitionGranted {
            missingPermissions.append("Speech Recognition")
        }

        guard !missingPermissions.isEmpty else {
            return "Complete permission setup to start Open Assist"
        }

        if missingPermissions.count == 1, let permission = missingPermissions.first {
            return "Grant \(permission) permission to start Open Assist"
        }

        let permissionList = missingPermissions.joined(separator: ", ")
        return "Grant required permissions (\(permissionList)) to start Open Assist"
    }

    private func requestStartupPermissionPromptIfNeeded() {
        guard !didRequestStartupPermissionPrompt else { return }
        didRequestStartupPermissionPrompt = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard !self.permissionsReady else { return }
            self.transcriber.requestPermissions(promptIfNeeded: true)
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = "Open Assist"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Wire view model actions
        statusBarViewModel.onToggleDictation = { [weak self] in
            self?.popover?.close()
            self?.toggleContinuousDictation()
        }
        statusBarViewModel.onPasteLastTranscript = { [weak self] in
            self?.popover?.close()
            self?.pasteLastTranscriptFromHistory()
        }
        statusBarViewModel.onOpenHistory = { [weak self] in
            self?.popover?.close()
            self?.windowCoordinator?.openHistoryWindow()
        }
        statusBarViewModel.onOpenAIMemoryStudio = { [weak self] in
            self?.popover?.close()
            self?.windowCoordinator?.openAIMemoryStudioWindow()
        }
        statusBarViewModel.onOpenAssistant = { [weak self] in
            self?.popover?.close()
            self?.openAssistantWindow()
        }
        statusBarViewModel.onSpeakAssistantTask = { [weak self] in
            self?.popover?.close()
            self?.beginAssistantVoiceTaskCapture()
        }
        statusBarViewModel.onStopAssistant = { [weak self] in
            self?.popover?.close()
            self?.stopAssistantFromMenuBar()
        }
        statusBarViewModel.onOpenSettings = { [weak self] in
            self?.popover?.close()
            self?.windowCoordinator?.openSettingsWindow()
        }
        statusBarViewModel.onQuit = { [weak self] in
            self?.popover?.close()
            NSApplication.shared.terminate(nil)
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusBarPopoverView(viewModel: statusBarViewModel)
        )
        self.popover = popover
        updateMenuState(forcePopoverRefresh: true, forceIconRefresh: true)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            statusBarViewModel.isPopoverVisible = true
            updateMenuState(forcePopoverRefresh: true)
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        statusBarViewModel.isPopoverVisible = true
        updateMenuState(forcePopoverRefresh: true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusBarViewModel.isPopoverVisible = false
        if statusBarViewModel.currentAudioLevel != 0 {
            statusBarViewModel.currentAudioLevel = 0
        }
    }

    private func openAssistantWindow() {
        guard FeatureFlags.personalAssistantEnabled else {
            windowCoordinator?.openSettingsWindow()
            return
        }

        guard settings.assistantBetaEnabled else {
            setUIStatus(.message("Turn on Assistant in Settings first."))
            windowCoordinator?.openSettingsWindow()
            return
        }

        isAssistantWindowVisible = true
        syncAssistantCompactVisibility()
        windowCoordinator?.openAssistantWindow(
            rootView: AssistantWindowView(assistant: assistantController)
            .environmentObject(settings)
        )
    }

    private func minimizeAssistantToCompact() {
        guard settings.assistantFloatingHUDEnabled else { return }
        assistantCompactHUD?.setPreferredScreen(windowCoordinator?.assistantWindowScreen)
        windowCoordinator?.closeAssistantWindow()
        // The compact assistant becomes visible via syncAssistantCompactVisibility
        // (triggered by onAssistantWindowVisibilityChanged). If there is a selected
        // session, show its follow-up preview in the compact view.
        if let sessionID = assistantController.selectedSessionID,
           let session = assistantController.sessions.first(where: { $0.id == sessionID }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.assistantCompactHUD?.showFollowUp(for: session)
            }
        }
    }

    private func syncAssistantCompactVisibility() {
        assistantCompactHUD?.setPresentationStyle(settings.assistantCompactPresentationStyle)

        let shouldEnableCompactAssistant =
            FeatureFlags.personalAssistantEnabled
            && settings.assistantBetaEnabled
            && settings.assistantFloatingHUDEnabled
            && !isAssistantWindowVisible

        assistantCompactHUD?.isEnabled = shouldEnableCompactAssistant

        guard shouldEnableCompactAssistant else {
            assistantCompactHUD?.hide()
            return
        }

        assistantCompactHUD?.update(state: assistantController.hudState)
    }

    private func beginLiveVoiceCapture() -> Bool {
        guard FeatureFlags.personalAssistantEnabled else { return false }
        guard settings.assistantBetaEnabled else {
            liveVoiceCoordinator?.handleCaptureFailure("Turn on Assistant in Settings first.")
            return false
        }
        guard !isDictating else {
            liveVoiceCoordinator?.handleCaptureFailure("Finish the current recording first.")
            return false
        }

        assistantController.stopAssistantVoicePlayback()
        liveVoiceCaptureActive = true
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        startRecording()

        if !isDictating {
            liveVoiceCaptureActive = false
        }

        return isDictating
    }

    private func stopLiveVoiceCapture() {
        guard liveVoiceCaptureActive else { return }
        liveVoiceCoordinator?.beginTranscribingTurn()
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantCompactHUD?.updateLevel(0)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        stopStatusIconAnimation()
        updateMenuState()
    }

    private func cancelLiveVoiceCapture(message: String = "Live voice listening stopped.") {
        guard liveVoiceCaptureActive else { return }
        liveVoiceCaptureActive = false
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantCompactHUD?.updateLevel(0)
        transcriber.stopRecording(emitFinalText: false)
        isDictating = false
        currentAudioLevel = 0
        stopStatusIconAnimation()
        updateMenuState()
        liveVoiceCoordinator?.handleCaptureCancelled(message: message)
    }

    private func beginAssistantVoiceTaskCapture(stopMode: AssistantVoiceStopMode = .silenceAutoStop) {
        guard FeatureFlags.personalAssistantEnabled else { return }
        guard settings.assistantBetaEnabled else {
            setUIStatus(.message("Turn on Assistant in Settings first."))
            openAssistantWindow()
            return
        }
        guard settings.assistantVoiceTaskEntryEnabled else {
            assistantController.failVoiceDraft("Voice task entry is turned off in Assistant settings.")
            openAssistantWindow()
            return
        }
        guard !isDictating else {
            assistantController.failVoiceDraft("Finish the current recording first.")
            openAssistantWindow()
            return
        }

        openAssistantWindow()
        assistantController.stopAssistantVoicePlayback()
        assistantVoiceCaptureActive = true
        assistantVoiceStopMode = stopMode
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantController.prepareForVoiceCapture()
        startRecording()
    }

    func sendAssistantTypedPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !assistantController.attachments.isEmpty else { return }

        if assistantVoiceCaptureActive {
            assistantVoiceCaptureActive = false
            transcriber.stopRecording(emitFinalText: false)
            isDictating = false
            currentAudioLevel = 0
            waveform.hide()
            stopStatusIconAnimation()
            assistantController.cancelVoiceDraft("Switched to typed task.")
            setUIStatus(.ready)
            updateMenuState()
        }

        assistantController.stopAssistantVoicePlayback()

        Task { @MainActor in
            await assistantController.sendPrompt(trimmed)
            self.updateMenuState()
        }
    }

    private func runScheduledJob(
        jobID: String,
        prompt: String,
        preferredModelID: String?,
        reasoningEffortRawValue: String?
    ) async {
        let coordinator = JobQueueCoordinator.shared
        guard let job = coordinator.jobs.first(where: { $0.id == jobID }) else {
            coordinator.markJobExecutionFinished(id: jobID)
            return
        }
        scheduledJobInFlightID = jobID
        _ = coordinator.beginRun(jobID: jobID, startedAt: Date())
        let existingSessionID = coordinator.jobs.first(where: { $0.id == jobID })?.dedicatedSessionID

        if let preferredModelID {
            assistantController.chooseModel(preferredModelID)
        }
        if let reasoningEffortRawValue,
           let reasoningEffort = AssistantReasoningEffort(rawValue: reasoningEffortRawValue) {
            assistantController.reasoningEffort = reasoningEffort
        }

        // Set up the dedicated session for this job (resume existing or start fresh).
        guard let sessionID = await assistantController.resumeOrStartScheduledJobSession(existingID: existingSessionID) else {
            let note = "Failed — could not set up a session for this job."
            CrashReporter.logWarning("Scheduled job \(jobID): \(note)")
            coordinator.recordJobResult(id: jobID, note: note)
            await finishScheduledJobIfNeeded(nil, forcedOutcome: .failed, fallbackNote: note)
            return
        }
        coordinator.updateActiveRunSession(jobID: jobID, sessionID: sessionID)

        openAssistantWindow()
        try? await Task.sleep(nanoseconds: 500_000_000)

        guard !assistantController.hasActiveTurn else {
            let note = "Skipped — assistant was busy with another task."
            CrashReporter.logWarning("Scheduled job \(jobID): \(note)")
            coordinator.recordJobResult(id: jobID, note: note, sessionID: sessionID)
            await finishScheduledJobIfNeeded(nil, forcedOutcome: .interrupted, fallbackNote: note)
            return
        }

        coordinator.recordJobResult(id: jobID, note: "Prompt sent · session \(sessionID.prefix(8))…", sessionID: sessionID)
        await assistantController.sendPrompt(prompt, automationJob: job)

        if !assistantController.hasActiveTurn {
            CrashReporter.logWarning("Scheduled job \(jobID) did not start an assistant turn.")
            let note = "Submitted but no turn started — check model/provider config."
            coordinator.recordJobResult(id: jobID, note: note, sessionID: sessionID)
            await finishScheduledJobIfNeeded(nil, forcedOutcome: .failed, fallbackNote: note)
        }
    }

    private func finishScheduledJobIfNeeded(
        _ completionStatus: AssistantTurnCompletionStatus? = nil,
        forcedOutcome: ScheduledJobRunOutcome? = nil,
        fallbackNote: String? = nil
    ) async {
        guard let jobID = scheduledJobInFlightID else { return }
        scheduledJobInFlightID = nil
        let coordinator = JobQueueCoordinator.shared
        defer {
            coordinator.markJobExecutionFinished(id: jobID)
        }

        guard let job = coordinator.jobs.first(where: { $0.id == jobID }) else {
            return
        }

        let outcome: ScheduledJobRunOutcome = forcedOutcome ?? {
            switch completionStatus {
            case .completed:
                return .completed
            case .interrupted:
                return .interrupted
            case .failed:
                return .failed
            case .none:
                return .failed
            }
        }()

        let finishedAt = Date()
        var run = coordinator.activeRun(jobID: jobID) ?? ScheduledJobRun.make(jobID: jobID, startedAt: finishedAt)
        run.finishedAt = finishedAt
        run.outcome = outcome

        let sessionID = run.sessionID ?? job.dedicatedSessionID
        let history: ([AssistantTimelineItem], [AssistantTranscriptEntry])
        if let sessionID {
            history = await assistantController.loadSessionHistoryForAutomationSummary(sessionID: sessionID)
        } else {
            history = ([], [])
        }

        let sessionCWD = sessionID.flatMap { activeSessionID in
            assistantController.sessions.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(activeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            })?.cwd
        }

        let processed = await AutomationMemoryService.shared.processCompletedRun(
            job: job,
            run: run,
            transcript: history.1,
            timeline: history.0,
            cwd: sessionCWD
        )

        let resolvedNote: String
        if let fallbackNote = fallbackNote?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            resolvedNote = fallbackNote
        } else if case let .failed(message)? = completionStatus,
                  let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            resolvedNote = normalized
        } else {
            resolvedNote = processed.statusNote
        }

        coordinator.completeRun(
            jobID: jobID,
            outcome: outcome,
            statusNote: resolvedNote,
            summaryText: processed.summaryText,
            firstIssueAt: processed.firstIssueAt,
            learnedLessonCount: processed.learnedLessonCount,
            finishedAt: finishedAt
        )
    }

    private func disableAssistantBeta() {
        settings.assistantBetaEnabled = false
        stopAssistantExperience()
        setUIStatus(.ready)
        updateMenuState()
    }

    private func stopAssistantVoiceCapture() {
        guard assistantVoiceCaptureActive else { return }
        // Keep assistantVoiceCaptureActive = true so handleFinalTranscript routes to assistant
        assistantVoiceStopMode = .silenceAutoStop
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantController.finalizingVoiceCapture()
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        stopStatusIconAnimation()
        updateMenuState()
    }

    // MARK: - Compact Voice Capture

    private func beginCompactVoiceCapture(stopMode: AssistantVoiceStopMode = .manualRelease) {
        guard !isDictating else { return }
        guard permissionsReady else {
            updatePermissionGate(openOnboardingIfNeeded: true)
            assistantCompactHUD?.receiveVoiceTranscript("")
            return
        }

        assistantController.stopAssistantVoicePlayback()
        compactVoiceCaptureActive = true
        compactVoiceStopMode = stopMode
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantCompactHUD?.setVoiceRecording(true)
        startRecording()

        if !isDictating {
            compactVoiceCaptureActive = false
            compactVoiceStopMode = .manualRelease
            assistantCompactHUD?.receiveVoiceTranscript("")
        }
    }

    private func stopCompactVoiceCapture() {
        guard compactVoiceCaptureActive else { return }
        // Keep compactVoiceCaptureActive = true so handleFinalTranscript routes to the compact assistant.
        compactVoiceStopMode = .manualRelease
        assistantVoiceSilenceStart = nil
        assistantVoiceHasSpoken = false
        assistantVoiceBaselineSamples = []
        assistantVoiceBaselineCalibrated = false
        assistantCompactHUD?.setVoiceRecording(false)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        assistantCompactHUD?.updateLevel(0)
        stopStatusIconAnimation()
        updateMenuState()
    }

    private func evaluateLiveVoiceSilence(level: Float) {
        let calibrationSampleCount = 15
        let speechMultiplier: Float = 3.0
        let minimumSpeechThreshold: Float = 0.08
        let silenceDuration: TimeInterval = 2.0

        if !assistantVoiceBaselineCalibrated {
            assistantVoiceBaselineSamples.append(level)
            if assistantVoiceBaselineSamples.count >= calibrationSampleCount {
                let sum = assistantVoiceBaselineSamples.reduce(0, +)
                assistantVoiceBaselineNoise = sum / Float(assistantVoiceBaselineSamples.count)
                assistantVoiceBaselineCalibrated = true
            }
            return
        }

        let speechThreshold = max(assistantVoiceBaselineNoise * speechMultiplier, minimumSpeechThreshold)

        if level > speechThreshold {
            assistantVoiceHasSpoken = true
            assistantVoiceSilenceStart = nil
            return
        }

        guard assistantVoiceHasSpoken else { return }

        if assistantVoiceSilenceStart == nil {
            assistantVoiceSilenceStart = Date()
        }

        if let start = assistantVoiceSilenceStart,
           Date().timeIntervalSince(start) >= silenceDuration {
            stopLiveVoiceCapture()
        }
    }

    private func evaluateCompactVoiceSilence(level: Float) {
        guard compactVoiceStopMode == .silenceAutoStop else { return }

        let calibrationSampleCount = 15
        let speechMultiplier: Float = 3.0
        let minimumSpeechThreshold: Float = 0.08
        let silenceDuration: TimeInterval = 2.0

        if !assistantVoiceBaselineCalibrated {
            assistantVoiceBaselineSamples.append(level)
            if assistantVoiceBaselineSamples.count >= calibrationSampleCount {
                let sum = assistantVoiceBaselineSamples.reduce(0, +)
                assistantVoiceBaselineNoise = sum / Float(assistantVoiceBaselineSamples.count)
                assistantVoiceBaselineCalibrated = true
            }
            return
        }

        let speechThreshold = max(assistantVoiceBaselineNoise * speechMultiplier, minimumSpeechThreshold)

        if level > speechThreshold {
            assistantVoiceHasSpoken = true
            assistantVoiceSilenceStart = nil
            return
        }

        guard assistantVoiceHasSpoken else { return }

        if assistantVoiceSilenceStart == nil {
            assistantVoiceSilenceStart = Date()
        }

        if let start = assistantVoiceSilenceStart,
           Date().timeIntervalSince(start) >= silenceDuration {
            stopCompactVoiceCapture()
        }
    }

    private func evaluateAssistantVoiceSilence(level: Float) {
        guard assistantVoiceStopMode == .silenceAutoStop else { return }

        let calibrationSampleCount = 15
        let speechMultiplier: Float = 3.0
        let minimumSpeechThreshold: Float = 0.08
        let silenceDuration: TimeInterval = 2.0

        // Phase 1: Calibrate ambient noise baseline from initial samples
        if !assistantVoiceBaselineCalibrated {
            assistantVoiceBaselineSamples.append(level)
            if assistantVoiceBaselineSamples.count >= calibrationSampleCount {
                let sum = assistantVoiceBaselineSamples.reduce(0, +)
                assistantVoiceBaselineNoise = sum / Float(assistantVoiceBaselineSamples.count)
                assistantVoiceBaselineCalibrated = true
            }
            return
        }

        // Phase 2: Detect speech as significantly above ambient baseline
        let speechThreshold = max(assistantVoiceBaselineNoise * speechMultiplier, minimumSpeechThreshold)

        if level > speechThreshold {
            assistantVoiceHasSpoken = true
            assistantVoiceSilenceStart = nil
            return
        }

        // Phase 3: After user has spoken, wait for sustained silence to auto-stop
        guard assistantVoiceHasSpoken else { return }

        if assistantVoiceSilenceStart == nil {
            assistantVoiceSilenceStart = Date()
        }

        if let start = assistantVoiceSilenceStart,
           Date().timeIntervalSince(start) >= silenceDuration {
            stopAssistantVoiceCapture()
        }
    }

    private func stopAssistantFromMenuBar() {
        if liveVoiceCaptureActive {
            cancelLiveVoiceCapture()
            return
        }

        if assistantController.isLiveVoiceSessionActive {
            assistantController.endLiveVoiceSession()
            updateMenuState()
            return
        }

        if compactVoiceCaptureActive {
            compactVoiceCaptureActive = false
            compactVoiceStopMode = .manualRelease
            transcriber.stopRecording(emitFinalText: false)
            isDictating = false
            currentAudioLevel = 0
            assistantCompactHUD?.updateLevel(0)
            assistantCompactHUD?.receiveVoiceTranscript("")
            stopStatusIconAnimation()
            setUIStatus(.ready)
            updateMenuState()
            return
        }

        if assistantVoiceCaptureActive {
            assistantVoiceCaptureActive = false
            assistantVoiceStopMode = .silenceAutoStop
            transcriber.stopRecording(emitFinalText: false)
            isDictating = false
            currentAudioLevel = 0
            waveform.hide()
            stopStatusIconAnimation()
            assistantController.cancelVoiceDraft("Assistant listening stopped.")
            setUIStatus(.ready)
            updateMenuState()
            return
        }

        if assistantController.pendingPermissionRequest != nil {
            Task { @MainActor in
                await assistantController.cancelPermissionRequest()
                self.updateMenuState()
            }
            return
        }

        Task { @MainActor in
            await assistantController.cancelActiveTurn()
            self.updateMenuState()
        }
    }

    private func stopAssistantExperience() {
        if liveVoiceCaptureActive {
            cancelLiveVoiceCapture(message: "Live voice stopped.")
        }
        if assistantController.isLiveVoiceSessionActive {
            assistantController.endLiveVoiceSession()
        }
        if assistantVoiceCaptureActive {
            assistantVoiceCaptureActive = false
            assistantVoiceStopMode = .silenceAutoStop
            transcriber.stopRecording(emitFinalText: false)
        }
        assistantCompactHUD?.hide()
        Task { @MainActor in
            await assistantController.stopRuntime()
        }
        windowCoordinator?.closeAssistantWindow()
    }

    private func scheduleApplySettingsChanges() {
        settingsApplyWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.applySettingsChanges()
        }
        settingsApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.settingsApplyDebounceSeconds,
            execute: workItem
        )
    }

    private func currentSettingsApplySnapshot() -> SettingsApplySnapshot {
        SettingsApplySnapshot(
            autoDetectMicrophone: settings.autoDetectMicrophone,
            selectedMicrophoneUID: settings.selectedMicrophoneUID,
            shortcutKeyCode: settings.shortcutKeyCode,
            shortcutModifiers: settings.shortcutModifiers,
            continuousToggleShortcutKeyCode: settings.continuousToggleShortcutKeyCode,
            continuousToggleShortcutModifiers: settings.continuousToggleShortcutModifiers,
            assistantLiveVoiceShortcutKeyCode: settings.assistantLiveVoiceShortcutKeyCode,
            assistantLiveVoiceShortcutModifiers: settings.assistantLiveVoiceShortcutModifiers,
            muteSystemSoundsWhileHoldingShortcut: settings.muteSystemSoundsWhileHoldingShortcut,
            transcriptionEngineRawValue: settings.transcriptionEngineRawValue,
            cloudTranscriptionProviderRawValue: settings.cloudTranscriptionProviderRawValue,
            cloudTranscriptionModel: settings.cloudTranscriptionModel,
            cloudTranscriptionBaseURL: settings.cloudTranscriptionBaseURL,
            cloudTranscriptionRequestTimeoutSeconds: settings.cloudTranscriptionRequestTimeoutSeconds,
            cloudTranscriptionAPIKey: settings.cloudTranscriptionAPIKey,
            selectedWhisperModelID: settings.selectedWhisperModelID,
            whisperUseCoreML: settings.whisperUseCoreML,
            whisperAutoUnloadIdleContextEnabled: settings.whisperAutoUnloadIdleContextEnabled,
            whisperIdleContextUnloadSeconds: settings.whisperIdleContextUnloadSeconds,
            adaptiveCorrectionsEnabled: settings.adaptiveCorrectionsEnabled,
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            recognitionModeRawValue: settings.recognitionModeRawValue,
            autoPunctuation: settings.autoPunctuation,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases,
            assistantBetaEnabled: settings.assistantBetaEnabled
        )
    }

    private func applySettingsChanges() {
        let snapshot = currentSettingsApplySnapshot()
        let previousSnapshot = lastAppliedSettingsSnapshot

        let microphoneChanged = previousSnapshot == nil
            || previousSnapshot?.autoDetectMicrophone != snapshot.autoDetectMicrophone
            || previousSnapshot?.selectedMicrophoneUID != snapshot.selectedMicrophoneUID
        if microphoneChanged {
            settings.refreshMicrophones(notifyChange: false)
            transcriber.applyMicrophoneSettings(
                autoDetect: settings.autoDetectMicrophone,
                microphoneUID: settings.selectedMicrophoneUID
            )
        }

        let recognitionChanged = previousSnapshot == nil
            || previousSnapshot?.adaptiveCorrectionsEnabled != snapshot.adaptiveCorrectionsEnabled
            || previousSnapshot?.enableContextualBias != snapshot.enableContextualBias
            || previousSnapshot?.keepTextAcrossPauses != snapshot.keepTextAcrossPauses
            || previousSnapshot?.recognitionModeRawValue != snapshot.recognitionModeRawValue
            || previousSnapshot?.autoPunctuation != snapshot.autoPunctuation
            || previousSnapshot?.finalizeDelaySeconds != snapshot.finalizeDelaySeconds
            || previousSnapshot?.customContextPhrases != snapshot.customContextPhrases
        if recognitionChanged {
            applyRecognitionSettingsToTranscriber()
        }

        let engineChanged = previousSnapshot == nil
            || previousSnapshot?.transcriptionEngineRawValue != snapshot.transcriptionEngineRawValue
        let whisperRuntimeChanged = previousSnapshot == nil
            || previousSnapshot?.selectedWhisperModelID != snapshot.selectedWhisperModelID
            || previousSnapshot?.whisperUseCoreML != snapshot.whisperUseCoreML
            || previousSnapshot?.whisperAutoUnloadIdleContextEnabled != snapshot.whisperAutoUnloadIdleContextEnabled
            || previousSnapshot?.whisperIdleContextUnloadSeconds != snapshot.whisperIdleContextUnloadSeconds
        let cloudRuntimeChanged = previousSnapshot == nil
            || previousSnapshot?.cloudTranscriptionProviderRawValue != snapshot.cloudTranscriptionProviderRawValue
            || previousSnapshot?.cloudTranscriptionModel != snapshot.cloudTranscriptionModel
            || previousSnapshot?.cloudTranscriptionBaseURL != snapshot.cloudTranscriptionBaseURL
            || previousSnapshot?.cloudTranscriptionRequestTimeoutSeconds != snapshot.cloudTranscriptionRequestTimeoutSeconds
            || previousSnapshot?.cloudTranscriptionAPIKey != snapshot.cloudTranscriptionAPIKey
        if engineChanged || whisperRuntimeChanged {
            syncWhisperModelSelectionIfNeeded()
            transcriber.applyWhisperSettings(
                selectedModelID: settings.selectedWhisperModelID,
                useCoreML: settings.whisperUseCoreML
            )
            transcriber.applyWhisperContextRetentionSettings(
                autoUnloadIdleContext: settings.whisperAutoUnloadIdleContextEnabled,
                idleContextUnloadDelaySeconds: settings.whisperIdleContextUnloadSeconds
            )
        }
        if engineChanged || cloudRuntimeChanged {
            transcriber.applyCloudTranscriptionSettings(
                provider: settings.cloudTranscriptionProvider,
                model: settings.cloudTranscriptionModel,
                baseURL: settings.cloudTranscriptionBaseURL,
                apiKey: settings.cloudTranscriptionAPIKey,
                requestTimeoutSeconds: settings.cloudTranscriptionRequestTimeoutSeconds
            )
        }

        if engineChanged {
            transcriber.setTranscriptionEngine(settings.transcriptionEngine)
            updatePermissionGate(openOnboardingIfNeeded: false)
        }

        let hotkeysChanged = previousSnapshot == nil
            || previousSnapshot?.shortcutKeyCode != snapshot.shortcutKeyCode
            || previousSnapshot?.shortcutModifiers != snapshot.shortcutModifiers
            || previousSnapshot?.continuousToggleShortcutKeyCode != snapshot.continuousToggleShortcutKeyCode
            || previousSnapshot?.continuousToggleShortcutModifiers != snapshot.continuousToggleShortcutModifiers
            || previousSnapshot?.assistantLiveVoiceShortcutKeyCode != snapshot.assistantLiveVoiceShortcutKeyCode
            || previousSnapshot?.assistantLiveVoiceShortcutModifiers != snapshot.assistantLiveVoiceShortcutModifiers
            || previousSnapshot?.muteSystemSoundsWhileHoldingShortcut != snapshot.muteSystemSoundsWhileHoldingShortcut
        if hotkeysChanged {
            applyHotkeyMode()
            configurePasteLastTranscriptHotkey()
        }

        if (previousSnapshot?.adaptiveCorrectionsEnabled ?? true) && !settings.adaptiveCorrectionsEnabled {
            postInsertCorrectionMonitor.stopMonitoring(commitSession: false)
        }

        let assistantTurnedOff = (previousSnapshot?.assistantBetaEnabled ?? false) && !snapshot.assistantBetaEnabled
        if assistantTurnedOff {
            stopAssistantExperience()
        }

        syncAssistantCompactVisibility()

        automationAPICoordinator.applySettings(settings)
        telegramRemoteCoordinator.applySettings(settings)
        lastAppliedSettingsSnapshot = currentSettingsApplySnapshot()
        updateMenuState()
    }

    private func observeAdaptiveCorrectionChanges() {
        adaptiveCorrectionObserver = adaptiveCorrectionStore.$learnedCorrections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyRecognitionSettingsToTranscriber()
            }
    }

    private func applyRecognitionSettingsToTranscriber() {
        let adaptiveBiasPhrases: [String]
        if settings.adaptiveCorrectionsEnabled {
            adaptiveBiasPhrases = adaptiveCorrectionStore.preferredRecognitionPhrases()
        } else {
            adaptiveBiasPhrases = []
        }

        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            recognitionMode: settings.recognitionMode,
            autoPunctuation: settings.autoPunctuation,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases,
            adaptiveBiasPhrases: adaptiveBiasPhrases
        )
    }

    private func syncWhisperModelSelectionIfNeeded() {
        guard settings.transcriptionEngine == .whisperCpp else { return }

        whisperModelManager.refreshInstallStates()
        if whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
            return
        }

        if let fallbackModel = WhisperModelCatalog.curatedModels.first(where: { whisperModelManager.hasInstalledModel(id: $0.id) }) {
            settings.selectedWhisperModelID = fallbackModel.id
        } else {
            settings.selectedWhisperModelID = ""
        }
    }

    private func applyHotkeyMode() {
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        assistantLiveVoiceHotkeyManager?.stop()
        assistantLiveVoiceHotkeyManager = nil
        guard permissionsReady else { return }

        hotkeyManager = HoldToTalkManager(
            keyCode: settings.shortcutKeyCode,
            modifiers: settings.shortcutModifierFlags,
            suppressSystemShortcutSounds: settings.muteSystemSoundsWhileHoldingShortcut,
            onStart: { [weak self] in self?.startHoldToTalkDictation() },
            onStop: { [weak self] in self?.stopHoldToTalkDictation() }
        )
        hotkeyManager?.start()
        configureContinuousToggleHotkey()
        configureAssistantLiveVoiceHotkey()
        updateMenuState()
    }

    private func configureContinuousToggleHotkey() {
        if shortcutsConflict(
            lhsKeyCode: settings.continuousToggleShortcutKeyCode,
            lhsModifiers: settings.continuousToggleShortcutModifierFlags,
            rhsKeyCode: settings.shortcutKeyCode,
            rhsModifiers: settings.shortcutModifierFlags
        ) || shortcutsConflict(
            lhsKeyCode: settings.continuousToggleShortcutKeyCode,
            lhsModifiers: settings.continuousToggleShortcutModifierFlags,
            rhsKeyCode: PasteLastTranscriptShortcut.keyCode,
            rhsModifiers: PasteLastTranscriptShortcut.modifiers
        ) || shortcutsConflict(
            lhsKeyCode: settings.continuousToggleShortcutKeyCode,
            lhsModifiers: settings.continuousToggleShortcutModifierFlags,
            rhsKeyCode: settings.assistantLiveVoiceShortcutKeyCode,
            rhsModifiers: settings.assistantLiveVoiceShortcutModifierFlags
        ) {
            setUIStatus(.message("Fix shortcut conflicts in Settings to enable continuous toggle hotkey"))
            return
        }

        continuousToggleHotkeyManager = OneShotHotkeyManager(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiers: settings.continuousToggleShortcutModifierFlags
        ) { [weak self] in
            self?.toggleContinuousDictation()
        }
        continuousToggleHotkeyManager?.start()
    }

    private func configureAssistantLiveVoiceHotkey() {
        if shortcutsConflict(
            lhsKeyCode: settings.assistantLiveVoiceShortcutKeyCode,
            lhsModifiers: settings.assistantLiveVoiceShortcutModifierFlags,
            rhsKeyCode: settings.shortcutKeyCode,
            rhsModifiers: settings.shortcutModifierFlags
        ) || shortcutsConflict(
            lhsKeyCode: settings.assistantLiveVoiceShortcutKeyCode,
            lhsModifiers: settings.assistantLiveVoiceShortcutModifierFlags,
            rhsKeyCode: settings.continuousToggleShortcutKeyCode,
            rhsModifiers: settings.continuousToggleShortcutModifierFlags
        ) || shortcutsConflict(
            lhsKeyCode: settings.assistantLiveVoiceShortcutKeyCode,
            lhsModifiers: settings.assistantLiveVoiceShortcutModifierFlags,
            rhsKeyCode: PasteLastTranscriptShortcut.keyCode,
            rhsModifiers: PasteLastTranscriptShortcut.modifiers
        ) {
            setUIStatus(.message("Fix shortcut conflicts in Settings to enable the agent shortcut"))
            return
        }

        assistantLiveVoiceHotkeyManager = HoldToTalkManager(
            keyCode: settings.assistantLiveVoiceShortcutKeyCode,
            modifiers: settings.assistantLiveVoiceShortcutModifierFlags,
            suppressSystemShortcutSounds: settings.muteSystemSoundsWhileHoldingShortcut,
            onStart: { [weak self] in self?.startAssistantShortcutCapture() },
            onStop: { [weak self] in self?.stopAssistantShortcutCapture() }
        )
        assistantLiveVoiceHotkeyManager?.start()
    }

    private func shortcutsConflict(
        lhsKeyCode: UInt16,
        lhsModifiers: NSEvent.ModifierFlags,
        rhsKeyCode: UInt16,
        rhsModifiers: NSEvent.ModifierFlags
    ) -> Bool {
        lhsKeyCode == rhsKeyCode && lhsModifiers == rhsModifiers
    }

    private func configurePasteLastTranscriptHotkey() {
        pasteLastTranscriptHotkeyManager?.stop()
        guard permissionsReady else {
            pasteLastTranscriptHotkeyManager = nil
            return
        }
        pasteLastTranscriptHotkeyManager = OneShotHotkeyManager(
            keyCode: PasteLastTranscriptShortcut.keyCode,
            modifiers: PasteLastTranscriptShortcut.modifiers
        ) { [weak self] in
            self?.pasteLastTranscriptFromHistory()
        }
        pasteLastTranscriptHotkeyManager?.start()
    }

    private func startAssistantShortcutCapture() {
        guard FeatureFlags.personalAssistantEnabled else { return }
        guard settings.assistantBetaEnabled else {
            setUIStatus(.message("Turn on Assistant in Settings first."))
            windowCoordinator?.openSettingsWindow()
            return
        }

        if liveVoiceCaptureActive {
            cancelLiveVoiceCapture(message: "Live voice ended.")
        }
        if assistantController.isLiveVoiceSessionActive {
            assistantController.endLiveVoiceSession()
        }

        guard !isDictating else {
            setUIStatus(.message("Finish the current recording first."))
            updateMenuState()
            return
        }

        let shouldUseCompactSurface = settings.assistantFloatingHUDEnabled && !isAssistantWindowVisible
        if shouldUseCompactSurface {
            syncAssistantCompactVisibility()
            assistantCompactHUD?.prepareVoiceCaptureComposer()
            beginCompactVoiceCapture(stopMode: .manualRelease)
        } else {
            beginAssistantVoiceTaskCapture(stopMode: .manualRelease)
        }

        updateMenuState()
    }

    private func stopAssistantShortcutCapture() {
        if compactVoiceCaptureActive {
            stopCompactVoiceCapture()
            return
        }
        if assistantVoiceCaptureActive {
            stopAssistantVoiceCapture()
        }
    }


    private func startHoldToTalkDictation() {
        guard DictationInputModeStateMachine.onHoldStart(dictationInputMode) == .holdToTalk else {
            return
        }
        guard dictationInputMode == .idle else {
            return
        }

        if shouldBlockDictationShortcutInsideAssistant() {
            return
        }

        startRecording()
        if isDictating {
            dictationInputMode = .holdToTalk
        }
    }

    private func stopHoldToTalkDictation() {
        guard DictationInputModeStateMachine.onHoldStop(dictationInputMode) == .idle else {
            return
        }

        stopRecording()
        dictationInputMode = .idle
    }

    private func toggleContinuousDictation() {
        let nextMode = DictationInputModeStateMachine.onContinuousToggle(dictationInputMode)
        guard nextMode != dictationInputMode else {
            // Hold-to-talk active: ignore continuous toggle until hold cycle ends.
            return
        }

        switch nextMode {
        case .continuous:
            if shouldBlockDictationShortcutInsideAssistant() {
                return
            }
            startRecording()
            if isDictating {
                dictationInputMode = nextMode
                updateMenuState()
            }
        case .idle:
            dictationInputMode = nextMode
            stopRecording()
        case .holdToTalk:
            break
        }
    }

    private func shouldBlockDictationShortcutInsideAssistant() -> Bool {
        guard AssistantComposerBridge.shared.activeCaptureTarget != nil else { return false }
        setUIStatus(.message("Use the agent shortcut inside Open Assist."))
        return true
    }

    private func startRecording() {
        guard !isDictating else { return }
        guard permissionsReady else {
            updatePermissionGate(openOnboardingIfNeeded: true)
            if liveVoiceCaptureActive {
                liveVoiceCaptureActive = false
                liveVoiceCoordinator?.handleCaptureFailure(
                    "Live voice needs microphone and accessibility permissions."
                )
            }
            if assistantVoiceCaptureActive {
                assistantVoiceCaptureActive = false
                assistantVoiceStopMode = .silenceAutoStop
                assistantController.failVoiceDraft("Assistant voice capture needs microphone and accessibility permissions.")
            }
            if compactVoiceCaptureActive {
                compactVoiceCaptureActive = false
                compactVoiceStopMode = .manualRelease
                assistantCompactHUD?.receiveVoiceTranscript("")
            }
            return
        }
        postInsertCorrectionMonitor.stopMonitoring(commitSession: false)

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
            lastTargetApplication = frontmost
        } else if let fallback = lastExternalApplication, !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        currentAudioLevel = 0
        let started = transcriber.startRecording()
        isDictating = started

        if started {
            playDictationFeedbackSound(.startListening)
            setUIStatus(.listening)
            if !liveVoiceCaptureActive && !assistantVoiceCaptureActive && !compactVoiceCaptureActive {
                waveform.show()
            }
            startStatusIconAnimation()
        } else {
            if liveVoiceCaptureActive {
                liveVoiceCaptureActive = false
                liveVoiceCoordinator?.handleCaptureFailure("Open Assist could not start live voice listening.")
            }
            if assistantVoiceCaptureActive {
                assistantVoiceCaptureActive = false
                assistantVoiceStopMode = .silenceAutoStop
                assistantController.failVoiceDraft("Open Assist could not start voice capture.")
            }
            if compactVoiceCaptureActive {
                compactVoiceCaptureActive = false
                compactVoiceStopMode = .manualRelease
                assistantCompactHUD?.receiveVoiceTranscript("")
            }
            waveform.hide()
            stopStatusIconAnimation()
            updatePermissionGate(openOnboardingIfNeeded: true)
            if settings.transcriptionEngine == .whisperCpp,
               !whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
                setUIStatus(.message("Install a whisper model in Settings > Recognition to start dictation"))
                windowCoordinator?.openSettingsWindow()
            } else if settings.transcriptionEngine == .cloudProviders,
                      settings.cloudTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setUIStatus(.message("Add a cloud provider API key in Settings > Recognition to start dictation"))
                windowCoordinator?.openSettingsWindow()
            }
        }

        updateMenuState()
    }

    private func stopRecording() {
        guard isDictating else {
            waveform.hide()
            stopStatusIconAnimation()
            updateMenuState()
            return
        }

        setUIStatus(.finalizing)
        playDictationFeedbackSound(.stopListening)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        waveform.hide()
        stopStatusIconAnimation()
        updateMenuState()
    }

    private func handleFinalTranscript(_ text: String) async {
        let cleaned = TextCleanup.process(text, mode: settings.textCleanupMode)

        if liveVoiceCaptureActive {
            liveVoiceCaptureActive = false
            assistantVoiceSilenceStart = nil
            assistantVoiceHasSpoken = false
            assistantVoiceBaselineSamples = []
            assistantVoiceBaselineCalibrated = false
            liveVoiceCoordinator?.handleFinalTranscript(cleaned)
            setUIStatus(.ready)
            updateMenuState()
            return
        }

        if compactVoiceCaptureActive {
            compactVoiceCaptureActive = false
            compactVoiceStopMode = .manualRelease
            assistantVoiceBaselineSamples = []
            assistantVoiceBaselineCalibrated = false
            if settings.promptRewriteEnabled {
                assistantController.showTransientHUDState(AssistantHUDState(
                    phase: .thinking,
                    title: "Refining",
                    detail: "Applying AI corrections to your message"
                ))
            }
            let refinedAssistantDraft = await refinedAssistantVoiceDraft(from: cleaned)
            assistantCompactHUD?.receiveVoiceTranscript(refinedAssistantDraft)
            setUIStatus(.ready)
            updateMenuState()
            return
        }

        if assistantVoiceCaptureActive {
            assistantVoiceCaptureActive = false
            assistantVoiceStopMode = .silenceAutoStop
            assistantVoiceBaselineSamples = []
            assistantVoiceBaselineCalibrated = false
            openAssistantWindow()
            if settings.promptRewriteEnabled {
                assistantController.showTransientHUDState(AssistantHUDState(
                    phase: .thinking,
                    title: "Refining",
                    detail: "Applying AI corrections to your message"
                ))
            }
            let refinedAssistantDraft = await refinedAssistantVoiceDraft(from: cleaned)
            assistantController.receiveVoiceDraft(refinedAssistantDraft)
            setUIStatus(.ready)
            updateMenuState()
            return
        }

        guard !cleaned.isEmpty else {
            if !isDictating {
                setUIStatus(.ready)
            }
            return
        }

        if insertTranscriptIntoAssistantComposerIfPossible(cleaned) {
            if !isDictating {
                setUIStatus(.ready)
            }
            updateMenuState()
            return
        }

        let insertionSessionContext = capturePromptRewriteSessionContext()
        let rewriteResolution: PromptRewriteInsertionResolution
        if settings.promptRewriteEnabled {
            guard let resolved = await resolvePromptRewriteInsertionText(
                for: cleaned,
                insertionSessionContext: insertionSessionContext
            ) else {
                if !isDictating {
                    setUIStatus(.ready)
                }
                return
            }
            rewriteResolution = resolved
        } else {
            rewriteResolution = PromptRewriteInsertionResolution(
                insertionText: cleaned,
                conversationContext: nil,
                insertionHUDContext: insertionSessionContext.insertionHUDContext
            )
        }

        let readyForInsert: String
        if rewriteResolution.preserveInsertionText {
            readyForInsert = rewriteResolution.insertionText
        } else {
            readyForInsert = applyAdaptiveCorrectionsIfNeeded(to: rewriteResolution.insertionText)
        }
        if settings.promptRewriteEnabled,
           let conversationContext = rewriteResolution.conversationContext {
            promptRewriteConversationStore.recordTurn(
                originalText: cleaned,
                finalText: readyForInsert,
                context: conversationContext,
                timeoutMinutes: settings.promptRewriteConversationTimeoutMinutes,
                maxTurns: settings.promptRewriteConversationTurnLimit
            )
        }
        transcriptHistory.add(readyForInsert)
        insertText(
            readyForInsert,
            trackCorrections: settings.adaptiveCorrectionsEnabled,
            insertionContext: rewriteResolution.insertionHUDContext,
            forceActivateTargetBeforeInsert: rewriteResolution.forceTargetRefocusBeforeInsert
        )
        if !isDictating {
            setUIStatus(.ready)
        }
    }

    private func refinedAssistantVoiceDraft(from transcript: String) async -> String {
        await assistantVoiceDraftRefinementService.refine(
            transcript,
            aiCorrectionEnabled: settings.promptRewriteEnabled
        )
    }

    @MainActor
    private func insertTranscriptIntoAssistantComposerIfPossible(_ text: String) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              AssistantComposerBridge.shared.canInsertIntoActiveComposer,
              AssistantComposerBridge.shared.insert(text) else {
            return false
        }

        transcriptHistory.add(text)
        playDictationFeedbackSound(.pasted)
        return true
    }

    private func resolvePromptRewriteInsertionText(
        for cleanedTranscript: String,
        insertionSessionContext: PromptRewriteSessionContext
    ) async -> PromptRewriteInsertionResolution? {
        guard settings.promptRewriteEnabled else {
            return PromptRewriteInsertionResolution(
                insertionText: cleanedTranscript,
                conversationContext: nil,
                insertionHUDContext: insertionSessionContext.insertionHUDContext
            )
        }

        let conversationRequestContext = promptRewriteConversationRequestContext(
            for: insertionSessionContext.conversationContext,
            userText: cleanedTranscript
        )
        let conversationContext = conversationRequestContext?.activeContext
        let conversationHistory = conversationRequestContext?.mergedHistory ?? []
        let loadingNarrative = makePromptRewriteLoadingNarrative(
            cleanedTranscript: cleanedTranscript,
            conversationHistoryTurnCount: conversationHistory.count
        )

        if let conversationRequestContext {
            scheduleMappingEvaluationIfNeeded(
                resolvedBundle: conversationRequestContext,
                capturedContext: insertionSessionContext.conversationContext,
                userText: cleanedTranscript
            )
        }

        while true {
            do {
                let refinementStart = Date()
                PromptRewriteHUDManager.shared.showLoadingIndicator(
                    insertionContext: insertionSessionContext.insertionHUDContext,
                    displayState: loadingNarrative.displayState(step: "Preparing rewrite request")
                )
                let retrievalOutcome: PromptRewriteRetrievalOutcome
                do {
                    defer {
                        PromptRewriteHUDManager.shared.hideLoadingIndicator(
                            insertionContext: insertionSessionContext.insertionHUDContext
                        )
                    }
                    retrievalOutcome = try await retrievePromptRewriteSuggestionOrBypass(
                        for: cleanedTranscript,
                        conversationContext: conversationContext,
                        conversationHistory: conversationHistory,
                        insertionContext: insertionSessionContext.insertionHUDContext,
                        loadingNarrative: loadingNarrative
                    )
                }

                if case .bypassed = retrievalOutcome {
                    await recordPromptRewriteFeedback(
                        action: .insertedOriginal,
                        originalText: cleanedTranscript,
                        finalInsertedText: cleanedTranscript,
                        failureDetail: "user-paused-ai-refinement"
                    )
                    setUIStatus(.message("AI refinement paused - using transcript"))
                    return PromptRewriteInsertionResolution(
                        insertionText: cleanedTranscript,
                        conversationContext: conversationContext,
                        insertionHUDContext: insertionSessionContext.insertionHUDContext,
                        preserveInsertionText: true,
                        forceTargetRefocusBeforeInsert: true
                    )
                }

                let rawSuggestion: PromptRewriteSuggestion?
                switch retrievalOutcome {
                case let .suggestion(suggestion):
                    rawSuggestion = suggestion
                case .bypassed:
                    rawSuggestion = nil
                }

                guard let rawSuggestion else {
                    return PromptRewriteInsertionResolution(
                        insertionText: cleanedTranscript,
                        conversationContext: conversationContext,
                        insertionHUDContext: insertionSessionContext.insertionHUDContext
                    )
                }
                let refinementElapsed = Date().timeIntervalSince(refinementStart)
                let suggestion = formatPromptRewriteSuggestion(
                    rawSuggestion,
                    originalText: cleanedTranscript,
                    refinementDurationSeconds: refinementElapsed
                )
                let autoInsertEnabled = settings.promptRewriteAutoInsertEnabled
                let autoInsertThreshold = Self.promptRewriteAutoInsertMinimumConfidence
                let suggestionConfidence = suggestion.confidence
                let suggestionConfidenceString = suggestionConfidence.map { value in
                    String(format: "%.3f", value)
                } ?? "nil"
                let thresholdString = String(format: "%.3f", autoInsertThreshold)

                if autoInsertEnabled,
                   let suggestionConfidence,
                   suggestionConfidence >= autoInsertThreshold {
                    CrashReporter.logInfo(
                        "Prompt rewrite insertion decision=auto-insert " +
                        "provider=\(settings.promptRewriteProviderModeRawValue) " +
                        "confidence=\(suggestionConfidenceString) " +
                        "threshold=\(thresholdString) " +
                        "continuity=\(suggestion.continuityTrace ?? "none")"
                    )
                    await recordPromptRewriteFeedback(
                        action: .autoInsertedSuggested,
                        originalText: cleanedTranscript,
                        suggestedText: suggestion.suggestedText,
                        finalInsertedText: suggestion.suggestedText
                    )
                    return PromptRewriteInsertionResolution(
                        insertionText: suggestion.suggestedText,
                        conversationContext: conversationContext,
                        insertionHUDContext: insertionSessionContext.insertionHUDContext
                    )
                }

                let previewReason: String
                if !autoInsertEnabled {
                    previewReason = "auto-insert-disabled"
                } else if suggestionConfidence == nil {
                    previewReason = "confidence-missing"
                } else {
                    previewReason = "below-threshold"
                }
                CrashReporter.logInfo(
                    "Prompt rewrite insertion decision=preview " +
                    "provider=\(settings.promptRewriteProviderModeRawValue) " +
                    "reason=\(previewReason) " +
                    "confidence=\(suggestionConfidenceString) " +
                    "threshold=\(thresholdString) " +
                    "continuity=\(suggestion.continuityTrace ?? "none")"
                )

                while true {
                    switch await presentPromptRewritePreviewDialog(
                        originalText: cleanedTranscript,
                        suggestion: suggestion,
                        insertionContext: insertionSessionContext.insertionHUDContext
                    ) {
                    case .useSuggested:
                        await recordPromptRewriteFeedback(
                            action: .usedSuggested,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: suggestion.suggestedText
                        )
                        return PromptRewriteInsertionResolution(
                            insertionText: suggestion.suggestedText,
                            conversationContext: conversationContext,
                            insertionHUDContext: insertionSessionContext.insertionHUDContext
                        )
                    case .editThenInsert:
                        guard let edited = presentPromptRewriteEditDialog(initialText: suggestion.suggestedText) else {
                            continue
                        }
                        let normalizedEdited = PromptRewriteFormatting.prepareEditedTextForInsertion(
                            edited,
                            forceMarkdown: settings.promptRewriteAlwaysConvertToMarkdown
                        )
                        let finalEdited = normalizedEdited.isEmpty ? edited : normalizedEdited
                        await recordPromptRewriteFeedback(
                            action: .editedThenInserted,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: finalEdited
                        )
                        return PromptRewriteInsertionResolution(
                            insertionText: finalEdited,
                            conversationContext: conversationContext,
                            insertionHUDContext: insertionSessionContext.insertionHUDContext
                        )
                    case .insertOriginal:
                        await recordPromptRewriteFeedback(
                            action: .insertedOriginal,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: cleanedTranscript
                        )
                        return PromptRewriteInsertionResolution(
                            insertionText: cleanedTranscript,
                            conversationContext: conversationContext,
                            insertionHUDContext: insertionSessionContext.insertionHUDContext,
                            preserveInsertionText: true,
                            forceTargetRefocusBeforeInsert: true
                        )
                    case .rejectSuggestion:
                        await recordPromptRewriteFeedback(
                            action: .dismissedSuggestion,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText
                        )
                        return nil
                    }
                }
            } catch {
                let failureDetail = promptRewriteFailureDetail(for: error)
                switch presentPromptRewriteFailureDialog(failureDetail: failureDetail) {
                case .retry:
                    await recordPromptRewriteFeedback(
                        action: .retriedAfterFailure,
                        originalText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    continue
                case .insertOriginal:
                    await recordPromptRewriteFeedback(
                        action: .insertedOriginalAfterFailure,
                        originalText: cleanedTranscript,
                        finalInsertedText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    return PromptRewriteInsertionResolution(
                        insertionText: cleanedTranscript,
                        conversationContext: conversationContext,
                        insertionHUDContext: insertionSessionContext.insertionHUDContext,
                        preserveInsertionText: true,
                        forceTargetRefocusBeforeInsert: true
                    )
                case .close:
                    await recordPromptRewriteFeedback(
                        action: .canceledAfterFailure,
                        originalText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    return nil
                }
            }
        }
    }

    private func makePromptRewriteLoadingNarrative(
        cleanedTranscript: String,
        conversationHistoryTurnCount: Int
    ) -> PromptRewriteLoadingNarrative {
        let transcript = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let aiSuggestionsEnabled = settings.promptRewriteEnabled
        guard aiSuggestionsEnabled else {
            return PromptRewriteLoadingNarrative(
                transcript: transcript,
                aiSuggestionsEnabled: false,
                aiGenerationSummary: "AI suggestions are disabled. Open Assist will insert the cleaned transcription as-is.",
                aiRuntimeSummary: nil
            )
        }

        let providerLabel = settings.promptRewriteProviderMode.displayName
        let configuredModel = settings.promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelLabel = configuredModel.isEmpty
            ? settings.promptRewriteProviderMode.defaultModel
            : configuredModel
        let styleLabel = settings.promptRewriteStylePreset.rawValue
            .replacingOccurrences(of: " (Default)", with: "")
        let historyPhrase = conversationHistoryTurnCount > 0
            ? "\(conversationHistoryTurnCount) prior turn(s)"
            : "current utterance only"
        let insertionPath = settings.promptRewriteAutoInsertEnabled
            ? "auto-insert for high confidence"
            : "manual preview before insert"
        let processNarrative = "Improving clarity, grammar, and tone from your transcript while preserving intent."
        let contextNarrative = "Context source: \(historyPhrase)."
        let decisionNarrative = "Decision path: \(insertionPath)."

        return PromptRewriteLoadingNarrative(
            transcript: transcript,
            aiSuggestionsEnabled: true,
            aiGenerationSummary: "\(processNarrative) Style profile: \(styleLabel). \(contextNarrative) \(decisionNarrative)",
            aiRuntimeSummary: "\(providerLabel) · \(modelLabel)"
        )
    }

    private func retrievePromptRewriteSuggestionOrBypass(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn],
        insertionContext: PromptRewriteInsertionHUDContext,
        loadingNarrative: PromptRewriteLoadingNarrative
    ) async throws -> PromptRewriteRetrievalOutcome {
        PromptRewriteHUDManager.shared.clearLoadingBypassRequest(insertionContext: insertionContext)
        PromptRewriteHUDManager.shared.updateLoadingIndicator(
            insertionContext: insertionContext,
            displayState: loadingNarrative.displayState(step: "Preparing rewrite request")
        )

        PromptRewriteHUDManager.shared.updateLoadingIndicator(
            insertionContext: insertionContext,
            displayState: loadingNarrative.displayState(step: "Connecting to AI suggestion service")
        )
        return try await withThrowingTaskGroup(of: PromptRewriteRetrievalOutcome.self) { group in
            group.addTask {
                await PromptRewriteHUDManager.shared.updateLoadingIndicator(
                    insertionContext: insertionContext,
                    displayState: loadingNarrative.displayState(step: "Sending transcript for rewrite suggestion")
                )

                // Drip-feed progress while waiting for the API response
                let progressDripTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: 1_800_000_000)
                        guard !Task.isCancelled else { return }
                        await PromptRewriteHUDManager.shared.updateLoadingIndicator(
                            insertionContext: insertionContext,
                            displayState: loadingNarrative.displayState(step: "Waiting for AI response")
                        )
                        try await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        await PromptRewriteHUDManager.shared.updateLoadingIndicator(
                            insertionContext: insertionContext,
                            displayState: loadingNarrative.displayState(step: "Analyzing transcript context")
                        )
                        try await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        await PromptRewriteHUDManager.shared.updateLoadingIndicator(
                            insertionContext: insertionContext,
                            displayState: loadingNarrative.displayState(step: "Receiving and normalizing AI response")
                        )
                    } catch {
                        // Cancellation is expected when the suggestion returns quickly.
                    }
                }
                defer { progressDripTask.cancel() }

                let suggestion = try await PromptRewriteService.shared.retrieveSuggestion(
                    for: cleanedTranscript,
                    conversationContext: conversationContext,
                    conversationHistory: conversationHistory,
                    onPartialSuggestion: { partialPreview in
                        progressDripTask.cancel()
                        Task { @MainActor in
                            PromptRewriteHUDManager.shared.updateLoadingIndicator(
                                insertionContext: insertionContext,
                                displayState: loadingNarrative.displayState(
                                    step: "Receiving live AI draft",
                                    partialPreviewText: partialPreview,
                                    isStreamingPreviewActive: true
                                )
                            )
                        }
                    }
                )
                return .suggestion(suggestion)
            }

            group.addTask {
                while true {
                    if await PromptRewriteHUDManager.shared.consumeLoadingBypassRequest(
                        insertionContext: insertionContext
                    ) {
                        await PromptRewriteHUDManager.shared.updateLoadingIndicator(
                            insertionContext: insertionContext,
                            displayState: loadingNarrative.displayState(step: "Paused AI refinement. Restoring transcript")
                        )
                        return .bypassed
                    }
                    if Task.isCancelled {
                        return .suggestion(nil)
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }

            guard let firstResult = try await group.next() else {
                group.cancelAll()
                return .suggestion(nil)
            }

            PromptRewriteHUDManager.shared.updateLoadingIndicator(
                insertionContext: insertionContext,
                displayState: loadingNarrative.displayState(step: "Finalizing rewrite decision")
            )
            group.cancelAll()
            return firstResult
        }
    }

    private func promptRewriteConversationRequestContext(
        for capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> ConversationContextResolverV2.ResolvedContextBundle? {
        guard settings.promptRewriteEnabled else {
            return nil
        }

        guard let requestContext = conversationContextResolverV2.resolve(
            capturedContext: capturedContext,
            userText: userText,
            timeoutMinutes: settings.promptRewriteConversationTimeoutMinutes,
            turnLimit: settings.promptRewriteConversationTurnLimit,
            pinnedContextID: settings.promptRewriteConversationPinnedContextID
        ) else {
            return nil
        }

        logPromptRewriteMappingTelemetry(
            mappingSource: "resolver",
            linkedContextCount: requestContext.linkedContextIDs.count,
            mergeTurns: requestContext.mergedHistory.count,
            aiMatchTimeout: false,
            detail: requestContext.resolutionTrace
        )

        let pinnedID = settings.promptRewriteConversationPinnedContextID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinnedID.isEmpty, !requestContext.usesPinnedContext {
            settings.promptRewriteConversationPinnedContextID = ""
        }

        return requestContext
    }

    private func scheduleMappingEvaluationIfNeeded(
        resolvedBundle: ConversationContextResolverV2.ResolvedContextBundle,
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) {
        let linkedContextCount = resolvedBundle.linkedContextIDs.count
        let mergeTurns = resolvedBundle.mergedHistory.count
        guard linkedContextCount == 0 else {
            logPromptRewriteMappingTelemetry(
                mappingSource: "linked-existing",
                linkedContextCount: linkedContextCount,
                mergeTurns: mergeTurns,
                aiMatchTimeout: false,
                detail: "skipped_mapping=true reason=linked-existing"
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let deterministicCandidate = await self.evaluateDeterministicMappingCandidateOffMain(
                capturedContext: capturedContext,
                userText: userText
            )

            if let deterministicCandidate {
                let matchType = deterministicCandidate.matchType.rawValue
                if deterministicCandidate.matchType == .exact
                    || deterministicCandidate.confidence >= Self.deterministicMappingHighConfidenceThreshold {
                    self.conversationContextResolverV2.persistMappingDecision(
                        .link,
                        prompt: deterministicCandidate.prompt,
                        source: .deterministic
                    )
                    self.setUIStatus(.message("Linked related conversation"))
                    self.logPromptRewriteMappingTelemetry(
                        mappingSource: "deterministic",
                        linkedContextCount: linkedContextCount,
                        mergeTurns: mergeTurns,
                        aiMatchTimeout: false,
                        detail: "candidate_found=true auto_linked=true match_axis=\(deterministicCandidate.matchAxis.rawValue) match_type=\(matchType) confidence=\(String(format: "%.3f", deterministicCandidate.confidence))"
                    )
                    return
                }
                self.logPromptRewriteMappingTelemetry(
                    mappingSource: "deterministic",
                    linkedContextCount: linkedContextCount,
                    mergeTurns: mergeTurns,
                    aiMatchTimeout: false,
                    detail: "candidate_found=true auto_linked=false match_axis=\(deterministicCandidate.matchAxis.rawValue) match_type=\(matchType) confidence=\(String(format: "%.3f", deterministicCandidate.confidence)) below_threshold=true"
                )
            } else {
                self.logPromptRewriteMappingTelemetry(
                    mappingSource: "deterministic",
                    linkedContextCount: linkedContextCount,
                    mergeTurns: mergeTurns,
                    aiMatchTimeout: false,
                    detail: "candidate_found=false"
                )
            }

            let evaluationStartedAt = Date()
            let aiCandidate = await self.evaluateAIMappingCandidateOffMain(
                capturedContext: capturedContext,
                userText: userText
            )
            let elapsed = Date().timeIntervalSince(evaluationStartedAt)
            let timedOut = elapsed > Self.aiMappingTimeoutSeconds

            if timedOut {
                self.logPromptRewriteMappingTelemetry(
                    mappingSource: "ai",
                    linkedContextCount: linkedContextCount,
                    mergeTurns: mergeTurns,
                    aiMatchTimeout: true,
                    detail: "candidate_found=unknown elapsed_ms=\(Int((elapsed * 1_000).rounded()))"
                )
                return
            }

            guard let aiCandidate else {
                self.logPromptRewriteMappingTelemetry(
                    mappingSource: "ai",
                    linkedContextCount: linkedContextCount,
                    mergeTurns: mergeTurns,
                    aiMatchTimeout: false,
                    detail: "candidate_found=false"
                )
                return
            }

            guard aiCandidate.confidence >= Self.aiMappingHighConfidenceThreshold else {
                self.logPromptRewriteMappingTelemetry(
                    mappingSource: "ai",
                    linkedContextCount: linkedContextCount,
                    mergeTurns: mergeTurns,
                    aiMatchTimeout: false,
                    detail: "candidate_found=true auto_linked=false confidence=\(String(format: "%.3f", aiCandidate.confidence)) below_threshold=true"
                )
                return
            }

            self.conversationContextResolverV2.persistMappingDecision(
                .link,
                prompt: aiCandidate.prompt,
                source: .ai
            )
            self.setUIStatus(.message("Linked related conversation"))
            self.logPromptRewriteMappingTelemetry(
                mappingSource: "ai",
                linkedContextCount: linkedContextCount,
                mergeTurns: mergeTurns,
                aiMatchTimeout: false,
                detail: "candidate_found=true auto_linked=true confidence=\(String(format: "%.3f", aiCandidate.confidence)) fallback_from=deterministic"
            )
        }
    }

    private func evaluateDeterministicMappingCandidateOffMain(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) async -> ConversationContextResolverV2.DeterministicMappingCandidate? {
        await MainActor.run {
            self.conversationContextResolverV2.evaluateDeterministicMappingCandidate(
                capturedContext: capturedContext,
                userText: userText
            )
        }
    }

    private func evaluateAIMappingCandidateOffMain(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) async -> PromptRewriteAIMappingCandidate? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let candidate = PromptRewriteAIMappingEvaluator.evaluate(
                    capturedContext: capturedContext,
                    userText: userText
                )
                continuation.resume(returning: candidate)
            }
        }
    }

    private func logPromptRewriteMappingTelemetry(
        mappingSource: String,
        linkedContextCount: Int,
        mergeTurns: Int,
        aiMatchTimeout: Bool,
        detail: String? = nil
    ) {
        var message = "Prompt rewrite mapping telemetry"
        message += " mapping_source=\(mappingSource)"
        message += " linked_context_count=\(linkedContextCount)"
        message += " merge_turns=\(mergeTurns)"
        message += " ai_match_timeout=\(aiMatchTimeout)"
        if let detail,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += " \(detail)"
        }
        CrashReporter.logInfo(message)
    }

    private func capturePromptRewriteSessionContext() -> PromptRewriteSessionContext {
        let fallbackApp = lastTargetApplication ?? lastExternalApplication
        let insertionHUDContext = PromptRewriteHUDManager.shared.captureCurrentInsertionContext(
            fallbackApp: fallbackApp
        )
        let conversationFallbackApp = insertionHUDContext.targetProcessIdentifier.flatMap { processID in
            guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else {
                return nil
            }
            return app
        } ?? fallbackApp
        let conversationContext = PromptRewriteConversationContextResolver.captureCurrentContext(
            fallbackApp: conversationFallbackApp,
            screenLabel: nil
        )
        return PromptRewriteSessionContext(
            conversationContext: conversationContext,
            insertionHUDContext: insertionHUDContext
        )
    }

    private func applyAdaptiveCorrectionsIfNeeded(to text: String) -> String {
        let readyForInsert: String
        let appliedEvents: [AdaptiveCorrectionStore.AppliedEvent]
        if settings.adaptiveCorrectionsEnabled {
            let applyResult = adaptiveCorrectionStore.applyWithEvents(to: text)
            readyForInsert = applyResult.text
            appliedEvents = applyResult.appliedEvents
        } else {
            readyForInsert = text
            appliedEvents = []
        }

        if !appliedEvents.isEmpty {
            let applyMessage: String
            if appliedEvents.count == 1, let first = appliedEvents.first {
                applyMessage = "Applied learned: \(first.source) -> \(first.replacement)"
            } else {
                applyMessage = "Applied \(appliedEvents.count) learned corrections"
            }
            waveform.flashEvent(
                message: applyMessage,
                symbolName: "arrow.triangle.2.circlepath.circle.fill",
                duration: 1.2
            )
        }

        return readyForInsert
    }

    private func presentPromptRewritePreviewDialog(
        originalText: String,
        suggestion: PromptRewriteSuggestion,
        insertionContext: PromptRewriteInsertionHUDContext
    ) async -> PromptRewritePreviewChoice {
        await PromptRewriteHUDManager.shared.present(
            originalText: originalText,
            suggestion: suggestion,
            insertionContext: insertionContext
        )
    }

    private func presentPromptRewriteEditDialog(initialText: String) -> String? {
        var draft = initialText
        while true {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
            textView.string = draft
            textView.font = NSFont.systemFont(ofSize: 13)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.textContainerInset = NSSize(width: 8, height: 8)

            let scrollView = NSScrollView(frame: textView.frame)
            scrollView.borderType = .bezelBorder
            scrollView.hasVerticalScroller = true
            scrollView.documentView = textView

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Edit Suggested Rewrite"
            alert.informativeText = "Update the text below, then choose Insert Edited."
            alert.accessoryView = scrollView
            alert.addButton(withTitle: "Insert Edited")
            alert.addButton(withTitle: "Back")

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return nil
            }

            let edited = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !edited.isEmpty {
                return edited
            }

            draft = textView.string
            let emptyAlert = NSAlert()
            emptyAlert.alertStyle = .warning
            emptyAlert.messageText = "Edited text is empty"
            emptyAlert.informativeText = "Enter text before inserting, or go back and choose a different action."
            emptyAlert.addButton(withTitle: "Continue Editing")
            _ = emptyAlert.runModal()
        }
    }

    private func presentPromptRewriteFailureDialog(failureDetail: String) -> PromptRewriteFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rewrite Provider Unavailable"
        alert.informativeText = "Could not get a rewrite suggestion.\n\(failureDetail)"
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Keep Original")
        alert.addButton(withTitle: "Close")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .retry
        case .alertSecondButtonReturn:
            return .insertOriginal
        default:
            return .close
        }
    }

    private func promptRewritePreviewBody(
        originalText: String,
        suggestion: PromptRewriteSuggestion
    ) -> String {
        let suggestedSnippet = promptRewriteSnippet(for: suggestion.suggestedText)
        let originalSnippet = promptRewriteSnippet(for: originalText)
        if let memoryContext = suggestion.memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !memoryContext.isEmpty {
            let memorySnippet = promptRewriteSnippet(for: memoryContext, maxLength: 160)
            return """
            Memory context:
            \(memorySnippet)

            Suggested:
            \(suggestedSnippet)

            Original:
            \(originalSnippet)
            """
        }

        return """
        Suggested:
        \(suggestedSnippet)

        Original:
        \(originalSnippet)
        """
    }

    private func promptRewriteSnippet(for text: String, maxLength: Int = 320) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else {
            return normalized
        }
        let prefix = normalized.prefix(maxLength)
        return "\(prefix)..."
    }

    private func promptRewriteFailureDetail(for error: Error) -> String {
        if let serviceError = error as? PromptRewriteServiceError {
            switch serviceError {
            case let .timedOut(timeoutSeconds):
                if settings.promptRewriteProviderMode == .ollama {
                    return "Local model timed out after \(String(format: "%.1f", timeoutSeconds))s. Increase Rewrite request timeout in AI Studio -> Prompt Models."
                }
                return "Timed out after \(String(format: "%.1f", timeoutSeconds))s."
            case let .providerUnavailable(reason):
                return reason
            }
        }

        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "unknown-provider-error"
        }
        return raw
    }

    private func formatPromptRewriteSuggestion(
        _ suggestion: PromptRewriteSuggestion,
        originalText: String,
        refinementDurationSeconds: TimeInterval? = nil
    ) -> PromptRewriteSuggestion {
        let formatted = PromptRewriteFormatting.prepareSuggestedTextForInsertion(
            suggestion.suggestedText,
            originalText: originalText,
            forceMarkdown: settings.promptRewriteAlwaysConvertToMarkdown
        )
        let resolvedText = formatted.isEmpty ? suggestion.suggestedText : formatted
        return PromptRewriteSuggestion(
            suggestedText: resolvedText,
            memoryContext: suggestion.memoryContext,
            confidence: suggestion.confidence,
            rewriteStrength: suggestion.rewriteStrength,
            continuityTrace: suggestion.continuityTrace,
            refinementDurationSeconds: refinementDurationSeconds ?? suggestion.refinementDurationSeconds
        )
    }

    private func recordPromptRewriteFeedback(
        action: PromptRewriteFeedbackAction,
        originalText: String,
        suggestedText: String? = nil,
        finalInsertedText: String? = nil,
        failureDetail: String? = nil
    ) async {
        let event = PromptRewriteFeedbackEvent(
            action: action,
            originalText: originalText,
            suggestedText: suggestedText,
            finalInsertedText: finalInsertedText,
            failureDetail: failureDetail
        )
        await promptRewriteService.recordFeedback(event)
    }

    private func insertText(
        _ text: String,
        forceCopyToClipboard: Bool = false,
        overrideCopyToClipboard: Bool? = nil,
        trackCorrections: Bool = false,
        insertionContext: PromptRewriteInsertionHUDContext? = nil,
        forceActivateTargetBeforeInsert: Bool = false
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard ensureAccessibilityReadyForInsertion() else { return }
        let copyToClipboard = overrideCopyToClipboard ?? (settings.copyToClipboard || forceCopyToClipboard)
        if forceActivateTargetBeforeInsert,
           let target = targetApplication(for: insertionContext),
           !target.isTerminated {
            lastTargetApplication = target
            _ = target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.attemptInsertText(
                    text,
                    copyToClipboard: copyToClipboard,
                    attemptsRemaining: 5,
                    insertionContext: insertionContext
                ) { [weak self] didInsert in
                    guard let self else { return }
                    if didInsert {
                        self.playDictationFeedbackSound(.pasted)
                    }
                    guard trackCorrections else { return }
                    if didInsert {
                        self.postInsertCorrectionMonitor.startMonitoring(insertedText: text)
                    }
                }
            }
            return
        }
        attemptInsertText(
            text,
            copyToClipboard: copyToClipboard,
            attemptsRemaining: 5,
            insertionContext: insertionContext
        ) { [weak self] didInsert in
            guard let self else { return }
            if didInsert {
                self.playDictationFeedbackSound(.pasted)
            }
            guard trackCorrections else { return }
            if didInsert {
                self.postInsertCorrectionMonitor.startMonitoring(insertedText: text)
            }
        }
    }

    private func pasteLastTranscriptFromHistory() {
        if isDictating {
            setUIStatus(.message("Stop transcribing before pasting last transcript"))
            return
        }

        guard let latest = transcriptHistory.entries.first?.text,
              !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setUIStatus(.message("No transcript in Open Assist History"))
            return
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
            lastTargetApplication = frontmost
        } else if let fallback = lastExternalApplication, !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        // Privacy-first quick paste: always insert from Open Assist history without copying to system clipboard.
        insertText(latest, overrideCopyToClipboard: false)
    }

    private func ensureAccessibilityReadyForInsertion() -> Bool {
        settings.refreshAccessibilityStatus(prompt: false)
        guard settings.accessibilityTrusted else {
            setUIStatus(.message("Enable Accessibility via menu: Complete Permission Setup…"))
            updatePermissionGate(openOnboardingIfNeeded: true)
            return false
        }
        return true
    }

    private func targetApplication(for insertionContext: PromptRewriteInsertionHUDContext?) -> NSRunningApplication? {
        if let context = insertionContext,
           let pid = context.targetProcessIdentifier,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }
        return nil
    }

    private func attemptInsertText(
        _ text: String,
        copyToClipboard: Bool,
        attemptsRemaining: Int,
        insertionContext: PromptRewriteInsertionHUDContext?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard attemptsRemaining > 0 else {
            if copyToClipboard {
                ensureClipboardFallback(text)
                setUIStatus(.message("Paste unavailable — copied to clipboard"))
            } else {
                setUIStatus(.message("Paste unavailable — transcript is in Open Assist History"))
            }
            lastTargetApplication = nil
            completion?(false)
            return
        }

        if let explicitTarget = targetApplication(for: insertionContext) {
            lastTargetApplication = explicitTarget
        } else if lastTargetApplication == nil,
                  let fallback = lastExternalApplication,
                  !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        if let target = lastTargetApplication,
           !target.isTerminated,
           !target.isActive {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            if attemptsRemaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                    self?.attemptInsertText(
                        text,
                        copyToClipboard: copyToClipboard,
                        attemptsRemaining: attemptsRemaining - 1,
                        insertionContext: insertionContext,
                        completion: completion
                    )
                }
                return
            }

            // Activation failed repeatedly; fall back to best-effort insertion/copy behavior.
            lastTargetApplication = nil
        }

        let result = TextInserter.insert(text, copyToClipboard: copyToClipboard)
        let retryPlan = InsertionRetryPolicy.plan(
            for: result,
            retriesRemaining: attemptsRemaining - 1,
            debugStatus: TextInserter.lastDebugStatus
        )

        switch retryPlan {
        case let .retry(delay, nextRetriesRemaining):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptInsertText(
                    text,
                    copyToClipboard: copyToClipboard,
                    attemptsRemaining: nextRetriesRemaining + 1,
                    insertionContext: insertionContext,
                    completion: completion
                )
            }

        case let .complete(statusMessage):
            let didInsert = result == .pasted
            if let statusMessage, statusMessage.hasPrefix("Paste unavailable") {
                if copyToClipboard {
                    ensureClipboardFallback(text)
                    let clipboardStatus = statusMessage.replacingOccurrences(
                        of: "Paste unavailable",
                        with: "Paste unavailable — copied to clipboard"
                    )
                    applyInsertionStatusMessage(clipboardStatus)
                } else {
                    let historyStatus = statusMessage.replacingOccurrences(
                        of: "Paste unavailable",
                        with: "Paste unavailable — transcript is in Open Assist History"
                    )
                    applyInsertionStatusMessage(historyStatus)
                }
            } else {
                applyInsertionStatusMessage(statusMessage)
            }
            lastTargetApplication = nil
            completion?(didInsert)
        }
    }

    private func handleLearnedCorrection(from originalText: String, correctedText: String, insertedText: String) {
        guard settings.adaptiveCorrectionsEnabled else { return }

        guard let proposedEvent = adaptiveCorrectionStore.proposedLearningEvent(
            from: originalText,
            correctedText: correctedText,
            insertionHint: insertedText
        ) else { return }

        let source = proposedEvent.source
        let replacement = proposedEvent.replacement
        waveform.presentCorrectionDecision(
            source: source,
            replacement: replacement,
            onAccept: { [weak self] in
                self?.acceptLearnedCorrection(source: source, replacement: replacement)
            },
            onReject: { [weak self] in
                self?.setUIStatus(.message("Skipped correction: \(source) -> \(replacement)"))
            }
        )
    }

    private func acceptLearnedCorrection(source: String, replacement: String) {
        guard let event = adaptiveCorrectionStore.acceptProposedLearning(
            source: source,
            replacement: replacement
        ) else {
            return
        }

        let hudMessage = "Learned correction: \(event.source) -> \(event.replacement)"

        waveform.flashEvent(
            message: hudMessage,
            symbolName: "arrow.triangle.2.circlepath.circle.fill",
            duration: 1.2
        )
        if settings.playCorrectionLearnedSound {
            playDictationFeedbackSound(.correctionLearned)
        }
        setUIStatus(.message(hudMessage))
    }

    private func ensureClipboardFallback(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(trimmed, forType: .string)
    }

    private func applyInsertionStatusMessage(_ statusMessage: String?) {
        guard let statusMessage else {
            return
        }

        if statusMessage == "Ready" {
            if !isDictating {
                setUIStatus(.ready)
            }
            return
        }

        if statusMessage.hasPrefix("Copied to clipboard") {
            if statusMessage == "Copied to clipboard" {
                setUIStatus(.copiedToClipboard)
            } else {
                setUIStatus(.message(statusMessage))
            }
            return
        }

        if statusMessage.hasPrefix("Paste unavailable") {
            if statusMessage == "Paste unavailable" {
                setUIStatus(.pasteUnavailable)
            } else {
                setUIStatus(.message(statusMessage))
            }
            return
        }

        setUIStatus(.message(statusMessage))
    }

    private func setUIStatus(_ status: DictationUIStatus) {
        if status == .ready, isDictating {
            return
        }

        if statusBarViewModel.uiStatus != status {
            statusBarViewModel.uiStatus = status
        }

        if status.resetsDictationIndicators {
            isDictating = false
            dictationInputMode = .idle
            currentAudioLevel = 0
            waveform.hide()
            stopStatusIconAnimation()
        }

        updateMenuState()
    }

    private func playDictationFeedbackSound(_ cue: DictationFeedbackCue) {
        guard let sound = dictationFeedbackSounds[cue] else { return }
        sound.stop()
        sound.currentTime = 0
        let baseVolume = min(1, max(0, Float(settings.dictationFeedbackVolume)))
        sound.volume = baseVolume * cue.volumeMultiplier
        sound.play()
    }

    private func updateMenuState(
        forcePopoverRefresh: Bool = false,
        forceIconRefresh: Bool = false
    ) {
        updateStatusBarViewModel(\.isContinuousMode, value: dictationInputMode == .continuous)
        updateStatusBarViewModel(\.permissionsReady, value: permissionsReady)
        updateStatusBarViewModel(\.isDictating, value: isDictating)
        updateStatusBarViewModel(
            \.assistantEnabled,
            value: FeatureFlags.personalAssistantEnabled && settings.assistantBetaEnabled
        )

        let assistantBusy = liveVoiceCaptureActive
            || assistantController.isLiveVoiceSessionActive
            || assistantVoiceCaptureActive
            || compactVoiceCaptureActive
            || assistantController.pendingPermissionRequest != nil
            || [.thinking, .acting, .waitingForPermission, .streaming].contains(assistantController.hudState.phase)
        updateStatusBarViewModel(
            \.assistantCanStopCurrentAction,
            value: statusBarViewModel.assistantEnabled && assistantBusy
        )
        updateStatusBarViewModel(
            \.assistantStopActionLabel,
            value: liveVoiceCaptureActive
                ? "Stop Live Voice Listening"
                : assistantController.isLiveVoiceSessionActive
                    ? "End Live Voice"
                    : (assistantVoiceCaptureActive || compactVoiceCaptureActive)
                        ? "Stop Assistant Listening"
                        : "Cancel Assistant Turn"
        )

        let popoverVisible = statusBarViewModel.isPopoverVisible || popover?.isShown == true
        let normalizedLevel = max(0, min(1, currentAudioLevel))
        if popoverVisible || forcePopoverRefresh {
            updateStatusBarAudioLevel(normalizedLevel, force: forcePopoverRefresh)
        } else if statusBarViewModel.currentAudioLevel != 0 {
            statusBarViewModel.currentAudioLevel = 0
        }

        updateStatusItemIcon(force: forceIconRefresh)
    }

    private func updateStatusBarAudioLevel(_ value: Float, force: Bool) {
        let currentValue = statusBarViewModel.currentAudioLevel
        let delta = abs(currentValue - value)
        let threshold: Float = value == 0 || currentValue == 0 ? 0.01 : 0.04
        if force || delta >= threshold {
            statusBarViewModel.currentAudioLevel = value
        }
    }

    private func updateStatusBarViewModel<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<StatusBarViewModel, T>,
        value: T
    ) {
        if statusBarViewModel[keyPath: keyPath] != value {
            statusBarViewModel[keyPath: keyPath] = value
        }
    }

    private func updateStatusItemIcon(force: Bool = false) {
        let renderState = StatusIconRenderState(
            isRecording: isDictating,
            level: currentAudioLevel,
            animationPhase: statusIconAnimationPhase
        )

        guard force || renderState != lastStatusIconRenderState else { return }
        lastStatusIconRenderState = renderState

        if let cached = statusIconCache[renderState] {
            statusItem?.button?.image = cached
            statusItem?.button?.contentTintColor = nil
            return
        }

        guard let image = makeStatusIcon(renderState: renderState) else { return }
        statusIconCache[renderState] = image
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = nil
    }

    private func startStatusIconAnimation() {
        guard statusIconAnimationTimer == nil else { return }

        statusIconAnimationPhase = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.04, repeating: 0.08)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isDictating else {
                self.stopStatusIconAnimation()
                return
            }

            self.statusIconAnimationPhase += 0.38
            if self.statusIconAnimationPhase > (.pi * 2) {
                self.statusIconAnimationPhase -= (.pi * 2)
            }
            self.updateMenuState()
        }
        statusIconAnimationTimer = timer
        timer.resume()
    }

    private func stopStatusIconAnimation() {
        statusIconAnimationTimer?.cancel()
        statusIconAnimationTimer = nil
        statusIconAnimationPhase = 0
    }

    private func makeStatusIcon(renderState: StatusIconRenderState) -> NSImage? {
        let symbol: NSImage?
        if #available(macOS 13.3, *) {
            symbol = NSImage(
                systemSymbolName: "waveform.circle",
                variableValue: renderState.variableValue,
                accessibilityDescription: "Open Assist"
            )
        } else {
            symbol = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Open Assist")
        }

        guard let symbol else {
            return nil
        }

        let pointSize: CGFloat = 18
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        guard let configured = symbol.withSymbolConfiguration(config) else { return nil }
        configured.isTemplate = true

        // Flip horizontally so the variable fill runs left-to-right
        let size = configured.size
        let flipped = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: size.width, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
            configured.draw(in: rect)
            return true
        }
        flipped.isTemplate = true
        return flipped
    }

}

struct SettingsView: View {
    private enum SettingsSection: CaseIterable, Identifiable {
        case essentials
        case shortcuts
        case speech
        case aiModels
        case computerControl
        case integrations
        case corrections
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .essentials: return "Essentials"
            case .shortcuts: return "Shortcuts"
            case .speech: return "Speech & Input"
            case .aiModels: return "AI & Models"
            case .computerControl: return "Automation"
            case .integrations: return "Integrations"
            case .corrections: return "Corrections"
            case .about: return "About & Permissions"
            }
        }

        var subtitle: String {
            switch self {
            case .essentials: return "Daily assistant, voice capture, and feedback controls"
            case .shortcuts: return "Dictation and agent shortcut keys"
            case .speech: return "Microphone, engine, whisper models, timing, and text quality"
            case .aiModels: return "Prompt rewrite, memory assistant, and provider connections"
            case .computerControl: return "Browser reuse, automation permissions, helper status, and direct app actions"
            case .integrations: return "Local automation and agent notifications"
            case .corrections: return "Learn from and manage text fixes"
            case .about: return "Permission health, diagnostics, and uninstall"
            }
        }

        var iconName: String {
            switch self {
            case .essentials: return "sparkles"
            case .shortcuts: return "keyboard"
            case .speech: return "waveform.and.mic"
            case .aiModels: return "shippingbox.fill"
            case .computerControl: return "point.3.connected.trianglepath.dotted"
            case .integrations: return "point.3.connected.trianglepath.dotted"
            case .corrections: return "text.badge.checkmark"
            case .about: return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .essentials:
                return Color(red: 0.30, green: 0.58, blue: 0.95)
            case .shortcuts:
                return Color(red: 0.94, green: 0.58, blue: 0.24)
            case .speech:
                return Color(red: 0.27, green: 0.72, blue: 0.54)
            case .aiModels:
                return Color(red: 0.45, green: 0.56, blue: 0.92)
            case .computerControl:
                return Color(red: 0.23, green: 0.67, blue: 0.76)
            case .integrations:
                return Color(red: 0.84, green: 0.52, blue: 0.28)
            case .corrections:
                return Color(red: 0.21, green: 0.70, blue: 0.73)
            case .about:
                return Color(red: 0.56, green: 0.62, blue: 0.72)
            }
        }

        var searchTerms: [String] {
            switch self {
            case .essentials:
                return ["essential", "clipboard", "waveform", "accessibility", "output", "sound", "feedback"]
            case .shortcuts:
                return ["shortcut", "keyboard", "hold to talk", "continuous", "hotkey"]
            case .speech:
                return ["recognition", "engine", "punctuation", "context", "cleanup", "delay", "text quality", "speech", "whisper", "model", "download", "install", "core ml", "tiny", "base", "small", "medium", "large"]
            case .aiModels:
                return ["ai", "prompt", "rewrite", "memory", "provider", "oauth", "api key", "openai", "anthropic", "google", "gemini", "studio", "style", "conversation", "history"]
            case .computerControl:
                return ["automation", "browser", "browser profile", "apple events", "finder", "terminal", "calendar", "system settings", "helper", "messages", "notes", "contacts", "reminders"]
            case .integrations:
                return ["integrations", "automation", "api", "localhost", "claude", "codex", "cloud", "hooks", "notification", "speech", "sound", "token", "port"]
            case .corrections:
                return ["adaptive", "learned", "correction", "replacement", "sound", "edit", "remove", "clear"]
            case .about:
                return ["about", "permission", "uninstall", "version", "crash logs"]
            }
        }
    }

    private enum ShortcutCaptureTarget {
        case holdToTalk
        case continuousToggle
        case assistantLiveVoice
    }

    private enum IntegrationsPage {
        case overview
        case automationNotifications
        case telegramRemote
    }

    private struct ShortcutBinding: Equatable {
        let keyCode: UInt16
        let modifiersRaw: UInt
    }

    private struct ShortcutModifierOption: Identifiable {
        let id: String
        let label: String
        let flag: NSEvent.ModifierFlags
    }

    private struct ShortcutKeyOption: Identifiable {
        let keyCode: UInt16
        let label: String

        var id: UInt16 {
            keyCode
        }
    }

    private struct SettingSearchEntry: Identifiable {
        let section: SettingsSection
        let title: String
        let detail: String
        let keywords: [String]
        let integrationsPage: IntegrationsPage?

        init(
            section: SettingsSection,
            title: String,
            detail: String,
            keywords: [String],
            integrationsPage: IntegrationsPage? = nil
        ) {
            self.section = section
            self.title = title
            self.detail = detail
            self.keywords = keywords
            self.integrationsPage = integrationsPage
        }

        var id: String {
            "\(section.title)-\(title)"
        }
    }

    private enum ReservedShortcut {
        static let pasteLastKeyCode: UInt16 = 9 // V
        static let pasteLastModifiersRaw: UInt = NSEvent.ModifierFlags([.command, .option]).rawValue
    }

    private static let manualModifierOnlyKeyCode: UInt16 = UInt16.max
    private static let shortcutModifierOptions: [ShortcutModifierOption] = [
        .init(id: "fn", label: "Fn", flag: .function),
        .init(id: "control", label: "⌃", flag: .control),
        .init(id: "option", label: "⌥", flag: .option),
        .init(id: "shift", label: "⇧", flag: .shift),
        .init(id: "command", label: "⌘", flag: .command)
    ]

    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var whisperModelManager = WhisperModelManager.shared
    @StateObject private var adaptiveCorrectionStore = AdaptiveCorrectionStore.shared
    @StateObject private var promptRewriteConversationStore = PromptRewriteConversationStore.shared
    @StateObject private var localAISetupService = LocalAISetupService.shared
    @StateObject private var updateCheckStatusStore = UpdateCheckStatusStore.shared
    @StateObject private var automationAPICoordinator = AutomationAPICoordinator.shared
    @StateObject private var telegramRemoteCoordinator = TelegramRemoteCoordinator.shared
    @State private var selectedSection: SettingsSection = .essentials
    @State private var selectedIntegrationsPage: IntegrationsPage = .overview
    @State private var searchQuery = ""
    @State private var hoveredSection: SettingsSection?
    @State private var isCapturingShortcut = false
    @State private var shortcutCaptureTarget: ShortcutCaptureTarget?
    @State private var shortcutCaptureMessage: String?
    @State private var showHoldManualMap = false
    @State private var showContinuousManualMap = false
    @State private var showAssistantLiveVoiceManualMap = false
    @State private var showDictationOutputSettings = false
    @State private var showDictationSoundSettings = false
    @State private var showWaveformAppearanceSettings = false
    @State private var showQuickReferenceTips = false
    @State private var showAppleSpeechAdvancedSettings = false
    @State private var showRecognitionAdvancedSettings = false
    @State private var whisperModelSearchQuery = ""
    @State private var whisperFamilyFilter = "all"
    @State private var whisperShowInstalledOnly = false
    @State private var whisperBrowserModelID = ""
    @State private var showWhisperModelFilters = false
    @State private var showUninstallSheet = false
    @State private var showUninstallConfirmation = false
    @State private var uninstallDeleteDownloadedModels = false
    @State private var uninstallDeleteLearnedCorrections = false
    @State private var uninstallDeleteMemories = false
    @State private var uninstallDeleteProviderCredentials = false
    @State private var isCorrectionEditorPresented = false
    @State private var correctionSourceDraft = ""
    @State private var correctionReplacementDraft = ""
    @State private var correctionEditingSource: String?
    @State private var correctionDialogMessage: String?
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
    @State private var memoryBrowserEntries: [MemoryIndexedEntry] = []
    @State private var promptRewriteOpenAIKeyVisible = false
    @State private var cloudTranscriptionAPIKeyVisible = false
    @State private var cloudTranscriptionModelsLoading = false
    @State private var cloudTranscriptionAvailableModels: [CloudTranscriptionModelOption] = []
    @State private var cloudTranscriptionModelStatusMessage: String?
    @State private var cloudTranscriptionModelRequestToken = UUID()
    @State private var memoryActionMessage: String?
    @State private var showingProvidersSheet = false
    @State private var showingSourceFoldersSheet = false
    @State private var showingCorrectionsListSheet = false
    @State private var correctionsSearchQuery = ""
    @State private var automationActionMessage: String?
    @State private var telegramActionMessage: String?
    @State private var telegramBotTokenDraft = ""
    @State private var computerPermissionSnapshot = PermissionCenter.snapshot(using: .shared)
    @State private var computerControlStatus: HelperCapabilityStatus?
    @State private var installClaudeNotificationHook = false
    @State private var installClaudeStopHook = false
    @State private var installClaudeSubagentStopHook = false
    @State private var installedClaudeHookOptions: Set<ClaudeHookInstallOption> = []
    private let memoryIndexingSettingsService = MemoryIndexingSettingsService.shared
    private let settingsSidebarWidth: CGFloat = 304
    private let manualShortcutKeyOptions: [ShortcutKeyOption] = ShortcutValidation.manualAssignableKeyCodes.map {
        ShortcutKeyOption(keyCode: $0, label: ShortcutValidation.keyName(for: $0))
    }

    private var appVersionDisplayText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        let short = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (short.isEmpty, build.isEmpty) {
        case (false, false):
            return "Version \(short) (\(build))"
        case (false, true):
            return "Version \(short)"
        case (true, false):
            return "Build \(build)"
        case (true, true):
            return "Version unavailable"
        }
    }

    @ViewBuilder
    private var updateCheckStatusRow: some View {
        switch updateCheckStatusStore.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("You’re up to date.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.green.opacity(0.92))
        case .updateAvailable(let version):
            Label("Update \(version) is available.", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(AppVisualTheme.accentTint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.red.opacity(0.92))
        }
    }

    var body: some View {
        ZStack {
            AppSplitChromeBackground(
                leadingPaneFraction: 0.33,
                leadingPaneMaxWidth: settingsSidebarWidth + 30,
                leadingPaneWidth: settingsSidebarWidth + 10,
                leadingTint: AppVisualTheme.sidebarTint,
                trailingTint: .black,
                accent: AppVisualTheme.accentTint,
                leadingPaneTransparent: true
            )

            HStack(spacing: 0) {
                settingsSidebar
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                Rectangle()
                    .fill(AppVisualTheme.foreground(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                settingsDetailPane
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
            }

            ShortcutCaptureMonitor(
                isCapturing: $isCapturingShortcut,
                onCapture: { keyCode, modifiers in
                    guard let target = shortcutCaptureTarget else {
                        return false
                    }

                    let didApply = applyShortcutSelection(
                        for: target,
                        keyCode: keyCode,
                        modifiersRaw: modifiers,
                        validationMessage: "Shortcut must use 2 to 4 keys. Try again."
                    )
                    guard didApply else { return false }
                    shortcutCaptureTarget = nil
                    isCapturingShortcut = false
                    return true
                },
                onCancel: {
                    shortcutCaptureMessage = nil
                    shortcutCaptureTarget = nil
                    isCapturingShortcut = false
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .appScrollbars()
        .tint(AppVisualTheme.accentTint)
        .frame(minWidth: 900, idealWidth: 980, minHeight: 640, idealHeight: 720)
        .onChange(of: searchQuery) { _ in
            guard !trimmedSearchQuery.isEmpty else { return }
            if let firstMatch = filteredSearchEntries.first {
                navigateToSearchEntry(firstMatch)
            } else if let firstSection = filteredSections.first {
                selectedSection = firstSection
            }
        }
        .onChange(of: selectedSection) { _ in
            cancelShortcutCapture()
            if selectedSection != .integrations {
                selectedIntegrationsPage = .overview
            }
            if selectedSection == .computerControl || selectedSection == .about {
                refreshComputerControlState()
            }
        }
        .onAppear {
            sanitizePinnedConversationContextSelection()
            refreshComputerControlState()
        }
        .onChange(of: promptRewriteConversationStore.contextSummaries) { _ in
            sanitizePinnedConversationContextSelection()
        }
        .onChange(of: settings.browserAutomationEnabled) { _ in
            refreshComputerControlState()
        }
        .onChange(of: settings.browserSelectedProfileID) { _ in
            refreshComputerControlState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshComputerControlState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAssistOpenAssistantSetup)) { _ in
            NotificationCenter.default.post(name: .openAssistOpenAIMemoryStudio, object: nil)
        }
        .sheet(isPresented: $isCorrectionEditorPresented) {
            correctionEditorSheet
        }
        .sheet(isPresented: $showingCorrectionsListSheet) {
            correctionsListSheet
        }
    }

    @ViewBuilder
    private func settingsHeroCard(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppVisualTheme.foreground(0.94))
            Text(section.subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppVisualTheme.foreground(0.58))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppVisualTheme.accentTint.opacity(0.80))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppVisualTheme.accentTint.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Open Assist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                Text("Settings")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(0.44))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            sidebarBrandHeader

            AppSidebarSearchField(
                placeholder: "Search settings",
                text: $searchQuery
            )

            VStack(spacing: 4) {
                ForEach(filteredSections) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        sidebarSectionRow(for: section)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        if isHovering {
                            hoveredSection = section
                        } else if hoveredSection == section {
                            hoveredSection = nil
                        }
                    }
                }
            }

            if filteredSections.isEmpty {
                Text("No matching sections")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: settingsSidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sidebarSectionRow(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        let isHovered = hoveredSection == section
        let matchCount = matchCount(for: section)

        HStack(spacing: 10) {
            Image(systemName: section.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? section.tint.opacity(0.95) : AppVisualTheme.foreground(0.54))
                .frame(width: 22, height: 22)

            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.96) : AppVisualTheme.foreground(0.82))

            Spacer(minLength: 0)

            if !trimmedSearchQuery.isEmpty && matchCount > 0 {
                Text("\(matchCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.40))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AppVisualTheme.foreground(0.08) : (isHovered ? AppVisualTheme.foreground(0.04) : Color.clear))
        )
    }

    @ViewBuilder
    private var settingsDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsHeroCard(for: selectedSection)

                if !trimmedSearchQuery.isEmpty {
                    searchHighlightsCard
                }
                sectionContent(for: selectedSection)
            }
            .padding(.top, 34)
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func settingsSectionHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconBadge(
                    symbol: section.iconName,
                    tint: section.tint,
                    size: 22,
                    symbolSize: 10
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(section.title) Controls")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(section.tint.opacity(0.88))
                    Text("Section details")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.mutedText)
                }

                Spacer(minLength: 0)
            }

            LinearGradient(
                colors: [
                    section.tint.opacity(0.35),
                    AppVisualTheme.foreground(0.09),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var searchHighlightsCard: some View {
        settingsCard(
            title: "Search Results",
            subtitle: "Matching controls for \"\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\"",
            symbol: "magnifyingglass.circle.fill",
            tint: AppVisualTheme.accentTint
        ) {
            if filteredSearchEntries.isEmpty {
                Text("No exact setting name matched. Try another keyword or use the section list.")
                    .font(.callout)
                    .foregroundStyle(AppVisualTheme.mutedText)
            } else {
                ForEach(Array(filteredSearchEntries.prefix(7))) { entry in
                    Button {
                        navigateToSearchEntry(entry)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            AppIconBadge(
                                symbol: entry.section.iconName,
                                tint: entry.section.tint,
                                size: 24,
                                symbolSize: 11
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(AppVisualTheme.mutedText)
                            }
                            Spacer()
                            Text(entry.section.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.section.tint)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppVisualTheme.foreground(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(entry.section.tint.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(entry.section.tint.opacity(0.22), lineWidth: 0.65)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .essentials:
            essentialsSection
        case .shortcuts:
            shortcutsSection
        case .speech:
            speechSection
        case .aiModels:
            aiModelsSection
        case .computerControl:
            computerControlSection
        case .integrations:
            integrationsSection
        case .corrections:
            correctionsSection
        case .about:
            aboutSection
        }
    }

    @ViewBuilder
    private var essentialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .essentials)
            accessibilityCard

            settingsDisclosureCard(
                title: "Dictation Output",
                symbol: "doc.on.clipboard",
                tint: AppVisualTheme.accentTint,
                isExpanded: $showDictationOutputSettings
            ) {
                Toggle("Also copy transcript to system clipboard", isOn: $settings.copyToClipboard)
                    .help("Turn off to keep dictations out of clipboard history. Explicit Copy actions from History still copy as expected.")
            }

            settingsDisclosureCard(
                title: "Dictation Sounds",
                subtitle: "Choose the sounds for each dictation event.",
                symbol: "speaker.wave.2.fill",
                tint: AppVisualTheme.accentTint,
                isExpanded: $showDictationSoundSettings
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    dictationSoundRow(
                        title: "Start listening",
                        selection: $settings.dictationStartSoundName
                    )

                    dictationSoundRow(
                        title: "Stop/Finalize",
                        selection: $settings.dictationStopSoundName
                    )

                    dictationSoundRow(
                        title: "Processing (finalize)",
                        selection: $settings.dictationProcessingSoundName
                    )

                    dictationSoundRow(
                        title: "Pasted",
                        selection: $settings.dictationPastedSoundName
                    )

                    VStack(spacing: 6) {
                        HStack {
                            Text("Feedback volume")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(settings.dictationFeedbackVolume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        Slider(value: $settings.dictationFeedbackVolume, in: 0...1, step: 0.01)
                            .help("Reduce this value to lower all dictation feedback sounds.")
                    }
                }
            }

            settingsDisclosureCard(
                title: "Appearance & Visual Feedback",
                subtitle: "Customize waveform colors and visual style.",
                symbol: "sparkles.tv.fill",
                tint: AppVisualTheme.accentTint,
                isExpanded: $showWaveformAppearanceSettings
            ) {
                Picker("Color Theme", selection: $settings.colorThemeRawValue) {
                    ForEach(ColorTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose the overall color palette for the app.")

                HStack(spacing: 6) {
                    let p = settings.colorTheme.palette
                    Circle().fill(p.accentTint).frame(width: 14, height: 14)
                    Circle().fill(p.historyTint).frame(width: 14, height: 14)
                    Circle().fill(p.baseTint).frame(width: 14, height: 14)
                    Text("Theme preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.vertical, 6)

                Picker("Interface Style", selection: $settings.appChromeStyleRawValue) {
                    ForEach(AppChromeStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text("Glass style auto-adjusts when macOS Reduce Transparency is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 6)

                Picker("Waveform Theme", selection: $settings.waveformThemeRawValue) {
                    ForEach(WaveformTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose the color scheme for the recording waveform.")

                Divider()
                    .padding(.vertical, 6)

                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                WaveformThemePreview(theme: settings.waveformTheme)
            }

            settingsDisclosureCard(
                title: "Quick Reference",
                subtitle: "Reminders for common dictation actions.",
                symbol: "lightbulb.fill",
                tint: AppVisualTheme.accentTint,
                isExpanded: $showQuickReferenceTips
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste last transcript shortcut: ⌥⌘V")
                    Text("Hold-to-talk: hold your shortcut while speaking in normal dictation.")
                    Text("Continuous mode: press your toggle shortcut to start/stop normal dictation.")
                    Text("Agent shortcut: hold it while speaking, then release it to paste text into Open Assist.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            showDictationOutputSettings = false
            showDictationSoundSettings = false
            showWaveformAppearanceSettings = false
            showQuickReferenceTips = false
        }
    }

    @ViewBuilder
    private func dictationSoundRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.medium))
            Spacer()
            Picker("", selection: selection) {
                ForEach(SettingsStore.dictationStartSoundOptions, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        }
        .help(selection.wrappedValue == SettingsStore.noDictationSoundName
            ? "No sound for this event."
            : "Play this sound when: \(title.lowercased())")
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .shortcuts)
            settingsCard(
                title: "Hold-to-Talk Shortcut",
                subtitle: "Hold this shortcut while speaking.",
                symbol: "mic.badge.plus",
                tint: AppVisualTheme.accentTint
            ) {
                shortcutSegmentRow(holdToTalkShortcutSegments)

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        beginShortcutCapture(for: .holdToTalk)
                    }) {
                        Text(isCapturingShortcut && shortcutCaptureTarget == .holdToTalk ? "Listening..." : "Choose Shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Use 2 to 4 keys, like ⌘+Space or ⌃+⌥+⌘+Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Mute system sounds while this shortcut is held", isOn: $settings.muteSystemSoundsWhileHoldingShortcut)
                    .help("Suppresses this hold-to-talk key chord in other apps to avoid system alert beeps.")

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showHoldManualMap.toggle() }
                    } label: {
                        HStack {
                            Text("Manual map (advanced)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showHoldManualMap ? 90 : 0))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showHoldManualMap {
                        manualShortcutBuilder(for: .holdToTalk)
                            .padding(.top, 6)
                    }
                }

                if isCapturingShortcut && shortcutCaptureTarget == .holdToTalk {
                    Text("Press hold-to-talk shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isHoldToTalkShortcutValid {
                    Text("Hold-to-talk shortcut must include 2 to 4 keys.")
                        .font(.callout)
                        .foregroundStyle(AppVisualTheme.accentTint)
                }
            }

            settingsCard(
                title: "Continuous Toggle Shortcut",
                subtitle: "Press once to start, press again to stop.",
                symbol: "repeat.circle.fill",
                tint: AppVisualTheme.accentTint
            ) {
                shortcutSegmentRow(continuousToggleShortcutSegments)

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        beginShortcutCapture(for: .continuousToggle)
                    }) {
                        Text(isCapturingShortcut && shortcutCaptureTarget == .continuousToggle ? "Listening..." : "Choose Shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Use 2 to 4 keys. Keep this different from hold-to-talk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showContinuousManualMap.toggle() }
                    } label: {
                        HStack {
                            Text("Manual map (advanced)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showContinuousManualMap ? 90 : 0))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showContinuousManualMap {
                        manualShortcutBuilder(for: .continuousToggle)
                            .padding(.top, 6)
                    }
                }

                if isCapturingShortcut && shortcutCaptureTarget == .continuousToggle {
                    Text("Press continuous toggle shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isContinuousToggleShortcutValid {
                    Text("Continuous toggle shortcut must include 2 to 4 keys.")
                        .font(.callout)
                        .foregroundStyle(AppVisualTheme.accentTint)
                }
            }

            settingsCard(
                title: "Agent Shortcut",
                subtitle: "Hold while speaking. Release to paste into the assistant box.",
                symbol: "waveform.badge.mic",
                tint: AppVisualTheme.accentTint
            ) {
                shortcutSegmentRow(assistantLiveVoiceShortcutSegments)

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        beginShortcutCapture(for: .assistantLiveVoice)
                    }) {
                        Text(isCapturingShortcut && shortcutCaptureTarget == .assistantLiveVoice ? "Listening..." : "Choose Shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("This shortcut records into Open Assist. It cannot match dictation shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Inside Open Assist, this shortcut records one voice draft into the agent box. Use Live Voice Start for the full listen, reply, and speak loop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAssistantLiveVoiceManualMap.toggle() }
                    } label: {
                        HStack {
                            Text("Manual map (advanced)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showAssistantLiveVoiceManualMap ? 90 : 0))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showAssistantLiveVoiceManualMap {
                        manualShortcutBuilder(for: .assistantLiveVoice)
                            .padding(.top, 6)
                    }
                }

                if isCapturingShortcut && shortcutCaptureTarget == .assistantLiveVoice {
                    Text("Press the agent shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isAssistantLiveVoiceShortcutValid {
                    Text("Agent shortcut must include 2 to 4 keys.")
                        .font(.callout)
                        .foregroundStyle(AppVisualTheme.accentTint)
                }
            }

            settingsCard(
                title: "Reserved Shortcut",
                symbol: "lock.fill",
                tint: .gray
            ) {
                Text("⌥⌘V is reserved for Paste Last Transcript and cannot be reassigned.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let shortcutCaptureMessage {
                Text(shortcutCaptureMessage)
                    .font(.callout)
                    .foregroundStyle(AppVisualTheme.accentTint)
            }
        }
    }

    @ViewBuilder
    private var microphoneInputCard: some View {
        settingsCard(
            title: "Input Device",
            symbol: "mic.fill",
            tint: AppVisualTheme.accentTint
        ) {
            Toggle("Auto-detect microphone", isOn: $settings.autoDetectMicrophone)

            HStack {
                Picker("Microphone", selection: $settings.selectedMicrophoneUID) {
                    ForEach(settings.availableMicrophones) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                .disabled(settings.autoDetectMicrophone)

                Button("Refresh") {
                    settings.refreshMicrophones()
                }
                .disabled(settings.autoDetectMicrophone)
            }

            if settings.availableMicrophones.isEmpty {
                Text("No microphones detected.")
                    .font(.callout)
                    .foregroundStyle(AppVisualTheme.accentTint)
            }
        }
    }

    @ViewBuilder
    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .speech)
            microphoneInputCard

            settingsCard(
                title: "Transcription Engine",
                symbol: "waveform",
                tint: AppVisualTheme.accentTint
            ) {
                HStack {
                    Text("Engine")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.transcriptionEngineRawValue) {
                        ForEach(TranscriptionEngineType.allCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                Text(settings.transcriptionEngine.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.transcriptionEngine == .appleSpeech {
                settingsCard(
                    title: "Apple Speech Behavior",
                    subtitle: "Keep common recognition controls visible and tuck advanced tuning below.",
                    symbol: "apple.logo",
                    tint: AppVisualTheme.accentTint
                ) {
                    Toggle("Use contextual language bias", isOn: $settings.enableContextualBias)
                        .help("Boost likely words/phrases for better recognition.")

                    Toggle("Preserve words across short pauses", isOn: $settings.keepTextAcrossPauses)
                        .help("Helps avoid dropping earlier words when you pause briefly mid-sentence.")

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAppleSpeechAdvancedSettings.toggle() }
                        } label: {
                            HStack {
                                Text("Advanced Apple Speech options")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showAppleSpeechAdvancedSettings ? 90 : 0))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showAppleSpeechAdvancedSettings {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Recognition mode")
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Picker("", selection: $settings.recognitionModeRawValue) {
                                        ForEach(RecognitionMode.allCases) { mode in
                                            Text(mode.displayName).tag(mode.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 150)
                                }
                                .help(settings.recognitionMode.helpText)

                                Text(settings.recognitionMode.helpText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Toggle("Enable Apple automatic punctuation", isOn: $settings.autoPunctuation)
                                    .help("Uses Apple Speech punctuation generation during recognition.")
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            } else if settings.transcriptionEngine == .whisperCpp {
                settingsCard(
                    title: "Model Runtime",
                    subtitle: "Control whisper.cpp runtime options and active model.",
                    symbol: "cpu.fill",
                    tint: AppVisualTheme.accentTint
                ) {
                    Toggle("Use Core ML encoder when available", isOn: $settings.whisperUseCoreML)
                        .help("If installed for the selected model, Core ML can improve whisper speed on Apple Silicon.")

                    Toggle("Release model after idle", isOn: $settings.whisperAutoUnloadIdleContextEnabled)
                        .help("Frees whisper context memory when dictation is inactive.")

                    if settings.whisperAutoUnloadIdleContextEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Idle unload delay: \(Int(settings.whisperIdleContextUnloadSeconds.rounded())) sec")
                                .font(.callout.weight(.medium))
                            Slider(value: $settings.whisperIdleContextUnloadSeconds, in: 30...3600, step: 30)
                            Text("Lower values free memory sooner; higher values keep whisper warm for faster restarts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if settings.selectedWhisperModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No model selected yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Current model: \(settings.selectedWhisperModelID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard(
                    title: "Model Library",
                    subtitle: "Use focused controls first, then expand filters when you need to narrow down.",
                    symbol: "shippingbox.fill",
                    tint: AppVisualTheme.accentTint
                ) {
                    if WhisperModelCatalog.curatedModels.isEmpty {
                        Text("No curated whisper models are configured.")
                            .font(.callout)
                            .foregroundStyle(AppVisualTheme.accentTint)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { showWhisperModelFilters.toggle() }
                                } label: {
                                    HStack {
                                        Text("Find a model")
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .rotationEffect(.degrees(showWhisperModelFilters ? 90 : 0))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if showWhisperModelFilters {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 10) {
                                            TextField("Search model ID (e.g. medium, large-v3, q5)", text: $whisperModelSearchQuery)
                                                .textFieldStyle(.roundedBorder)

                                            Toggle("Installed only", isOn: $whisperShowInstalledOnly)
                                                .toggleStyle(.switch)
                                                .fixedSize()
                                        }

                                        HStack(spacing: 10) {
                                            Picker("Family", selection: $whisperFamilyFilter) {
                                                ForEach(whisperFamilyFilterOptions, id: \.self) { family in
                                                    Text(family == "all" ? "All families" : family.capitalized)
                                                        .tag(family)
                                                }
                                            }
                                            .pickerStyle(.menu)
                                            .frame(width: 180)

                                            Spacer()
                                        }
                                    }
                                    .padding(.top, 8)
                                }
                            }

                            HStack(spacing: 10) {
                                Text("Model")
                                    .font(.callout.weight(.medium))
                                Spacer()

                                Picker("Model", selection: $whisperBrowserModelID) {
                                    if filteredWhisperModels.isEmpty {
                                        Text("No matching models").tag("")
                                    } else {
                                        ForEach(filteredWhisperModels) { model in
                                            Text(model.displayName).tag(model.id)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 290)
                                .disabled(filteredWhisperModels.isEmpty)
                            }

                            if let browsingModel = activeWhisperBrowserModel {
                                whisperModelRow(for: browsingModel)
                            } else {
                                Text("No models match the current filters.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
            } else {
                settingsCard(
                    title: "Cloud Provider",
                    subtitle: "Bring your own API key and model for cloud transcription.",
                    symbol: "network",
                    tint: AppVisualTheme.accentTint
                ) {
                    HStack {
                        Text("Provider")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Picker("", selection: $settings.cloudTranscriptionProviderRawValue) {
                            ForEach(CloudTranscriptionProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 260)
                    }

                    Text(settings.cloudTranscriptionProvider.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model")
                                .font(.callout.weight(.medium))
                            Spacer()
                            TextField("Model ID", text: $settings.cloudTranscriptionModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .autocorrectionDisabled()
                        }

                        HStack(spacing: 8) {
                            Button {
                                refreshCloudTranscriptionModels(showMessage: true)
                            } label: {
                                if cloudTranscriptionModelsLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Load Models", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(cloudTranscriptionModelsLoading)

                            if !cloudTranscriptionAvailableModels.isEmpty {
                                Menu("Use Fetched Model") {
                                    ForEach(cloudTranscriptionAvailableModels.prefix(80)) { option in
                                        Button(option.displayName) {
                                            settings.cloudTranscriptionModel = option.id
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                            }

                            Spacer()

                            if !cloudTranscriptionAvailableModels.isEmpty {
                                Text("\(cloudTranscriptionAvailableModels.count) models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let cloudTranscriptionModelStatusMessage {
                            Text(cloudTranscriptionModelStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack {
                        Text("Base URL")
                            .font(.callout.weight(.medium))
                        Spacer()
                        TextField("Base URL", text: $settings.cloudTranscriptionBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Request timeout")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(Int(settings.cloudTranscriptionRequestTimeoutSeconds.rounded())) sec")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.cloudTranscriptionRequestTimeoutSeconds, in: 5...180, step: 1)

                    HStack(spacing: 8) {
                        if cloudTranscriptionAPIKeyVisible {
                            TextField("\(settings.cloudTranscriptionProvider.displayName) API key", text: $settings.cloudTranscriptionAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("\(settings.cloudTranscriptionProvider.displayName) API key", text: $settings.cloudTranscriptionAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Toggle("Show", isOn: $cloudTranscriptionAPIKeyVisible)
                            .toggleStyle(.checkbox)
                            .fixedSize()

                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            _ = pasteboard.setString(settings.cloudTranscriptionAPIKey, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy API key to clipboard")
                        .disabled(settings.cloudTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Credentials are stored in macOS Keychain.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Reset Provider Defaults") {
                            settings.applyCloudTranscriptionProviderDefaultsIfNeeded(force: true)
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                }
            }

            settingsCard(
                title: "Text Quality & Timing",
                subtitle: "Keep finalize timing visible and place deep text processing in advanced controls.",
                symbol: "text.badge.checkmark",
                tint: AppVisualTheme.accentTint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Finalize delay: \(Int(settings.finalizeDelaySeconds * 1000)) ms")
                        .font(.callout.weight(.medium))
                    Slider(value: $settings.finalizeDelaySeconds, in: 0.15...1.2, step: 0.05)
                    Text("Lower = faster paste, higher = fewer cut-offs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showRecognitionAdvancedSettings.toggle() }
                        } label: {
                            HStack {
                                Text("Advanced text processing")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showRecognitionAdvancedSettings ? 90 : 0))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showRecognitionAdvancedSettings {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Cleanup mode")
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Picker("", selection: $settings.textCleanupModeRawValue) {
                                        ForEach(TextCleanupMode.allCases) { mode in
                                            Text(mode.displayName).tag(mode.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170)
                                }
                                .help("Light keeps original phrasing; Aggressive normalizes punctuation/casing more strongly.")

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Custom phrases (comma or new line separated)")
                                        .font(.callout.weight(.medium))
                                    TextEditor(text: $settings.customContextPhrases)
                                        .frame(height: 120)
                                        .font(.callout)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                        )
                                    Text("Examples: names, products, acronyms, slang")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }

            settingsCard(
                title: "Adaptive Corrections",
                subtitle: "Learning controls and correction management moved to a dedicated section.",
                symbol: "wand.and.rays",
                tint: AppVisualTheme.accentTint
            ) {
                Text("Open Corrections to review learned fixes, add custom replacements, and tune correction sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open Corrections") {
                        selectedSection = .corrections
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
            }
        }
        .onAppear {
            showAppleSpeechAdvancedSettings = false
            showRecognitionAdvancedSettings = false
            if settings.transcriptionEngine == .whisperCpp {
                refreshWhisperModelBrowserState()
                showWhisperModelFilters = false
            } else if settings.transcriptionEngine == .cloudProviders {
                refreshCloudTranscriptionModels(showMessage: false)
            }
        }
        .onChange(of: settings.transcriptionEngineRawValue) { _ in
            if settings.transcriptionEngine == .whisperCpp {
                refreshWhisperModelBrowserState()
                showWhisperModelFilters = false
            } else if settings.transcriptionEngine == .cloudProviders {
                refreshCloudTranscriptionModels(showMessage: false)
            }
        }
        .onChange(of: settings.cloudTranscriptionProviderRawValue) { _ in
            cloudTranscriptionAvailableModels = []
            cloudTranscriptionModelStatusMessage = nil
            if settings.transcriptionEngine == .cloudProviders {
                refreshCloudTranscriptionModels(showMessage: false)
            }
        }
        .onChange(of: whisperModelSearchQuery) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperFamilyFilter) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperShowInstalledOnly) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperModelManager.installStateByModelID) { _ in
            ensureSelectedWhisperModelIsValid()
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: settings.selectedWhisperModelID) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if filteredWhisperModels.contains(where: { $0.id == trimmed }) {
                whisperBrowserModelID = trimmed
            }
        }
    }

    @ViewBuilder
    private var aiModelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .aiModels)

            aiMemoryAssistantCard
            aiProviderStatusCard
        }
        .onAppear {
            localAISetupService.refreshStatus()
        }
    }

    @ViewBuilder
    private var aiMemoryAssistantCard: some View {
        settingsCard(
            title: "AI Prompt Assistant",
            subtitle: "Core toggles first, with style and history controls in collapsible groups.",
            symbol: "brain.head.profile",
            tint: AppVisualTheme.accentTint
        ) {
            Toggle("Enable AI prompt correction", isOn: $settings.promptRewriteEnabled)
            if FeatureFlags.aiMemoryEnabled {
                Toggle("Enable AI memory assistant", isOn: $settings.memoryIndexingEnabled)
            }
            Toggle("Auto-insert high-confidence AI suggestions", isOn: $settings.promptRewriteAutoInsertEnabled)
                .disabled(!settings.promptRewriteEnabled)
            Toggle("Always convert AI suggestion to Markdown", isOn: $settings.promptRewriteAlwaysConvertToMarkdown)
                .disabled(!settings.promptRewriteEnabled)

            Divider()

            Text("Advanced rewrite style, conversation-aware history, and context mappings are managed in AI Studio.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("AI Studio…") {
                    cancelShortcutCapture()
                    NotificationCenter.default.post(name: .openAssistOpenAIMemoryStudio, object: nil)
                }
                .buttonStyle(.bordered)
            }

            Text("Current rewrite provider: \(settings.promptRewriteProviderMode.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Structured suggestions keep their formatting when inserted, including bullets and question lists. Rewrites are instructed to keep dialogue flow continuous.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var aiProviderStatusCard: some View {
        settingsCard(
            title: "Provider Connection Status",
            subtitle: "AI Studio for OAuth and API-key provider setup plus prompt model controls.",
            symbol: "network.badge.shield.half.filled",
            tint: AppVisualTheme.accentTint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OpenAI")
                    Spacer()
                    Text(settings.hasPromptRewriteOAuthSession(for: .openAI) ? "Connected" : "Not connected")
                        .foregroundStyle(settings.hasPromptRewriteOAuthSession(for: .openAI) ? AppVisualTheme.accentTint : .secondary)
                }
                HStack {
                    Text("Anthropic")
                    Spacer()
                    Text(settings.hasPromptRewriteOAuthSession(for: .anthropic) ? "Connected" : "Not connected")
                        .foregroundStyle(settings.hasPromptRewriteOAuthSession(for: .anthropic) ? AppVisualTheme.accentTint : .secondary)
                }
                HStack {
                    Text("Google Gemini")
                    Spacer()
                    Text(settings.hasPromptRewriteAPIKey(for: .google) ? "API key set" : "API key missing")
                        .foregroundStyle(settings.hasPromptRewriteAPIKey(for: .google) ? AppVisualTheme.accentTint : .secondary)
                }
                HStack {
                    Text("Local AI (Ollama)")
                    Spacer()
                    Text(localAISetupStatusLabel)
                        .foregroundStyle(localAISetupService.isReady ? AppVisualTheme.accentTint : .secondary)
                }
                if settings.localAISetupCompleted {
                    Text("Model: \(settings.localAISelectedModelID.isEmpty ? "(not selected)" : settings.localAISelectedModelID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("AI Studio…") {
                        cancelShortcutCapture()
                        NotificationCenter.default.post(name: .openAssistOpenAIMemoryStudio, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var localAISetupStatusLabel: String {
        switch localAISetupService.setupState {
        case .ready:
            return "Ready"
        case .installingRuntime:
            return "Installing runtime"
        case .downloadingModel:
            return "Downloading model"
        case .verifying:
            return "Verifying"
        case .failed:
            return "Needs repair"
        case .waitingForModelSelection:
            return "Select model"
        case .idle:
            if localAISetupService.runtimeDetection.installed {
                return localAISetupService.runtimeDetection.isHealthy ? "Runtime installed" : "Runtime unavailable"
            }
            return "Not installed"
        }
    }

    private var maskedAutomationToken: String {
        automationAPICoordinator.maskedToken(for: settings)
    }

    private var maskedTelegramBotToken: String {
        telegramRemoteCoordinator.maskedBotToken(for: settings)
    }

    private var automationAPIPortTextBinding: Binding<String> {
        Binding(
            get: { String(settings.automationAPIPort) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                guard !digits.isEmpty else { return }
                if let parsed = Int(digits), (1024...Int(UInt16.max)).contains(parsed) {
                    settings.automationAPIPort = UInt16(parsed)
                }
            }
        )
    }

    private var automationNotificationPermissionGranted: Bool {
        switch automationAPICoordinator.notificationAuthorizationState {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    private var automationNotificationPermissionHint: String {
        switch automationAPICoordinator.notificationAuthorizationState {
        case .authorized:
            return "Desktop notifications are allowed for automation alerts."
        case .provisional:
            return "Desktop notifications are provisionally allowed."
        case .ephemeral:
            return "Desktop notifications are temporarily allowed."
        case .notDetermined:
            return "Grant notification access so local API alerts can appear on your desktop."
        case .denied:
            return "Notifications are denied. Enable Open Assist in macOS Notification settings."
        case .unknown:
            return "Notification permission status is unavailable."
        }
    }

    private var codexCLINotifySnippet: String {
        automationAPICoordinator.codexCLINotifyExample(for: settings)
    }

    private var selectedClaudeHookInstallOptions: Set<ClaudeHookInstallOption> {
        var options: Set<ClaudeHookInstallOption> = []
        if installClaudeStopHook {
            options.insert(.stop)
        }
        if installClaudeSubagentStopHook {
            options.insert(.subagentStop)
        }
        if installClaudeNotificationHook {
            options.insert(.notification)
        }
        return options
    }

    private var installedClaudeHooksSummary: String {
        let installedOptions = ClaudeHookInstallOption.allCases.filter { installedClaudeHookOptions.contains($0) }
        guard !installedOptions.isEmpty else {
            return "No Open Assist Claude hooks are installed yet."
        }

        let labels = installedOptions.map(\.displayName).joined(separator: ", ")
        return "Already installed from Open Assist: \(labels)."
    }

    private var automationServerStatusLabel: String {
        switch automationAPICoordinator.serverState {
        case "running":
            return "Server is running"
        case "starting":
            return "Server is starting"
        case "failed":
            return "Server failed"
        default:
            return "Server is stopped"
        }
    }

    private var automationServerStatusColor: Color {
        switch automationAPICoordinator.serverState {
        case "running":
            return Color.green.opacity(0.92)
        case "starting":
            return Color.orange.opacity(0.92)
        case "failed":
            return Color.red.opacity(0.92)
        default:
            return Color.orange.opacity(0.92)
        }
    }

    private var integrationsOverviewSummary: String {
        let enabledSources = [
            settings.automationClaudeEnabled ? AutomationAPISource.claudeCode.displayName : nil,
            settings.automationCodexCLIEnabled ? AutomationAPISource.codexCLI.displayName : nil,
            settings.automationCodexCloudEnabled ? AutomationAPISource.codexCloud.displayName : nil
        ].compactMap { $0 }

        if enabledSources.isEmpty {
            return "No notification sources are enabled yet. Open Automation & Notifications to turn on Claude Code, Codex CLI, or Codex Cloud alerts."
        }

        return "Enabled sources: \(enabledSources.joined(separator: ", ")). Delivery settings are shared so users only configure sound, speech, and desktop alerts once."
    }

    private var telegramOverviewSummary: String {
        if settings.hasTelegramRemoteOwner {
            return "Telegram remote is paired and ready. The bot shows one active session view at a time, so chats do not get mixed together."
        }
        if settings.hasTelegramPendingPairing {
            let displayName = settings.telegramPendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty {
                return "A Telegram pairing request from \(displayName) is waiting for approval."
            }
            return "A Telegram pairing request is waiting for approval."
        }
        if settings.telegramRemoteEnabled {
            return "Telegram remote is on, but it still needs pairing. Open the focused page to paste your bot token, send /start from Telegram, and approve the pairing."
        }
        return "Telegram remote is off. Open the focused page to add a bot token, pair your Telegram DM, and control Open Assist while you are away from the Mac."
    }

    private var telegramBotChatURL: URL? {
        let label = telegramRemoteCoordinator.botIdentityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.hasPrefix("@") else { return nil }
        let username = label.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        return URL(string: "https://t.me/\(username)")
    }

    @ViewBuilder
    private var integrationsDetailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedIntegrationsPage = .overview
            } label: {
                Label("Back to Integrations", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppVisualTheme.accentTint)

            VStack(alignment: .leading, spacing: 4) {
                Text("Automation & Notifications")
                    .font(.title3.bold())
                    .foregroundStyle(AppVisualTheme.foreground(0.97))
                Text("Manage sources, shared delivery settings, local API access, and Codex status in one place.")
                    .font(.callout)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
        }
    }

    @ViewBuilder
    private var telegramDetailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedIntegrationsPage = .overview
            } label: {
                Label("Back to Integrations", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppVisualTheme.accentTint)

            VStack(alignment: .leading, spacing: 4) {
                Text("Telegram Remote")
                    .font(.title3.bold())
                    .foregroundStyle(AppVisualTheme.foreground(0.97))
                Text("Set up a Telegram bot, approve your private DM, and control one Open Assist session at a time without mixing chats.")
                    .font(.callout)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
        }
    }

    @ViewBuilder
    private var integrationsSection: some View {
        Group {
            switch selectedIntegrationsPage {
            case .overview:
                VStack(alignment: .leading, spacing: 14) {
                    settingsSectionHeader(for: .integrations)

                    settingsCard(
                        title: "Automation & Notifications",
                        subtitle: "Keep integrations simple here, then open the focused page when you need the details.",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Text(integrationsOverviewSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(settings.automationAPIEnabled ? "Local API is on." : "Local API is off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Automation & Notifications") {
                                selectedIntegrationsPage = .automationNotifications
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    settingsCard(
                        title: "Telegram Remote",
                        subtitle: "Control one Open Assist session at a time from your private Telegram chat.",
                        symbol: "paperplane.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Text(telegramOverviewSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(settings.telegramRemoteEnabled ? "Telegram remote is on." : "Telegram remote is off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Telegram Remote") {
                                selectedIntegrationsPage = .telegramRemote
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

            case .automationNotifications:
                VStack(alignment: .leading, spacing: 14) {
                    integrationsDetailHeader

                    if let automationActionMessage {
                        Text(automationActionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(
                        title: "Sources",
                        subtitle: "Choose which tools are allowed to notify through Open Assist.",
                        symbol: "switch.2",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Toggle(AutomationAPISource.claudeCode.displayName, isOn: $settings.automationClaudeEnabled)
                        Toggle(AutomationAPISource.codexCLI.displayName, isOn: $settings.automationCodexCLIEnabled)
                        Toggle(AutomationAPISource.codexCloud.displayName, isOn: $settings.automationCodexCloudEnabled)

                        Text("Claude Code and Codex CLI use the local API. Codex Cloud beta watches your local codex tasks while Open Assist stays open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(
                        title: "Delivery",
                        subtitle: "These sound, speech, and desktop alert choices are shared across every source.",
                        symbol: "speaker.wave.3.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        permissionRow(
                            name: "Notifications",
                            granted: automationNotificationPermissionGranted,
                            hint: automationNotificationPermissionHint
                        ) {
                            Task {
                                await automationAPICoordinator.requestNotificationPermissionIfNeeded()
                            }
                        }

                        Toggle("Desktop notification", isOn: $settings.automationAPINotificationsEnabled)
                        Toggle("Speak message", isOn: $settings.automationAPISpeechEnabled)
                        Toggle("Play sound", isOn: $settings.automationAPISoundEnabled)

                        HStack {
                            Text("Default voice")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Picker("Default voice", selection: $settings.automationAPIDefaultVoiceIdentifier) {
                                ForEach(automationAPICoordinator.availableVoices) { voice in
                                    Text(voice.displayLabel).tag(voice.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 280)
                        }

                        HStack {
                            Text("Default sound")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Picker("Default sound", selection: $settings.automationAPIDefaultSoundRawValue) {
                                ForEach(AutomationAPISound.allCases) { sound in
                                    Text(sound.displayName).tag(sound.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220)
                        }

                        HStack {
                            Button("Test Notification") {
                                Task {
                                    automationActionMessage = await automationAPICoordinator.sendTestAnnouncement(channels: [.notification])
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.automationAPINotificationsEnabled)

                            Button("Test Speech") {
                                Task {
                                    automationActionMessage = await automationAPICoordinator.sendTestAnnouncement(channels: [.speech])
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.automationAPISpeechEnabled)

                            Button("Test Sound") {
                                Task {
                                    automationActionMessage = await automationAPICoordinator.sendTestAnnouncement(channels: [.sound])
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.automationAPISoundEnabled)
                        }
                    }

                    settingsCard(
                        title: "Local API & Examples",
                        subtitle: "Set up Claude Code from this page, then copy the Codex CLI example if you need it.",
                        symbol: "terminal.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Toggle("Enable Automation API", isOn: $settings.automationAPIEnabled)

                        HStack {
                            Text("Bind address")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("127.0.0.1")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Port")
                                .font(.callout.weight(.medium))
                            Spacer()
                            TextField("Port", text: automationAPIPortTextBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .multilineTextAlignment(.trailing)
                                .disabled(!settings.automationAPIEnabled)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bearer token")
                                    .font(.callout.weight(.medium))
                                Text(maskedAutomationToken)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Copy") {
                                copyTextToPasteboard(settings.automationAPIToken)
                                automationActionMessage = "Token copied."
                            }
                            .buttonStyle(.bordered)
                            .disabled(settings.automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Rotate") {
                                let token = settings.rotateAutomationAPIToken()
                                copyTextToPasteboard(token)
                                automationActionMessage = "Token rotated and copied."
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.automationAPIEnabled)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Claude Code")
                                .font(.callout.weight(.medium))

                            Text("Select the Claude events you want, then Open Assist updates ~/.claude/settings.json for you.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(installedClaudeHooksSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Stop", isOn: $installClaudeStopHook)
                                    .toggleStyle(.checkbox)
                                Text(ClaudeHookInstallOption.stop.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("SubagentStop", isOn: $installClaudeSubagentStopHook)
                                    .toggleStyle(.checkbox)
                                Text(ClaudeHookInstallOption.subagentStop.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("Notification", isOn: $installClaudeNotificationHook)
                                    .toggleStyle(.checkbox)
                                Text(ClaudeHookInstallOption.notification.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(alignment: .center, spacing: 10) {
                                Button("Add Selected Hooks") {
                                    installSelectedClaudeHooks()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(selectedClaudeHookInstallOptions.isEmpty)

                                Text("Writes to ~/.claude/settings.json")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let automationActionMessage {
                                Text(automationActionMessage)
                                    .font(.caption)
                                    .foregroundStyle(AppVisualTheme.accentTint)
                            }

                            Divider()

                            Text("Codex CLI")
                                .font(.callout.weight(.medium))

                            automationSnippetCard(
                                title: "Codex CLI notify config",
                                snippet: codexCLINotifySnippet
                            )
                        }
                    }

                    settingsCard(
                        title: "Status",
                        subtitle: "Quick status for the local API, Codex CLI, and Codex Cloud beta.",
                        symbol: "info.circle.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        automationStatusRow(
                            title: "Local API",
                            badgeText: automationServerStatusLabel,
                            badgeColor: automationServerStatusColor,
                            detail: automationAPICoordinator.serverStatusText
                        )

                        automationStatusRow(
                            title: "Codex CLI",
                            badgeText: settings.automationCodexCLIEnabled ? "Enabled" : "Off",
                            badgeColor: settings.automationCodexCLIEnabled ? AppVisualTheme.accentTint : Color.orange.opacity(0.92),
                            detail: automationAPICoordinator.codexCLIStatusMessage
                        )

                        automationStatusRow(
                            title: "Codex Cloud (beta)",
                            badgeText: settings.automationCodexCloudEnabled ? "Enabled" : "Off",
                            badgeColor: settings.automationCodexCloudEnabled ? AppVisualTheme.accentTint : Color.orange.opacity(0.92),
                            detail: automationAPICoordinator.codexCloudStatusMessage
                        )
                    }
                }
                .onAppear {
                    automationActionMessage = nil
                    syncInstalledClaudeHooksFromDisk()
                    Task {
                        await automationAPICoordinator.refreshNotificationAuthorizationState()
                    }
                }
                .onChange(of: settings.automationAPIEnabled) { isEnabled in
                    if isEnabled && settings.automationAPINotificationsEnabled {
                        Task {
                            await automationAPICoordinator.requestNotificationPermissionIfNeeded()
                        }
                    }
                }
                .onChange(of: settings.automationAPINotificationsEnabled) { isEnabled in
                    if isEnabled && settings.automationAPIEnabled {
                        Task {
                            await automationAPICoordinator.requestNotificationPermissionIfNeeded()
                        }
                    }
                }

            case .telegramRemote:
                VStack(alignment: .leading, spacing: 14) {
                    telegramDetailHeader

                    if let telegramActionMessage {
                        Text(telegramActionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(
                        title: "Setup",
                        subtitle: "Paste your bot token, then approve your private Telegram DM.",
                        symbol: "paperplane.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Toggle("Enable Telegram Remote", isOn: $settings.telegramRemoteEnabled)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bot token")
                                .font(.callout.weight(.medium))

                            SecureField("Paste your Telegram bot token", text: $telegramBotTokenDraft)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 10) {
                                Button("Save Token") {
                                    settings.telegramBotToken = telegramBotTokenDraft
                                    telegramActionMessage = "Telegram bot token saved."
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Copy Saved Token") {
                                    copyTextToPasteboard(settings.telegramBotToken)
                                    telegramActionMessage = "Saved Telegram bot token copied."
                                }
                                .buttonStyle(.bordered)
                                .disabled(settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button("Clear Token") {
                                    settings.telegramBotToken = ""
                                    telegramBotTokenDraft = ""
                                    telegramActionMessage = "Telegram bot token cleared."
                                }
                                .buttonStyle(.bordered)
                            }

                            Text(maskedTelegramBotToken)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Button("Open BotFather") {
                                if let url = URL(string: "https://t.me/BotFather") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)

                            if let telegramBotChatURL {
                                Button("Open Bot Chat") {
                                    NSWorkspace.shared.open(telegramBotChatURL)
                                }
                                .buttonStyle(.bordered)
                            }

                            Button("Test Bot Connection") {
                                Task {
                                    telegramActionMessage = await telegramRemoteCoordinator.testConnection()
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("""
                        1. If you already made the bot, skip BotFather and just use your existing token.
                        2. Paste the bot token here and save it.
                        3. Turn on Telegram Remote.
                        4. Open your bot in Telegram and send /start.
                        5. If /start was sent before, send it one more time now.
                        6. Come back here and approve the pairing request.
                        7. After pairing, use /sessions, /new, or normal messages in Telegram.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsCard(
                        title: "Pairing",
                        subtitle: "Only one approved private Telegram DM can control Open Assist in this first version.",
                        symbol: "person.crop.circle.badge.checkmark",
                        tint: AppVisualTheme.accentTint
                    ) {
                        if settings.hasTelegramRemoteOwner {
                            Text("Paired Telegram user ID: \(settings.telegramOwnerUserID)")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Button("Forget Paired Chat") {
                                settings.clearTelegramRemoteOwner()
                                telegramActionMessage = "Removed the paired Telegram chat."
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("No Telegram chat is paired yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Text("The bot connection already works. The next step is to open the bot in Telegram and send /start. If you changed the token, send /start again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if settings.hasTelegramPendingPairing {
                            Divider()

                            let pendingDisplayName = settings.telegramPendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(pendingDisplayName.isEmpty ? "Pending pairing request." : "Pending pairing request from \(pendingDisplayName).")
                                .font(.callout.weight(.medium))

                            Text("Approve this request to let that private Telegram chat control one Open Assist session view at a time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Button("Approve Pairing") {
                                    Task {
                                        telegramActionMessage = await telegramRemoteCoordinator.approvePendingPairing()
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Decline") {
                                    Task {
                                        telegramActionMessage = await telegramRemoteCoordinator.rejectPendingPairing()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    settingsCard(
                        title: "Behavior",
                        subtitle: "Telegram shows one active session view so different Open Assist sessions do not get mixed together.",
                        symbol: "rectangle.3.group.bubble.left.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        Text("""
                        When you switch sessions in Telegram, Open Assist removes the temporary view for the old session and loads the new session instead. The real history stays safe inside Open Assist on your Mac.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsCard(
                        title: "Status",
                        subtitle: "See bot identity, pairing state, and polling health.",
                        symbol: "info.circle.fill",
                        tint: AppVisualTheme.accentTint
                    ) {
                        automationStatusRow(
                            title: "Telegram Bot",
                            badgeText: settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Missing token" : "Configured",
                            badgeColor: settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange.opacity(0.92) : AppVisualTheme.accentTint,
                            detail: telegramRemoteCoordinator.botIdentityLabel
                        )

                        automationStatusRow(
                            title: "Remote status",
                            badgeText: settings.telegramRemoteEnabled ? "Enabled" : "Off",
                            badgeColor: settings.telegramRemoteEnabled ? AppVisualTheme.accentTint : Color.orange.opacity(0.92),
                            detail: telegramRemoteCoordinator.connectionStatusMessage
                        )

                        automationStatusRow(
                            title: "Pairing",
                            badgeText: settings.hasTelegramRemoteOwner ? "Paired" : (settings.hasTelegramPendingPairing ? "Pending" : "Waiting"),
                            badgeColor: settings.hasTelegramRemoteOwner ? Color.green.opacity(0.92) : Color.orange.opacity(0.92),
                            detail: telegramRemoteCoordinator.pairingStatusMessage
                        )

                        if let lastErrorMessage = telegramRemoteCoordinator.lastErrorMessage,
                           !lastErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(lastErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .onAppear {
                    telegramActionMessage = nil
                    telegramBotTokenDraft = settings.telegramBotToken
                }
            }
        }
    }

    @ViewBuilder
    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .corrections)

            settingsCard(
                title: "Adaptive Corrections",
                subtitle: "Learn from quick edits and manage learned replacements.",
                symbol: "text.badge.checkmark",
                tint: AppVisualTheme.accentTint
            ) {
                Text("Learned corrections are used as recognition hints for Apple Speech and whisper.cpp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Learn from quick post-insert corrections", isOn: $settings.adaptiveCorrectionsEnabled)

                Toggle("Play sound when a correction is learned", isOn: $settings.playCorrectionLearnedSound)
                    .disabled(!settings.adaptiveCorrectionsEnabled)

                if settings.playCorrectionLearnedSound {
                    dictationSoundRow(
                        title: "Learned correction sound",
                        selection: $settings.dictationCorrectionLearnedSoundName
                    )
                        .disabled(!settings.adaptiveCorrectionsEnabled)
                } else {
                    Text("Enable this option to play a custom sound when a correction is learned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Add Custom Correction…") {
                        openCreateCorrectionDialog()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }

                if adaptiveCorrectionStore.learnedCorrections.isEmpty {
                    Text("No learned corrections yet. Fix a mistaken word once and Open Assist can learn it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(adaptiveCorrectionStore.learnedCorrections.prefix(12)), id: \.id) { correction in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(correction.source)
                                    .font(.callout.monospaced())
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                Text(correction.replacement)
                                    .font(.callout.monospaced())
                                Spacer()
                                Button("Edit") {
                                    beginEditingCorrection(correction)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button("Remove") {
                                    adaptiveCorrectionStore.removeCorrection(source: correction.source)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if adaptiveCorrectionStore.learnedCorrections.count > 12 {
                            HStack {
                                Button("View All \\(adaptiveCorrectionStore.learnedCorrections.count) Corrections...") {
                                    showingCorrectionsListSheet = true
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                            }
                            .padding(.top, 4)
                        }

                        HStack {
                            Spacer()
                            Button("Clear Learned Corrections", role: .destructive) {
                                adaptiveCorrectionStore.clearAll()
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredCorrections: [AdaptiveCorrectionStore.LearnedCorrection] {
        let all = adaptiveCorrectionStore.learnedCorrections
        let query = correctionsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return all }
        return all.filter {
            $0.source.lowercased().contains(query) || $0.replacement.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var correctionsListSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack {
                    Text("Learned Corrections")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showingCorrectionsListSheet = false
                    }
                }
                .padding()
                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    if adaptiveCorrectionStore.learnedCorrections.isEmpty {
                        Text("No learned corrections yet. Fix a mistaken word once and Open Assist can learn it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        TextField("Search corrections", text: $correctionsSearchQuery)
                            .textFieldStyle(.roundedBorder)

                        if filteredCorrections.isEmpty {
                            Text("No corrections match \"\\(correctionsSearchQuery)\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(filteredCorrections, id: \.id) { correction in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(correction.source)
                                                .font(.callout.monospaced())
                                            Image(systemName: "arrow.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                            Text(correction.replacement)
                                                .font(.callout.monospaced())
                                            Spacer()
                                            Button("Edit") {
                                                beginEditingCorrection(correction)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            Button("Remove") {
                                                adaptiveCorrectionStore.removeCorrection(source: correction.source)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
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
        .frame(width: 500, height: 500)
    }

    @ViewBuilder
    private var providersSelectionSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack {
                    Text("Manage Detected Providers")
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
                        Text("No providers detected yet. Click Rescan to detect providers.")
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
                            .disabled(!settings.memoryIndexingEnabled || filteredMemoryProviders.isEmpty)

                            Button("Clear Visible") {
                                setMemoryProvidersEnabled(filteredMemoryProviders, enabled: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.memoryIndexingEnabled || filteredMemoryProviders.isEmpty)
                        }

                        if filteredMemoryProviders.isEmpty {
                            Text("No providers match the current filters.")
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
                                        .disabled(!settings.memoryIndexingEnabled)
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
                            Toggle("Only", isOn: $memoryFoldersOnlyEnabledProviders)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                                .help("Only enabled source providers")
                        }

                        HStack(spacing: 8) {
                            Button("Select All Visible") {
                                setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: true)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.memoryIndexingEnabled || filteredMemorySourceFolders.isEmpty)

                            Button("Clear Visible") {
                                setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.memoryIndexingEnabled || filteredMemorySourceFolders.isEmpty)
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
                                        .disabled(!settings.memoryIndexingEnabled)
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

    private func prepareMemorySourcesSection() {
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

    private func refreshMemoryBrowser() {
        let entries = memoryIndexingSettingsService.browseIndexedMemories(
            query: memoryBrowserQuery,
            providerID: normalizedMemoryBrowserProviderID,
            sourceFolderID: normalizedMemoryBrowserFolderID,
            includePlanContent: memoryBrowserIncludePlanContent,
            limit: 200
        )
        if memoryBrowserHighSignalOnly {
            memoryBrowserEntries = entries.filter(isHighSignalMemoryEntry)
        } else {
            memoryBrowserEntries = entries
        }
    }

    private func isHighSignalMemoryEntry(_ entry: MemoryIndexedEntry) -> Bool {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == "workspace" || title == "storage" || title == "state" {
            return false
        }

        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func setMemoryProvidersEnabled(
        _ providers: [MemoryIndexingSettingsService.Provider],
        enabled: Bool
    ) {
        for provider in providers {
            settings.setMemoryProviderEnabled(provider.id, enabled: enabled)
        }
    }

    private func setMemorySourceFoldersEnabled(
        _ folders: [MemoryIndexingSettingsService.SourceFolder],
        enabled: Bool
    ) {
        for folder in folders {
            settings.setMemorySourceFolderEnabled(folder.id, enabled: enabled)
        }
    }

    private func normalizedMemoryFilter(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

        guard showMessage else { return }
        if result.indexQueued {
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued \(result.queuedSourceCount) selected source(s) for indexing in the background."
        } else if !FeatureFlags.aiMemoryEnabled {
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. AI memory feature flag is disabled, so no sources were queued."
        } else {
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued 0 selected sources for indexing."
        }
    }

    private func handleMemoryIndexingCompletion(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        let isRebuild = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.rebuild] as? Bool ?? false
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
        if failureCount > 0 {
            if let firstFailure, !firstFailure.isEmpty {
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards. First issue: \(firstFailure)"
            } else {
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards."
            }
            refreshMemoryBrowser()
            return
        }

        memoryActionMessage = "\(actionLabel) finished. Indexed \(indexedFiles) files, skipped \(skippedFiles), produced \(indexedCards) cards, and generated \(indexedRewrites) rewrite suggestion(s)."
        refreshMemoryBrowser()
    }

    private func refreshWhisperModelBrowserState() {
        whisperModelManager.refreshInstallStates()
        ensureSelectedWhisperModelIsValid()
        ensureWhisperBrowserModelSelectionIsValid()
    }

    @ViewBuilder
    private func whisperModelRow(for model: WhisperModelCatalog.Model) -> some View {
        let installState = whisperModelManager.installStateByModelID[model.id] ?? .notInstalled
        let isSelected = settings.selectedWhisperModelID == model.id
        let cardTint: Color = {
            if isSelected { return AppVisualTheme.accentTint }
            switch installState {
            case .installed:
                return AppVisualTheme.accentTint
            case .downloading, .installing:
                return AppVisualTheme.baseTint
            case .failed:
                return Color.red.opacity(0.78)
            case .notInstalled:
                return AppVisualTheme.baseTint.opacity(0.65)
            }
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AppIconBadge(
                    symbol: "waveform.path.ecg.rectangle.fill",
                    tint: cardTint,
                    size: 22,
                    symbolSize: 10,
                    isEmphasized: isSelected
                )

                Text(model.displayName)
                    .font(.callout.weight(.semibold))

                if model.isEnglishOnly {
                    whisperModelBadge("EN")
                }
                if model.isQuantized {
                    whisperModelBadge("Quantized")
                }
                if model.isDiarization {
                    whisperModelBadge("Diarize")
                }

                if isSelected {
                    Text("Selected")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppVisualTheme.accentTint.opacity(0.12)))
                }
                Spacer()
                Text(model.diskSizeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(model.memoryFootprintText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(model.useCaseDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch installState {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            case .installing:
                Text("Installing model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.82))

            case .installed:
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.accentTint)

            case .notInstalled:
                Text("Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(isSelected ? "Using" : "Use Model") {
                    settings.selectedWhisperModelID = model.id
                }
                .buttonStyle(.bordered)
                .disabled(installState != .installed || isSelected)

                switch installState {
                case .downloading:
                    Button("Cancel") {
                        whisperModelManager.cancelDownload(modelID: model.id)
                    }
                    .buttonStyle(.bordered)

                case .installing:
                    Button("Installing…") {}
                        .buttonStyle(.bordered)
                        .disabled(true)

                case .installed:
                    Button("Delete") {
                        whisperModelManager.deleteModel(modelID: model.id)
                        if settings.selectedWhisperModelID == model.id {
                            settings.selectedWhisperModelID = ""
                        }
                    }
                    .buttonStyle(.bordered)

                case .notInstalled, .failed:
                    Button(installState.installButtonTitle) {
                        whisperModelManager.installModel(
                            modelID: model.id,
                            includeCoreML: settings.whisperUseCoreML
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .appThemedSurface(
            cornerRadius: 12,
            tint: cardTint,
            strokeOpacity: 0.19,
            tintOpacity: 0.09
        )
    }

    @ViewBuilder
    private func whisperModelBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppVisualTheme.foreground(0.82))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(AppVisualTheme.foreground(0.10))
                    .overlay(
                        Capsule()
                            .stroke(AppVisualTheme.foreground(0.18), lineWidth: 0.6)
                    )
            )
    }

    private var whisperFamilyFilterOptions: [String] {
        let defaultOrder = ["tiny", "base", "small", "medium", "large"]
        let availableFamilies = Set(WhisperModelCatalog.curatedModels.map(\.family))

        var options: [String] = ["all"]
        for family in defaultOrder where availableFamilies.contains(family) {
            options.append(family)
        }
        for family in availableFamilies.sorted() where !defaultOrder.contains(family) {
            options.append(family)
        }
        return options
    }

    private var filteredWhisperModels: [WhisperModelCatalog.Model] {
        var models = WhisperModelCatalog.curatedModels

        if whisperFamilyFilter != "all" {
            models = models.filter { $0.family == whisperFamilyFilter }
        }

        if whisperShowInstalledOnly {
            models = models.filter { whisperModelManager.hasInstalledModel(id: $0.id) }
        }

        let query = whisperModelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            models = models.filter { model in
                model.id.lowercased().contains(query) ||
                    model.useCaseDescription.lowercased().contains(query)
            }
        }

        return models.sorted { lhs, rhs in
            let rankByFamily: [String: Int] = [
                "tiny": 0,
                "base": 1,
                "small": 2,
                "medium": 3,
                "large": 4
            ]
            let lhsRank = rankByFamily[lhs.family] ?? 99
            let rhsRank = rankByFamily[rhs.family] ?? 99
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.id < rhs.id
        }
    }

    private var activeWhisperBrowserModel: WhisperModelCatalog.Model? {
        guard !whisperBrowserModelID.isEmpty else { return nil }
        guard filteredWhisperModels.contains(where: { $0.id == whisperBrowserModelID }) else {
            return nil
        }
        return WhisperModelCatalog.model(withID: whisperBrowserModelID)
    }

    private func ensureWhisperBrowserModelSelectionIsValid() {
        guard settings.transcriptionEngine == .whisperCpp else { return }

        if filteredWhisperModels.isEmpty {
            whisperBrowserModelID = ""
            return
        }

        if filteredWhisperModels.contains(where: { $0.id == whisperBrowserModelID }) {
            return
        }

        let preferredID = settings.selectedWhisperModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredID.isEmpty,
           filteredWhisperModels.contains(where: { $0.id == preferredID }) {
            whisperBrowserModelID = preferredID
            return
        }

        whisperBrowserModelID = filteredWhisperModels[0].id
    }

    private func ensureSelectedWhisperModelIsValid() {
        if settings.transcriptionEngine != .whisperCpp {
            return
        }

        if whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
            return
        }

        if let firstInstalled = WhisperModelCatalog.curatedModels.first(where: { whisperModelManager.hasInstalledModel(id: $0.id) }) {
            settings.selectedWhisperModelID = firstInstalled.id
        } else {
            settings.selectedWhisperModelID = ""
        }
    }

    private func refreshCloudTranscriptionModels(showMessage: Bool) {
        let provider = settings.cloudTranscriptionProvider
        let baseURL = settings.cloudTranscriptionBaseURL
        let apiKey = settings.cloudTranscriptionAPIKey

        let requestToken = UUID()
        cloudTranscriptionModelRequestToken = requestToken
        cloudTranscriptionModelsLoading = true
        if showMessage {
            cloudTranscriptionModelStatusMessage = "Loading \(provider.displayName) models..."
        }

        Task {
            let result = await CloudTranscriptionModelCatalogService.shared.fetchModels(
                provider: provider,
                baseURL: baseURL,
                apiKey: apiKey
            )

            await MainActor.run {
                guard requestToken == cloudTranscriptionModelRequestToken else { return }
                cloudTranscriptionModelsLoading = false

                let currentModel = settings.cloudTranscriptionModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if result.models.isEmpty, !currentModel.isEmpty {
                    cloudTranscriptionAvailableModels = [
                        CloudTranscriptionModelOption(
                            id: currentModel,
                            displayName: currentModel
                        )
                    ]
                } else {
                    cloudTranscriptionAvailableModels = result.models
                }

                if currentModel.isEmpty {
                    if let preferredDefault = result.models.first(where: {
                        $0.id.caseInsensitiveCompare(provider.defaultModel) == .orderedSame
                    }) {
                        settings.cloudTranscriptionModel = preferredDefault.id
                    } else if let firstModel = result.models.first {
                        settings.cloudTranscriptionModel = firstModel.id
                    }
                }

                if showMessage || result.source == .fallback {
                    cloudTranscriptionModelStatusMessage = result.message
                } else if let resultMessage = result.message,
                          resultMessage.localizedCaseInsensitiveContains("loaded") {
                    cloudTranscriptionModelStatusMessage = resultMessage
                }
            }
        }
    }

    @ViewBuilder
    @MainActor
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let tint = tint ?? AppVisualTheme.accentTint
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(tint.opacity(0.12))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.90))

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(0.54))
                    }
                }

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.foreground(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.06), lineWidth: 0.5)
                )
        )
    }

    @MainActor
    @ViewBuilder
    private func settingsDisclosureCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let tint = tint ?? AppVisualTheme.accentTint
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tint.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(tint.opacity(0.12))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.90))

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(AppVisualTheme.foreground(0.54))
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.foreground(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.07), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func shortcutSegmentRow(_ segments: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(segments, id: \.self) { segment in
                Text(segment)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppVisualTheme.foreground(0.86))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppVisualTheme.foreground(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.5)
                            )
                    )
            }
        }
    }

    @ViewBuilder
    private func manualShortcutBuilder(for target: ShortcutCaptureTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Self.shortcutModifierOptions) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { manualShortcutHasModifier(option.flag, for: target) },
                        set: { isEnabled in
                            setManualShortcutModifier(option.flag, enabled: isEnabled, for: target)
                        }
                    ))
                    .toggleStyle(.button)
                }
            }

            HStack(spacing: 10) {
                Text("Primary key")
                    .font(.callout.weight(.medium))
                Picker("Primary key", selection: manualShortcutKeyBinding(for: target)) {
                    Text("Modifier only")
                        .tag(Self.manualModifierOnlyKeyCode)
                    ForEach(manualShortcutKeyOptions) { option in
                        Text(option.label)
                            .tag(option.keyCode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 210)
                .labelsHidden()
            }

            Text("For modifier-only shortcuts, choose 2 to 4 modifiers and select \"Modifier only\".")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func manualShortcutHasModifier(_ modifier: NSEvent.ModifierFlags, for target: ShortcutCaptureTarget) -> Bool {
        ShortcutValidation.filteredModifierFlags(from: shortcutModifiersRaw(for: target)).contains(modifier)
    }

    private func setManualShortcutModifier(
        _ modifier: NSEvent.ModifierFlags,
        enabled: Bool,
        for target: ShortcutCaptureTarget
    ) {
        var flags = ShortcutValidation.filteredModifierFlags(from: shortcutModifiersRaw(for: target))
        if enabled {
            flags.insert(modifier)
        } else {
            flags.remove(modifier)
        }

        _ = applyShortcutSelection(
            for: target,
            keyCode: shortcutKeyCode(for: target),
            modifiersRaw: flags.rawValue,
            validationMessage: "Shortcut must use 2 to 4 keys. Use 1-3 modifiers with a key, or 2-4 modifiers with \"Modifier only\"."
        )
    }

    private func manualShortcutKeyBinding(for target: ShortcutCaptureTarget) -> Binding<UInt16> {
        Binding(
            get: { shortcutKeyCode(for: target) },
            set: { newKeyCode in
                _ = applyShortcutSelection(
                    for: target,
                    keyCode: newKeyCode,
                    modifiersRaw: shortcutModifiersRaw(for: target),
                    validationMessage: "Shortcut must use 2 to 4 keys. Use 1-3 modifiers with a key, or 2-4 modifiers with \"Modifier only\"."
                )
            }
        )
    }

    private func sanitizePinnedConversationContextSelection() {
        let pinned = settings.promptRewriteConversationPinnedContextID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinned.isEmpty else { return }
        if !promptRewriteConversationStore.hasContext(id: pinned) {
            settings.promptRewriteConversationPinnedContextID = ""
        }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchEntries: [SettingSearchEntry] {
        [
            .init(section: .essentials, title: "Accessibility access", detail: "Grant or verify accessibility permission", keywords: ["accessibility", "permission", "grant"]),
            .init(section: .essentials, title: "Copy transcript to clipboard", detail: "Automatically copy inserted voice results", keywords: ["clipboard", "copy", "output"]),
            .init(section: .essentials, title: "Dictation sound profile", detail: "Choose tones for start, stop, processing, and pasted cues", keywords: ["sound", "start", "listening", "feedback", "processing", "stop", "pasted"]),
            .init(section: .essentials, title: "Waveform theme", detail: "Choose visual waveform style", keywords: ["waveform", "theme", "appearance"]),
            .init(section: .shortcuts, title: "Hold-to-talk shortcut", detail: "Set keys for press-and-hold voice capture", keywords: ["hold", "shortcut", "keyboard"]),
            .init(section: .shortcuts, title: "Mute shortcut system sounds", detail: "Optionally suppress beeps while hold-to-talk is pressed", keywords: ["mute", "beep", "sound", "hold", "shortcut"]),
            .init(section: .shortcuts, title: "Manual shortcut map", detail: "Click modifiers and choose a key manually", keywords: ["manual", "map", "shortcut", "click", "keys"]),
            .init(section: .shortcuts, title: "Continuous toggle shortcut", detail: "Set keys for start/stop continuous voice capture", keywords: ["continuous", "toggle", "shortcut"]),
            .init(section: .shortcuts, title: "Agent shortcut", detail: "Hold to speak, then release to paste into the assistant box", keywords: ["assistant", "agent", "voice", "shortcut", "keyboard", "hold", "paste"]),
            .init(section: .shortcuts, title: "Paste last transcript", detail: "Reserved shortcut: ⌥⌘V", keywords: ["paste", "last transcript", "reserved"]),
            .init(section: .speech, title: "Auto-detect microphone", detail: "Automatically use best available input", keywords: ["microphone", "input", "auto"]),
            .init(section: .speech, title: "Microphone device picker", detail: "Choose a specific microphone manually", keywords: ["microphone", "device", "picker"]),
            .init(section: .speech, title: "Transcription engine", detail: "Switch between Apple Speech, whisper.cpp, and cloud providers", keywords: ["engine", "whisper", "apple", "cloud", "openai", "groq", "deepgram", "gemini", "api key", "recognition"]),
            .init(section: .speech, title: "Contextual language bias", detail: "Improve recognition with likely words", keywords: ["context", "bias", "recognition"]),
            .init(section: .speech, title: "Preserve words across pauses", detail: "Prevent dropped words in short pauses", keywords: ["pause", "preserve", "recognition"]),
            .init(section: .speech, title: "Recognition mode", detail: "Choose local/cloud behavior for Apple Speech", keywords: ["on-device", "cloud", "privacy", "recognition"]),
            .init(section: .speech, title: "Automatic punctuation", detail: "Enable punctuation from Apple Speech", keywords: ["punctuation", "speech"]),
            .init(section: .speech, title: "Finalize delay", detail: "Control speed vs stability before insertion", keywords: ["delay", "finalize", "timing"]),
            .init(section: .speech, title: "Cleanup mode", detail: "Light or aggressive text cleanup", keywords: ["cleanup", "mode"]),
            .init(section: .speech, title: "Custom phrases", detail: "Add names, acronyms, and domain language", keywords: ["phrases", "vocabulary", "context"]),
            .init(section: .speech, title: "whisper model install", detail: "Download and manage all whisper.cpp models", keywords: ["model", "download", "whisper", "tiny", "base", "small", "medium", "large"]),
            .init(section: .speech, title: "whisper Core ML", detail: "Use Core ML encoder when available", keywords: ["core ml", "ane", "whisper", "speed"]),
            .init(section: .speech, title: "whisper idle unload", detail: "Unload whisper context after inactivity to reduce memory", keywords: ["memory", "idle", "unload", "whisper", "context"]),
            .init(section: .corrections, title: "Adaptive corrections", detail: "Learn from your quick word/phrase fixes", keywords: ["adaptive", "learned", "corrections", "backspace"]),
            .init(section: .corrections, title: "Correction learned sound", detail: "Choose a tone when a new correction is learned", keywords: ["sound", "beep", "feedback", "correction", "learned"]),
            .init(section: .corrections, title: "Learned corrections list", detail: "View, remove, or clear saved corrections", keywords: ["learned", "list", "remove", "clear"]),
            .init(section: .aiModels, title: "AI prompt correction toggle", detail: "Enable or disable AI prompt rewrite assistance", keywords: ["prompt", "rewrite", "toggle", "enable", "ai"]),
            .init(section: .aiModels, title: "Auto-insert high-confidence suggestions", detail: "Skip preview and insert AI suggestion immediately when confidence is at least 85%", keywords: ["auto", "insert", "confidence", "rewrite", "preview"]),
            .init(section: .aiModels, title: "Markdown suggestion conversion", detail: "Always convert AI suggestions to Markdown before insertion", keywords: ["markdown", "format", "rewrite", "insert", "assistant"]),
            .init(section: .aiModels, title: "Rewrite style preset", detail: "Choose formal, casual, architect, developer, or writer voice", keywords: ["style", "tone", "formal", "casual", "architect", "senior", "junior", "writer"]),
            .init(section: .aiModels, title: "Custom style instructions", detail: "Provide tone-only rewrite guidance without changing refine-only behavior", keywords: ["custom", "style", "persona", "voice", "architect", "developer", "writer", "instruction", "tone-only"]),
            .init(section: .aiModels, title: "Conversation-aware rewrite history", detail: "Opt in to rolling history scoped by app and screen", keywords: ["conversation", "history", "context", "app", "screen", "rewrite"]),
            .init(section: .aiModels, title: "Rewrite conversation timeout", detail: "Expire conversation buckets after inactivity", keywords: ["timeout", "expire", "conversation", "history", "minutes"]),
            .init(section: .aiModels, title: "Rewrite history source switch", detail: "Pin to a saved context or use automatic app/screen context", keywords: ["switch", "pin", "context", "history", "conversation"]),
            .init(section: .aiModels, title: "Provider connection status", detail: "See OAuth and API key status for OpenAI, Anthropic, and Google Gemini", keywords: ["provider", "oauth", "api key", "openai", "anthropic", "google", "gemini", "connection"]),
            .init(section: .aiModels, title: "AI Studio", detail: "Launch dedicated AI page for provider and prompt model controls", keywords: ["ai", "studio", "providers", "models", "rewrite"]),
            .init(section: .computerControl, title: "Automation permissions", detail: "Review Automation and Full Disk Access for browser and app actions", keywords: ["automation", "apple events", "full disk", "browser"]),
            .init(section: .computerControl, title: "Browser profile", detail: "Choose the Chrome, Brave, or Edge profile Open Assist should reuse", keywords: ["browser", "profile", "chrome", "brave", "edge", "session"]),
            .init(section: .computerControl, title: "Helper status", detail: "See local automation helper readiness and current setup issues", keywords: ["helper", "status", "issues", "readiness"]),
            .init(section: .computerControl, title: "Supported app actions", detail: "See Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages actions", keywords: ["finder", "terminal", "calendar", "system settings", "app action", "messages", "notes", "contacts", "reminders"]),
            .init(section: .computerControl, title: "Approval behavior", detail: "Understand session approvals and high-risk confirmation rules", keywords: ["approval", "allow", "session", "confirmation", "risky"]),
            .init(section: .integrations, title: "Automation & notifications", detail: "Open the focused page for Claude Code, Codex CLI, and Codex Cloud alerts", keywords: ["automation", "notifications", "sources", "codex", "claude"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Enable automation API", detail: "Run a localhost API for Claude Code and Codex CLI", keywords: ["automation", "api", "localhost", "server", "claude", "codex"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Automation API token", detail: "Copy or rotate the local bearer token", keywords: ["token", "bearer", "auth", "copy", "rotate"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Claude hook examples", detail: "Copy sample Notification and Stop hook snippets", keywords: ["claude", "hook", "notification", "stop", "subagent", "curl"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Codex CLI notify config", detail: "Copy the Codex CLI notify snippet for ~/.codex/config.toml", keywords: ["codex", "notify", "config", "toml", "cloud"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Codex Cloud beta", detail: "Watch local codex cloud tasks and alert when they are ready or fail", keywords: ["codex", "cloud", "beta", "polling", "ready", "failed"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Automation notification permission", detail: "Allow desktop notifications for local API alerts", keywords: ["notification", "permission", "desktop", "grant"], integrationsPage: .automationNotifications),
            .init(section: .integrations, title: "Telegram remote", detail: "Control the selected Open Assist session from a private Telegram bot chat", keywords: ["telegram", "remote", "bot", "chat", "session"], integrationsPage: .telegramRemote),
            .init(section: .integrations, title: "Telegram bot token", detail: "Paste, copy, test, or clear your Telegram bot token", keywords: ["telegram", "botfather", "token", "paste", "copy"], integrationsPage: .telegramRemote),
            .init(section: .integrations, title: "Telegram pairing", detail: "Approve or forget the private Telegram chat that can control Open Assist", keywords: ["telegram", "pairing", "approve", "private", "chat"], integrationsPage: .telegramRemote),
            .init(section: .integrations, title: "Telegram setup steps", detail: "Follow the built-in BotFather and /start setup guide", keywords: ["telegram", "setup", "steps", "botfather", "start"], integrationsPage: .telegramRemote),
            .init(section: .integrations, title: "Telegram session switching", detail: "Switch sessions without mixing messages from different chats", keywords: ["telegram", "switch", "session", "messages", "mixed"], integrationsPage: .telegramRemote),
            .init(section: .about, title: "Permission overview", detail: "See accessibility, mic, and speech status", keywords: ["permissions", "accessibility", "microphone", "speech"]),
            .init(section: .about, title: "Crash logs", detail: "Open existing crash logs in Finder", keywords: ["crash", "logs", "diagnostics"]),
            .init(section: .about, title: "Uninstall Open Assist", detail: "Remove app and clear saved settings", keywords: ["uninstall", "remove", "reset"])
        ]
    }

    private var filteredSearchEntries: [SettingSearchEntry] {
        guard !trimmedSearchQuery.isEmpty else { return [] }
        return searchEntries.filter { entry in
            let haystack = ([entry.title, entry.detail] + entry.keywords).joined(separator: " ").lowercased()
            return haystack.contains(trimmedSearchQuery)
        }
    }

    private func navigateToSearchEntry(_ entry: SettingSearchEntry) {
        selectedSection = entry.section
        if entry.section == .integrations {
            selectedIntegrationsPage = entry.integrationsPage ?? .overview
        }
    }

    private var filteredSections: [SettingsSection] {
        let availableSections = SettingsSection.allCases

        guard !trimmedSearchQuery.isEmpty else {
            return availableSections
        }

        let query = trimmedSearchQuery
        let fromSectionTerms = availableSections.filter { section in
            let sectionHaystack = ([section.title, section.subtitle] + section.searchTerms)
                .joined(separator: " ")
                .lowercased()
            return sectionHaystack.contains(query)
        }
        let fromEntries = Set(filteredSearchEntries.map(\.section))

        let combined = availableSections.filter { section in
            fromSectionTerms.contains(section) || fromEntries.contains(section)
        }
        return combined
    }

    private var canSubmitCorrectionDraft: Bool {
        !correctionSourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !correctionReplacementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func openCreateCorrectionDialog() {
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
        correctionDialogMessage = nil
        isCorrectionEditorPresented = true
    }

    private func beginEditingCorrection(_ correction: AdaptiveCorrectionStore.LearnedCorrection) {
        correctionEditingSource = correction.source
        correctionSourceDraft = correction.source
        correctionReplacementDraft = correction.replacement
        correctionDialogMessage = nil
        isCorrectionEditorPresented = true
    }

    private func closeCorrectionEditorDialog() {
        isCorrectionEditorPresented = false
        correctionDialogMessage = nil
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
    }

    private func submitCorrectionDraft() {
        let originalEditingSource = correctionEditingSource
        guard let saved = adaptiveCorrectionStore.upsertManualCorrection(
            source: correctionSourceDraft,
            replacement: correctionReplacementDraft
        ) else {
            correctionDialogMessage = "Enter both fields with real words."
            return
        }

        if let originalEditingSource, originalEditingSource != saved.source {
            adaptiveCorrectionStore.removeCorrection(source: originalEditingSource)
        }

        correctionDialogMessage = nil
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
        isCorrectionEditorPresented = false
    }

    @ViewBuilder
    private var correctionEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(correctionEditingSource == nil ? "Add Custom Correction" : "Edit Correction")
                .font(.title3.weight(.semibold))

            Text("When Open Assist hears")
                .font(.callout.weight(.medium))
            TextField("e.g. get ignored", text: $correctionSourceDraft)
                .textFieldStyle(.roundedBorder)

            Text("Replace with")
                .font(.callout.weight(.medium))
            TextField("e.g. gitignored", text: $correctionReplacementDraft)
                .textFieldStyle(.roundedBorder)

            if let correctionDialogMessage {
                Text(correctionDialogMessage)
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.accentTint)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    closeCorrectionEditorDialog()
                }
                .buttonStyle(.bordered)

                Button(correctionEditingSource == nil ? "Add Correction" : "Save Changes") {
                    submitCorrectionDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitCorrectionDraft)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
        .padding(10)
        .background(AppChromeBackground())
        .frame(width: 460)
    }

    private func matchCount(for section: SettingsSection) -> Int {
        filteredSearchEntries.filter { $0.section == section }.count
    }

    @ViewBuilder
    private var accessibilityCard: some View {
        settingsCard(
            title: settings.accessibilityTrusted ? "Accessibility access granted" : "Accessibility access required",
            subtitle: settings.accessibilityTrusted
                ? "Open Assist can control paste and insertion reliably."
                : "Enable Open Assist in Privacy & Security -> Accessibility so paste and text insertion works across apps.",
            symbol: settings.accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
            tint: settings.accessibilityTrusted ? AppVisualTheme.accentTint : AppVisualTheme.baseTint
        ) {
            HStack(spacing: 8) {
                Button("Check again") {
                    settings.refreshAccessibilityStatus(prompt: false)
                }
                .buttonStyle(.bordered)

                if !settings.accessibilityTrusted {
                    Button("Grant Accessibility Access…") {
                        PermissionCenter.requestAccessibilityPermission(
                            using: settings,
                            promptIfNeeded: true,
                            openSettingsIfDenied: false
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            settings.refreshAccessibilityStatus(prompt: false)
        }
    }

    @ViewBuilder
    private var computerControlSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .computerControl)

            settingsCard(
                title: "Automation Permissions",
                subtitle: "Grant only the Mac permissions needed for browser reuse and direct app actions.",
                symbol: "hand.raised.fill",
                tint: SettingsSection.computerControl.tint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow(
                        name: "Automation / Apple Events",
                        granted: computerPermissionSnapshot.appleEventsGranted,
                        hint: computerPermissionSnapshot.appleEventsKnown
                            ? "Needed for direct browser and app scripting. Click Grant to ask for each installed target app one by one."
                            : "Click Grant to ask for each installed target app one by one.",
                        action: {
                            PermissionCenter.requestAppleEventsPermission(openSettingsIfDenied: true)
                            refreshComputerControlState()
                        }
                    )

                    permissionRow(
                        name: "Full Disk Access",
                        granted: computerPermissionSnapshot.fullDiskAccessGranted,
                        hint: computerPermissionSnapshot.fullDiskAccessKnown
                            ? "Optional. Only needed for protected folders like Mail, Messages, or Safari data."
                            : "Optional. Open this only when a protected location needs it.",
                        action: {
                            PermissionCenter.openPrivacySettingsPane(query: "Full Disk Access")
                            refreshComputerControlState()
                        }
                    )
                }

                HStack(spacing: 8) {
                    Button("Check Again") {
                        refreshComputerControlState()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Privacy Settings") {
                        PermissionCenter.openPrivacySettingsPane(query: "Privacy")
                    }
                    .buttonStyle(.bordered)
                }
            }

            settingsCard(
                title: "Automation App Access",
                subtitle: "Ask macOS for the same per-app Automation entries that older builds may already have.",
                symbol: "switch.2",
                tint: SettingsSection.computerControl.tint
            ) {
                AutomationAccessSettingsView {
                    refreshComputerControlState()
                }
            }

            settingsCard(
                title: "Local Helper Status",
                subtitle: "See whether the local automation layer is ready to run browser and app actions.",
                symbol: "desktopcomputer",
                tint: SettingsSection.computerControl.tint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let computerControlStatus {
                        statusBadgeRow(
                            title: computerControlStatus.helperName,
                            detail: "\(computerControlStatus.executionMode) • \(computerControlStatus.available ? "Available" : "Unavailable")",
                            color: computerControlStatus.available ? .green : .orange
                        )

                        if let selectedProfile = computerControlStatus.selectedBrowserProfileLabel?.nonEmpty {
                            statusBadgeRow(
                                title: "Selected Browser Profile",
                                detail: selectedProfile,
                                color: SettingsSection.computerControl.tint
                            )
                        }

                        if computerControlStatus.issues.isEmpty {
                            Text("Everything needed for local browser and app actions looks ready.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(computerControlStatus.issues, id: \.self) { issue in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.orange)
                                        Text(issue)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking local automation helper status…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            settingsCard(
                title: "Browser Profile",
                subtitle: "Reuse a real signed-in browser profile for Chrome, Brave, or Edge.",
                symbol: "globe",
                tint: SettingsSection.computerControl.tint
            ) {
                BrowserAutomationSettingsView(settings: settings)
            }

            settingsCard(
                title: "Supported Direct App Actions",
                subtitle: "These app actions run directly without any extra live-control layer.",
                symbol: "app.connected.to.app.below.fill",
                tint: SettingsSection.computerControl.tint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    statusBadgeRow(
                        title: "Finder",
                        detail: "Open folders, reveal files, and select items.",
                        color: SettingsSection.computerControl.tint
                    )
                    statusBadgeRow(
                        title: "Terminal",
                        detail: "Open Terminal and run a command.",
                        color: SettingsSection.computerControl.tint
                    )
                    statusBadgeRow(
                        title: "Calendar",
                        detail: "Prepare an event draft first, then create it when you confirm.",
                        color: SettingsSection.computerControl.tint
                    )
                    statusBadgeRow(
                        title: "System Settings",
                        detail: "Jump directly to a settings page or search target.",
                        color: SettingsSection.computerControl.tint
                    )
                    statusBadgeRow(
                        title: "Reminders, Contacts, Notes, Messages",
                        detail: "Read supported data directly through native frameworks.",
                        color: SettingsSection.computerControl.tint
                    )
                }
            }

            settingsCard(
                title: "Approval Behavior",
                subtitle: "Open Assist explains what each browser or app automation approval means.",
                symbol: "checkmark.shield.fill",
                tint: SettingsSection.computerControl.tint
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("`app_action` and `browser_use` only run in Agentic mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("“Allow for Session” remembers approval only for the current conversation and tool type.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("High-risk actions like send, post, submit, purchase, and delete always ask again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        PermissionCenter.requestMicrophonePermission(openSettingsIfDenied: true)
    }

    private func requestSpeechRecognitionPermission() {
        PermissionCenter.requestSpeechRecognitionPermission(openSettingsIfDenied: true)
    }

    private var selectedComputerControlProfile: BrowserProfile? {
        BrowserProfileManager.shared.profile(withID: settings.browserSelectedProfileID)
    }

    private func refreshComputerControlState() {
        computerPermissionSnapshot = PermissionCenter.snapshot(using: settings)

        Task {
            let status = await LocalAutomationHelper.shared.capabilityStatus(
                selectedBrowserProfile: selectedComputerControlProfile,
                settings: settings
            )
            await MainActor.run {
                computerControlStatus = status
            }
        }
    }

    private var holdToTalkShortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.shortcutKeyCode,
            modifiersRaw: settings.shortcutModifiers
        )
    }

    private var continuousToggleShortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: settings.continuousToggleShortcutModifiers
        )
    }

    private var assistantLiveVoiceShortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.assistantLiveVoiceShortcutKeyCode,
            modifiersRaw: settings.assistantLiveVoiceShortcutModifiers
        )
    }

    private var isHoldToTalkShortcutValid: Bool {
        ShortcutValidation.isValid(keyCode: settings.shortcutKeyCode, modifiersRaw: settings.shortcutModifiers)
    }

    private var isContinuousToggleShortcutValid: Bool {
        ShortcutValidation.isValid(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: settings.continuousToggleShortcutModifiers
        )
    }

    private var isAssistantLiveVoiceShortcutValid: Bool {
        ShortcutValidation.isValid(
            keyCode: settings.assistantLiveVoiceShortcutKeyCode,
            modifiersRaw: settings.assistantLiveVoiceShortcutModifiers
        )
    }

    private func shortcutKeyCode(for target: ShortcutCaptureTarget) -> UInt16 {
        switch target {
        case .holdToTalk:
            settings.shortcutKeyCode
        case .continuousToggle:
            settings.continuousToggleShortcutKeyCode
        case .assistantLiveVoice:
            settings.assistantLiveVoiceShortcutKeyCode
        }
    }

    private func shortcutModifiersRaw(for target: ShortcutCaptureTarget) -> UInt {
        switch target {
        case .holdToTalk:
            settings.shortcutModifiers
        case .continuousToggle:
            settings.continuousToggleShortcutModifiers
        case .assistantLiveVoice:
            settings.assistantLiveVoiceShortcutModifiers
        }
    }

    @discardableResult
    private func applyShortcutSelection(
        for target: ShortcutCaptureTarget,
        keyCode: UInt16,
        modifiersRaw: UInt,
        validationMessage: String
    ) -> Bool {
        let filteredModifiers = ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        guard ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filteredModifiers) else {
            shortcutCaptureMessage = validationMessage
            return false
        }

        if let conflictMessage = shortcutConflictMessage(
            for: target,
            keyCode: keyCode,
            modifiersRaw: filteredModifiers
        ) {
            shortcutCaptureMessage = conflictMessage
            return false
        }

        switch target {
        case .holdToTalk:
            settings.shortcutKeyCode = keyCode
            settings.shortcutModifiers = filteredModifiers
        case .continuousToggle:
            settings.continuousToggleShortcutKeyCode = keyCode
            settings.continuousToggleShortcutModifiers = filteredModifiers
        case .assistantLiveVoice:
            settings.assistantLiveVoiceShortcutKeyCode = keyCode
            settings.assistantLiveVoiceShortcutModifiers = filteredModifiers
        }

        shortcutCaptureMessage = nil
        return true
    }

    private func beginShortcutCapture(for target: ShortcutCaptureTarget) {
        shortcutCaptureTarget = target
        shortcutCaptureMessage = nil
        isCapturingShortcut = true
    }

    private func cancelShortcutCapture() {
        shortcutCaptureTarget = nil
        shortcutCaptureMessage = nil
        isCapturingShortcut = false
    }

    private func shortcutConflictMessage(
        for target: ShortcutCaptureTarget,
        keyCode: UInt16,
        modifiersRaw: UInt
    ) -> String? {
        let candidate = ShortcutBinding(
            keyCode: keyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        )
        let holdToTalk = ShortcutBinding(
            keyCode: settings.shortcutKeyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: settings.shortcutModifiers)
        )
        let continuousToggle = ShortcutBinding(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: settings.continuousToggleShortcutModifiers)
        )
        let assistantLiveVoice = ShortcutBinding(
            keyCode: settings.assistantLiveVoiceShortcutKeyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: settings.assistantLiveVoiceShortcutModifiers)
        )
        let pasteLast = ShortcutBinding(
            keyCode: ReservedShortcut.pasteLastKeyCode,
            modifiersRaw: ReservedShortcut.pasteLastModifiersRaw
        )

        switch target {
        case .holdToTalk:
            if candidate == continuousToggle {
                return "Hold-to-talk shortcut cannot match continuous toggle shortcut."
            }
            if candidate == assistantLiveVoice {
                return "Hold-to-talk shortcut cannot match the agent shortcut."
            }
        case .continuousToggle:
            if candidate == holdToTalk {
                return "Continuous toggle shortcut cannot match hold-to-talk shortcut."
            }
            if candidate == assistantLiveVoice {
                return "Continuous toggle shortcut cannot match the agent shortcut."
            }
        case .assistantLiveVoice:
            if candidate == holdToTalk {
                return "Agent shortcut cannot match hold-to-talk shortcut."
            }
            if candidate == continuousToggle {
                return "Agent shortcut cannot match continuous toggle shortcut."
            }
        }

        if candidate == pasteLast {
            return "Shortcut cannot match Paste Last Transcript (⌥⌘V)."
        }

        return nil
    }

    @ViewBuilder
    private func appLogoImage(size: CGFloat) -> some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .about)

            settingsCard(
                title: "App Info",
                subtitle: "Current version and release details.",
                symbol: "app.badge.fill",
                tint: AppVisualTheme.accentTint
            ) {
                HStack(spacing: 12) {
                    appLogoImage(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Assist")
                            .font(.headline)
                        Text(appVersionDisplayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        updateCheckStatusRow
                    }
                    Spacer()
                    Button(updateCheckStatusStore.isChecking ? "Checking…" : "Check for Updates…") {
                        AppDelegate.shared?.checkForUpdatesFromSettings()
                    }
                    .disabled(updateCheckStatusStore.isChecking)
                }
            }

            settingsCard(
                title: "Permissions",
                subtitle: "Grant access for assistant, voice capture, and reliable text insertion.",
                symbol: "hand.raised.fill",
                tint: AppVisualTheme.accentTint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow(
                        name: "Accessibility",
                        granted: settings.accessibilityTrusted,
                        hint: "Required for text insertion and global hotkeys",
                        action: {
                            PermissionCenter.requestAccessibilityPermission(
                                using: settings,
                                promptIfNeeded: true,
                                openSettingsIfDenied: false
                            )
                        }
                    )

                    permissionRow(
                        name: "Microphone",
                        granted: microphoneAuthorized,
                        hint: "Required to capture speech",
                        action: {
                            requestMicrophonePermission()
                        }
                    )

                    permissionRow(
                        name: "Speech Recognition",
                        granted: settings.transcriptionEngine == .appleSpeech ? speechRecognitionAuthorized : true,
                        hint: settings.transcriptionEngine == .appleSpeech
                            ? "Required when Apple Speech engine is selected"
                            : "Not required while whisper.cpp engine is selected",
                        action: {
                            requestSpeechRecognitionPermission()
                        }
                    )

                    permissionRow(
                        name: "Automation / Apple Events",
                        granted: computerPermissionSnapshot.appleEventsGranted,
                        hint: "Needed for direct browser and app scripting",
                        action: {
                            PermissionCenter.requestAppleEventsPermission(openSettingsIfDenied: true)
                            refreshComputerControlState()
                        }
                    )

                    permissionRow(
                        name: "Full Disk Access",
                        granted: computerPermissionSnapshot.fullDiskAccessGranted,
                        hint: "Optional for protected folders and app data",
                        action: {
                            PermissionCenter.openPrivacySettingsPane(query: "Full Disk Access")
                            refreshComputerControlState()
                        }
                    )
                }
            }

            if CrashReporter.hasLogs {
                settingsCard(
                    title: "Diagnostics",
                    subtitle: "Crash reports were detected on this Mac.",
                    symbol: "stethoscope",
                    tint: AppVisualTheme.accentTint
                ) {
                    HStack {
                        Text("Crash logs available")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal in Finder") {
                            CrashReporter.revealInFinder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            settingsCard(
                title: "Uninstall",
                subtitle: "Remove Open Assist, reset permissions, and clear local app data.",
                symbol: "trash.fill",
                tint: .red
            ) {
                Button(role: .destructive, action: {
                    uninstallDeleteDownloadedModels = false
                    uninstallDeleteLearnedCorrections = false
                    uninstallDeleteMemories = false
                    uninstallDeleteProviderCredentials = false
                    showUninstallSheet = true
                }) {
                    Label("Uninstall Open Assist…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showUninstallSheet) {
                    ZStack {
                        AppChromeBackground()

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Uninstall Open Assist")
                                .font(.title2.bold())

                            Text("This will reset permissions, remove settings, and uninstall the app. Enable any options below to also remove additional data.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Delete downloaded whisper models", isOn: $uninstallDeleteDownloadedModels)
                                    .toggleStyle(.switch)
                                Toggle("Delete learned corrections", isOn: $uninstallDeleteLearnedCorrections)
                                    .toggleStyle(.switch)
                                Toggle("Delete indexed memories", isOn: $uninstallDeleteMemories)
                                    .toggleStyle(.switch)
                                Toggle("Delete provider credentials (API keys & OAuth sessions)", isOn: $uninstallDeleteProviderCredentials)
                                    .toggleStyle(.switch)
                            }

                            Divider()

                            Text(uninstallSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    showUninstallSheet = false
                                }
                                .keyboardShortcut(.cancelAction)

                                Button("Uninstall", role: .destructive) {
                                    showUninstallSheet = false
                                    SettingsStore.resetAndUninstall(
                                        deleteDownloadedModels: uninstallDeleteDownloadedModels,
                                        deleteLearnedCorrections: uninstallDeleteLearnedCorrections,
                                        deleteMemories: uninstallDeleteMemories,
                                        deleteProviderCredentials: uninstallDeleteProviderCredentials
                                    )
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(24)
                        .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
                        .padding(10)
                    }
                    .frame(width: 420)
                }
            }

            Text("Built with Apple Speech and whisper.cpp")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func automationSnippetCard(title: String, snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Copy") {
                    copyTextToPasteboard(snippet)
                    automationActionMessage = "\(title) copied."
                }
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal) {
                Text(snippet)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppVisualTheme.foreground(0.10), lineWidth: 0.7)
                    )
            )
        }
    }

    private func installSelectedClaudeHooks() {
        settings.ensureAutomationAPIToken()

        do {
            let result = try ClaudeHookInstaller().installSelectedHooks(
                selectedClaudeHookInstallOptions,
                port: settings.automationAPIPort,
                token: settings.automationAPIToken
            )

            if result.changedCount > 0 {
                if result.unchangedCount > 0 {
                    automationActionMessage = "Added or updated \(result.changedCount) Claude hook(s). \(result.unchangedCount) selected hook(s) were already ready."
                } else {
                    automationActionMessage = "Added or updated \(result.changedCount) Claude hook(s) in ~/.claude/settings.json."
                }
            } else {
                automationActionMessage = "The selected Claude hooks are already in ~/.claude/settings.json."
            }
            syncInstalledClaudeHooksFromDisk()
        } catch {
            automationActionMessage = "Could not update ~/.claude/settings.json. \(error.localizedDescription)"
        }
    }

    private func syncInstalledClaudeHooksFromDisk() {
        do {
            let installedOptions = try ClaudeHookInstaller().installedOptions()
            installedClaudeHookOptions = installedOptions
            installClaudeStopHook = installedOptions.contains(.stop)
            installClaudeSubagentStopHook = installedOptions.contains(.subagentStop)
            installClaudeNotificationHook = installedOptions.contains(.notification)
        } catch {
            installedClaudeHookOptions = []
            automationActionMessage = "Could not read ~/.claude/settings.json. \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func automationStatusRow(
        title: String,
        badgeText: String,
        badgeColor: Color,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(badgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(badgeColor.opacity(0.14))
                    )
                Spacer()
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func copyTextToPasteboard(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(trimmed, forType: .string)
    }

    private var uninstallSummaryText: String {
        let modelText = uninstallDeleteDownloadedModels ? "delete downloaded whisper models" : "keep downloaded whisper models"
        let correctionText = uninstallDeleteLearnedCorrections ? "delete learned corrections" : "keep learned corrections"
        let memoryText = uninstallDeleteMemories ? "delete indexed memories" : "keep indexed memories"
        let credentialText = uninstallDeleteProviderCredentials ? "delete provider credentials" : "keep provider credentials"

        return "This will reset permissions, remove settings, \(modelText), \(correctionText), \(memoryText), \(credentialText), and uninstall the app."
    }

    @ViewBuilder
    private func statusBadgeRow(title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconBadge(
                symbol: "checkmark.circle.fill",
                tint: color,
                size: 24,
                symbolSize: 10,
                isEmphasized: true
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.foreground(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.10), lineWidth: 0.7)
                )
        )
    }

    @ViewBuilder
    private func permissionRow(name: String, granted: Bool, hint: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            AppIconBadge(
                symbol: granted ? "checkmark" : "exclamationmark.triangle.fill",
                tint: granted ? AppVisualTheme.accentTint : AppVisualTheme.baseTint,
                size: 24,
                symbolSize: 10,
                isEmphasized: granted
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.94))
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.foreground(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.10), lineWidth: 0.7)
                )
        )
    }

    private var microphoneAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            // Pre-Sonoma: if the app has been able to record, it's authorized
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private var speechRecognitionAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

}

private extension WhisperModelManager.InstallState {
    var installButtonTitle: String {
        switch self {
        case .failed:
            return "Retry Install"
        default:
            return "Install"
        }
    }
}


struct TranscriptHistoryView: View {
    @EnvironmentObject private var history: TranscriptHistoryStore
    let onCopy: (String) -> Void
    let onReinsert: (String) -> Void

    @State private var query = ""

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var filteredEntries: [TranscriptHistoryStore.Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ZStack {
            AppChromeBackground()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcript History")
                            .font(.title3.weight(.semibold))
                        Text("Re-use recent voice capture or assistant drafting without recording again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(filteredEntries.count) of \(history.entries.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    TextField("Search transcripts", text: $query)
                        .textFieldStyle(.roundedBorder)

                    Button("Clear All", role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            history.clear()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(history.entries.isEmpty)
                }

                if history.entries.isEmpty {
                    emptyState(
                        title: "No transcripts yet",
                        message: "Your recent voice captures will appear here automatically.",
                        systemImage: "text.bubble"
                    )
                } else if filteredEntries.isEmpty {
                    emptyState(
                        title: "No matches found",
                        message: "Try a different search phrase.",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                TranscriptHistoryEntryCard(
                                    entry: entry,
                                    timestampText: timestampFormatter.string(from: entry.createdAt),
                                    relativeText: relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()),
                                    showsDivider: index < (filteredEntries.count - 1),
                                    onCopy: { onCopy(entry.text) },
                                    onReinsert: {
                                        onReinsert(entry.text)
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            history.remove(id: entry.id)
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            history.remove(id: entry.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, 34)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppVisualTheme.adaptiveMaterialFill())
            )
            .padding(10)
        }
        .appScrollbars()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptHistoryEntryCard: View {
    let entry: TranscriptHistoryStore.Entry
    let timestampText: String
    let relativeText: String
    let showsDivider: Bool
    let onCopy: () -> Void
    let onReinsert: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    private var showsExpandButton: Bool {
        entry.text.count > 220 || entry.text.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(relativeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(timestampText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy transcript")

                    Button(action: onReinsert) {
                        Label("Re-insert", systemImage: "arrow.uturn.backward.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Insert transcript in the focused app")

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete transcript from history")
                }
            }

            Text(entry.text)
                .font(.system(size: 13, weight: .regular))
                .lineSpacing(2)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
                .foregroundStyle(.primary)

            if showsExpandButton {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .overlay(AppVisualTheme.foreground(0.08))
            }
        }
    }
}

struct ShortcutCaptureMonitor: NSViewRepresentable {
    @Binding var isCapturing: Bool
    let onCapture: (UInt16, UInt) -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isCapturing {
            context.coordinator.start()
        } else {
            context.coordinator.stop()
        }
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private static let manualModifierOnlyKeyCode: UInt16 = UInt16.max
        private var parent: ShortcutCaptureMonitor
        private var globalKeyMonitor: Any?
        private var localKeyMonitor: Any?
        private var globalFlagsMonitor: Any?
        private var localFlagsMonitor: Any?
        private var didCapture = false

        init(parent: ShortcutCaptureMonitor) {
            self.parent = parent
        }

        func start() {
            guard globalKeyMonitor == nil, localKeyMonitor == nil, globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }
            didCapture = false

            let mask = ShortcutValidation.supportedModifierFlags

            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleKeyDown(event, mask: mask)
            }

            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handled = self.handleKeyDown(event, mask: mask)
                return handled ? nil : event
            }

            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                _ = self?.handleFlagsChanged(event, mask: mask)
            }

            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let handled = self.handleFlagsChanged(event, mask: mask)
                return handled ? nil : event
            }
        }

        @discardableResult
        private func handleKeyDown(_ event: NSEvent, mask: NSEvent.ModifierFlags) -> Bool {
            guard !didCapture else { return true }

            if event.keyCode == 53 { // Escape
                didCapture = true
                DispatchQueue.main.async {
                    self.parent.isCapturing = false
                    self.parent.onCancel()
                    self.stop()
                }
                return true
            }

            let capturedCode = event.keyCode
            if ShortcutValidation.isModifierOnlyKeyCode(capturedCode) {
                return false
            }

            let capturedMods = ShortcutValidation.filteredModifierRawValue(from: event.modifierFlags.intersection(mask).rawValue)
            guard capturedMods != 0 else { return false }
            let didCaptureShortcut = parent.onCapture(capturedCode, capturedMods)
            guard didCaptureShortcut else { return false }
            didCapture = true
            stop()
            DispatchQueue.main.async {
                self.parent.isCapturing = false
            }
            return true
        }

        @discardableResult
        private func handleFlagsChanged(_ event: NSEvent, mask: NSEvent.ModifierFlags) -> Bool {
            guard !didCapture else { return true }

            let capturedFlags = event.modifierFlags.intersection(mask)
            let count = ShortcutValidation.modifierCount(in: capturedFlags)
            guard (2...4).contains(count) else { return false }

            let didCaptureShortcut = parent.onCapture(
                Self.manualModifierOnlyKeyCode,
                capturedFlags.rawValue
            )
            guard didCaptureShortcut else { return false }
            didCapture = true
            stop()
            DispatchQueue.main.async {
                self.parent.isCapturing = false
            }
            return true
        }

        func stop() {
            if let globalKeyMonitor {
                NSEvent.removeMonitor(globalKeyMonitor)
                self.globalKeyMonitor = nil
            }
            if let localKeyMonitor {
                NSEvent.removeMonitor(localKeyMonitor)
                self.localKeyMonitor = nil
            }
            if let globalFlagsMonitor {
                NSEvent.removeMonitor(globalFlagsMonitor)
                self.globalFlagsMonitor = nil
            }
            if let localFlagsMonitor {
                NSEvent.removeMonitor(localFlagsMonitor)
                self.localFlagsMonitor = nil
            }
            didCapture = false
        }

        deinit {
            stop()
        }
    }
}
