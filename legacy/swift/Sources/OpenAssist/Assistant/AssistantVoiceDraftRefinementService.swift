import Foundation

protocol AssistantVoiceDraftPromptRewriting {
    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion?
}

extension PromptRewriteService: AssistantVoiceDraftPromptRewriting {}

struct AssistantVoiceDraftRefinementService {
    private let promptRewriter: AssistantVoiceDraftPromptRewriting

    init(promptRewriter: AssistantVoiceDraftPromptRewriting = PromptRewriteService.shared) {
        self.promptRewriter = promptRewriter
    }

    func refine(_ transcript: String, aiCorrectionEnabled: Bool) async -> String {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return "" }
        guard aiCorrectionEnabled else { return normalizedTranscript }

        do {
            guard let suggestion = try await promptRewriter.retrieveSuggestion(
                for: normalizedTranscript,
                conversationContext: nil,
                conversationHistory: []
            ) else {
                return normalizedTranscript
            }

            let refinedTranscript = suggestion.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return refinedTranscript.isEmpty ? normalizedTranscript : refinedTranscript
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "unknown-error" : detail
            CrashReporter.logWarning("Assistant voice draft refinement failed: \(message)")
            return normalizedTranscript
        }
    }
}
