import Foundation
import UniformTypeIdentifiers

@MainActor
final class TelegramRemoteCoordinator: ObservableObject {
    static let shared = TelegramRemoteCoordinator()
    private static let telegramDownloadLimitBytes = 20 * 1024 * 1024
    private static let supportedAudioFileExtensions: Set<String> = [
        "wav", "mp3", "mp4", "mpeg", "mpga", "m4a", "flac", "ogg", "opus", "oga", "webm"
    ]
    private static let supportedAudioMIMETypes: Set<String> = [
        "audio/flac",
        "audio/m4a",
        "audio/mp3",
        "audio/mp4",
        "audio/mpeg",
        "audio/ogg",
        "audio/opus",
        "audio/wav",
        "audio/webm",
        "application/ogg",
        "video/mp4"
    ]
    private static let botCommands: [TelegramBotCommand] = [
        .init(command: "start", description: "Open the Telegram remote home screen"),
        .init(command: "help", description: "Show the main Telegram commands"),
        .init(command: "new", description: "Start a new Open Assist session"),
        .init(command: "clear", description: "Clear this Telegram screen and keep one fresh card"),
        .init(command: "temp", description: "Start a temporary Open Assist chat"),
        .init(command: "projects", description: "Browse projects and their threads"),
        .init(command: "sessions", description: "Switch to another Open Assist session"),
        .init(command: "backend", description: "Switch between Codex and GitHub Copilot"),
        .init(command: "models", description: "Change the active session model"),
        .init(command: "mode", description: "Switch between Plan and Agentic"),
        .init(command: "effort", description: "Change the model thinking level"),
        .init(command: "usage", description: "Show context and token usage"),
        .init(command: "status", description: "Show the active session status"),
        .init(command: "stop", description: "Stop the current assistant turn")
    ]

    @Published private(set) var botIdentityLabel = "No bot connected"
    @Published private(set) var connectionStatusMessage = "Disabled"
    @Published private(set) var pairingStatusMessage = "Not paired"
    @Published private(set) var lastErrorMessage: String?

    private enum ControllerMenu {
        case home
        case projects
        case sessions
        case backend
        case models
        case mode
        case effort
    }

    private enum ViewSlot {
        case header
        case transcript
        case stream
        case permission
    }

    private struct MessageSlot {
        var messageID: Int?
        var signature: String?

        mutating func reset() {
            messageID = nil
            signature = nil
        }
    }

    private struct ChatState {
        var selectedProjectID: String?
        var selectedSessionID: String?
        var viewGeneration = 0
        var shouldShowTranscriptPreview = true
        var controllerMenu: ControllerMenu = .home
        var controllerMessageID: Int?
        var controllerSignature: String?
        var projectMenuFolderID: String?
        var projectMenuProjectIDs: [String] = []
        var sessionMenuSessionIDs: [String] = []
        var modelMenuModelIDs: [String] = []
        var headerSlot = MessageSlot()
        var transcriptSlot = MessageSlot()
        var streamSlot = MessageSlot()
        var permissionSlot = MessageSlot()
        var replyOverflowMessageIDs: [Int] = []
        var replyOverflowSignature: String?
        var imageMessageIDs: [Int] = []
        var lastDeliveredImageSignature: String?
        var trackedMessageIDs: [Int] = []
        var structuredQuestionIndex = 0
        var structuredAnswers: [String: [String]] = [:]
        var awaitingCustomAnswerQuestionID: String?

        mutating func trackMessage(_ messageID: Int) {
            if trackedMessageIDs.contains(messageID) == false {
                trackedMessageIDs.append(messageID)
            }
            if trackedMessageIDs.count > 400 {
                trackedMessageIDs.removeFirst(trackedMessageIDs.count - 400)
            }
        }

        mutating func forgetMessage(_ messageID: Int) {
            trackedMessageIDs.removeAll { $0 == messageID }
        }

        mutating func resetStructuredInput() {
            structuredQuestionIndex = 0
            structuredAnswers = [:]
            awaitingCustomAnswerQuestionID = nil
        }

        mutating func resetSessionView() {
            shouldShowTranscriptPreview = true
            headerSlot.reset()
            transcriptSlot.reset()
            streamSlot.reset()
            permissionSlot.reset()
            replyOverflowMessageIDs = []
            replyOverflowSignature = nil
            imageMessageIDs = []
            lastDeliveredImageSignature = nil
            resetStructuredInput()
        }

        mutating func switchSessionView(
            to sessionID: String?,
            showTranscriptPreview: Bool = true
        ) {
            viewGeneration += 1
            selectedSessionID = sessionID
            shouldShowTranscriptPreview = showTranscriptPreview
            resetStructuredInput()
        }

        mutating func invalidateSessionView() {
            viewGeneration += 1
            shouldShowTranscriptPreview = true
            resetStructuredInput()
        }

        mutating func clearTrackedPresentationState() {
            controllerMessageID = nil
            controllerSignature = nil
            headerSlot.reset()
            transcriptSlot.reset()
            streamSlot.reset()
            permissionSlot.reset()
            replyOverflowMessageIDs = []
            replyOverflowSignature = nil
            imageMessageIDs = []
            lastDeliveredImageSignature = nil
            trackedMessageIDs = []
            shouldShowTranscriptPreview = true
            resetStructuredInput()
        }
    }

    private struct Configuration: Equatable {
        let enabled: Bool
        let token: String
    }

    private struct TelegramAudioAttachment {
        let fileID: String
        let fileName: String
        let mimeType: String
        let fileSize: Int?
        let kindDescription: String
    }

    private enum TelegramAudioRoutingError: LocalizedError {
        case unsupportedAttachment
        case fileUnavailable
        case fileTooLarge
        case missingCredentials(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unsupportedAttachment:
                return "Send a Telegram voice note or a supported audio file such as mp3, m4a, wav, ogg, opus, flac, or webm."
            case .fileUnavailable:
                return "Telegram did not provide a downloadable file for that attachment."
            case .fileTooLarge:
                return "Telegram bots can only download audio files up to 20 MB."
            case .missingCredentials(let message):
                return message
            case .emptyTranscript:
                return "The audio upload finished, but no transcript text came back."
            }
        }
    }

    private let bridge = AssistantRemoteBridge()
    private let transcriptionService = AudioTranscriptionService.shared
    private weak var settings: SettingsStore?
    private var configuration: Configuration?
    private var client: TelegramBotClient?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var typingIndicatorTask: Task<Void, Never>?
    private var typingIndicatorChatID: Int64?
    private var didRegisterBotCommands = false
    private var shouldDrainBacklog = false
    private var shouldClearRecoveredChatHistory = false
    private var chatState = ChatState()

    private init() {}

    func applySettings(_ settings: SettingsStore) {
        self.settings = settings
        let newConfiguration = Configuration(
            enabled: settings.telegramRemoteEnabled,
            token: settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        updatePairingStatus(using: settings)

        guard newConfiguration != configuration else {
            return
        }

        configuration = newConfiguration
        stopTasks(resetIdentity: false)

        if !newConfiguration.enabled {
            client = nil
            shouldDrainBacklog = false
            shouldClearRecoveredChatHistory = false
            connectionStatusMessage = "Disabled"
            return
        }

        guard !newConfiguration.token.isEmpty else {
            client = nil
            shouldDrainBacklog = false
            shouldClearRecoveredChatHistory = false
            connectionStatusMessage = "Add your Telegram bot token to start."
            return
        }

        let recoveredTrackedMessageIDs = settings.telegramTrackedMessageIDs
        chatState.trackedMessageIDs = recoveredTrackedMessageIDs
        shouldClearRecoveredChatHistory = !recoveredTrackedMessageIDs.isEmpty
        client = TelegramBotClient(token: newConfiguration.token)
        didRegisterBotCommands = false
        shouldDrainBacklog = settings.telegramLastProcessedUpdateID == 0
        connectionStatusMessage = "Starting Telegram polling..."
        startTasks()
    }

    func stop() {
        configuration = nil
        client = nil
        stopTasks(resetIdentity: true)
        connectionStatusMessage = "Disabled"
    }

    func testConnection() async -> String {
        guard let settings else {
            return "Telegram settings are unavailable."
        }
        let token = settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return "Paste the bot token first."
        }

        do {
            let bot = try await TelegramBotClient(token: token).getMe()
            botIdentityLabel = botIdentityText(for: bot)
            lastErrorMessage = nil
            if settings.hasTelegramRemoteOwner {
                return "Connected to \(botIdentityText(for: bot)). Telegram is already paired."
            }
            return "Connected to \(botIdentityText(for: bot)). Next step: open the bot in Telegram and send /start. If you already sent /start earlier, send it one more time now."
        } catch {
            lastErrorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func approvePendingPairing() async -> String {
        guard let settings else {
            return "Telegram settings are unavailable."
        }
        guard settings.hasTelegramPendingPairing else {
            return "There is no pending Telegram pairing request."
        }

        settings.approveTelegramPendingPairing()
        updatePairingStatus(using: settings)

        if let chatID = Int64(settings.telegramOwnerChatID) {
            _ = try? await sendTelegramMessage(
                chatID: chatID,
                text: "Pairing approved. Send /start to begin using Open Assist from Telegram."
            )
            await renderHomeMenu(chatID: chatID, notice: "Telegram pairing approved.")
        }

        return "Approved the pending Telegram pairing."
    }

    func rejectPendingPairing() async -> String {
        guard let settings else {
            return "Telegram settings are unavailable."
        }
        guard settings.hasTelegramPendingPairing else {
            return "There is no pending Telegram pairing request."
        }

        let pendingChatID = Int64(settings.telegramPendingChatID)
        settings.clearTelegramPendingPairing()
        updatePairingStatus(using: settings)

        if let pendingChatID {
            _ = try? await sendTelegramMessage(
                chatID: pendingChatID,
                text: "The pairing request was declined in Open Assist Settings."
            )
        }

        return "Declined the pending Telegram pairing."
    }

    func maskedBotToken(for settings: SettingsStore) -> String {
        let token = settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > 12 else {
            return token.isEmpty ? "No token yet" : token
        }
        return "\(token.prefix(6))••••\(token.suffix(4))"
    }

    private func startTasks() {
        guard pollingTask == nil, refreshTask == nil else { return }

        pollingTask = Task { [weak self] in
            await self?.runPollingLoop()
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    private func stopTasks(resetIdentity: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        typingIndicatorTask?.cancel()
        typingIndicatorTask = nil
        typingIndicatorChatID = nil
        didRegisterBotCommands = false
        shouldDrainBacklog = false
        shouldClearRecoveredChatHistory = false
        chatState = ChatState()
        if resetIdentity {
            botIdentityLabel = "No bot connected"
            lastErrorMessage = nil
        }
    }

    private func runPollingLoop() async {
        await bridge.prime()

        while !Task.isCancelled {
            guard let settings, let client else { return }

            do {
                let bot = try await client.getMe()
                botIdentityLabel = botIdentityText(for: bot)
                connectionStatusMessage = "Connected as \(botIdentityText(for: bot))."
                lastErrorMessage = nil

                if !didRegisterBotCommands {
                    do {
                        _ = try await client.setMyCommands(Self.botCommands)
                        didRegisterBotCommands = true
                    } catch {
                        lastErrorMessage = "Connected, but could not register Telegram commands: \(error.localizedDescription)"
                    }
                }

                let updates = try await client.getUpdates(
                    offset: settings.telegramLastProcessedUpdateID,
                    timeout: 25
                )

                if shouldDrainBacklog {
                    if let lastUpdateID = updates.map(\.updateID).max() {
                        settings.telegramLastProcessedUpdateID = max(
                            settings.telegramLastProcessedUpdateID,
                            lastUpdateID + 1
                        )
                    }
                    shouldDrainBacklog = false
                    continue
                }

                for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
                    settings.telegramLastProcessedUpdateID = max(
                        settings.telegramLastProcessedUpdateID,
                        update.updateID + 1
                    )
                    await handle(update: update)
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                lastErrorMessage = error.localizedDescription
                connectionStatusMessage = "Polling failed: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            guard let settings,
                  settings.hasTelegramRemoteOwner,
                  let ownerChatID = Int64(settings.telegramOwnerChatID) else {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            if shouldClearRecoveredChatHistory {
                await clearTrackedChatHistory(chatID: ownerChatID)
            }

            let snapshot = await refreshSelectedSessionView(chatID: ownerChatID)
            await updateTypingIndicator(chatID: ownerChatID, snapshot: snapshot)
            if chatState.controllerMenu == .home {
                await renderHomeMenu(chatID: ownerChatID, notice: nil)
            }

            let refreshDelaySeconds = refreshIntervalSeconds(snapshot: snapshot)
            let nanoseconds = UInt64(max(refreshDelaySeconds, 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private func handle(update: TelegramUpdate) async {
        if let callbackQuery = update.callbackQuery {
            await handle(callbackQuery: callbackQuery)
            return
        }

        if let message = update.message {
            await handle(message: message)
        }
    }

    private func handle(message: TelegramMessage) async {
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.flatMap { $0.isEmpty ? nil : $0 }
        let audioAttachment = telegramAudioAttachment(from: message)

        guard normalizedText != nil || audioAttachment != nil || telegramMessageIncludesMedia(message) else {
            return
        }

        guard message.chat.type == "private" else {
            _ = try? await sendTelegramMessage(
                chatID: message.chat.id,
                text: "Use a private chat with the bot for Open Assist remote control."
            )
            return
        }

        guard let settings else { return }

        if !settings.hasTelegramRemoteOwner {
            await handlePendingPairing(text: normalizedText ?? "", message: message)
            return
        }

        guard isAuthorized(user: message.from, chat: message.chat) else {
            _ = try? await sendTelegramMessage(
                chatID: message.chat.id,
                text: "This Telegram chat is not approved for Open Assist."
            )
            return
        }

        trackMessageID(message.messageID)

        if let normalizedText,
           let customQuestionID = chatState.awaitingCustomAnswerQuestionID,
           !normalizedText.hasPrefix("/") {
            chatState.awaitingCustomAnswerQuestionID = nil
            chatState.structuredAnswers[customQuestionID] = [normalizedText]
            await continueStructuredInput(chatID: message.chat.id)
            return
        }

        if let normalizedText, let command = normalizedCommand(from: normalizedText) {
            await handle(command: command, rawText: normalizedText, chatID: message.chat.id)
            return
        }

        if let normalizedText {
            await sendPrompt(normalizedText, chatID: message.chat.id)
            return
        }

        guard let audioAttachment else {
            await renderHomeMenu(chatID: message.chat.id, notice: TelegramAudioRoutingError.unsupportedAttachment.localizedDescription)
            await refreshSelectedSessionView(chatID: message.chat.id, force: true)
            return
        }

        await handle(audioAttachment: audioAttachment, chatID: message.chat.id)
    }

    private func handle(callbackQuery: TelegramCallbackQuery) async {
        guard let chat = callbackQuery.message?.chat else {
            _ = try? await client?.answerCallbackQuery(
                callbackQueryID: callbackQuery.id,
                text: "This action is no longer available."
            )
            return
        }

        guard settings != nil else { return }
        guard isAuthorized(user: callbackQuery.from, chat: chat) else {
            _ = try? await client?.answerCallbackQuery(
                callbackQueryID: callbackQuery.id,
                text: "This chat is not approved.",
                showAlert: true
            )
            return
        }

        guard let data = callbackQuery.data else {
            _ = try? await client?.answerCallbackQuery(
                callbackQueryID: callbackQuery.id,
                text: "That button no longer works."
            )
            return
        }

        do {
            switch data {
            case "menu:projects":
                chatState.projectMenuFolderID = nil
                await renderProjectMenu(chatID: chat.id)
            case "menu:sessions":
                await renderSessionMenu(chatID: chat.id)
            case "menu:backend":
                await renderBackendMenu(chatID: chat.id)
            case "menu:models":
                await renderModelMenu(chatID: chat.id)
            case "menu:mode":
                await renderModeMenu(chatID: chat.id)
            case "menu:effort":
                await renderEffortMenu(chatID: chat.id)
            case "nav:home":
                await renderHomeMenu(chatID: chat.id, notice: nil)
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            case "nav:projects-root":
                chatState.projectMenuFolderID = nil
                await renderProjectMenu(chatID: chat.id)
            case "act:new":
                await startFreshSession(chatID: chat.id, isTemporary: false, moveControllerToBottom: false)
            case "act:clear":
                await clearChatWindow(chatID: chat.id)
            case "act:temp":
                await startFreshSession(chatID: chat.id, isTemporary: true, moveControllerToBottom: false)
            case "act:keep":
                await keepSelectedTemporarySession(chatID: chat.id)
            case "act:refresh":
                await renderHomeMenu(chatID: chat.id, notice: "Refreshed the active session view.")
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            case "act:usage":
                await renderHomeMenu(chatID: chat.id, notice: await usageSummaryText())
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            case "act:provider":
                await renderHomeMenu(chatID: chat.id, notice: await providerUsageSummaryText())
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            case "act:stop":
                await bridge.cancelActiveTurn()
                await renderHomeMenu(chatID: chat.id, notice: "Stopped the current turn.")
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            case let data where data.hasPrefix("sel:s:"):
                try await handleSessionSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("sel:p:"):
                try await handleProjectSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("nav:projects-folder:"):
                chatState.projectMenuFolderID = data.replacingOccurrences(of: "nav:projects-folder:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                await renderProjectMenu(chatID: chat.id)
            case let data where data.hasPrefix("sel:backend:"):
                try await handleBackendSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("sel:m:"):
                try await handleModelSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("sel:mode:"):
                try await handleModeSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("sel:eff:"):
                try await handleEffortSelection(data: data, chatID: chat.id)
            case let data where data.hasPrefix("perm:o:"):
                try await handlePermissionOption(data: data, chatID: chat.id)
            case let data where data.hasPrefix("perm:q:"):
                try await handleStructuredQuestionOption(data: data, chatID: chat.id)
            case "perm:other":
                try await handleStructuredOther(chatID: chat.id)
            case "perm:cancel":
                await bridge.cancelPendingPermissionRequest()
                chatState.resetStructuredInput()
                await refreshSelectedSessionView(chatID: chat.id, force: true)
            default:
                _ = try? await client?.answerCallbackQuery(
                    callbackQueryID: callbackQuery.id,
                    text: "That button is no longer available."
                )
                return
            }

            _ = try? await client?.answerCallbackQuery(callbackQueryID: callbackQuery.id)
        } catch {
            _ = try? await client?.answerCallbackQuery(
                callbackQueryID: callbackQuery.id,
                text: error.localizedDescription,
                showAlert: true
            )
        }
    }

    private func handle(command: String, rawText: String, chatID: Int64) async {
        switch command {
        case "/start", "/help":
            await ensureDefaultSelectedSession()
            await moveControllerMessageToBottom(chatID: chatID)
            await renderHomeMenu(chatID: chatID, notice: helpText())
            await refreshSelectedSessionView(chatID: chatID, force: true)
        case "/new":
            await startFreshSession(chatID: chatID, isTemporary: false, moveControllerToBottom: true)
        case "/clear":
            await clearChatWindow(chatID: chatID)
        case "/temp":
            await startFreshSession(chatID: chatID, isTemporary: true, moveControllerToBottom: true)
        case "/projects":
            await moveControllerMessageToBottom(chatID: chatID)
            chatState.projectMenuFolderID = nil
            await renderProjectMenu(chatID: chatID)
        case "/sessions":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderSessionMenu(chatID: chatID)
        case "/backend":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderBackendMenu(chatID: chatID)
        case "/models":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderModelMenu(chatID: chatID)
        case "/mode":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderModeMenu(chatID: chatID)
        case "/effort":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderEffortMenu(chatID: chatID)
        case "/usage":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderHomeMenu(chatID: chatID, notice: await usageSummaryText())
            await refreshSelectedSessionView(chatID: chatID, force: true)
        case "/status":
            await moveControllerMessageToBottom(chatID: chatID)
            await renderHomeMenu(chatID: chatID, notice: await statusSummaryText())
            await refreshSelectedSessionView(chatID: chatID, force: true)
        case "/stop":
            await bridge.cancelActiveTurn()
            await moveControllerMessageToBottom(chatID: chatID)
            await renderHomeMenu(chatID: chatID, notice: "Stopped the current turn.")
            await refreshSelectedSessionView(chatID: chatID, force: true)
        default:
            _ = try? await sendTelegramMessage(
                chatID: chatID,
                text: "Unknown command. Use /help to see the main actions."
            )
        }
    }

    private func handlePendingPairing(text _: String, message: TelegramMessage) async {
        guard let settings else { return }

        guard !settings.hasTelegramPendingPairing else {
            _ = try? await sendTelegramMessage(
                chatID: message.chat.id,
                text: """
                An approval request is already pending on the Mac.

                Please wait for the owner to approve or reject it.
                """
            )
            return
        }

        settings.updateTelegramPendingPairing(
            userID: String(message.from?.id ?? message.chat.id),
            chatID: String(message.chat.id),
            displayName: message.from?.displayName ?? displayName(for: message.chat)
        )
        updatePairingStatus(using: settings)

        _ = try? await sendTelegramMessage(
            chatID: message.chat.id,
            text: """
            Pairing request received.

            Open Open Assist on your Mac, go to Settings > Integrations > Telegram Remote, and approve this chat.
            """
        )
    }

    private func ensureDefaultSelectedSession() async {
        if chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return
        }

        await applySelectedProjectFilter()
        let selectedSessionID = bridge.statusSnapshot().selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedSessionID, !selectedSessionID.isEmpty {
            chatState.selectedSessionID = selectedSessionID
            return
        }

        let sessions = await bridge.listSessions(limit: 1, projectID: chatState.selectedProjectID)
        chatState.selectedSessionID = sessions.first?.id
    }

    private func startFreshSession(
        chatID: Int64,
        isTemporary: Bool,
        moveControllerToBottom: Bool
    ) async {
        await applySelectedProjectFilter()
        let snapshot: AssistantRemoteSessionSnapshot?
        if isTemporary {
            snapshot = await bridge.startNewTemporarySession()
        } else {
            snapshot = await bridge.startNewSession()
        }
        chatState.switchSessionView(to: snapshot?.session.id ?? bridge.statusSnapshot().selectedSessionID)
        await clearTrackedChatHistory(chatID: chatID)
        if moveControllerToBottom {
            await moveControllerMessageToBottom(chatID: chatID)
        }
        await renderHomeMenu(
            chatID: chatID,
            notice: isTemporary ? "Started a temporary chat." : "Started a new session."
        )
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func keepSelectedTemporarySession(chatID: Int64) async {
        let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedSessionID, !selectedSessionID.isEmpty else {
            await renderHomeMenu(chatID: chatID, notice: "No session is selected right now.")
            await refreshSelectedSessionView(chatID: chatID, force: true)
            return
        }

        let promoted = await bridge.promoteTemporarySession(sessionID: selectedSessionID)
        await renderHomeMenu(
            chatID: chatID,
            notice: promoted ? "Kept this chat as a regular session." : "This chat is already a regular session."
        )
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func clearChatWindow(chatID: Int64) async {
        let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        await clearTrackedChatHistory(chatID: chatID)
        chatState.switchSessionView(
            to: selectedSessionID,
            showTranscriptPreview: false
        )
        await renderHomeMenu(
            chatID: chatID,
            notice: "Screen cleared. This keeps only one fresh Telegram card here."
        )
    }

    private func sendPrompt(
        _ text: String,
        chatID: Int64,
        successNotice: String = "Message sent to the active session."
    ) async {
        await applySelectedProjectFilter()

        if slot(for: .transcript).messageID != nil {
            await clearSlot(chatID: chatID, kind: .transcript)
        }
        detachSlot(.stream)

        let selectedSessionID = chatState.selectedSessionID
        let snapshot = await bridge.sendPrompt(text, sessionID: selectedSessionID)
        chatState.switchSessionView(
            to: snapshot?.session.id ?? bridge.statusSnapshot().selectedSessionID,
            showTranscriptPreview: false
        )
        await renderHomeMenu(chatID: chatID, notice: successNotice)
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handle(audioAttachment: TelegramAudioAttachment, chatID: Int64) async {
        guard let client, let settings else { return }

        do {
            await renderHomeMenu(chatID: chatID, notice: "Downloading the \(audioAttachment.kindDescription) from Telegram…")
            _ = try? await client.sendChatAction(chatID: chatID, action: "typing")

            let telegramFile = try await client.getFile(fileID: audioAttachment.fileID)
            guard let filePath = telegramFile.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !filePath.isEmpty else {
                throw TelegramAudioRoutingError.fileUnavailable
            }

            let knownFileSize = audioAttachment.fileSize ?? telegramFile.fileSize
            if let knownFileSize, knownFileSize > Self.telegramDownloadLimitBytes {
                throw TelegramAudioRoutingError.fileTooLarge
            }

            let fileData = try await client.downloadFile(filePath: filePath)
            if fileData.count > Self.telegramDownloadLimitBytes {
                throw TelegramAudioRoutingError.fileTooLarge
            }

            await renderHomeMenu(chatID: chatID, notice: "Transcribing the \(audioAttachment.kindDescription)…")
            let configuration = try makeTelegramTranscriptionConfiguration(using: settings)
            let transcript = try await transcriptionService.transcribe(
                upload: AudioTranscriptionUpload(
                    fileData: fileData,
                    fileName: audioAttachment.fileName,
                    mimeType: audioAttachment.mimeType
                ),
                configuration: configuration
            )
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                throw TelegramAudioRoutingError.emptyTranscript
            }

            await sendPrompt(
                trimmedTranscript,
                chatID: chatID,
                successNotice: "Transcribed the \(audioAttachment.kindDescription) and sent it to the active session."
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await renderHomeMenu(chatID: chatID, notice: "Audio transcription failed: \(message)")
            await refreshSelectedSessionView(chatID: chatID, force: true)
        }
    }

    private func makeTelegramTranscriptionConfiguration(
        using settings: SettingsStore
    ) throws -> AudioTranscriptionRequestConfiguration {
        let provider = settings.cloudTranscriptionProvider
        let model = settings.cloudTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = settings.cloudTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (
            provider == .gemini
                ? settings.googleAIStudioAPIKey
                : settings.cloudTranscriptionAPIKey
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if provider.requiresAPIKey && apiKey.isEmpty {
            let guidance = provider == .gemini
                ? "Open AI Studio and add a Google AI Studio API key before using Telegram audio transcription with Gemini."
                : "Open Settings > Recognition and add a \(provider.displayName) API key before using Telegram audio transcription."
            throw TelegramAudioRoutingError.missingCredentials(guidance)
        }

        return AudioTranscriptionRequestConfiguration(
            provider: provider,
            model: model.isEmpty ? provider.defaultModel : model,
            baseURL: baseURL.isEmpty ? provider.defaultBaseURL : baseURL,
            apiKey: apiKey,
            requestTimeoutSeconds: settings.cloudTranscriptionRequestTimeoutSeconds,
            biasPhrases: []
        )
    }

    private func telegramMessageIncludesMedia(_ message: TelegramMessage) -> Bool {
        message.voice != nil || message.audio != nil || message.document != nil
    }

    private func telegramAudioAttachment(from message: TelegramMessage) -> TelegramAudioAttachment? {
        if let voice = message.voice {
            let fileName = "telegram-voice-\(message.messageID).ogg"
            return TelegramAudioAttachment(
                fileID: voice.fileID,
                fileName: fileName,
                mimeType: resolvedAudioMimeType(rawValue: voice.mimeType, fileName: fileName, fallback: "audio/ogg"),
                fileSize: voice.fileSize,
                kindDescription: "voice note"
            )
        }

        if let audio = message.audio {
            let fileName = normalizedAudioFileName(
                rawValue: audio.fileName,
                fallback: "telegram-audio-\(message.messageID).m4a"
            )
            return TelegramAudioAttachment(
                fileID: audio.fileID,
                fileName: fileName,
                mimeType: resolvedAudioMimeType(rawValue: audio.mimeType, fileName: fileName, fallback: "audio/m4a"),
                fileSize: audio.fileSize,
                kindDescription: "audio file"
            )
        }

        if let document = message.document, isSupportedAudioDocument(document) {
            let fileName = normalizedAudioFileName(
                rawValue: document.fileName,
                fallback: "telegram-audio-\(message.messageID).bin"
            )
            return TelegramAudioAttachment(
                fileID: document.fileID,
                fileName: fileName,
                mimeType: resolvedAudioMimeType(rawValue: document.mimeType, fileName: fileName, fallback: "application/octet-stream"),
                fileSize: document.fileSize,
                kindDescription: "audio file"
            )
        }

        return nil
    }

    private func isSupportedAudioDocument(_ document: TelegramDocument) -> Bool {
        let normalizedMimeType = document.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedMimeType, normalizedMimeType.hasPrefix("audio/") {
            return true
        }
        if let normalizedMimeType, Self.supportedAudioMIMETypes.contains(normalizedMimeType) {
            return true
        }
        let fileExtension = document.fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .last?
            .lowercased()
        if let fileExtension, Self.supportedAudioFileExtensions.contains(fileExtension) {
            return true
        }
        return false
    }

    private func normalizedAudioFileName(rawValue: String?, fallback: String) -> String {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }

    private func resolvedAudioMimeType(rawValue: String?, fileName: String, fallback: String) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }

        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        if !fileExtension.isEmpty,
           let inferredMimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType,
           !inferredMimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inferredMimeType
        }

        return fallback
    }

    private func renderHomeMenu(chatID: Int64, notice: String?) async {
        let status = await telegramSessionContext()
        let projectName = await currentProjectName()
        let selectedSessionLine = formattedSelectedSessionLine(
            sessionID: status.selectedSessionID,
            title: status.selectedSessionTitle,
            isTemporary: status.selectedSessionIsTemporary
        )

        var lines = [
            "Open Assist Telegram Remote",
            "",
            "Project: \(projectName ?? "All projects")",
            "Session: \(selectedSessionLine)",
            "Backend: \(status.assistantBackendName)"
        ]

        if status.selectedSessionIsTemporary {
            lines.append("Type: Temporary chat")
        }

        if let notice, !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append(notice)
        } else if status.selectedSessionID == nil {
            lines.append("")
            lines.append("Send a message, tap New, or tap Temp to start.")
        }

        var rows: [[TelegramInlineKeyboardButton]] = [
            [
                .init(text: "Projects", callbackData: "menu:projects"),
                .init(text: "Sessions", callbackData: "menu:sessions")
            ],
            [
                .init(text: "New", callbackData: "act:new"),
                .init(text: "Temp", callbackData: "act:temp")
            ],
            [
                .init(text: "Clear", callbackData: "act:clear")
            ],
            [
                .init(text: "Backend", callbackData: "menu:backend"),
                .init(text: "Models", callbackData: "menu:models")
            ],
            [
                .init(text: "Mode", callbackData: "menu:mode"),
                .init(text: "Effort", callbackData: "menu:effort")
            ],
            [
                .init(text: "Usage", callbackData: "act:usage"),
                .init(text: "Provider", callbackData: "act:provider")
            ],
            [
                .init(text: "Refresh", callbackData: "act:refresh"),
                .init(text: "Stop", callbackData: "act:stop")
            ]
        ]

        if status.selectedSessionIsTemporary {
            rows.insert([.init(text: "Keep Chat", callbackData: "act:keep")], at: 2)
        }

        let markup = TelegramInlineKeyboardMarkup(inlineKeyboard: rows)

        chatState.controllerMenu = .home
        let text = lines.joined(separator: "\n")
        let signature = "home:\(text)"
        await upsertControllerMessage(chatID: chatID, text: text, signature: signature, markup: markup)
    }

    private func renderProjectMenu(chatID: Int64) async {
        let projects = await bridge.availableProjects()
        chatState.projectMenuProjectIDs = projects.map(\.id)
        chatState.controllerMenu = .projects
        let rootFolders = projects.filter { $0.kind == .folder && $0.parentID == nil }
        let rootProjects = projects.filter { $0.kind == .project && $0.parentID == nil }

        var rows: [[TelegramInlineKeyboardButton]] = []
        let text: String

        if let folderID = chatState.projectMenuFolderID,
           let folder = projects.first(where: { $0.id.caseInsensitiveCompare(folderID) == .orderedSame }) {
            let childProjects = projects.filter {
                $0.kind == .project && $0.parentID?.caseInsensitiveCompare(folder.id) == .orderedSame
            }

            rows.append([
                .init(
                    text: chatState.selectedProjectID?.caseInsensitiveCompare(folder.id) == .orderedSame
                        ? "• All in \(folder.name) (\(folder.sessionCount))"
                        : "All in \(folder.name) (\(folder.sessionCount))",
                    callbackData: "sel:p:\(folder.id)"
                )
            ])

            rows += childProjects.map { project in
                let label = "\(project.name) (\(project.sessionCount))"
                return [
                    TelegramInlineKeyboardButton(
                        text: project.id.caseInsensitiveCompare(chatState.selectedProjectID ?? "") == .orderedSame
                            ? "• \(label)"
                            : label,
                        callbackData: "sel:p:\(project.id)"
                    )
                ]
            }
            rows.append([.init(text: "Back to Projects", callbackData: "nav:projects-root")])
            rows.append([.init(text: "Back", callbackData: "nav:home")])

            text = childProjects.isEmpty
                ? "\(folder.name) does not have any projects yet. You can still choose all chats in this group, or go back."
                : "Choose all chats in the group \(folder.name), or pick one project inside it."
        } else {
            rows.append([
                .init(
                    text: chatState.selectedProjectID == nil ? "• All projects" : "All projects",
                    callbackData: "sel:p:all"
                )
            ])

            rows += rootFolders.flatMap { folder in
                let label = "\(folder.name) (\(folder.sessionCount))"
                return [[
                    TelegramInlineKeyboardButton(
                        text: chatState.selectedProjectID?.caseInsensitiveCompare(folder.id) == .orderedSame
                            ? "• \(label)"
                            : label,
                        callbackData: "sel:p:\(folder.id)"
                    ),
                    TelegramInlineKeyboardButton(
                        text: "Open",
                        callbackData: "nav:projects-folder:\(folder.id)"
                    )
                ]]
            }

            rows += rootProjects.map { project in
                let label = "\(project.name) (\(project.sessionCount))"
                return [
                    TelegramInlineKeyboardButton(
                        text: project.id.caseInsensitiveCompare(chatState.selectedProjectID ?? "") == .orderedSame
                            ? "• \(label)"
                            : label,
                        callbackData: "sel:p:\(project.id)"
                    )
                ]
            }
            rows.append([.init(text: "Back", callbackData: "nav:home")])

            text = projects.isEmpty
                ? "No projects yet. You can still use /new or /temp to start an ungrouped session."
                : "Choose all chats, a group, or a project. Open a group to see the projects inside it."
        }

        await upsertControllerMessage(
            chatID: chatID,
            text: text,
            signature: "projects:\(chatState.projectMenuFolderID ?? "root"):\(projects.map(\.id).joined(separator: ",")):\(chatState.selectedProjectID ?? "all")",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    private func renderSessionMenu(chatID: Int64) async {
        let sessions = await bridge.listSessions(limit: 8, projectID: chatState.selectedProjectID)
        chatState.sessionMenuSessionIDs = sessions.map(\.id)
        chatState.controllerMenu = .sessions

        var rows = sessions.enumerated().map { index, session in
            [TelegramInlineKeyboardButton(
                text: TelegramRemoteRenderer.sessionMenuLabel(
                    session,
                    isSelected: session.id.caseInsensitiveCompare(chatState.selectedSessionID ?? "") == .orderedSame
                ),
                callbackData: "sel:s:\(index)"
            )]
        }
        rows.append([.init(text: "Back", callbackData: "nav:home")])

        let text: String
        if sessions.isEmpty {
            if let projectName = await currentProjectName() {
                text = "No sessions found inside \(projectName). Tap Back and use New or Temp to start one there."
            } else {
                text = "No sessions yet. Tap Back, use New or Temp, or send a message to start a regular session."
            }
        } else {
            if let projectName = await currentProjectName() {
                text = "Choose a session inside \(projectName). Telegram will remove the current session view and load only the thread you select."
            } else {
                text = "Choose a session. Telegram will remove the current session view and load only the session you select."
            }
        }

        await upsertControllerMessage(
            chatID: chatID,
            text: text,
            signature: "sessions:\(sessions.map { "\($0.id)|\($0.title)|\($0.isTemporary)" }.joined(separator: ",")):\(chatState.selectedSessionID ?? "")",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    private func renderBackendMenu(chatID: Int64) async {
        chatState.controllerMenu = .backend
        let status = await telegramSessionContext()
        let rows = bridge.availableBackends().map { backend in
            [TelegramInlineKeyboardButton(
                text: backend == status.assistantBackend ? "• \(backend.displayName)" : backend.displayName,
                callbackData: "sel:backend:\(backend.rawValue)"
            )]
        } + [[.init(text: "Back", callbackData: "nav:home")]]

        await upsertControllerMessage(
            chatID: chatID,
            text: "Choose which assistant backend Telegram should drive for this app.",
            signature: "backend:\(status.assistantBackend.rawValue)",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    private func renderModelMenu(chatID: Int64) async {
        let models = await bridge.availableModels()
        chatState.modelMenuModelIDs = models.map(\.id)
        chatState.controllerMenu = .models
        let selectedModelID = await telegramSessionContext().selectedModelID

        var rows = models.enumerated().map { index, model in
            [TelegramInlineKeyboardButton(
                text: model.id == selectedModelID ? "• \(model.displayName)" : model.displayName,
                callbackData: "sel:m:\(index)"
            )]
        }
        rows.append([.init(text: "Back", callbackData: "nav:home")])

        let text = models.isEmpty
            ? "No models are available yet. Connect a provider or choose a model in Open Assist first."
            : "Choose the model for the active session."
        await upsertControllerMessage(
            chatID: chatID,
            text: text,
            signature: "models:\(models.map(\.id).joined(separator: ",")):\(selectedModelID ?? "")",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    private func renderModeMenu(chatID: Int64) async {
        chatState.controllerMenu = .mode
        let selectedMode = await telegramSessionContext().interactionMode
        let rows: [[TelegramInlineKeyboardButton]] = [
            [
                .init(
                    text: selectedMode == .plan ? "• Plan" : "Plan",
                    callbackData: "sel:mode:plan"
                )
            ],
            [
                .init(
                    text: selectedMode == .agentic ? "• Agentic" : "Agentic",
                    callbackData: "sel:mode:agentic"
                )
            ],
            [.init(text: "Back", callbackData: "nav:home")]
        ]
        await upsertControllerMessage(
            chatID: chatID,
            text: "Choose the mode for the active session.",
            signature: "mode:\(selectedMode.rawValue)",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    private func renderEffortMenu(chatID: Int64) async {
        chatState.controllerMenu = .effort
        let status = await telegramSessionContext()
        let selectedEffort = status.reasoningEffort
        var rows: [[TelegramInlineKeyboardButton]] = []
        if status.canAdjustReasoningEffort {
            rows = status.supportedReasoningEfforts.map { effort in
                [TelegramInlineKeyboardButton(
                    text: effort == selectedEffort ? "• \(effort.label)" : effort.label,
                    callbackData: "sel:eff:\(effort.rawValue)"
                )]
            }
        }
        rows.append([.init(text: "Back", callbackData: "nav:home")])
        let text: String
        if status.canAdjustReasoningEffort {
            text = "Choose the reasoning effort for the active session."
        } else {
            text = "\(status.assistantBackendName) does not expose adjustable reasoning effort for the active model in Telegram right now. Current effort: \(selectedEffort.label)."
        }
        await upsertControllerMessage(
            chatID: chatID,
            text: text,
            signature: "effort:\(status.assistantBackend.rawValue):\(selectedEffort.rawValue):\(status.supportedReasoningEfforts.map(\.rawValue).joined(separator: ",")):\(status.canAdjustReasoningEffort)",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows)
        )
    }

    @discardableResult
    private func refreshSelectedSessionView(chatID: Int64, force: Bool = false) async -> AssistantRemoteSessionSnapshot? {
        guard let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedSessionID.isEmpty else {
            if force {
                chatState.invalidateSessionView()
                await clearSessionView(chatID: chatID)
            }
            return nil
        }

        let expectedGeneration = chatState.viewGeneration
        guard let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID) else {
            chatState.switchSessionView(to: nil)
            await clearSessionView(chatID: chatID)
            await renderHomeMenu(chatID: chatID, notice: "The selected session is no longer available.")
            return nil
        }
        guard expectedGeneration == chatState.viewGeneration,
              chatState.selectedSessionID?.caseInsensitiveCompare(selectedSessionID) == .orderedSame else {
            return snapshot
        }

        await upsertViewSlot(
            chatID: chatID,
            kind: .header,
            text: TelegramRemoteRenderer.sessionHeaderText(snapshot: snapshot),
            signaturePrefix: "header",
            markup: snapshot.session.isTemporary
                ? TelegramInlineKeyboardMarkup(inlineKeyboard: [[
                    .init(text: "Keep Chat", callbackData: "act:keep")
                ]])
                : nil,
            expectedGeneration: expectedGeneration
        )

        if chatState.shouldShowTranscriptPreview,
           let catchUpText = TelegramRemoteRenderer.catchUpText(snapshot: snapshot) {
            await upsertViewSlot(
                chatID: chatID,
                kind: .transcript,
                text: catchUpText,
                signaturePrefix: "transcript",
                expectedGeneration: expectedGeneration
            )
        } else if slot(for: .transcript).messageID != nil, !chatState.shouldShowTranscriptPreview {
            await clearSlot(chatID: chatID, kind: .transcript)
        }

        if let streamPresentation = TelegramRemoteRenderer.streamPresentation(snapshot: snapshot) {
            let renderedChunks = renderedMessageChunks(streamPresentation.text)
            let firstChunk = renderedChunks.first ?? renderedSingleMessage(streamPresentation.text)
            await upsertViewSlot(
                chatID: chatID,
                kind: .stream,
                rendered: firstChunk,
                signaturePrefix: "\(streamPresentation.signaturePrefix):\(firstChunk.visibleSignature)",
                expectedGeneration: expectedGeneration
            )
            if streamPresentation.allowsOverflow {
                await syncReplyOverflowMessages(
                    chatID: chatID,
                    chunks: Array(renderedChunks.dropFirst()),
                    signaturePrefix: streamPresentation.signaturePrefix,
                    expectedGeneration: expectedGeneration
                )
            } else {
                await clearReplyOverflowMessages(chatID: chatID)
            }
        } else if slot(for: .stream).messageID != nil {
            await clearSlot(chatID: chatID, kind: .stream)
            await clearReplyOverflowMessages(chatID: chatID)
        }

        if let request = snapshot.pendingPermissionRequest {
            await renderPermissionMessage(request, chatID: chatID, expectedGeneration: expectedGeneration)
        } else if slot(for: .permission).messageID != nil {
            chatState.resetStructuredInput()
            await clearSlot(chatID: chatID, kind: .permission)
        }

        if let imageDelivery = snapshot.imageDelivery {
            await deliverImageDelivery(
                imageDelivery,
                sessionTitle: snapshot.session.title,
                chatID: chatID,
                expectedGeneration: expectedGeneration
            )
        }

        return snapshot
    }

    private func renderPermissionMessage(
        _ request: AssistantPermissionRequest,
        chatID: Int64,
        expectedGeneration: Int
    ) async {
        if request.hasStructuredUserInput {
            await renderStructuredQuestion(request, chatID: chatID, expectedGeneration: expectedGeneration)
            return
        }

        let rows = request.options.enumerated().map { index, option in
            [TelegramInlineKeyboardButton(text: option.title, callbackData: "perm:o:\(index)")]
        }
        await upsertViewSlot(
            chatID: chatID,
            kind: .permission,
            text: TelegramRemoteRenderer.permissionText(request),
            signaturePrefix: "perm:\(request.id)",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows),
            expectedGeneration: expectedGeneration
        )
    }

    private func renderStructuredQuestion(
        _ request: AssistantPermissionRequest,
        chatID: Int64,
        expectedGeneration: Int? = nil
    ) async {
        let expectedGeneration = expectedGeneration ?? chatState.viewGeneration
        let questionIndex = min(chatState.structuredQuestionIndex, max(request.userInputQuestions.count - 1, 0))
        let question = request.userInputQuestions[questionIndex]
        var rows = question.options.enumerated().map { index, option in
            [TelegramInlineKeyboardButton(text: option.label, callbackData: "perm:q:\(index)")]
        }
        if question.allowsCustomAnswer {
            rows.append([.init(text: "Other", callbackData: "perm:other")])
        }
        rows.append([.init(text: "Cancel", callbackData: "perm:cancel")])

        var text = """
        Open Assist needs your answer to continue.

        \(question.header)
        \(question.prompt)
        """
        if chatState.awaitingCustomAnswerQuestionID == question.id {
            text += "\n\nReply with your custom answer in the next message."
        }

        await upsertViewSlot(
            chatID: chatID,
            kind: .permission,
            text: text,
            signaturePrefix: "structured:\(request.id):\(question.id):\(chatState.awaitingCustomAnswerQuestionID ?? "")",
            markup: TelegramInlineKeyboardMarkup(inlineKeyboard: rows),
            expectedGeneration: expectedGeneration
        )
    }

    private func continueStructuredInput(chatID: Int64) async {
        guard let selectedSessionID = chatState.selectedSessionID,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID),
              let request = snapshot.pendingPermissionRequest,
              request.hasStructuredUserInput else {
            chatState.resetStructuredInput()
            return
        }

        let answeredCount = request.userInputQuestions.filter {
            chatState.structuredAnswers[$0.id]?.isEmpty == false
        }.count

        if answeredCount >= request.userInputQuestions.count {
            let answers = chatState.structuredAnswers
            chatState.resetStructuredInput()
            await bridge.resolvePermission(answers: answers)
            await refreshSelectedSessionView(chatID: chatID, force: true)
            return
        }

        chatState.structuredQuestionIndex = answeredCount
        await renderStructuredQuestion(request, chatID: chatID)
    }

    private func handleSessionSelection(data: String, chatID: Int64) async throws {
        let rawIndex = data.replacingOccurrences(of: "sel:s:", with: "")
        guard let index = Int(rawIndex), chatState.sessionMenuSessionIDs.indices.contains(index) else {
            throw TelegramBotClientError.server(message: "That session button expired. Open /sessions again.")
        }

        let sessionID = chatState.sessionMenuSessionIDs[index]
        chatState.switchSessionView(to: sessionID)
        await clearTrackedChatHistory(chatID: chatID)
        _ = await bridge.openSession(sessionID: sessionID)
        await renderHomeMenu(chatID: chatID, notice: "Switched sessions.")
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleProjectSelection(data: String, chatID: Int64) async throws {
        let selectedProjectID: String?
        if data == "sel:p:all" {
            selectedProjectID = nil
        } else {
            let projectID = data.replacingOccurrences(of: "sel:p:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty else {
                throw TelegramBotClientError.server(message: "That project button expired. Open /projects again.")
            }
            selectedProjectID = projectID
        }

        chatState.selectedProjectID = selectedProjectID
        await applySelectedProjectFilter()
        let sessions = await bridge.listSessions(limit: 1, projectID: selectedProjectID)
        let previousSessionID = chatState.selectedSessionID
        let nextSessionID: String?
        if let currentSessionID = chatState.selectedSessionID,
           sessions.contains(where: { $0.id.caseInsensitiveCompare(currentSessionID) == .orderedSame }) {
            nextSessionID = currentSessionID
        } else {
            nextSessionID = sessions.first?.id
        }

        chatState.switchSessionView(to: nextSessionID)
        if previousSessionID?.caseInsensitiveCompare(nextSessionID ?? "") != .orderedSame
            || selectedProjectID != nil {
            await clearTrackedChatHistory(chatID: chatID)
        } else {
            await clearSessionView(chatID: chatID)
        }
        await renderHomeMenu(
            chatID: chatID,
            notice: selectedProjectID == nil ? "Showing all chats." : "Filter updated."
        )
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleModelSelection(data: String, chatID: Int64) async throws {
        let rawIndex = data.replacingOccurrences(of: "sel:m:", with: "")
        guard let index = Int(rawIndex), chatState.modelMenuModelIDs.indices.contains(index) else {
            throw TelegramBotClientError.server(message: "That model button expired. Open /models again.")
        }
        let modelID = chatState.modelMenuModelIDs[index]
        guard await bridge.chooseModel(modelID, sessionID: chatState.selectedSessionID) else {
            throw TelegramBotClientError.server(message: "That model is no longer available.")
        }
        await renderHomeMenu(chatID: chatID, notice: "Updated the model.")
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleBackendSelection(data: String, chatID: Int64) async throws {
        let rawValue = data.replacingOccurrences(of: "sel:backend:", with: "")
        guard let backend = AssistantRuntimeBackend(rawValue: rawValue) else {
            throw TelegramBotClientError.server(message: "That backend is no longer supported.")
        }

        let changed = await bridge.selectBackend(backend)
        chatState.switchSessionView(to: bridge.statusSnapshot().selectedSessionID)
        await clearTrackedChatHistory(chatID: chatID)
        await renderHomeMenu(
            chatID: chatID,
            notice: changed
                ? "Switched the assistant backend to \(backend.displayName)."
                : "\(backend.displayName) is already active."
        )
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleModeSelection(data: String, chatID: Int64) async throws {
        let rawValue = data.replacingOccurrences(of: "sel:mode:", with: "")
        guard let mode = AssistantInteractionMode(rawValue: rawValue)?.normalizedForActiveUse else {
            throw TelegramBotClientError.server(message: "That mode is not supported.")
        }
        await bridge.setInteractionMode(mode, sessionID: chatState.selectedSessionID)
        await renderHomeMenu(chatID: chatID, notice: "Updated the mode.")
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleEffortSelection(data: String, chatID: Int64) async throws {
        let rawValue = data.replacingOccurrences(of: "sel:eff:", with: "")
        guard let effort = AssistantReasoningEffort(rawValue: rawValue) else {
            throw TelegramBotClientError.server(message: "That effort value is not supported.")
        }
        let status = await telegramSessionContext()
        guard status.canAdjustReasoningEffort else {
            throw TelegramBotClientError.server(
                message: "\(status.assistantBackendName) does not expose adjustable reasoning effort for the active model."
            )
        }
        guard status.supportedReasoningEfforts.contains(effort) else {
            throw TelegramBotClientError.server(message: "That effort is not available for the current model.")
        }
        await bridge.setReasoningEffort(effort, sessionID: chatState.selectedSessionID)
        await renderHomeMenu(chatID: chatID, notice: "Updated the reasoning effort.")
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handlePermissionOption(data: String, chatID: Int64) async throws {
        guard let selectedSessionID = chatState.selectedSessionID,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID),
              let request = snapshot.pendingPermissionRequest else {
            throw TelegramBotClientError.server(message: "There is no active approval request.")
        }

        let rawIndex = data.replacingOccurrences(of: "perm:o:", with: "")
        guard let index = Int(rawIndex), request.options.indices.contains(index) else {
            throw TelegramBotClientError.server(message: "That approval option is no longer available.")
        }

        await bridge.resolvePermission(optionID: request.options[index].id)
        await refreshSelectedSessionView(chatID: chatID, force: true)
    }

    private func handleStructuredQuestionOption(data: String, chatID: Int64) async throws {
        guard let selectedSessionID = chatState.selectedSessionID,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID),
              let request = snapshot.pendingPermissionRequest,
              request.hasStructuredUserInput else {
            throw TelegramBotClientError.server(message: "There is no active question right now.")
        }

        let rawIndex = data.replacingOccurrences(of: "perm:q:", with: "")
        guard let optionIndex = Int(rawIndex),
              request.userInputQuestions.indices.contains(chatState.structuredQuestionIndex) else {
            throw TelegramBotClientError.server(message: "That question is no longer active.")
        }

        let question = request.userInputQuestions[chatState.structuredQuestionIndex]
        guard question.options.indices.contains(optionIndex) else {
            throw TelegramBotClientError.server(message: "That answer is no longer available.")
        }

        chatState.structuredAnswers[question.id] = [question.options[optionIndex].label]
        chatState.awaitingCustomAnswerQuestionID = nil
        chatState.structuredQuestionIndex += 1
        await continueStructuredInput(chatID: chatID)
    }

    private func handleStructuredOther(chatID: Int64) async throws {
        guard let selectedSessionID = chatState.selectedSessionID,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID),
              let request = snapshot.pendingPermissionRequest,
              request.hasStructuredUserInput,
              request.userInputQuestions.indices.contains(chatState.structuredQuestionIndex) else {
            throw TelegramBotClientError.server(message: "There is no active question right now.")
        }

        let question = request.userInputQuestions[chatState.structuredQuestionIndex]
        guard question.allowsCustomAnswer else {
            throw TelegramBotClientError.server(message: "This question only supports the listed choices.")
        }

        chatState.awaitingCustomAnswerQuestionID = question.id
        await renderStructuredQuestion(request, chatID: chatID)
    }

    private func clearSessionView(chatID: Int64) async {
        await clearSlot(chatID: chatID, kind: .header)
        await clearSlot(chatID: chatID, kind: .transcript)
        await clearSlot(chatID: chatID, kind: .stream)
        await clearSlot(chatID: chatID, kind: .permission)
        await clearReplyOverflowMessages(chatID: chatID)
        await clearImageMessages(chatID: chatID)
        chatState.resetSessionView()
    }

    private func trackMessageID(_ messageID: Int) {
        chatState.trackMessage(messageID)
        settings?.telegramTrackedMessageIDs = chatState.trackedMessageIDs
    }

    private func forgetMessageID(_ messageID: Int) {
        chatState.forgetMessage(messageID)
        settings?.telegramTrackedMessageIDs = chatState.trackedMessageIDs
    }

    private func clearTrackedChatHistory(chatID: Int64) async {
        let messageIDs = Array(Set(chatState.trackedMessageIDs)).sorted()
        guard !messageIDs.isEmpty else {
            chatState.clearTrackedPresentationState()
            settings?.telegramTrackedMessageIDs = []
            shouldClearRecoveredChatHistory = false
            return
        }

        for messageID in messageIDs {
            _ = try? await client?.deleteMessage(chatID: chatID, messageID: messageID)
        }

        chatState.clearTrackedPresentationState()
        settings?.telegramTrackedMessageIDs = []
        shouldClearRecoveredChatHistory = false
    }

    private func clearReplyOverflowMessages(chatID: Int64) async {
        guard !chatState.replyOverflowMessageIDs.isEmpty else {
            chatState.replyOverflowSignature = nil
            return
        }

        for messageID in chatState.replyOverflowMessageIDs {
            _ = try? await client?.deleteMessage(chatID: chatID, messageID: messageID)
            forgetMessageID(messageID)
        }
        chatState.replyOverflowMessageIDs = []
        chatState.replyOverflowSignature = nil
    }

    private func clearImageMessages(chatID: Int64) async {
        guard !chatState.imageMessageIDs.isEmpty else {
            return
        }

        for messageID in chatState.imageMessageIDs {
            _ = try? await client?.deleteMessage(chatID: chatID, messageID: messageID)
            forgetMessageID(messageID)
        }
        chatState.imageMessageIDs = []
        chatState.lastDeliveredImageSignature = nil
    }

    private func clearSlot(chatID: Int64, kind: ViewSlot) async {
        var slot = slot(for: kind)
        guard let messageID = slot.messageID else {
            slot.reset()
            setSlot(slot, for: kind)
            return
        }

        do {
            _ = try await client?.deleteMessage(chatID: chatID, messageID: messageID)
        } catch {
            _ = try? await editTelegramMessage(
                chatID: chatID,
                messageID: messageID,
                text: TelegramRemoteRenderer.closedSessionText()
            )
        }
        forgetMessageID(messageID)
        slot.reset()
        setSlot(slot, for: kind)
    }

    private func upsertControllerMessage(
        chatID: Int64,
        text: String,
        signature: String,
        markup: TelegramInlineKeyboardMarkup
    ) async {
        let rendered = renderedSingleMessage(text)
        let effectiveSignature = "\(signature):\(rendered.visibleSignature)"
        guard effectiveSignature != chatState.controllerSignature || chatState.controllerMessageID == nil else {
            return
        }

        if let messageID = chatState.controllerMessageID {
            do {
                _ = try await editTelegramMessage(
                    chatID: chatID,
                    messageID: messageID,
                    rendered: rendered,
                    replyMarkup: markup
                )
                chatState.controllerSignature = effectiveSignature
                return
            } catch where isNotModifiedError(error) {
                chatState.controllerSignature = effectiveSignature
                return
            } catch {
                chatState.controllerMessageID = nil
            }
        }

        if let message = try? await sendTelegramMessage(
            chatID: chatID,
            rendered: rendered,
            replyMarkup: markup
        ) {
            chatState.controllerMessageID = message.messageID
            chatState.controllerSignature = effectiveSignature
        }
    }

    private func moveControllerMessageToBottom(chatID: Int64) async {
        if let messageID = chatState.controllerMessageID {
            _ = try? await client?.deleteMessage(chatID: chatID, messageID: messageID)
            forgetMessageID(messageID)
        }
        chatState.controllerMessageID = nil
        chatState.controllerSignature = nil
    }

    private func upsertViewSlot(
        chatID: Int64,
        kind: ViewSlot,
        text: String,
        signaturePrefix: String,
        markup: TelegramInlineKeyboardMarkup? = nil,
        expectedGeneration: Int
    ) async {
        await upsertViewSlot(
            chatID: chatID,
            kind: kind,
            rendered: renderedSingleMessage(text),
            signaturePrefix: signaturePrefix,
            markup: markup,
            expectedGeneration: expectedGeneration
        )
    }

    private func upsertViewSlot(
        chatID: Int64,
        kind: ViewSlot,
        rendered: TelegramRenderedText,
        signaturePrefix: String,
        markup: TelegramInlineKeyboardMarkup? = nil,
        expectedGeneration: Int
    ) async {
        guard expectedGeneration == chatState.viewGeneration else {
            return
        }

        var slot = slot(for: kind)
        let signature = "\(signaturePrefix):\(rendered.visibleSignature)"
        guard signature != slot.signature || slot.messageID == nil else {
            return
        }

        if let messageID = slot.messageID {
            do {
                _ = try await editTelegramMessage(
                    chatID: chatID,
                    messageID: messageID,
                    rendered: rendered,
                    replyMarkup: markup
                )
                guard expectedGeneration == chatState.viewGeneration else {
                    return
                }
                slot.signature = signature
                setSlot(slot, for: kind)
                return
            } catch where isNotModifiedError(error) {
                guard expectedGeneration == chatState.viewGeneration else {
                    return
                }
                slot.signature = signature
                setSlot(slot, for: kind)
                return
            } catch {
                slot.reset()
            }
        }

        if let message = try? await sendTelegramMessage(
            chatID: chatID,
            rendered: rendered,
            replyMarkup: markup
        ) {
            guard expectedGeneration == chatState.viewGeneration else {
                _ = try? await client?.deleteMessage(chatID: chatID, messageID: message.messageID)
                return
            }
            slot.messageID = message.messageID
            slot.signature = signature
            setSlot(slot, for: kind)
        } else {
            setSlot(slot, for: kind)
        }
    }

    private func slot(for kind: ViewSlot) -> MessageSlot {
        switch kind {
        case .header:
            return chatState.headerSlot
        case .transcript:
            return chatState.transcriptSlot
        case .stream:
            return chatState.streamSlot
        case .permission:
            return chatState.permissionSlot
        }
    }

    private func detachSlot(_ kind: ViewSlot) {
        var slot = slot(for: kind)
        slot.reset()
        setSlot(slot, for: kind)
    }

    private func setSlot(_ slot: MessageSlot, for kind: ViewSlot) {
        switch kind {
        case .header:
            chatState.headerSlot = slot
        case .transcript:
            chatState.transcriptSlot = slot
        case .stream:
            chatState.streamSlot = slot
        case .permission:
            chatState.permissionSlot = slot
        }
    }

    private func syncReplyOverflowMessages(
        chatID: Int64,
        chunks: [TelegramRenderedText],
        signaturePrefix: String,
        expectedGeneration: Int
    ) async {
        guard expectedGeneration == chatState.viewGeneration else {
            return
        }
        guard !chunks.isEmpty else {
            await clearReplyOverflowMessages(chatID: chatID)
            return
        }

        let digest = MemoryIdentifier.stableHexDigest(
            for: chunks.map(\.visibleSignature).joined(separator: "\n\n")
        )
        let signature = "\(signaturePrefix):\(digest)"
        guard signature != chatState.replyOverflowSignature else {
            return
        }

        await clearReplyOverflowMessages(chatID: chatID)
        guard let client else {
            return
        }

        var messageIDs: [Int] = []
        for renderedChunk in chunks {
            guard expectedGeneration == chatState.viewGeneration else {
                for messageID in messageIDs {
                    _ = try? await client.deleteMessage(chatID: chatID, messageID: messageID)
                }
                return
            }

            if let message = try? await sendTelegramMessage(
                chatID: chatID,
                rendered: renderedChunk
            ) {
                messageIDs.append(message.messageID)
            }
        }

        guard expectedGeneration == chatState.viewGeneration else {
            for messageID in messageIDs {
                _ = try? await client.deleteMessage(chatID: chatID, messageID: messageID)
            }
            return
        }

        chatState.replyOverflowMessageIDs = messageIDs
        chatState.replyOverflowSignature = messageIDs.isEmpty ? nil : signature
    }

    private func deliverImageDelivery(
        _ delivery: AssistantRemoteImageDelivery,
        sessionTitle: String,
        chatID: Int64,
        expectedGeneration: Int
    ) async {
        guard expectedGeneration == chatState.viewGeneration else {
            return
        }
        guard delivery.signature != chatState.lastDeliveredImageSignature else {
            return
        }
        guard let client else {
            return
        }

        var sentMessageIDs: [Int] = []
        for (index, attachment) in delivery.attachments.enumerated() {
            guard expectedGeneration == chatState.viewGeneration else {
                for messageID in sentMessageIDs {
                    _ = try? await client.deleteMessage(chatID: chatID, messageID: messageID)
                }
                return
            }

            let caption = index == 0 ? renderedPhotoCaption(delivery.caption, sessionTitle: sessionTitle) : nil
            do {
                let message: TelegramMessage
                do {
                    message = try await sendTelegramPhoto(
                        chatID: chatID,
                        data: attachment.data,
                        filename: attachment.filename,
                        mimeType: attachment.mimeType,
                        caption: caption
                    )
                } catch {
                    message = try await sendTelegramDocument(
                        chatID: chatID,
                        data: attachment.data,
                        filename: attachment.filename,
                        mimeType: attachment.mimeType,
                        caption: caption
                    )
                }
                sentMessageIDs.append(message.messageID)
            } catch {
                lastErrorMessage = "Could not send Telegram image: \(error.localizedDescription)"
            }
        }

        guard expectedGeneration == chatState.viewGeneration else {
            for messageID in sentMessageIDs {
                _ = try? await client.deleteMessage(chatID: chatID, messageID: messageID)
            }
            return
        }

        if !sentMessageIDs.isEmpty {
            chatState.imageMessageIDs.append(contentsOf: sentMessageIDs)
            chatState.lastDeliveredImageSignature = delivery.signature
        }
    }

    private func normalizedCommand(from rawText: String) -> String? {
        guard rawText.hasPrefix("/") else { return nil }
        let commandToken = rawText.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rawText
        let primary = commandToken.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? commandToken
        return primary.lowercased()
    }

    private func telegramSessionContext() async -> AssistantRemoteStatusSnapshot {
        let fallback = bridge.statusSnapshot()
        guard let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedSessionID.isEmpty,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID) else {
            return fallback
        }

        let modelID = snapshot.session.latestModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = (modelID?.isEmpty == false) ? modelID : nil
        let reasoningEffort = snapshot.session.latestReasoningEffort ?? fallback.reasoningEffort
        let effortState = bridge.reasoningEffortState(
            modelID: normalizedModelID,
            currentEffort: reasoningEffort,
            backend: snapshot.session.activeProviderBackend ?? fallback.assistantBackend
        )

        return AssistantRemoteStatusSnapshot(
            runtimeHealth: fallback.runtimeHealth,
            assistantBackend: snapshot.session.activeProviderBackend ?? fallback.assistantBackend,
            selectedSessionID: snapshot.session.id,
            selectedSessionTitle: snapshot.session.title,
            selectedSessionIsTemporary: snapshot.session.isTemporary,
            selectedModelID: normalizedModelID,
            selectedModelSummary: normalizedModelID ?? fallback.selectedModelSummary,
            interactionMode: snapshot.session.latestInteractionMode?.normalizedForActiveUse ?? .agentic,
            reasoningEffort: reasoningEffort,
            supportedReasoningEfforts: effortState.efforts,
            canAdjustReasoningEffort: effortState.canAdjust,
            fastModeEnabled: snapshot.session.fastModeEnabled,
            tokenUsage: fallback.tokenUsage,
            lastStatusMessage: fallback.lastStatusMessage
        )
    }

    private func currentProjectName() async -> String? {
        let availableProjects = await bridge.availableProjects()
        if let selectedProjectID = chatState.selectedProjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedProjectID.isEmpty {
            return availableProjects.first(where: {
                $0.id.caseInsensitiveCompare(selectedProjectID) == .orderedSame
            })?.name
        }

        guard let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedSessionID.isEmpty,
              let snapshot = await bridge.sessionSnapshot(sessionID: selectedSessionID) else {
            return nil
        }
        guard let sessionProjectID = snapshot.session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return snapshot.session.projectName
        }
        return availableProjects.first(where: {
            $0.id.caseInsensitiveCompare(sessionProjectID) == .orderedSame
        })?.name
    }

    private func applySelectedProjectFilter() async {
        await bridge.selectProject(chatState.selectedProjectID)
    }

    private func refreshIntervalSeconds(snapshot: AssistantRemoteSessionSnapshot?) -> Double {
        guard let snapshot else {
            return 20
        }
        if snapshot.hasActiveTurn {
            return 1.5
        }
        if snapshot.pendingPermissionRequest != nil {
            return 4
        }
        return 20
    }

    private func updateTypingIndicator(chatID: Int64, snapshot: AssistantRemoteSessionSnapshot?) async {
        guard snapshot?.hasActiveTurn == true else {
            stopTypingIndicator()
            return
        }
        startTypingIndicator(chatID: chatID)
    }

    private func startTypingIndicator(chatID: Int64) {
        if typingIndicatorChatID == chatID, typingIndicatorTask != nil {
            return
        }

        stopTypingIndicator()
        typingIndicatorChatID = chatID
        typingIndicatorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                _ = try? await client.sendChatAction(chatID: chatID, action: "typing")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func stopTypingIndicator() {
        typingIndicatorTask?.cancel()
        typingIndicatorTask = nil
        typingIndicatorChatID = nil
    }

    private func isAuthorized(user: TelegramUser?, chat: TelegramChat) -> Bool {
        guard let settings, let user else { return false }
        guard settings.hasTelegramRemoteOwner else { return false }
        return settings.telegramOwnerUserID.caseInsensitiveCompare(String(user.id)) == .orderedSame
            && settings.telegramOwnerChatID.caseInsensitiveCompare(String(chat.id)) == .orderedSame
    }

    private func displayName(for chat: TelegramChat) -> String {
        let parts = [chat.firstName, chat.lastName].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        if let username = chat.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return "@\(username)"
        }
        if let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(chat.id)
    }

    private func helpText() -> String {
        """
        Send a normal message to continue the selected session.

        Commands: /new, /clear, /temp, /projects, /sessions, /backend, /models, /mode, /effort, /usage, /status, /stop
        """
    }

    private func updatePairingStatus(using settings: SettingsStore) {
        if settings.hasTelegramRemoteOwner {
            pairingStatusMessage = "Paired to Telegram user \(settings.telegramOwnerUserID)."
        } else if settings.hasTelegramPendingPairing {
            let displayName = settings.telegramPendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            pairingStatusMessage = displayName.isEmpty
                ? "Pending Telegram pairing request."
                : "Pending pairing request from \(displayName)."
        } else {
            pairingStatusMessage = "Not paired"
        }
    }

    private func botIdentityText(for user: TelegramUser) -> String {
        if let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return "@\(username)"
        }
        return user.displayName
    }

    private func renderedSingleMessage(_ text: String) -> TelegramRenderedText {
        TelegramRemoteRenderer.renderSingleMessage(
            text,
            limit: TelegramRemoteRenderer.messageCharacterLimit
        ) ?? TelegramRenderedText(html: text, plainText: text)
    }

    private func renderedMessageChunks(_ text: String) -> [TelegramRenderedText] {
        let chunks = TelegramRemoteRenderer.renderMessage(
            text,
            limit: TelegramRemoteRenderer.messageCharacterLimit
        )
        return chunks.isEmpty ? [TelegramRenderedText(html: text, plainText: text)] : chunks
    }

    private func renderedPhotoCaption(_ text: String, sessionTitle: String) -> TelegramRenderedText {
        TelegramRemoteRenderer.renderCaption(
            text,
            fallback: "Image from \(sessionTitle)",
            limit: TelegramRemoteRenderer.captionCharacterLimit
        )
    }

    private func sendTelegramMessage(
        chatID: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        try await sendTelegramMessage(
            chatID: chatID,
            rendered: renderedSingleMessage(text),
            replyMarkup: replyMarkup
        )
    }

    private func sendTelegramMessage(
        chatID: Int64,
        rendered: TelegramRenderedText,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        guard let client else {
            throw TelegramBotClientError.invalidRequest
        }

        do {
            let message = try await client.sendMessage(
                chatID: chatID,
                text: rendered.html,
                parseMode: .html,
                replyMarkup: replyMarkup
            )
            trackMessageID(message.messageID)
            return message
        } catch {
            guard shouldRetryAsPlainText(after: error) else {
                throw error
            }
            let message = try await client.sendMessage(
                chatID: chatID,
                text: rendered.plainText,
                replyMarkup: replyMarkup
            )
            trackMessageID(message.messageID)
            return message
        }
    }

    private func editTelegramMessage(
        chatID: Int64,
        messageID: Int,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        try await editTelegramMessage(
            chatID: chatID,
            messageID: messageID,
            rendered: renderedSingleMessage(text),
            replyMarkup: replyMarkup
        )
    }

    private func editTelegramMessage(
        chatID: Int64,
        messageID: Int,
        rendered: TelegramRenderedText,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        guard let client else {
            throw TelegramBotClientError.invalidRequest
        }

        do {
            return try await client.editMessageText(
                chatID: chatID,
                messageID: messageID,
                text: rendered.html,
                parseMode: .html,
                replyMarkup: replyMarkup
            )
        } catch {
            guard shouldRetryAsPlainText(after: error) else {
                throw error
            }
            return try await client.editMessageText(
                chatID: chatID,
                messageID: messageID,
                text: rendered.plainText,
                replyMarkup: replyMarkup
            )
        }
    }

    private func sendTelegramPhoto(
        chatID: Int64,
        data: Data,
        filename: String,
        mimeType: String,
        caption: TelegramRenderedText?
    ) async throws -> TelegramMessage {
        guard let client else {
            throw TelegramBotClientError.invalidRequest
        }

        do {
            let message = try await client.sendPhoto(
                chatID: chatID,
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: caption?.html,
                parseMode: caption == nil ? nil : .html
            )
            trackMessageID(message.messageID)
            return message
        } catch {
            guard caption != nil, shouldRetryAsPlainText(after: error) else {
                throw error
            }
            let message = try await client.sendPhoto(
                chatID: chatID,
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: caption?.plainText
            )
            trackMessageID(message.messageID)
            return message
        }
    }

    private func sendTelegramDocument(
        chatID: Int64,
        data: Data,
        filename: String,
        mimeType: String,
        caption: TelegramRenderedText?
    ) async throws -> TelegramMessage {
        guard let client else {
            throw TelegramBotClientError.invalidRequest
        }

        do {
            let message = try await client.sendDocument(
                chatID: chatID,
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: caption?.html,
                parseMode: caption == nil ? nil : .html
            )
            trackMessageID(message.messageID)
            return message
        } catch {
            guard caption != nil, shouldRetryAsPlainText(after: error) else {
                throw error
            }
            let message = try await client.sendDocument(
                chatID: chatID,
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: caption?.plainText
            )
            trackMessageID(message.messageID)
            return message
        }
    }

    private func shouldRetryAsPlainText(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("can't parse entities")
            || message.contains("cannot parse entities")
            || message.contains("unsupported start tag")
            || message.contains("unexpected end tag")
            || message.contains("entity")
            || message.contains("tag")
    }

    private func formattedSelectedSessionLine(
        sessionID: String?,
        title: String?,
        isTemporary: Bool
    ) -> String {
        guard sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            return "No session selected"
        }
        return TelegramRemoteRenderer.displaySessionTitle(title: title, isTemporary: isTemporary)
    }

    private func usageSummaryText() async -> String {
        if let selectedSessionID = chatState.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedSessionID.isEmpty {
            _ = await bridge.openSession(sessionID: selectedSessionID)
        }

        let status = bridge.statusSnapshot()
        let usage = status.tokenUsage
        let last = usage.last
        let total = usage.total

        var lines = [
            "Usage",
            "Session: \(formattedSelectedSessionLine(sessionID: status.selectedSessionID, title: status.selectedSessionTitle, isTemporary: status.selectedSessionIsTemporary))",
            "Context: \(usage.exactContextSummary)"
        ]

        if status.selectedSessionIsTemporary {
            lines.append("Type: Temporary chat")
        }

        if let fraction = usage.contextUsageFraction {
            lines.append("Context used: \(Int(round(fraction * 100)))%")
        }

        lines.append(
            "Last turn: input \(formattedTokenCount(last.inputTokens)), output \(formattedTokenCount(last.outputTokens)), reasoning \(formattedTokenCount(last.reasoningOutputTokens)), total \(formattedTokenCount(last.totalTokens))"
        )
        lines.append(
            "Session total: input \(formattedTokenCount(total.inputTokens)), output \(formattedTokenCount(total.outputTokens)), reasoning \(formattedTokenCount(total.reasoningOutputTokens)), total \(formattedTokenCount(total.totalTokens))"
        )

        return lines.joined(separator: "\n")
    }

    private func providerUsageSummaryText() async -> String {
        let status = await telegramSessionContext()
        return TelegramRemoteRenderer.providerUsageText(
            status: status,
            rateLimits: bridge.rateLimitsSnapshot()
        )
    }

    private func statusSummaryText() async -> String {
        let status = await telegramSessionContext()
        let projectName = await currentProjectName() ?? "All projects"

        var lines = [
            "Status",
            "Project: \(projectName)",
            "Session: \(formattedSelectedSessionLine(sessionID: status.selectedSessionID, title: status.selectedSessionTitle, isTemporary: status.selectedSessionIsTemporary))",
            "Backend: \(status.assistantBackendName)",
            "Model: \(status.selectedModelSummary)",
            "Mode: \(status.interactionMode.label)",
            "Effort: \(status.reasoningEffort.label)",
            "Runtime: \(status.runtimeHealth.summary)"
        ]

        if status.selectedSessionIsTemporary {
            lines.append("Type: Temporary chat")
        }

        if let lastStatusMessage = status.lastStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastStatusMessage.isEmpty {
            lines.append("Last note: \(lastStatusMessage)")
        }

        return lines.joined(separator: "\n")
    }

    private func formattedTokenCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    private func isNotModifiedError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("message is not modified")
    }
}
