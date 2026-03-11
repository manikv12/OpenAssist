import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class MockPromptRewriteBackend: PromptRewriteBackendServing {
    var retrieveCallCount = 0
    var feedbackEvents: [PromptRewriteFeedbackEvent] = []
    var retrieveHandler: (String) async throws -> PromptRewriteSuggestion?

    init(retrieveHandler: @escaping (String) async throws -> PromptRewriteSuggestion?) {
        self.retrieveHandler = retrieveHandler
    }

    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion? {
        _ = conversationContext
        _ = conversationHistory
        retrieveCallCount += 1
        return try await retrieveHandler(cleanedTranscript)
    }

    func recordFeedback(_ event: PromptRewriteFeedbackEvent) async {
        feedbackEvents.append(event)
    }
}

@main
struct PromptRewriteSmokeTests {
    static func main() async {
        await testSuggestionRetrieval()
        await testNoSuggestion()
        await testTimeoutBehavior()
        await testProviderErrorMapping()
        await testFeedbackForwarding()
        await testStrictProjectIsolation()

        print("PASS: Prompt rewrite smoke tests passed")
    }

    private static func testSuggestionRetrieval() async {
        let backend = MockPromptRewriteBackend { transcript in
            check(transcript == "hello world", "Service should pass the cleaned transcript to backend")
            return PromptRewriteSuggestion(
                suggestedText: "Hello world.",
                memoryContext: "user prefers sentence punctuation"
            )
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            let suggestion = try await service.retrieveSuggestion(for: "hello world")
            check(suggestion?.suggestedText == "Hello world.", "Suggestion text should round-trip from backend")
            check(suggestion?.memoryContext == "user prefers sentence punctuation", "Memory context should be preserved")
            check(backend.retrieveCallCount == 1, "Expected one backend call for suggestion retrieval")
        } catch {
            check(false, "Suggestion retrieval should not throw: \(error)")
        }
    }

    private static func testNoSuggestion() async {
        let backend = MockPromptRewriteBackend { _ in nil }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            let suggestion = try await service.retrieveSuggestion(for: "leave unchanged")
            check(suggestion == nil, "Expected nil suggestion when backend has no rewrite")
        } catch {
            check(false, "Nil suggestion flow should not throw: \(error)")
        }
    }

    private static func testTimeoutBehavior() async {
        let backend = MockPromptRewriteBackend { _ in
            try await Task.sleep(nanoseconds: 900_000_000)
            return PromptRewriteSuggestion(suggestedText: "slow response", memoryContext: nil)
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 0.25)

        do {
            _ = try await service.retrieveSuggestion(for: "time out")
            check(false, "Expected timeout error when backend exceeds timeout")
        } catch let error as PromptRewriteServiceError {
            switch error {
            case .timedOut:
                check(true, "Timed out as expected")
            default:
                check(false, "Expected timeout error, got \(error)")
            }
        } catch {
            check(false, "Expected PromptRewriteServiceError timeout, got \(error)")
        }
    }

    private static func testProviderErrorMapping() async {
        let backend = MockPromptRewriteBackend { _ in
            throw PromptRewriteBackendError.providerFailure(reason: "backend-down")
        }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        do {
            _ = try await service.retrieveSuggestion(for: "trigger error")
            check(false, "Expected provider error mapping")
        } catch let error as PromptRewriteServiceError {
            switch error {
            case let .providerUnavailable(reason):
                check(reason == "backend-down", "Provider failure reason should be preserved")
            default:
                check(false, "Expected providerUnavailable error, got \(error)")
            }
        } catch {
            check(false, "Expected PromptRewriteServiceError providerUnavailable, got \(error)")
        }
    }

    private static func testFeedbackForwarding() async {
        let backend = MockPromptRewriteBackend { _ in nil }
        let service = PromptRewriteService(backend: backend, timeoutSeconds: 1.0)

        let event = PromptRewriteFeedbackEvent(
            action: .insertedOriginal,
            originalText: "foo",
            suggestedText: "bar",
            finalInsertedText: "foo",
            failureDetail: nil
        )
        await service.recordFeedback(event)

        check(backend.feedbackEvents.count == 1, "Feedback should be forwarded to backend layer")
        check(backend.feedbackEvents[0].action == .insertedOriginal, "Feedback action should be preserved")
        check(backend.feedbackEvents[0].originalText == "foo", "Feedback original text should be preserved")
    }

    private static func testStrictProjectIsolation() async {
        do {
            let sandboxRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("openassist-retrieval-scope-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sandboxRoot) }

            let store = try MemorySQLiteStore(
                databaseURL: sandboxRoot.appendingPathComponent("memory.sqlite3")
            )

            let appName = "Codex"
            let bundleID = "com.openai.codex"
            let surface = "Editor • Prompt"
            let timestamp = Date(timeIntervalSince1970: 1_706_000_000)

            let alphaScope = MemoryScopeContext(
                appName: appName,
                bundleID: bundleID,
                surfaceLabel: surface,
                projectName: "alpha",
                repositoryName: "alpha-repo",
                isCodingContext: true
            )
            let betaScope = MemoryScopeContext(
                appName: appName,
                bundleID: bundleID,
                surfaceLabel: surface,
                projectName: "beta",
                repositoryName: "beta-repo",
                isCodingContext: true
            )
            let appScope = MemoryScopeContext(
                appName: appName,
                bundleID: bundleID,
                surfaceLabel: surface,
                projectName: nil,
                repositoryName: nil,
                isCodingContext: true
            )

            try seedLesson(
                store: store,
                scope: alphaScope,
                mistake: "teh bug",
                correction: "the bug alpha",
                timestamp: timestamp
            )
            try seedLesson(
                store: store,
                scope: betaScope,
                mistake: "teh bug",
                correction: "the bug beta",
                timestamp: timestamp.addingTimeInterval(5)
            )
            try seedLesson(
                store: store,
                scope: appScope,
                mistake: "teh bug",
                correction: "the bug global",
                timestamp: timestamp.addingTimeInterval(10)
            )

            let retrieval = MemoryRewriteRetrievalService(storeFactory: { store })
            let alphaContext = try await retrieval.fetchPromptRewriteContext(
                for: "please fix teh bug",
                lessonLimit: 8,
                cardLimit: 4,
                scope: alphaScope
            )
            let alphaCorrections = Set(alphaContext.lessons.map(\.correctionText))
            check(alphaCorrections.contains("the bug alpha"), "Expected same-project lesson for alpha scope")
            check(!alphaCorrections.contains("the bug beta"), "Strict isolation should exclude beta lessons in alpha scope")
            check(!alphaCorrections.contains("the bug global"), "Same scope should take precedence over app-level fallback")

            let gammaScope = MemoryScopeContext(
                appName: appName,
                bundleID: bundleID,
                surfaceLabel: surface,
                projectName: "gamma",
                repositoryName: "gamma-repo",
                isCodingContext: true
            )
            let gammaContext = try await retrieval.fetchPromptRewriteContext(
                for: "please fix teh bug",
                lessonLimit: 8,
                cardLimit: 4,
                scope: gammaScope
            )
            let gammaCorrections = Set(gammaContext.lessons.map(\.correctionText))
            check(gammaCorrections.contains("the bug global"), "Expected app-level fallback lesson for unknown project")
            check(!gammaCorrections.contains("the bug alpha"), "Strict isolation should exclude cross-project alpha lesson")
            check(!gammaCorrections.contains("the bug beta"), "Strict isolation should exclude cross-project beta lesson")
        } catch {
            check(false, "Strict project isolation test should not throw: \(error)")
        }
    }

    private static func seedLesson(
        store: MemorySQLiteStore,
        scope: MemoryScopeContext,
        mistake: String,
        correction: String,
        timestamp: Date
    ) throws {
        let sourceID = UUID()
        let sourceFileID = UUID()
        let eventID = UUID()
        let cardID = UUID()
        let lessonID = UUID()

        let scopeMetadata: [String: String] = [
            "scope_key": scope.scopeKey,
            "app_name": scope.appName,
            "bundle_id": scope.bundleID,
            "surface_label": scope.surfaceLabel,
            "project_name": scope.projectName ?? "",
            "repository_name": scope.repositoryName ?? ""
        ]

        try store.upsertSource(
            MemorySource(
                id: sourceID,
                provider: .unknown,
                rootPath: "internal://scope/\(scope.scopeKey)",
                displayName: "\(scope.appName)-\(scope.scopeKey)",
                discoveredAt: timestamp,
                metadata: scopeMetadata
            )
        )
        try store.upsertSourceFile(
            MemorySourceFile(
                id: sourceFileID,
                sourceID: sourceID,
                absolutePath: "scope/\(scope.scopeKey).jsonl",
                relativePath: "scope/\(scope.scopeKey).jsonl",
                fileHash: UUID().uuidString,
                fileSizeBytes: Int64((mistake + correction).utf8.count),
                modifiedAt: timestamp,
                indexedAt: timestamp,
                parseError: nil
            )
        )

        let keywords = MemoryTextNormalizer.keywords(from: "\(mistake) \(correction)", limit: 8)
        let event = MemoryEvent(
            id: eventID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            provider: .unknown,
            kind: .rewrite,
            title: "Lesson \(correction)",
            body: "\(mistake) -> \(correction)",
            timestamp: timestamp,
            nativeSummary: "\(mistake) -> \(correction)",
            keywords: keywords,
            isPlanContent: false,
            metadata: scopeMetadata,
            rawPayload: nil
        )
        try store.upsertEvent(event)

        try store.upsertCard(
            MemoryCard(
                id: cardID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: .unknown,
                title: event.title,
                summary: event.nativeSummary ?? event.body,
                detail: event.body,
                keywords: keywords,
                score: 0.92,
                createdAt: timestamp,
                updatedAt: timestamp,
                isPlanContent: false,
                metadata: scopeMetadata
            )
        )

        var lessonMetadata = scopeMetadata
        lessonMetadata["validation_state"] = MemoryRewriteLessonValidationState.indexedValidated.rawValue
        lessonMetadata["extraction_method"] = "deterministic"
        lessonMetadata["provider_mode"] = "openai"
        lessonMetadata["origin"] = "conversation-history"
        try store.upsertLesson(
            MemoryLesson(
                id: lessonID,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                cardID: cardID,
                provider: .unknown,
                mistakePattern: mistake,
                improvedPrompt: correction,
                rationale: "Scope-isolation seed",
                validationConfidence: 0.95,
                sourceMetadata: lessonMetadata,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
    }
}
