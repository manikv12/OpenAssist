import AppKit
import SwiftUI
import WebKit

struct AssistantComposerWebOption: Equatable {
    let id: String
    let label: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "label": label,
        ]
    }
}

struct AssistantComposerWebAttachment: Equatable {
    let id: String
    let filename: String
    let kind: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "filename": filename,
            "kind": kind,
        ]
    }
}

struct AssistantComposerWebSkill: Equatable {
    let skillName: String
    let displayName: String
    let isMissing: Bool

    func toJSON() -> [String: Any] {
        [
            "skillName": skillName,
            "displayName": displayName,
            "isMissing": isMissing,
        ]
    }
}

struct AssistantComposerWebState: Equatable {
    let draftText: String
    let placeholder: String
    let isEnabled: Bool
    let canSend: Bool
    let isBusy: Bool
    let isVoiceCapturing: Bool
    let canUseVoiceInput: Bool
    let showStopVoicePlayback: Bool
    let canOpenSkills: Bool
    let selectedInteractionMode: String
    let interactionModes: [AssistantComposerWebOption]
    let selectedModelID: String?
    let modelOptions: [AssistantComposerWebOption]
    let selectedReasoningID: String
    let reasoningOptions: [AssistantComposerWebOption]
    let activeSkills: [AssistantComposerWebSkill]
    let attachments: [AssistantComposerWebAttachment]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "draftText": draftText,
            "placeholder": placeholder,
            "isEnabled": isEnabled,
            "canSend": canSend,
            "isBusy": isBusy,
            "isVoiceCapturing": isVoiceCapturing,
            "canUseVoiceInput": canUseVoiceInput,
            "showStopVoicePlayback": showStopVoicePlayback,
            "canOpenSkills": canOpenSkills,
            "selectedInteractionMode": selectedInteractionMode,
            "interactionModes": interactionModes.map { $0.toJSON() },
            "modelOptions": modelOptions.map { $0.toJSON() },
            "selectedReasoningId": selectedReasoningID,
            "reasoningOptions": reasoningOptions.map { $0.toJSON() },
            "activeSkills": activeSkills.map { $0.toJSON() },
            "attachments": attachments.map { $0.toJSON() },
        ]
        if let selectedModelID, !selectedModelID.isEmpty {
            json["selectedModelId"] = selectedModelID
        }
        return json
    }
}

struct AssistantComposerWebView: NSViewRepresentable {
    let state: AssistantComposerWebState
    var accentColor: Color? = nil
    let onCommand: (String, [String: Any]?) -> Void

    func makeCoordinator() -> AssistantComposerWebCoordinator {
        AssistantComposerWebCoordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> AssistantComposerWebContainerView {
        let container = AssistantComposerWebContainerView(coordinator: context.coordinator)
        container.applyState(state)
        if let accentColor {
            container.applyAccentColor(accentColor)
        }
        return container
    }

    func updateNSView(_ container: AssistantComposerWebContainerView, context: Context) {
        container.coordinator = context.coordinator
        container.applyState(state)
        if let accentColor {
            container.applyAccentColor(accentColor)
        }
    }
}

final class AssistantComposerWebCoordinator: NSObject, WKScriptMessageHandler {
    var onCommand: (String, [String: Any]?) -> Void

    init(onCommand: @escaping (String, [String: Any]?) -> Void) {
        self.onCommand = onCommand
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "composerCommand",
            let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else {
            return
        }

        let payload = body["payload"] as? [String: Any]
        DispatchQueue.main.async { [onCommand] in
            onCommand(type, payload)
        }
    }
}

final class AssistantComposerWebContainerView: NSView {
    var coordinator: AssistantComposerWebCoordinator

    private static var cachedHTMLString: String?

    private let webView: WKWebView
    private var isReady = false
    private var pendingState: AssistantComposerWebState?
    private var pendingAccentCSS: String?
    private var lastAppliedState: AssistantComposerWebState?
    private var lastAppliedAccentCSS: String?

    init(coordinator: AssistantComposerWebCoordinator) {
        self.coordinator = coordinator

        let config = WKWebViewConfiguration()
        let userContentController = config.userContentController
        let initialModeScript = WKUserScript(
            source: "window.__OPENASSIST_INITIAL_VIEW_MODE = 'composer';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(initialModeScript)
        userContentController.add(coordinator, name: "composerCommand")

        let webView = AssistantInteractiveWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true
        webView.navigationDelegate = self
        addSubview(webView)

        let readyHandler = AssistantComposerReadyHandler { [weak self] in
            self?.handleReady()
        }
        webView.configuration.userContentController.add(readyHandler, name: "ready")

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

    func applyState(_ state: AssistantComposerWebState) {
        guard lastAppliedState != state else { return }
        lastAppliedState = state
        sendState(state)
    }

    private func handleReady() {
        isReady = true
        webView.evaluateJavaScript("chatBridge.setViewMode('composer')", completionHandler: nil)
        if let pendingAccentCSS {
            webView.evaluateJavaScript(pendingAccentCSS, completionHandler: nil)
            self.pendingAccentCSS = nil
        }
        if let pendingState {
            sendState(pendingState)
            self.pendingState = nil
        }
    }

    private func loadTemplate() {
        if let html = Self.cachedHTMLString {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        let url: URL? =
            Bundle.main.url(forResource: "markdown-chat", withExtension: "html")
            ?? Bundle(identifier: "OpenAssist_OpenAssist")?.url(
                forResource: "markdown-chat", withExtension: "html")
            ?? {
                let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
                let candidates = [
                    execDir.appendingPathComponent(
                        "OpenAssist_OpenAssist.bundle/markdown-chat.html"),
                    execDir.appendingPathComponent("markdown-chat.html"),
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }()

        guard let url,
            let html = try? String(contentsOf: url, encoding: .utf8)
        else {
            return
        }

        Self.cachedHTMLString = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func sendState(_ state: AssistantComposerWebState) {
        guard isReady else {
            pendingState = state
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: state.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setViewMode('composer'); chatBridge.setComposerState(\(jsonString));",
            completionHandler: nil
        )
    }

    func applyAccentColor(_ color: Color) {
        let js = AssistantWebViewThemeBridge.accentJavaScript(color)
        guard lastAppliedAccentCSS != js else { return }
        lastAppliedAccentCSS = js
        guard isReady else {
            pendingAccentCSS = js
            return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

extension AssistantComposerWebContainerView: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        loadTemplate()
    }
}

private final class AssistantComposerReadyHandler: NSObject, WKScriptMessageHandler {
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
