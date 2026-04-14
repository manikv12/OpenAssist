import Foundation

enum AssistantToolSurfaceStyle: Hashable {
    case compact
    case granular
}

struct AssistantBackendCapabilities: Equatable {
    let supportsStructuredToolCalls: Bool
    let supportsImageInput: Bool
    let maxPracticalToolCount: Int?
    let supportsLongToolOutputs: Bool
    let supportsContinuation: Bool
    let preferredToolSurface: AssistantToolSurfaceStyle
}

protocol AssistantBackendAdapter {
    var backend: AssistantRuntimeBackend { get }
    var capabilities: AssistantBackendCapabilities { get }
}

struct CodexBackendAdapter: AssistantBackendAdapter {
    let backend: AssistantRuntimeBackend = .codex
    let capabilities = AssistantBackendCapabilities(
        supportsStructuredToolCalls: true,
        supportsImageInput: true,
        maxPracticalToolCount: nil,
        supportsLongToolOutputs: true,
        supportsContinuation: true,
        preferredToolSurface: .granular
    )
}

struct CopilotBackendAdapter: AssistantBackendAdapter {
    let backend: AssistantRuntimeBackend = .copilot
    let capabilities = AssistantBackendCapabilities(
        supportsStructuredToolCalls: true,
        supportsImageInput: true,
        maxPracticalToolCount: nil,
        supportsLongToolOutputs: true,
        supportsContinuation: true,
        preferredToolSurface: .granular
    )
}

struct ClaudeCodeBackendAdapter: AssistantBackendAdapter {
    let backend: AssistantRuntimeBackend = .claudeCode
    let capabilities = AssistantBackendCapabilities(
        supportsStructuredToolCalls: false,
        supportsImageInput: true,
        maxPracticalToolCount: nil,
        supportsLongToolOutputs: true,
        supportsContinuation: true,
        preferredToolSurface: .granular
    )
}

struct OllamaLocalBackendAdapter: AssistantBackendAdapter {
    let backend: AssistantRuntimeBackend = .ollamaLocal
    let capabilities = AssistantBackendCapabilities(
        supportsStructuredToolCalls: true,
        supportsImageInput: true,
        maxPracticalToolCount: nil,
        supportsLongToolOutputs: true,
        supportsContinuation: true,
        preferredToolSurface: .granular
    )
}

enum AssistantBackendAdapterRegistry {
    static func adapter(for backend: AssistantRuntimeBackend) -> any AssistantBackendAdapter {
        switch backend {
        case .codex:
            return CodexBackendAdapter()
        case .copilot:
            return CopilotBackendAdapter()
        case .claudeCode:
            return ClaudeCodeBackendAdapter()
        case .ollamaLocal:
            return OllamaLocalBackendAdapter()
        }
    }
}

struct AssistantHostCapabilities: Equatable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let appleEventsGranted: Bool
    let appleEventsKnown: Bool
    let fullDiskAccessGranted: Bool
    let browserAutomationEnabled: Bool
    let browserProfileSelected: Bool
    let computerUseEnabled: Bool
    let shellExecutionAvailable: Bool
    let windowInspectionAvailable: Bool

    @MainActor
    static func live(settings: SettingsStore) -> AssistantHostCapabilities {
        let snapshot = ToolPermissionRegistry.snapshot(using: settings)
        return AssistantHostCapabilities(
            accessibilityGranted: snapshot.accessibilityGranted,
            screenRecordingGranted: snapshot.screenRecordingGranted,
            appleEventsGranted: snapshot.appleEventsGranted,
            appleEventsKnown: snapshot.appleEventsKnown,
            fullDiskAccessGranted: snapshot.fullDiskAccessGranted,
            browserAutomationEnabled: snapshot.browserAutomationEnabled,
            browserProfileSelected: snapshot.browserProfileSelected,
            computerUseEnabled: snapshot.computerUseEnabled,
            shellExecutionAvailable: true,
            windowInspectionAvailable: true
        )
    }
}

enum AssistantToolExecutionKind {
    case assistantNotes
    case browserUse
    case appAction
    case computerUse
    case imageGeneration
    case execCommand
    case writeStdin
    case readTerminal
    case viewImage
    case screenCapture
    case windowList
    case windowCapture
    case uiInspect
    case uiClick
    case uiType
    case uiPressKey
}

struct AssistantToolDescriptor {
    let name: String
    let aliases: [String]
    let toolKind: String
    let displayName: String
    let description: String
    let inputSchema: [String: Any]
    let modes: Set<AssistantInteractionMode>
    let surfaceStyles: Set<AssistantToolSurfaceStyle>
    let permissionLeadText: String
    let executionKind: AssistantToolExecutionKind
    let availability: @MainActor () -> Bool
    let summaryProvider: (Any) -> String
    let requiresExplicitConfirmation: (Any) -> Bool

    func dynamicToolSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }

    func matches(_ rawName: String?) -> Bool {
        guard let normalized = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        if name.lowercased() == normalized {
            return true
        }
        return aliases.contains { $0.lowercased() == normalized }
    }
}

enum AssistantToolCatalog {
    static func allDescriptors() -> [AssistantToolDescriptor] {
        [
            AssistantToolDescriptor(
                name: AssistantImageGenerationToolDefinition.name,
                aliases: [],
                toolKind: AssistantImageGenerationToolDefinition.toolKind,
                displayName: "Image Generation",
                description: AssistantImageGenerationToolDefinition.description,
                inputSchema: AssistantImageGenerationToolDefinition.inputSchema,
                modes: [.conversational, .plan, .agentic],
                surfaceStyles: [.compact, .granular],
                permissionLeadText: "Image Generation sends the request to Google Gemini using the shared Google AI Studio API key configured in Open Assist and returns the generated image back into the conversation.",
                executionKind: .imageGeneration,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantImageGenerationService.parseRequest(from: arguments).summaryLine) ?? "Generate an image"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantNotesToolDefinition.name,
                aliases: [],
                toolKind: AssistantNotesToolDefinition.toolKind,
                displayName: "Assistant Notes",
                description: AssistantNotesToolDefinition.description,
                inputSchema: AssistantNotesToolDefinition.inputSchema,
                modes: [.plan, .agentic],
                surfaceStyles: [.compact, .granular],
                permissionLeadText: "Assistant Notes reads Open Assist project and thread note files, prepares note changes as previews, and only saves when you confirm an apply action.",
                executionKind: .assistantNotes,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantNotesToolService.parseRequest(from: arguments).summaryLine) ?? "Use project notes"
                },
                requiresExplicitConfirmation: { arguments in
                    (try? AssistantNotesToolService.parseRequest(from: arguments).action) == .applyPreview
                }
            ),
            AssistantToolDescriptor(
                name: AssistantAppActionToolDefinition.name,
                aliases: [],
                toolKind: AssistantAppActionToolDefinition.toolKind,
                displayName: "App Action",
                description: AssistantAppActionToolDefinition.description,
                inputSchema: AssistantAppActionToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.compact, .granular],
                permissionLeadText: "App Action can talk to supported Mac apps like Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages.",
                executionKind: .appAction,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantAppActionService.parseRequest(from: arguments).task) ?? "Use a supported Mac app"
                },
                requiresExplicitConfirmation: { arguments in
                    if let request = try? AssistantAppActionService.parseRequest(from: arguments),
                       request.command?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                        || request.app == .terminal
                        || request.commit {
                        return true
                    }
                    let summary = ((try? AssistantAppActionService.parseRequest(from: arguments).task) ?? "").lowercased()
                    return ["send", "post", "purchase", "delete", "submit"].contains(where: summary.contains)
                }
            ),
            AssistantToolDescriptor(
                name: AssistantBrowserUseToolDefinition.name,
                aliases: [],
                toolKind: AssistantBrowserUseToolDefinition.toolKind,
                displayName: "Browser Use",
                description: AssistantBrowserUseToolDefinition.description,
                inputSchema: AssistantBrowserUseToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.compact, .granular],
                permissionLeadText: "Browser Use works in the selected signed-in browser profile on this Mac and keeps you in that same browser session.",
                executionKind: .browserUse,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantBrowserUseService.parseTask(from: arguments).summaryLine) ?? "Use the selected browser profile"
                },
                requiresExplicitConfirmation: { arguments in
                    let summary = ((try? AssistantBrowserUseService.parseTask(from: arguments).summaryLine) ?? "").lowercased()
                    return ["send", "post", "purchase", "delete", "submit"].contains(where: summary.contains)
                }
            ),
            AssistantToolDescriptor(
                name: AssistantExecCommandToolDefinition.name,
                aliases: [],
                toolKind: AssistantExecCommandToolDefinition.toolKind,
                displayName: "Command",
                description: AssistantExecCommandToolDefinition.description,
                inputSchema: AssistantExecCommandToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Command runs a local shell command on this Mac in the current workspace and can keep the session open for follow-up input.",
                executionKind: .execCommand,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantShellExecutionService.parseExecCommandRequest(from: arguments).summaryLine) ?? "Run a local command"
                },
                requiresExplicitConfirmation: { arguments in
                    guard let request = try? AssistantShellExecutionService.parseExecCommandRequest(from: arguments) else {
                        return true
                    }
                    return AssistantModePolicy.commandSafetyClass(for: request.command) != .readOnly
                }
            ),
            AssistantToolDescriptor(
                name: AssistantWriteStdinToolDefinition.name,
                aliases: [],
                toolKind: AssistantWriteStdinToolDefinition.toolKind,
                displayName: "Write Stdin",
                description: AssistantWriteStdinToolDefinition.description,
                inputSchema: AssistantWriteStdinToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Write Stdin sends additional text into an already-running shell session on this Mac.",
                executionKind: .writeStdin,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantShellExecutionService.parseWriteStdinRequest(from: arguments).summaryLine) ?? "Continue a shell session"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantReadTerminalToolDefinition.name,
                aliases: ["read_thread_terminal"],
                toolKind: AssistantReadTerminalToolDefinition.toolKind,
                displayName: "Read Terminal",
                description: AssistantReadTerminalToolDefinition.description,
                inputSchema: AssistantReadTerminalToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Read Terminal reads output from the current shell session on this Mac.",
                executionKind: .readTerminal,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantShellExecutionService.parseReadTerminalRequest(from: arguments).summaryLine) ?? "Read the latest shell output"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantViewImageToolDefinition.name,
                aliases: [],
                toolKind: AssistantViewImageToolDefinition.toolKind,
                displayName: "View Image",
                description: AssistantViewImageToolDefinition.description,
                inputSchema: AssistantViewImageToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "View Image loads a local image file from this Mac and returns it to the conversation for inspection.",
                executionKind: .viewImage,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantWindowAutomationService.parseViewImageRequest(from: arguments).summaryLine) ?? "Load a local image"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantScreenCaptureToolDefinition.name,
                aliases: [],
                toolKind: AssistantScreenCaptureToolDefinition.toolKind,
                displayName: "Screen Capture",
                description: AssistantScreenCaptureToolDefinition.description,
                inputSchema: AssistantScreenCaptureToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Screen Capture takes a fresh screenshot from this Mac and returns it to the conversation.",
                executionKind: .screenCapture,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantWindowAutomationService.parseScreenCaptureRequest(from: arguments).summaryLine) ?? "Capture the current screen"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantWindowListToolDefinition.name,
                aliases: [],
                toolKind: AssistantWindowListToolDefinition.toolKind,
                displayName: "Window List",
                description: AssistantWindowListToolDefinition.description,
                inputSchema: AssistantWindowListToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Window List inspects the visible windows on this Mac so the assistant can find the right app window before capturing or automating it.",
                executionKind: .windowList,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantWindowAutomationService.parseWindowListRequest(from: arguments).summaryLine) ?? "List visible windows"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantWindowCaptureToolDefinition.name,
                aliases: [],
                toolKind: AssistantWindowCaptureToolDefinition.toolKind,
                displayName: "Window Capture",
                description: AssistantWindowCaptureToolDefinition.description,
                inputSchema: AssistantWindowCaptureToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "Window Capture takes a screenshot of one selected app window on this Mac and returns it to the conversation.",
                executionKind: .windowCapture,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantWindowAutomationService.parseWindowCaptureRequest(from: arguments).summaryLine) ?? "Capture a visible window"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantUIInspectToolDefinition.name,
                aliases: [],
                toolKind: AssistantUIInspectToolDefinition.toolKind,
                displayName: "UI Inspect",
                description: AssistantUIInspectToolDefinition.description,
                inputSchema: AssistantUIInspectToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "UI Inspect reads macOS accessibility elements so Open Assist can find buttons, fields, and labels without guessing screen coordinates.",
                executionKind: .uiInspect,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantAccessibilityAutomationService.parseInspectRequest(from: arguments).summaryLine) ?? "Inspect the current app UI"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantUIClickToolDefinition.name,
                aliases: [],
                toolKind: AssistantUIClickToolDefinition.toolKind,
                displayName: "UI Click",
                description: AssistantUIClickToolDefinition.description,
                inputSchema: AssistantUIClickToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "UI Click uses macOS accessibility first, then falls back to a direct screen click only when needed.",
                executionKind: .uiClick,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantAccessibilityAutomationService.parseClickRequest(from: arguments).summaryLine) ?? "Click a UI element"
                },
                requiresExplicitConfirmation: { arguments in
                    let summary = ((try? AssistantAccessibilityAutomationService.parseClickRequest(from: arguments).summaryLine) ?? "").lowercased()
                    return ["send", "post", "submit", "delete", "purchase", "confirm"].contains(where: summary.contains)
                }
            ),
            AssistantToolDescriptor(
                name: AssistantUITypeToolDefinition.name,
                aliases: [],
                toolKind: AssistantUITypeToolDefinition.toolKind,
                displayName: "UI Type",
                description: AssistantUITypeToolDefinition.description,
                inputSchema: AssistantUITypeToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "UI Type focuses a field and types text through the normal macOS input path instead of raw screenshot coordinates.",
                executionKind: .uiType,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantAccessibilityAutomationService.parseTypeRequest(from: arguments).summaryLine) ?? "Type into a UI field"
                },
                requiresExplicitConfirmation: { arguments in
                    let request = try? AssistantAccessibilityAutomationService.parseTypeRequest(from: arguments)
                    let text = request?.text.lowercased() ?? ""
                    return ["send", "post", "submit", "delete", "purchase", "confirm"].contains(where: text.contains)
                }
            ),
            AssistantToolDescriptor(
                name: AssistantUIPressKeyToolDefinition.name,
                aliases: [],
                toolKind: AssistantUIPressKeyToolDefinition.toolKind,
                displayName: "UI Press Key",
                description: AssistantUIPressKeyToolDefinition.description,
                inputSchema: AssistantUIPressKeyToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.granular],
                permissionLeadText: "UI Press Key sends keyboard shortcuts to the current Mac app through Accessibility.",
                executionKind: .uiPressKey,
                availability: { true },
                summaryProvider: { arguments in
                    (try? AssistantAccessibilityAutomationService.parsePressKeyRequest(from: arguments).summaryLine) ?? "Press UI keys"
                },
                requiresExplicitConfirmation: { _ in false }
            ),
            AssistantToolDescriptor(
                name: AssistantComputerUseToolDefinition.name,
                aliases: [],
                toolKind: AssistantComputerUseToolDefinition.toolKind,
                displayName: "Computer Use",
                description: AssistantComputerUseToolDefinition.description,
                inputSchema: AssistantComputerUseToolDefinition.inputSchema,
                modes: [.agentic],
                surfaceStyles: [.compact, .granular],
                permissionLeadText: "Computer Use captures the visible screen on this Mac, then uses mouse or keyboard actions on the live desktop when browser, app, and Accessibility UI tools are not enough.",
                executionKind: .computerUse,
                availability: { SettingsStore.shared.assistantComputerUseEnabled },
                summaryProvider: { arguments in
                    (try? AssistantComputerUseService.parseRequest(from: arguments).summaryLine) ?? "Use screenshot-based desktop control"
                },
                requiresExplicitConfirmation: { arguments in
                    (try? AssistantComputerUseService.parseRequest(from: arguments).isHighRisk) ?? true
                }
            )
        ]
    }

    static func descriptor(named rawName: String?) -> AssistantToolDescriptor? {
        allDescriptors().first(where: { $0.matches(rawName) })
    }
}

@MainActor
final class AssistantToolSurfaceCompiler {
    init() {}

    func descriptors(
        for mode: AssistantInteractionMode,
        backend: AssistantRuntimeBackend
    ) -> [AssistantToolDescriptor] {
        let adapter = AssistantBackendAdapterRegistry.adapter(for: backend)
        return AssistantToolCatalog.allDescriptors().filter { descriptor in
            descriptor.modes.contains(mode)
                && descriptor.surfaceStyles.contains(adapter.capabilities.preferredToolSurface)
                && descriptor.availability()
        }
    }

    func dynamicToolSpecs(
        for mode: AssistantInteractionMode,
        backend: AssistantRuntimeBackend
    ) -> [[String: Any]] {
        descriptors(for: mode, backend: backend).map { $0.dynamicToolSpec() }
    }

    func dynamicToolNames(
        for mode: AssistantInteractionMode,
        backend: AssistantRuntimeBackend
    ) -> [String] {
        descriptors(for: mode, backend: backend).map(\.name)
    }
}

actor ToolSessionStore {
    struct ShellSessionSnapshot: Sendable {
        let id: Int
        let command: String
        let workingDirectory: String?
        let isRunning: Bool
        let terminationStatus: Int32?
        let fullOutput: String
        let unreadOutput: String
    }

    final class ShellSession {
        let id: Int
        let command: String
        let workingDirectory: String?
        let process: Process
        let stdinHandle: FileHandle
        var output = Data()
        var unreadOffset = 0
        var terminationStatus: Int32?

        init(
            id: Int,
            command: String,
            workingDirectory: String?,
            process: Process,
            stdinHandle: FileHandle
        ) {
            self.id = id
            self.command = command
            self.workingDirectory = workingDirectory
            self.process = process
            self.stdinHandle = stdinHandle
        }
    }

    private var nextShellSessionID = 1
    private var shellSessions: [Int: ShellSession] = [:]
    private var lastShellSessionIDByThreadID: [String: Int] = [:]

    func registerShellSession(
        threadID: String?,
        command: String,
        workingDirectory: String?,
        process: Process,
        stdinHandle: FileHandle
    ) -> Int {
        let sessionID = nextShellSessionID
        nextShellSessionID += 1
        shellSessions[sessionID] = ShellSession(
            id: sessionID,
            command: command,
            workingDirectory: workingDirectory,
            process: process,
            stdinHandle: stdinHandle
        )
        if let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lastShellSessionIDByThreadID[normalizedThreadID] = sessionID
        }
        return sessionID
    }

    func appendShellOutput(_ data: Data, to sessionID: Int) {
        guard let session = shellSessions[sessionID], !data.isEmpty else { return }
        session.output.append(data)
    }

    func markShellSessionExited(_ sessionID: Int, terminationStatus: Int32) {
        guard let session = shellSessions[sessionID] else { return }
        session.terminationStatus = terminationStatus
    }

    func resolveShellSessionID(sessionID: Int?, threadID: String?) -> Int? {
        if let sessionID {
            return shellSessions[sessionID] == nil ? nil : sessionID
        }
        guard let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return lastShellSessionIDByThreadID[normalizedThreadID]
    }

    func shellSnapshot(sessionID: Int, consumeUnread: Bool) -> ShellSessionSnapshot? {
        guard let session = shellSessions[sessionID] else { return nil }
        let fullOutput = Self.decode(session.output)
        let unreadData = session.output.subdata(in: session.unreadOffset..<session.output.count)
        let unreadOutput = Self.decode(unreadData)
        if consumeUnread {
            session.unreadOffset = session.output.count
        }
        return ShellSessionSnapshot(
            id: session.id,
            command: session.command,
            workingDirectory: session.workingDirectory,
            isRunning: session.process.isRunning,
            terminationStatus: session.terminationStatus,
            fullOutput: fullOutput,
            unreadOutput: unreadOutput
        )
    }

    func writeToShell(sessionID: Int, text: String) throws {
        guard let session = shellSessions[sessionID] else {
            throw AssistantShellExecutionServiceError.sessionNotFound
        }
        guard session.process.isRunning else {
            throw AssistantShellExecutionServiceError.sessionNotRunning
        }
        if let data = text.data(using: .utf8) {
            session.stdinHandle.write(data)
        }
    }

    func closeShellSession(_ sessionID: Int) {
        guard let session = shellSessions[sessionID] else { return }
        session.stdinHandle.closeFile()
        if session.process.isRunning {
            session.process.terminate()
        }
    }

    private static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct AssistantToolExecutionContext {
    let toolName: String
    let arguments: Any
    let attachments: [AssistantAttachment]
    let sessionID: String?
    let assistantNotesContext: AssistantNotesRuntimeContext?
    let preferredModelID: String?
    let browserLoginResume: Bool
    let interactionMode: AssistantInteractionMode
}

@MainActor
final class AssistantToolExecutor {
    private let assistantNotesService: AssistantNotesToolService
    private let browserUseService: AssistantBrowserUseService
    private let appActionService: AssistantAppActionService
    private let computerUseService: AssistantComputerUseService
    private let imageGenerationService: AssistantImageGenerationService
    private let shellExecutionService: AssistantShellExecutionService
    private let windowAutomationService: AssistantWindowAutomationService
    private let accessibilityAutomationService: AssistantAccessibilityAutomationService
    private let surfaceCompiler: AssistantToolSurfaceCompiler

    init(
        assistantNotesService: AssistantNotesToolService,
        browserUseService: AssistantBrowserUseService,
        appActionService: AssistantAppActionService,
        computerUseService: AssistantComputerUseService,
        imageGenerationService: AssistantImageGenerationService,
        shellExecutionService: AssistantShellExecutionService,
        windowAutomationService: AssistantWindowAutomationService,
        accessibilityAutomationService: AssistantAccessibilityAutomationService,
        surfaceCompiler: AssistantToolSurfaceCompiler
    ) {
        self.assistantNotesService = assistantNotesService
        self.browserUseService = browserUseService
        self.appActionService = appActionService
        self.computerUseService = computerUseService
        self.imageGenerationService = imageGenerationService
        self.shellExecutionService = shellExecutionService
        self.windowAutomationService = windowAutomationService
        self.accessibilityAutomationService = accessibilityAutomationService
        self.surfaceCompiler = surfaceCompiler
    }

    func descriptors(for mode: AssistantInteractionMode, backend: AssistantRuntimeBackend) -> [AssistantToolDescriptor] {
        surfaceCompiler.descriptors(for: mode, backend: backend)
    }

    func dynamicToolSpecs(for mode: AssistantInteractionMode, backend: AssistantRuntimeBackend) -> [[String: Any]] {
        surfaceCompiler.dynamicToolSpecs(for: mode, backend: backend)
    }

    func dynamicToolNames(for mode: AssistantInteractionMode, backend: AssistantRuntimeBackend) -> [String] {
        surfaceCompiler.dynamicToolNames(for: mode, backend: backend)
    }

    func descriptor(for name: String?) -> AssistantToolDescriptor? {
        AssistantToolCatalog.descriptor(named: name)
    }

    func execute(_ context: AssistantToolExecutionContext) async -> AssistantToolExecutionResult {
        guard let descriptor = descriptor(for: context.toolName) else {
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: "Open Assist does not support the dynamic tool `\(context.toolName)` yet.", imageURL: nil)],
                success: false,
                summary: "Unsupported dynamic tool."
            )
        }

        switch descriptor.executionKind {
        case .assistantNotes:
            return await assistantNotesService.run(
                arguments: context.arguments,
                sessionID: context.sessionID,
                runtimeContext: context.assistantNotesContext,
                preferredModelID: context.preferredModelID,
                interactionMode: context.interactionMode
            )
        case .browserUse:
            return await (
                context.browserLoginResume
                    ? browserUseService.resumeAfterLogin(
                        arguments: context.arguments,
                        preferredModelID: context.preferredModelID
                    )
                    : browserUseService.run(
                        arguments: context.arguments,
                        preferredModelID: context.preferredModelID
                    )
            )
        case .appAction:
            return await appActionService.run(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .computerUse:
            return await computerUseService.run(
                sessionID: context.sessionID ?? "",
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .imageGeneration:
            return await imageGenerationService.run(
                arguments: context.arguments,
                referenceImages: context.attachments.filter(\.isImage),
                preferredModelID: context.preferredModelID
            )
        case .execCommand:
            return await shellExecutionService.runCommand(
                threadID: context.sessionID,
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .writeStdin:
            return await shellExecutionService.writeStdin(
                threadID: context.sessionID,
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .readTerminal:
            return await shellExecutionService.readTerminal(
                threadID: context.sessionID,
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .viewImage:
            return await windowAutomationService.viewImage(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .screenCapture:
            return await windowAutomationService.captureScreen(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .windowList:
            return await windowAutomationService.listWindows(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .windowCapture:
            return await windowAutomationService.captureWindow(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .uiInspect:
            return await accessibilityAutomationService.inspectUI(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .uiClick:
            return await accessibilityAutomationService.clickUI(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .uiType:
            return await accessibilityAutomationService.typeIntoUI(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        case .uiPressKey:
            return await accessibilityAutomationService.pressKeys(
                arguments: context.arguments,
                preferredModelID: context.preferredModelID
            )
        }
    }

    func workingDetail(for toolName: String, browserLoginResume: Bool) -> String {
        guard let descriptor = descriptor(for: toolName) else {
            return "Unsupported dynamic tool"
        }
        switch descriptor.executionKind {
        case .assistantNotes:
            return "Reading project notes and preparing note changes"
        case .browserUse:
            return browserLoginResume ? "Checking the browser after sign-in" : "Using the selected browser profile"
        case .appAction:
            return "Using a supported Mac app"
        case .computerUse:
            return "Resolving the target, observing the UI, acting, and verifying the result"
        case .imageGeneration:
            return "Generating an image with Google Gemini"
        case .execCommand:
            return "Running a local shell command"
        case .writeStdin:
            return "Sending input to a running shell session"
        case .readTerminal:
            return "Reading the latest shell output"
        case .viewImage:
            return "Loading a local image"
        case .screenCapture:
            return "Capturing the current screen"
        case .windowList:
            return "Listing visible windows"
        case .windowCapture:
            return "Capturing a visible window"
        case .uiInspect:
            return "Inspecting macOS UI elements"
        case .uiClick:
            return "Clicking a macOS UI element"
        case .uiType:
            return "Typing into a macOS UI field"
        case .uiPressKey:
            return "Pressing macOS UI keys"
        }
    }
}
