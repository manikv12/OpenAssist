import Foundation

@MainActor
final class ConversationContextResolverV2 {
    struct ResolvedContextBundle {
        let activeContext: PromptRewriteConversationContext
        let activeHistory: [PromptRewriteConversationTurn]
        let linkedContextIDs: [String]
        let mergedHistory: [PromptRewriteConversationTurn]
        let usesPinnedContext: Bool
        let resolutionTrace: String
    }

    struct AIMappingCandidate {
        let prompt: ConversationClarificationPrompt
        let candidateKey: String
        let candidateLabel: String
        let candidateBundleIdentifier: String
        let confidence: Double
    }

    struct DeterministicMappingCandidate {
        enum MatchAxis: String {
            case project
            case person
        }

        enum MatchType: String {
            case exact
            case highSimilar = "high-similar"
        }

        let prompt: ConversationClarificationPrompt
        let candidateKey: String
        let candidateLabel: String
        let candidateBundleIdentifier: String
        let confidence: Double
        let matchAxis: MatchAxis
        let matchType: MatchType
    }

    enum MappingSource: String {
        case ai
        case deterministic
        case manual
    }

    enum MappingDecision: String {
        case link
        case keepSeparate = "keep-separate"
    }

    private let store: PromptRewriteConversationStore

    init(store: PromptRewriteConversationStore) {
        self.store = store
    }

    convenience init() {
        self.init(store: .shared)
    }

    func resolve(
        capturedContext: PromptRewriteConversationContext,
        userText: String,
        timeoutMinutes: Double,
        turnLimit: Int,
        pinnedContextID: String?
    ) -> ResolvedContextBundle? {
        let requestContext = store.prepareRequestContext(
            capturedContext: capturedContext,
            userText: userText,
            timeoutMinutes: timeoutMinutes,
            turnLimit: turnLimit,
            pinnedContextID: pinnedContextID
        )

        let activeContext = requestContext.context
        let activeHistory = store.activePromptHistory(
            for: activeContext.id,
            userText: userText,
            limit: turnLimit
        )
        let linkedContextIDs = store.resolveLinkedContextIDs(for: activeContext)

        let resolutionTrace = """
        context_id=\(activeContext.id)
        uses_pinned_context=\(requestContext.usesPinnedContext)
        active_turns=\(activeHistory.count)
        linked_context_count=\(linkedContextIDs.count)
        merge_turns=\(requestContext.history.count)
        """

        return ResolvedContextBundle(
            activeContext: activeContext,
            activeHistory: activeHistory,
            linkedContextIDs: linkedContextIDs,
            mergedHistory: requestContext.history,
            usesPinnedContext: requestContext.usesPinnedContext,
            resolutionTrace: resolutionTrace.replacingOccurrences(of: "\n", with: " ")
        )
    }

    func evaluateAIMappingCandidate(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> AIMappingCandidate? {
        guard let prompt = store.nextClarificationPrompt(
            capturedContext: capturedContext,
            userText: userText
        ),
        let primary = prompt.primaryCandidate else {
            return nil
        }

        return AIMappingCandidate(
            prompt: prompt,
            candidateKey: primary.canonicalKey,
            candidateLabel: primary.label,
            candidateBundleIdentifier: primary.bundleIdentifier,
            confidence: max(0, min(1, primary.similarity))
        )
    }

    func evaluateDeterministicMappingCandidate(
        capturedContext: PromptRewriteConversationContext,
        userText: String
    ) -> DeterministicMappingCandidate? {
        store.nextDeterministicMappingCandidate(
            capturedContext: capturedContext,
            userText: userText
        ).map { candidate in
            DeterministicMappingCandidate(
                prompt: candidate.prompt,
                candidateKey: candidate.candidateKey,
                candidateLabel: candidate.candidateLabel,
                candidateBundleIdentifier: candidate.candidateBundleIdentifier,
                confidence: candidate.confidence,
                matchAxis: candidate.matchAxis == .project ? .project : .person,
                matchType: candidate.matchType == .exact ? .exact : .highSimilar
            )
        }
    }

    func persistMappingDecision(
        _ decision: MappingDecision,
        prompt: ConversationClarificationPrompt,
        source: MappingSource
    ) {
        let clarificationDecision: ConversationClarificationDecision
        switch decision {
        case .link:
            clarificationDecision = .link
        case .keepSeparate:
            clarificationDecision = .keepSeparate
        }

        let persistedSource: ConversationContextMappingSource
        switch source {
        case .ai:
            persistedSource = .ai
        case .deterministic:
            persistedSource = .deterministic
        case .manual:
            persistedSource = .manual
        }

        store.applyClarificationDecision(
            clarificationDecision,
            for: prompt,
            source: persistedSource
        )

        CrashReporter.logInfo(
            "Prompt rewrite mapping persisted mapping_source=\(source.rawValue) decision=\(decision.rawValue)"
        )
    }
}
