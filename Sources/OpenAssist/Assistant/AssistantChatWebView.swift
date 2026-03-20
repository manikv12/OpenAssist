import AppKit
import QuickLookUI
import SwiftUI
import WebKit

// MARK: - SwiftUI View

struct AssistantChatWebView: NSViewRepresentable {
    let messages: [AssistantChatWebMessage]
    let showTypingIndicator: Bool
    let typingTitle: String
    let typingDetail: String
    let textScale: CGFloat
    let canLoadOlderHistory: Bool
    var accentColor: Color? = nil
    let onScrollStateChanged: (Bool, Bool) -> Void // (isPinned, isScrolledUp)
    let onLoadOlderHistory: () -> Void
    let onUndoMessage: (String) -> Void
    let onEditMessage: (String) -> Void
    var onTextSelected: ((String, String, String, CGRect) -> Void)? = nil

    func makeCoordinator() -> AssistantChatWebCoordinator {
        AssistantChatWebCoordinator(
            onScrollStateChanged: onScrollStateChanged,
            onLoadOlderHistory: onLoadOlderHistory,
            onUndoMessage: onUndoMessage,
            onEditMessage: onEditMessage
        )
    }

    func makeNSView(context: Context) -> AssistantChatWebContainerView {
        let container = AssistantChatWebContainerView(coordinator: context.coordinator)
        context.coordinator.onTextSelected = onTextSelected
        context.coordinator.webViewContainer = container
        container.applyMessages(messages)
        container.applyTypingIndicator(showTypingIndicator, title: typingTitle, detail: typingDetail)
        container.applyTextScale(textScale)
        container.applyCanLoadOlder(canLoadOlderHistory)
        if let accent = accentColor {
            container.applyAccentColor(accent)
        }
        return container
    }

    func updateNSView(_ container: AssistantChatWebContainerView, context: Context) {
        container.coordinator = context.coordinator
        context.coordinator.onTextSelected = onTextSelected
        container.applyMessages(messages)
        container.applyTypingIndicator(showTypingIndicator, title: typingTitle, detail: typingDetail)
        container.applyTextScale(textScale)
        container.applyCanLoadOlder(canLoadOlderHistory)
        if let accent = accentColor {
            container.applyAccentColor(accent)
        }
    }
}

// MARK: - Message Model for Web

struct AssistantChatWebMessage: Equatable {
    let id: String
    let type: String // "user", "assistant", "activity", "activityGroup", "system"
    let text: String?
    let isStreaming: Bool
    let timestamp: Date
    let images: [Data]?
    let emphasis: Bool
    let canUndo: Bool
    let canEdit: Bool
    let rewriteAnchorID: String?

    // Activity
    let activityIcon: String?
    let activityTitle: String?
    let activityDetail: String?
    let activityStatus: String? // "running", "completed", "failed"
    let activityStatusLabel: String?
    let detailSections: [AssistantChatWebDetailSection]?

    // Activity group
    let groupItems: [AssistantChatWebActivityGroupItem]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "type": type,
            "isStreaming": isStreaming,
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
        ]
        if let text { json["text"] = text }
        if emphasis { json["emphasis"] = true }
        if canUndo { json["canUndo"] = true }
        if canEdit { json["canEdit"] = true }
        if let rewriteAnchorID { json["rewriteAnchorID"] = rewriteAnchorID }

        if let images, !images.isEmpty {
            json["images"] = images.compactMap { data -> String? in
                let base64 = data.base64EncodedString()
                // Detect PNG vs JPEG
                if data.count > 8 {
                    let bytes = [UInt8](data.prefix(8))
                    if bytes[0] == 0x89 && bytes[1] == 0x50 {
                        return "data:image/png;base64,\(base64)"
                    }
                }
                return "data:image/jpeg;base64,\(base64)"
            }
        }

        if let activityIcon { json["activityIcon"] = activityIcon }
        if let activityTitle { json["activityTitle"] = activityTitle }
        if let activityDetail { json["activityDetail"] = activityDetail }
        if let activityStatus { json["activityStatus"] = activityStatus }
        if let activityStatusLabel { json["activityStatusLabel"] = activityStatusLabel }
        if let detailSections, !detailSections.isEmpty {
            json["detailSections"] = detailSections.map { $0.toJSON() }
        }

        if let groupItems, !groupItems.isEmpty {
            json["groupItems"] = groupItems.map { $0.toJSON() }
        }

        return json
    }
}

struct AssistantChatWebActivityGroupItem: Equatable {
    let id: String
    let icon: String?
    let title: String
    let detail: String?
    let status: String
    let statusLabel: String?
    let timestamp: Date
    let detailSections: [AssistantChatWebDetailSection]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "status": status,
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
        ]
        if let icon { json["icon"] = icon }
        if let detail { json["detail"] = detail }
        if let statusLabel { json["statusLabel"] = statusLabel }
        if let detailSections, !detailSections.isEmpty {
            json["detailSections"] = detailSections.map { $0.toJSON() }
        }
        return json
    }
}

struct AssistantChatWebDetailSection: Equatable {
    let title: String
    let text: String

    func toJSON() -> [String: Any] {
        [
            "title": title,
            "text": text
        ]
    }
}

struct AssistantChatWebRenderContext {
    let pendingPermissionRequest: AssistantPermissionRequest?
    let activeRuntimeSessionID: String?
    let hasActiveTurn: Bool
    let sessionStatusByNormalizedID: [String: AssistantSessionStatus]

    func sessionStatus(for sessionID: String?) -> AssistantSessionStatus? {
        guard let normalizedSessionID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedSessionID.isEmpty else {
            return nil
        }
        return sessionStatusByNormalizedID[normalizedSessionID]
    }

    func shouldShowLiveRunningState(for sessionID: String?) -> Bool {
        assistantSessionOwnsLiveRuntimeState(
            sessionID: sessionID,
            activeRuntimeSessionID: activeRuntimeSessionID
        ) && hasActiveTurn
    }
}

private func assistantChatWebDetailSections(
    from rawDetails: String?
) -> [AssistantChatWebDetailSection] {
    guard let trimmed = rawDetails?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .assistantNonEmpty else {
        return []
    }

    guard let separatorRange = trimmed.range(of: "\n\n") else {
        return [
            AssistantChatWebDetailSection(
                title: "Details",
                text: trimmed
            )
        ]
    }

    let request = String(trimmed[..<separatorRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let response = String(trimmed[separatorRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var sections: [AssistantChatWebDetailSection] = []
    if let request = request.assistantNonEmpty {
        sections.append(
            AssistantChatWebDetailSection(
                title: "Request",
                text: request
            )
        )
    }
    if let response = response.assistantNonEmpty {
        sections.append(
            AssistantChatWebDetailSection(
                title: "Response",
                text: response
            )
        )
    }

    return sections
}

// MARK: - Coordinator

final class AssistantChatWebCoordinator: NSObject, WKScriptMessageHandler {
    var onScrollStateChanged: (Bool, Bool) -> Void
    var onLoadOlderHistory: () -> Void
    var onUndoMessage: (String) -> Void
    var onEditMessage: (String) -> Void
    var onTextSelected: ((String, String, String, CGRect) -> Void)? // selectedText, messageID, parentText, screenRect
    weak var webViewContainer: AssistantChatWebContainerView?
    private let imageQuickLookController = AssistantChatImageQuickLookController()

    init(
        onScrollStateChanged: @escaping (Bool, Bool) -> Void,
        onLoadOlderHistory: @escaping () -> Void,
        onUndoMessage: @escaping (String) -> Void,
        onEditMessage: @escaping (String) -> Void
    ) {
        self.onScrollStateChanged = onScrollStateChanged
        self.onLoadOlderHistory = onLoadOlderHistory
        self.onUndoMessage = onUndoMessage
        self.onEditMessage = onEditMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "scrollState":
            if let body = message.body as? [String: Any],
               let isPinned = body["isPinned"] as? Bool,
               let isScrolledUp = body["isScrolledUp"] as? Bool {
                DispatchQueue.main.async { [self] in
                    onScrollStateChanged(isPinned, isScrolledUp)
                }
            }
        case "loadOlderHistory":
            DispatchQueue.main.async { [self] in
                onLoadOlderHistory()
            }
        case "linkClicked":
            if let urlString = message.body as? String {
                handleLinkClick(urlString)
            }
        case "copyText":
            if let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "openImage":
            if let body = message.body as? [String: Any],
               let dataURLString = body["dataUrl"] as? String {
                let suggestedName = body["suggestedName"] as? String
                openImageInQuickLook(dataURLString: dataURLString, suggestedName: suggestedName)
            }
        case "textSelected":
            if message.body is NSNull {
                DispatchQueue.main.async { [self] in
                    onTextSelected?("", "", "", .zero)
                }
            } else if let body = message.body as? [String: Any],
                      let selectedText = body["selectedText"] as? String,
                      let messageID = body["messageID"] as? String,
                      let parentText = body["parentMessageText"] as? String,
                      let rectInfo = body["rect"] as? [String: Double] {
                // Rect from JS is relative to WKWebView viewport
                let viewRect = CGRect(
                    x: rectInfo["x"] ?? 0,
                    y: rectInfo["y"] ?? 0,
                    width: rectInfo["width"] ?? 0,
                    height: rectInfo["height"] ?? 0
                )
                // Convert to screen coordinates using the webView
                DispatchQueue.main.async { [self] in
                    let screenRect = webViewContainer?.convertToScreen(viewRect) ?? viewRect
                    onTextSelected?(selectedText, messageID, parentText, screenRect)
                }
            }
        case "undoMessage":
            if let anchorID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onUndoMessage(anchorID)
                }
            }
        case "editMessage":
            if let anchorID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onEditMessage(anchorID)
                }
            }
        default:
            break
        }
    }

    func handleLinkClick(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.path
        if (scheme == "file" || scheme.isEmpty), !path.isEmpty {
            if let vscodeURL = URL(string: "vscode://file\(path)"),
               NSWorkspace.shared.urlForApplication(toOpen: vscodeURL) != nil {
                NSWorkspace.shared.open(vscodeURL)
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func openImageInQuickLook(dataURLString: String, suggestedName: String?) {
        guard let imageFile = temporaryImageFile(from: dataURLString, suggestedName: suggestedName) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.imageQuickLookController.present(
                fileURL: imageFile,
                title: suggestedName,
                parentWindow: self?.webViewContainer?.window
            )
        }
    }

    private func temporaryImageFile(from dataURLString: String, suggestedName: String?) -> URL? {
        guard let commaIndex = dataURLString.firstIndex(of: ",") else { return nil }

        let metadata = String(dataURLString[..<commaIndex])
        let encodedPayload = String(dataURLString[dataURLString.index(after: commaIndex)...])

        guard metadata.hasPrefix("data:"),
              metadata.contains(";base64"),
              let imageData = Data(base64Encoded: encodedPayload) else {
            return nil
        }

        let mimeType = String(metadata.dropFirst(5).split(separator: ";").first ?? "")
        let fileExtension: String
        switch mimeType.lowercased() {
        case "image/png":
            fileExtension = "png"
        case "image/jpeg", "image/jpg":
            fileExtension = "jpg"
        case "image/gif":
            fileExtension = "gif"
        case "image/tiff":
            fileExtension = "tiff"
        case "image/webp":
            fileExtension = "webp"
        default:
            fileExtension = "png"
        }

        let baseName = (suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .assistantNonEmpty) ?? "chat-image"
        let uniqueName = "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"

        let previewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAssist-PreviewImages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: previewsDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = previewsDirectory.appendingPathComponent(uniqueName)
        do {
            try imageData.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            return nil
        }
    }
}

@MainActor
private final class AssistantChatImageQuickLookController: NSWindowController {
    // swiftlint:disable:next force_unwrapping
    private let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)!
    private let containerView = NSVisualEffectView(frame: .zero)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        super.init(window: panel)

        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 16
        containerView.layer?.masksToBounds = true

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.autostarts = false
        previewView.shouldCloseWithWindow = false

        containerView.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            previewView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -14),
            previewView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),
            previewView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -14)
        ])

        panel.contentView = containerView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(fileURL: URL, title: String?, parentWindow: NSWindow?) {
        previewView.previewItem = fileURL as NSURL
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).assistantNonEmpty {
            window?.title = title
        } else {
            window?.title = fileURL.lastPathComponent
        }

        resizeWindowToFitImage(at: fileURL, parentWindow: parentWindow)

        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func resizeWindowToFitImage(at fileURL: URL, parentWindow: NSWindow?) {
        guard let window else { return }

        let imageSize = NSImage(contentsOf: fileURL)?.size ?? NSSize(width: 960, height: 640)
        let clampedWidth = min(max(imageSize.width + 80, 460), 980)
        let clampedHeight = min(max(imageSize.height + 80, 320), 760)
        let targetSize = NSSize(width: clampedWidth, height: clampedHeight)

        if let parentFrame = parentWindow?.frame {
            let origin = NSPoint(
                x: parentFrame.midX - targetSize.width / 2,
                y: parentFrame.midY - targetSize.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: targetSize), display: false)
        } else {
            window.setContentSize(targetSize)
            window.center()
        }
    }
}

// MARK: - Container View

final class AssistantChatWebContainerView: NSView, WKNavigationDelegate {
    var coordinator: AssistantChatWebCoordinator

    private static var cachedHTMLString: String?

    private let webView: WKWebView
    private var isReady = false
    private var pendingMessages: [AssistantChatWebMessage]?
    private var pendingTyping: (Bool, String, String)?
    private var pendingTextScale: CGFloat?

    // Throttling for streaming updates
    private var throttleTimer: Timer?
    private var pendingStreamingMessages: [AssistantChatWebMessage]?
    private var lastRequestedMessages: [AssistantChatWebMessage] = []
    private var lastRenderedMessages: [AssistantChatWebMessage] = []
    private static let throttleInterval: TimeInterval = 1.0 / 30.0

    init(coordinator: AssistantChatWebCoordinator) {
        self.coordinator = coordinator

        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(coordinator, name: "scrollState")
        uc.add(coordinator, name: "loadOlderHistory")
        uc.add(coordinator, name: "linkClicked")
        uc.add(coordinator, name: "copyText")
        uc.add(coordinator, name: "openImage")
        uc.add(coordinator, name: "textSelected")
        uc.add(coordinator, name: "undoMessage")
        uc.add(coordinator, name: "editMessage")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true

        webView.navigationDelegate = self
        addSubview(webView)

        // Ready handler
        let readyHandler = ReadyHandler { [weak self] in
            guard let self else { return }
            self.isReady = true
            if let msgs = self.pendingMessages {
                self.sendMessages(msgs)
                self.pendingMessages = nil
            }
            if let t = self.pendingTyping {
                self.sendTypingIndicator(t.0, title: t.1, detail: t.2)
                self.pendingTyping = nil
            }
            if let s = self.pendingTextScale {
                self.sendTextScale(s)
                self.pendingTextScale = nil
            }
            if let js = self.pendingAccentCSS {
                self.webView.evaluateJavaScript(js, completionHandler: nil)
                self.pendingAccentCSS = nil
            }
        }
        uc.add(readyHandler, name: "ready")

        loadTemplate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+F → toggle find bar in React
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
            webView.evaluateJavaScript("chatBridge.toggleFind?.()", completionHandler: nil)
            return true
        }
        // Cmd+G → find next, Shift+Cmd+G → find prev
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "g" {
            let direction = event.modifierFlags.contains(.shift) ? "prev" : "next"
            webView.evaluateJavaScript("chatBridge.findNavigate?.('\(direction)')", completionHandler: nil)
            return true
        }
        // Escape → close find
        if event.keyCode == 53 { // Escape
            webView.evaluateJavaScript("chatBridge.closeFind?.()", completionHandler: nil)
            // Don't return true — let Escape propagate for other uses
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Convert a rect from WKWebView viewport coordinates to screen coordinates.
    func convertToScreen(_ viewportRect: CGRect) -> CGRect {
        guard let window = webView.window else { return viewportRect }

        // WKWebView viewport rect (origin top-left) → webView local (flipped)
        let localRect = NSRect(
            x: viewportRect.origin.x,
            y: viewportRect.origin.y,
            width: viewportRect.width,
            height: viewportRect.height
        )

        // Convert from webView's coordinate space to window coordinates
        let windowRect = webView.convert(localRect, to: nil)

        // Convert from window coordinates to screen coordinates
        return window.convertToScreen(windowRect)
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    // MARK: - Template Loading

    private func loadTemplate() {
        if let html = Self.cachedHTMLString {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        let url: URL? = Bundle.main.url(forResource: "markdown-chat", withExtension: "html")
            ?? Bundle(identifier: "OpenAssist_OpenAssist")?.url(forResource: "markdown-chat", withExtension: "html")
            ?? {
                let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
                let candidates = [
                    execDir.appendingPathComponent("OpenAssist_OpenAssist.bundle/markdown-chat.html"),
                    execDir.appendingPathComponent("markdown-chat.html")
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }()

        guard let url, let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        Self.cachedHTMLString = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Public API

    func applyMessages(_ messages: [AssistantChatWebMessage]) {
        guard messages != lastRequestedMessages else { return }
        lastRequestedMessages = messages

        let isStreaming = messages.last?.isStreaming ?? false
        if isStreaming {
            // Throttle during streaming to avoid overwhelming the web view
            pendingStreamingMessages = messages
            if throttleTimer == nil {
                flushStreamingMessages()
                throttleTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.throttleInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.flushStreamingMessages()
                }
            }
        } else {
            // Final render — send immediately
            cancelThrottle()
            sendMessages(messages)
        }
    }

    func applyTypingIndicator(_ visible: Bool, title: String, detail: String) {
        sendTypingIndicator(visible, title: title, detail: detail)
    }

    func applyTextScale(_ scale: CGFloat) {
        sendTextScale(scale)
    }

    func applyAccentColor(_ color: Color) {
        let nsColor = NSColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(r * 255), gi = Int(g * 255), bi = Int(b * 255)
        let css = "rgb(\(ri),\(gi),\(bi))"
        let js = "document.documentElement.style.setProperty('--chat-accent', '\(css)')"
        guard isReady else {
            pendingAccentCSS = js
            return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private var pendingAccentCSS: String?

    func applyCanLoadOlder(_ canLoad: Bool) {
        guard isReady else { return }
        webView.evaluateJavaScript("chatBridge.setCanLoadOlder(\(canLoad))", completionHandler: nil)
    }

    func scrollToBottom(animated: Bool) {
        guard isReady else { return }
        webView.evaluateJavaScript("chatBridge.scrollToBottom(\(animated))", completionHandler: nil)
    }

    // MARK: - Throttled Streaming

    private func flushStreamingMessages() {
        guard let messages = pendingStreamingMessages else {
            cancelThrottle()
            return
        }
        pendingStreamingMessages = nil
        if canIncrementallyStream(messages) {
            sendLastMessageUpdate(messages)
        } else {
            sendMessages(messages)
        }
    }

    private func cancelThrottle() {
        throttleTimer?.invalidate()
        throttleTimer = nil
        if pendingStreamingMessages != nil {
            flushStreamingMessages()
        }
    }

    // MARK: - JS Communication

    private func sendMessages(_ messages: [AssistantChatWebMessage]) {
        guard isReady else {
            pendingMessages = messages
            return
        }
        let jsonArray = messages.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        lastRenderedMessages = messages
        webView.evaluateJavaScript("chatBridge.setMessages(\(jsonString))", completionHandler: nil)
    }

    private func sendLastMessageUpdate(_ messages: [AssistantChatWebMessage]) {
        guard isReady, let lastMessage = messages.last else {
            pendingMessages = messages
            return
        }

        let text = lastMessage.text ?? ""
        guard let idData = try? JSONEncoder().encode(lastMessage.id),
              let textData = try? JSONEncoder().encode(text),
              let idString = String(data: idData, encoding: .utf8),
              let textString = String(data: textData, encoding: .utf8) else {
            sendMessages(messages)
            return
        }

        lastRenderedMessages = messages
        webView.evaluateJavaScript(
            "chatBridge.updateLastMessage(\(idString),\(textString),\(lastMessage.isStreaming))",
            completionHandler: nil
        )
    }

    private func canIncrementallyStream(_ messages: [AssistantChatWebMessage]) -> Bool {
        guard !lastRenderedMessages.isEmpty,
              messages.count == lastRenderedMessages.count,
              let lastMessage = messages.last,
              let previousLastMessage = lastRenderedMessages.last,
              lastMessage.id == previousLastMessage.id,
              messages.dropLast().elementsEqual(lastRenderedMessages.dropLast())
        else {
            return false
        }

        let stablePreviousLast = previousLastMessage.withStreamingText(
            previousLastMessage.text,
            isStreaming: lastMessage.isStreaming
        )
        let stableIncomingLast = lastMessage.withStreamingText(
            previousLastMessage.text,
            isStreaming: lastMessage.isStreaming
        )
        return stablePreviousLast == stableIncomingLast
    }

    private func sendTypingIndicator(_ visible: Bool, title: String, detail: String) {
        guard isReady else {
            pendingTyping = (visible, title, detail)
            return
        }
        guard let titleJSON = try? JSONEncoder().encode(title),
              let detailJSON = try? JSONEncoder().encode(detail),
              let titleStr = String(data: titleJSON, encoding: .utf8),
              let detailStr = String(data: detailJSON, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "chatBridge.setTypingIndicator(\(visible),\(titleStr),\(detailStr))",
            completionHandler: nil
        )
    }

    private func sendTextScale(_ scale: CGFloat) {
        guard isReady else {
            pendingTextScale = scale
            return
        }
        webView.evaluateJavaScript("chatBridge.setTextScale(\(scale))", completionHandler: nil)
    }

    // MARK: - Navigation Delegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            coordinator.handleLinkClick(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func handleLinkClick(_ urlString: String) {
        coordinator.handleLinkClick(urlString)
    }

    deinit {
        cancelThrottle()
    }
}

private extension AssistantChatWebMessage {
    func withStreamingText(_ text: String?, isStreaming: Bool) -> AssistantChatWebMessage {
        AssistantChatWebMessage(
            id: id,
            type: type,
            text: text,
            isStreaming: isStreaming,
            timestamp: timestamp,
            images: images,
            emphasis: emphasis,
            canUndo: canUndo,
            canEdit: canEdit,
            rewriteAnchorID: rewriteAnchorID,
            activityIcon: activityIcon,
            activityTitle: activityTitle,
            activityDetail: activityDetail,
            activityStatus: activityStatus,
            activityStatusLabel: activityStatusLabel,
            detailSections: detailSections,
            groupItems: groupItems
        )
    }
}

// MARK: - Ready Handler

private final class ReadyHandler: NSObject, WKScriptMessageHandler {
    private let onReady: () -> Void
    init(onReady: @escaping () -> Void) { self.onReady = onReady }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "ready" { onReady() }
    }
}

// MARK: - Conversion from Timeline Items

extension AssistantChatWebMessage {
    static func from(
        renderItem: AssistantTimelineRenderItem,
        historyActions: [String: AssistantHistoryActionAvailability] = [:],
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> [AssistantChatWebMessage] {
        switch renderItem {
        case .timeline(let item):
            return [
                from(
                    timelineItem: item,
                    historyAction: historyActions[item.id],
                    renderContext: renderContext
                )
            ]
        case .activityGroup(let group):
            return [fromActivityGroup(group, renderContext: renderContext)]
        }
    }

    static func from(
        timelineItem item: AssistantTimelineItem,
        historyAction: AssistantHistoryActionAvailability? = nil,
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> AssistantChatWebMessage {
        let type: String
        let activityIcon: String?
        let activityStatus: String?
        let activityStatusLabel: String?
        let activityTitle: String?
        let activityDetail: String?
        let detailSections: [AssistantChatWebDetailSection]?

        switch item.kind {
        case .userMessage:
            type = "user"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
        case .assistantProgress, .assistantFinal:
            type = "assistant"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
        case .activity:
            type = "activity"
            let activity = item.activity
            let effectiveStatus = activity.map {
                displayActivityStatus(
                    $0,
                    sessionID: item.sessionID ?? $0.sessionID,
                    renderContext: renderContext
                )
            }
            activityIcon = activity.map { iconForActivityKind($0.kind) }
            activityTitle = activity?.title ?? "Action"
            activityDetail = activity?.friendlySummary
            activityStatus = effectiveStatus.map { Self.activityStatusString(for: $0) }
            activityStatusLabel = effectiveStatus?.rawValue.capitalized
            detailSections = assistantChatWebDetailSections(from: activity?.rawDetails)
        case .permission:
            type = "activity"
            activityIcon = "permission"
            activityTitle = "Permission Request"
            activityDetail = item.text
            if let request = item.permissionRequest {
                let state = assistantPermissionCardState(
                    for: request,
                    pendingRequest: renderContext?.pendingPermissionRequest,
                    sessionStatus: renderContext?.sessionStatus(for: request.sessionID)
                )
                switch state {
                case .waitingForApproval:
                    activityStatus = "running"
                    activityStatusLabel = "Pending"
                case .waitingForInput:
                    activityStatus = "running"
                    activityStatusLabel = "Waiting"
                case .completed, .notActive:
                    activityStatus = "completed"
                    activityStatusLabel = "Handled"
                }
            } else {
                activityStatus = "completed"
                activityStatusLabel = "Handled"
            }
            detailSections = nil
        case .plan:
            type = "assistant"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
        case .system:
            type = "system"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
        }

        let text: String?
        if item.kind == .plan, let planText = item.planText {
            text = planText
        } else {
            text = item.text.flatMap { AssistantVisibleTextSanitizer.clean($0) }
        }

        return AssistantChatWebMessage(
            id: item.id,
            type: type,
            text: text,
            isStreaming: item.isStreaming,
            timestamp: item.sortDate,
            images: item.imageAttachments,
            emphasis: item.emphasis,
            canUndo: historyAction?.canUndo ?? false,
            canEdit: historyAction?.canEdit ?? false,
            rewriteAnchorID: historyAction?.anchorID,
            activityIcon: activityIcon,
            activityTitle: activityTitle,
            activityDetail: activityDetail,
            activityStatus: activityStatus,
            activityStatusLabel: activityStatusLabel,
            detailSections: detailSections?.isEmpty == false ? detailSections : nil,
            groupItems: nil
        )
    }

    static func fromActivityGroup(
        _ group: AssistantTimelineActivityGroup,
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> AssistantChatWebMessage {
        let groupItems = group.items.map { item -> AssistantChatWebActivityGroupItem in
            let activity = item.activity
            let effectiveStatus = activity.map {
                displayActivityStatus(
                    $0,
                    sessionID: item.sessionID ?? $0.sessionID,
                    renderContext: renderContext
                )
            } ?? .completed
            return AssistantChatWebActivityGroupItem(
                id: item.id,
                icon: activity.map { iconForActivityKind($0.kind) },
                title: activity?.title ?? "Action",
                detail: activity?.friendlySummary,
                status: activityStatusString(for: effectiveStatus),
                statusLabel: effectiveStatus.rawValue.capitalized,
                timestamp: item.sortDate,
                detailSections: assistantChatWebDetailSections(from: activity?.rawDetails)
            )
        }

        return AssistantChatWebMessage(
            id: "group-\(group.id)",
            type: "activityGroup",
            text: nil,
            isStreaming: false,
            timestamp: group.items.first?.sortDate ?? Date(),
            images: nil,
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            activityIcon: nil,
            activityTitle: nil,
            activityDetail: nil,
            activityStatus: nil,
            activityStatusLabel: nil,
            detailSections: nil,
            groupItems: groupItems
        )
    }

    private static func iconForActivityKind(_ kind: AssistantActivityKind) -> String {
        // Pass the kind as a string; React maps it to an SVG icon
        kind.rawValue
    }

    private static func displayActivityStatus(
        _ activity: AssistantActivityItem,
        sessionID: String?,
        renderContext: AssistantChatWebRenderContext?
    ) -> AssistantActivityStatus {
        guard activity.status.isActive else {
            return activity.status
        }

        guard let renderContext else {
            return activity.status
        }

        guard renderContext.shouldShowLiveRunningState(for: sessionID) else {
            return .completed
        }

        return activity.status
    }

    private static func activityStatusString(for status: AssistantActivityStatus) -> String {
        switch status {
        case .completed:
            return "completed"
        case .failed, .interrupted:
            return "failed"
        case .pending, .running, .waiting:
            return "running"
        }
    }

    private static func activityStatusString(for activity: AssistantActivityItem) -> String {
        activityStatusString(for: activity.status)
    }
}
