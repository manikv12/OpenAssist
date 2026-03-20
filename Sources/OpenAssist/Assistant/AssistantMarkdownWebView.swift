import AppKit
import SwiftUI
import WebKit

struct AssistantMarkdownWebView: View {
    let contentID: String
    let text: String
    let isStreaming: Bool
    let textScale: CGFloat

    @State private var measuredHeight: CGFloat = 22

    var body: some View {
        AssistantMarkdownWebNSView(
            contentID: contentID,
            text: text,
            isStreaming: isStreaming,
            textScale: textScale,
            measuredHeight: $measuredHeight
        )
        .frame(height: max(ceil(measuredHeight), 18))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - NSViewRepresentable

private struct AssistantMarkdownWebNSView: NSViewRepresentable {
    let contentID: String
    let text: String
    let isStreaming: Bool
    let textScale: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> AssistantMarkdownWebCoordinator {
        AssistantMarkdownWebCoordinator(measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> AssistantMarkdownWebContainerView {
        let container = AssistantMarkdownWebContainerView(coordinator: context.coordinator)
        container.apply(contentID: contentID, text: text, isStreaming: isStreaming, textScale: textScale)
        return container
    }

    func updateNSView(_ container: AssistantMarkdownWebContainerView, context: Context) {
        _ = context.coordinator
        container.apply(contentID: contentID, text: text, isStreaming: isStreaming, textScale: textScale)
    }
}

// MARK: - Coordinator

final class AssistantMarkdownWebCoordinator: NSObject, WKScriptMessageHandler {
    @Binding private var measuredHeight: CGFloat

    init(measuredHeight: Binding<CGFloat>) {
        _measuredHeight = measuredHeight
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "heightChanged", let height = message.body as? Double {
            let normalizedHeight = max(18, ceil(CGFloat(height)))
            guard abs(normalizedHeight - measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { [self] in
                measuredHeight = normalizedHeight
            }
        } else if message.name == "linkClicked", let urlString = message.body as? String {
            handleLinkClick(urlString)
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
            if let vscodeURL = vscodeFileURL(for: path),
               NSWorkspace.shared.urlForApplication(toOpen: vscodeURL) != nil {
                NSWorkspace.shared.open(vscodeURL)
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func vscodeFileURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        components.path = path
        return components.url
    }
}

// MARK: - Container View

final class AssistantMarkdownWebContainerView: NSView, WKNavigationDelegate {
    let coordinator: AssistantMarkdownWebCoordinator

    private static var cachedHTMLString: String?

    private let webView: WKWebView
    private var currentContentID: String?
    private var currentText = ""
    private var isReady = false
    private var pendingContent: (text: String, isStreaming: Bool)?
    private var pendingTextScale: CGFloat?

    // Streaming throttle
    private var streamingThrottleTimer: Timer?
    private var pendingStreamingText: String?
    private var pendingStreamingFlag = false
    private static let streamingThrottleInterval: TimeInterval = 0.05

    init(coordinator: AssistantMarkdownWebCoordinator) {
        self.coordinator = coordinator

        let config = WKWebViewConfiguration()
        let uc = config.userContentController
        uc.add(coordinator, name: "heightChanged")
        uc.add(coordinator, name: "linkClicked")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true

        webView.navigationDelegate = self
        addSubview(webView)

        // Add ready handler
        let readyHandler = ReadyMessageHandler { [weak self] in
            self?.isReady = true
            if let pending = self?.pendingContent {
                self?.sendContent(pending.text, isStreaming: pending.isStreaming)
                self?.pendingContent = nil
            }
            if let scale = self?.pendingTextScale {
                self?.sendTextScale(scale)
                self?.pendingTextScale = nil
            }
        }
        uc.add(readyHandler, name: "ready")

        loadTemplate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

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

        guard let url, let html = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        Self.cachedHTMLString = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Content Updates

    func apply(contentID: String, text: String, isStreaming: Bool, textScale: CGFloat) {
        let contentIDChanged = currentContentID != contentID
        currentContentID = contentID

        if contentIDChanged {
            // New message — full reset
            cancelStreamingThrottle()
            currentText = ""
        }

        if text == currentText && !contentIDChanged {
            // No text change; just ensure scale is applied
            sendTextScale(textScale)
            return
        }

        currentText = text
        sendTextScale(textScale)

        if isStreaming {
            // Throttle streaming updates
            pendingStreamingText = text
            pendingStreamingFlag = isStreaming
            if streamingThrottleTimer == nil {
                flushStreamingContent()
                streamingThrottleTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.streamingThrottleInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.flushStreamingContent()
                }
            }
        } else {
            // Final render — send immediately
            cancelStreamingThrottle()
            sendContent(text, isStreaming: false)
        }
    }

    private func flushStreamingContent() {
        guard let text = pendingStreamingText else {
            cancelStreamingThrottle()
            return
        }
        pendingStreamingText = nil
        sendContent(text, isStreaming: pendingStreamingFlag)
    }

    private func cancelStreamingThrottle() {
        streamingThrottleTimer?.invalidate()
        streamingThrottleTimer = nil
        if pendingStreamingText != nil {
            flushStreamingContent()
        }
    }

    private func sendContent(_ text: String, isStreaming: Bool) {
        guard isReady else {
            pendingContent = (text, isStreaming)
            return
        }

        guard let jsonData = try? JSONEncoder().encode(text),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let js = "setContent(\(jsonString),\(isStreaming))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func sendTextScale(_ scale: CGFloat) {
        guard isReady else {
            pendingTextScale = scale
            return
        }
        webView.evaluateJavaScript("setTextScale(\(scale))", completionHandler: nil)
    }

    // MARK: - Navigation Delegate (Link Handling Fallback)

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

    deinit {
        cancelStreamingThrottle()
        let uc = webView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "heightChanged")
        uc.removeScriptMessageHandler(forName: "linkClicked")
        uc.removeScriptMessageHandler(forName: "ready")
    }
}

// MARK: - Ready Message Handler

private final class ReadyMessageHandler: NSObject, WKScriptMessageHandler {
    private let onReady: () -> Void

    init(onReady: @escaping () -> Void) {
        self.onReady = onReady
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "ready" {
            onReady()
        }
    }
}
