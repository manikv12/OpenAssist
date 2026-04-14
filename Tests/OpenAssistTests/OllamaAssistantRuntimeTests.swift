import XCTest
@testable import OpenAssist

@MainActor
final class OllamaAssistantRuntimeTests: XCTestCase {
    func testRefreshEnvironmentReturnsInstallRequiredWhenGemmaIsMissing() async throws {
        let runtimeManager = MockLocalRuntimeManager(
            detection: LocalAIRuntimeDetection(
                installed: true,
                isManagedInstallation: true,
                isHealthy: true,
                appURL: URL(fileURLWithPath: "/Applications/Ollama.app"),
                executableURL: URL(fileURLWithPath: "/Applications/Ollama.app/Contents/MacOS/ollama"),
                version: "0.6.0"
            ),
            installedModels: []
        )
        let runtime = CodexAssistantRuntime(
            preferredModelID: "gemma4:e4b",
            localRuntimeManager: runtimeManager,
            ollamaChatService: MockOllamaChatService()
        )
        runtime.backend = .ollamaLocal

        let details = try await runtime.refreshEnvironment(codexPath: nil)

        XCTAssertEqual(details.health.availability, .installRequired)
        XCTAssertFalse(details.account.isLoggedIn)
        XCTAssertTrue(details.models.contains(where: { $0.id == "gemma4:e4b" }))
        XCTAssertTrue(details.models.contains(where: { $0.id == "gemma4:26b" }))
        XCTAssertFalse(details.models.first(where: { $0.id == "gemma4:e4b" })?.isInstalled ?? true)
    }

    func testRefreshEnvironmentReturnsReadyWhenInstalledGemmaMatchesSelection() async throws {
        let runtimeManager = MockLocalRuntimeManager(
            detection: LocalAIRuntimeDetection(
                installed: true,
                isManagedInstallation: true,
                isHealthy: true,
                appURL: URL(fileURLWithPath: "/Applications/Ollama.app"),
                executableURL: URL(fileURLWithPath: "/Applications/Ollama.app/Contents/MacOS/ollama"),
                version: "0.6.0"
            ),
            installedModels: ["gemma4:e4b"]
        )
        let runtime = CodexAssistantRuntime(
            preferredModelID: "gemma4:e4b",
            localRuntimeManager: runtimeManager,
            ollamaChatService: MockOllamaChatService()
        )
        runtime.backend = .ollamaLocal

        let details = try await runtime.refreshEnvironment(codexPath: nil)

        XCTAssertEqual(details.health.availability, .ready)
        XCTAssertEqual(details.health.selectedModelID, "gemma4:e4b")
        XCTAssertTrue(details.models.first(where: { $0.id == "gemma4:e4b" })?.isInstalled ?? false)
    }

    func testSendPromptStreamsLocalOllamaReply() async throws {
        let chatService = MockOllamaChatService(
            plannedResponses: [
                .init(
                    deltas: ["Hello ", "world"],
                    message: AssistantOllamaChatMessage(role: .assistant, content: "Hello world")
                )
            ]
        )
        let runtime = makeReadyRuntime(chatService: chatService)
        let recorder = LockedRuntimeObservationRecorder()
        runtime.onTranscriptMutation = { mutation in
            if case .appendDelta(_, _, .assistant, let delta, _, _, _) = mutation {
                recorder.appendAssistantDelta(delta)
            }
        }
        runtime.onTurnCompletion = { status in
            recorder.setCompletionStatus(status)
        }

        try await runtime.resumeSession("thread-1", cwd: nil, preferredModelID: "gemma4:e4b")
        try await runtime.sendPrompt(
            "Say hi",
            preferredModelID: "gemma4:e4b"
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.streamedAssistantText, "Hello world")
        XCTAssertEqual(snapshot.completionStatus, .completed)
        XCTAssertEqual(await chatService.unloadedModelsSnapshot(), ["gemma4:e4b"])
    }

    func testSendPromptExecutesToolCallAfterPermissionAndContinues() async throws {
        let chatService = MockOllamaChatService(
            plannedResponses: [
                .init(
                    deltas: [],
                    message: AssistantOllamaChatMessage(
                        role: .assistant,
                        toolCalls: [
                            AssistantOllamaToolCall(
                                id: "tool-1",
                                name: AssistantExecCommandToolDefinition.name,
                                arguments: ["command": "pwd"]
                            )
                        ]
                    )
                ),
                .init(
                    deltas: ["Done"],
                    message: AssistantOllamaChatMessage(role: .assistant, content: "Done")
                )
            ]
        )
        let runtime = makeReadyRuntime(chatService: chatService)
        let recorder = LockedRuntimeObservationRecorder()
        runtime.onPermissionRequest = { request in
            recorder.setPermissionRequest(request)
        }
        runtime.onTurnCompletion = { status in
            recorder.setCompletionStatus(status)
        }
        runtime.onTranscriptMutation = { mutation in
            if case .appendDelta(_, _, .assistant, let delta, _, _, _) = mutation {
                recorder.appendAssistantDelta(delta)
            }
        }

        try await runtime.resumeSession("thread-1", cwd: "/Users/manikvashith/Documents/PersonalProjects/OpenAssist", preferredModelID: "gemma4:e4b")

        let sendTask = Task {
            try await runtime.sendPrompt(
                "Show me the current folder",
                preferredModelID: "gemma4:e4b"
            )
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(recorder.snapshot().permissionRequest?.toolTitle, "Command")

        await runtime.respondToPermissionRequest(optionID: "accept")
        try await sendTask.value

        let requests = await chatService.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.messages.last?.role, .tool)
        XCTAssertEqual(requests.last?.messages.last?.toolName, AssistantExecCommandToolDefinition.name)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.streamedAssistantText, "Done")
        XCTAssertEqual(snapshot.completionStatus, .completed)
        XCTAssertEqual(await chatService.unloadedModelsSnapshot(), ["gemma4:e4b"])
    }

    func testSendPromptEncodesImageAttachmentsAsBase64Images() async throws {
        let chatService = MockOllamaChatService(
            plannedResponses: [
                .init(
                    deltas: ["Image checked"],
                    message: AssistantOllamaChatMessage(role: .assistant, content: "Image checked")
                )
            ]
        )
        let runtime = makeReadyRuntime(chatService: chatService)
        try await runtime.resumeSession("thread-1", cwd: nil, preferredModelID: "gemma4:e4b")

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let attachment = AssistantAttachment(
            filename: "sample.png",
            data: imageData,
            mimeType: "image/png"
        )

        try await runtime.sendPrompt(
            "What is in this image?",
            attachments: [attachment],
            preferredModelID: "gemma4:e4b",
            modelSupportsImageInput: true
        )

        let firstRequest = await chatService.requestsSnapshot().first
        let images = firstRequest?.messages.last?.images ?? []
        XCTAssertEqual(images, [imageData.base64EncodedString()])
        XCTAssertEqual(await chatService.unloadedModelsSnapshot(), ["gemma4:e4b"])
    }

    private func makeReadyRuntime(
        chatService: MockOllamaChatService
    ) -> CodexAssistantRuntime {
        let runtimeManager = MockLocalRuntimeManager(
            detection: LocalAIRuntimeDetection(
                installed: true,
                isManagedInstallation: true,
                isHealthy: true,
                appURL: URL(fileURLWithPath: "/Applications/Ollama.app"),
                executableURL: URL(fileURLWithPath: "/Applications/Ollama.app/Contents/MacOS/ollama"),
                version: "0.6.0"
            ),
            installedModels: ["gemma4:e4b"]
        )
        let runtime = CodexAssistantRuntime(
            preferredModelID: "gemma4:e4b",
            localRuntimeManager: runtimeManager,
            ollamaChatService: chatService
        )
        runtime.backend = .ollamaLocal
        return runtime
    }
}

private actor MockLocalRuntimeManager: LocalAIRuntimeManaging {
    let detection: LocalAIRuntimeDetection
    let installedModelsList: [String]

    init(
        detection: LocalAIRuntimeDetection,
        installedModels: [String]
    ) {
        self.detection = detection
        self.installedModelsList = installedModels
    }

    func detect() async -> LocalAIRuntimeDetection {
        detection
    }

    func installManagedRuntime() async throws -> LocalAIRuntimeDetection {
        detection
    }

    func start() async throws -> LocalAIRuntimeDetection {
        detection
    }

    func healthCheck() async -> Bool {
        detection.isHealthy
    }

    func stop() async {}

    func pullModel(
        id: String,
        onProgress: (@Sendable (Double, String) -> Void)?
    ) async throws {}

    func deleteModel(id: String) async throws {}

    func isModelInstalled(_ modelID: String) async -> Bool {
        installedModelsList.contains { $0.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    func installedModels() async -> [String] {
        installedModelsList
    }
}

private actor MockOllamaChatService: AssistantOllamaChatServing {
    struct PlannedResponse: Sendable {
        let deltas: [String]
        let message: AssistantOllamaChatMessage
    }

    private var plannedResponses: [PlannedResponse]
    private var requests: [AssistantOllamaChatRequest] = []
    private var unloadedModels: [String] = []

    init(plannedResponses: [PlannedResponse] = []) {
        self.plannedResponses = plannedResponses
    }

    func streamChat(
        request: AssistantOllamaChatRequest,
        onEvent: @escaping @Sendable (AssistantOllamaStreamEvent) async -> Void
    ) async throws -> AssistantOllamaChatResponse {
        requests.append(request)
        guard !plannedResponses.isEmpty else {
            return AssistantOllamaChatResponse(
                message: AssistantOllamaChatMessage(role: .assistant, content: ""),
                promptEvalCount: nil,
                evalCount: nil
            )
        }

        let planned = plannedResponses.removeFirst()
        for delta in planned.deltas {
            await onEvent(.assistantTextDelta(delta))
        }
        if !planned.message.toolCalls.isEmpty {
            await onEvent(.toolCalls(planned.message.toolCalls))
        }
        return AssistantOllamaChatResponse(
            message: planned.message,
            promptEvalCount: nil,
            evalCount: nil
        )
    }

    func requestsSnapshot() -> [AssistantOllamaChatRequest] {
        requests
    }

    func unloadModel(named model: String) async throws {
        unloadedModels.append(model)
    }

    func unloadedModelsSnapshot() -> [String] {
        unloadedModels
    }
}

private final class LockedRuntimeObservationRecorder: @unchecked Sendable {
    struct Snapshot {
        let streamedAssistantText: String
        let completionStatus: AssistantTurnCompletionStatus?
        let permissionRequest: AssistantPermissionRequest?
    }

    private let lock = NSLock()
    private var streamedAssistantText = ""
    private var completionStatus: AssistantTurnCompletionStatus?
    private var permissionRequest: AssistantPermissionRequest?

    func appendAssistantDelta(_ delta: String) {
        lock.lock()
        streamedAssistantText += delta
        lock.unlock()
    }

    func setCompletionStatus(_ status: AssistantTurnCompletionStatus) {
        lock.lock()
        completionStatus = status
        lock.unlock()
    }

    func setPermissionRequest(_ request: AssistantPermissionRequest?) {
        lock.lock()
        permissionRequest = request
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            streamedAssistantText: streamedAssistantText,
            completionStatus: completionStatus,
            permissionRequest: permissionRequest
        )
    }
}
