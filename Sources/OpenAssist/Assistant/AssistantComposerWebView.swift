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
    let previewDataURL: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "filename": filename,
            "kind": kind,
        ]
        if let previewDataURL, !previewDataURL.isEmpty {
            json["previewDataUrl"] = previewDataURL
        }
        return json
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

struct AssistantComposerWebPlugin: Equatable {
    let pluginID: String
    let displayName: String
    let summary: String?
    let needsSetup: Bool
    let iconDataURL: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "pluginId": pluginID,
            "displayName": displayName,
            "needsSetup": needsSetup,
        ]
        if let summary, !summary.isEmpty {
            json["summary"] = summary
        }
        if let iconDataURL, !iconDataURL.isEmpty {
            json["iconDataUrl"] = iconDataURL
        }
        return json
    }
}

struct AssistantComposerWebSlashCommand: Equatable {
    let id: String
    let label: String
    let subtitle: String
    let groupID: String
    let groupLabel: String
    let groupTone: String
    let groupOrder: Int
    let searchKeywords: [String]
    let insertText: String
    let behavior: String
    let localMode: String?

    init(descriptor: AssistantSlashCommandDescriptor) {
        self.id = descriptor.id
        self.label = descriptor.label
        self.subtitle = descriptor.subtitle
        self.groupID = descriptor.groupID
        self.groupLabel = descriptor.groupLabel
        self.groupTone = descriptor.groupTone
        self.groupOrder = descriptor.groupOrder
        self.searchKeywords = descriptor.searchKeywords
        self.insertText = descriptor.insertText
        self.behavior = descriptor.behavior.rawValue
        self.localMode = descriptor.localMode
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "label": label,
            "subtitle": subtitle,
            "groupId": groupID,
            "groupLabel": groupLabel,
            "groupTone": groupTone,
            "groupOrder": groupOrder,
            "searchKeywords": searchKeywords,
            "insertText": insertText,
            "behavior": behavior,
        ]
        if let localMode, !localMode.isEmpty {
            json["localMode"] = localMode
        }
        return json
    }
}

struct AssistantComposerWebBaseState: Equatable {
    let draftText: String
    let placeholder: String
    let isCompactComposer: Bool
    let isEnabled: Bool
    let canSend: Bool
    let isNoteModeActive: Bool
    let noteModeLabel: String?
    let noteModeHelperText: String?
    let showNoteModeButton: Bool
    let canOpenSkills: Bool
    let canOpenPlugins: Bool
    let preflightStatusMessage: String?
    let activeSkills: [AssistantComposerWebSkill]
    let selectedPlugins: [AssistantComposerWebPlugin]
    let availablePlugins: [AssistantComposerWebPlugin]
    let attachments: [AssistantComposerWebAttachment]
    let activeProviderID: String
    let slashCommands: [AssistantComposerWebSlashCommand]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "draftText": draftText,
            "placeholder": placeholder,
            "isCompactComposer": isCompactComposer,
            "isEnabled": isEnabled,
            "canSend": canSend,
            "isNoteModeActive": isNoteModeActive,
            "showNoteModeButton": showNoteModeButton,
            "canOpenSkills": canOpenSkills,
            "canOpenPlugins": canOpenPlugins,
            "activeSkills": activeSkills.map { $0.toJSON() },
            "selectedPlugins": selectedPlugins.map { $0.toJSON() },
            "availablePlugins": availablePlugins.map { $0.toJSON() },
            "attachments": attachments.map { $0.toJSON() },
            "activeProviderId": activeProviderID,
            "slashCommands": slashCommands.map { $0.toJSON() },
        ]
        if let noteModeLabel, !noteModeLabel.isEmpty {
            json["noteModeLabel"] = noteModeLabel
        }
        if let noteModeHelperText, !noteModeHelperText.isEmpty {
            json["noteModeHelperText"] = noteModeHelperText
        }
        if let preflightStatusMessage, !preflightStatusMessage.isEmpty {
            json["preflightStatusMessage"] = preflightStatusMessage
        }
        return json
    }
}

struct AssistantComposerWebControlsState: Equatable {
    let availability: AssistantRuntimeControlsAvailability
    let availabilityStatusText: String?
    let showsInteractionModeControl: Bool
    let showsModelControls: Bool
    let showsReasoningControls: Bool
    let selectedInteractionMode: String
    let interactionModes: [AssistantComposerWebOption]
    let selectedModelID: String?
    let modelOptions: [AssistantComposerWebOption]
    let modelPlaceholder: String
    let opensModelSetupWhenUnavailable: Bool
    let selectedReasoningID: String
    let reasoningOptions: [AssistantComposerWebOption]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "availability": availability.rawValue,
            "showsInteractionModeControl": showsInteractionModeControl,
            "showsModelControls": showsModelControls,
            "showsReasoningControls": showsReasoningControls,
            "selectedInteractionMode": selectedInteractionMode,
            "interactionModes": interactionModes.map { $0.toJSON() },
            "modelOptions": modelOptions.map { $0.toJSON() },
            "modelPlaceholder": modelPlaceholder,
            "opensModelSetupWhenUnavailable": opensModelSetupWhenUnavailable,
            "selectedReasoningId": selectedReasoningID,
            "reasoningOptions": reasoningOptions.map { $0.toJSON() },
        ]
        if let availabilityStatusText, !availabilityStatusText.isEmpty {
            json["availabilityStatusText"] = availabilityStatusText
        }
        if let selectedModelID, !selectedModelID.isEmpty {
            json["selectedModelId"] = selectedModelID
        }
        return json
    }
}

struct AssistantComposerWebActivityState: Equatable {
    let isBusy: Bool
    let activeTurnPhase: String
    let canCancelActiveTurn: Bool
    let canSteerActiveTurn: Bool
    let activeTurnProviderLabel: String?
    let hasPendingToolApproval: Bool
    let hasPendingInput: Bool
    let isVoiceCapturing: Bool
    let canUseVoiceInput: Bool
    let showStopVoicePlayback: Bool

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "isBusy": isBusy,
            "activeTurnPhase": activeTurnPhase,
            "canCancelActiveTurn": canCancelActiveTurn,
            "canSteerActiveTurn": canSteerActiveTurn,
            "hasPendingToolApproval": hasPendingToolApproval,
            "hasPendingInput": hasPendingInput,
            "isVoiceCapturing": isVoiceCapturing,
            "canUseVoiceInput": canUseVoiceInput,
            "showStopVoicePlayback": showStopVoicePlayback,
        ]
        if let activeTurnProviderLabel, !activeTurnProviderLabel.isEmpty {
            json["activeTurnProviderLabel"] = activeTurnProviderLabel
        }
        return json
    }
}

struct AssistantComposerWebState: Equatable {
    let base: AssistantComposerWebBaseState
    let controls: AssistantComposerWebControlsState
    let activity: AssistantComposerWebActivityState
}

struct AssistantComposerWebView: NSViewRepresentable {
    let state: AssistantComposerWebState
    var accentColor: Color? = nil
    let onHeightChange: (CGFloat) -> Void
    let onCommand: (String, [String: Any]?) -> Void

    func makeCoordinator() -> AssistantComposerWebCoordinator {
        AssistantComposerWebCoordinator(
            onCommand: onCommand,
            onHeightChange: onHeightChange
        )
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
        context.coordinator.onCommand = onCommand
        context.coordinator.onHeightChange = onHeightChange
        container.coordinator = context.coordinator
        container.applyState(state)
        if let accentColor {
            container.applyAccentColor(accentColor)
        }
    }
}

final class AssistantComposerWebCoordinator: NSObject, WKScriptMessageHandler {
    var onCommand: (String, [String: Any]?) -> Void
    var onHeightChange: (CGFloat) -> Void

    init(
        onCommand: @escaping (String, [String: Any]?) -> Void,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.onCommand = onCommand
        self.onHeightChange = onHeightChange
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "composerHeightDidChange" {
            let heightValue: CGFloat?
            if let number = message.body as? NSNumber {
                heightValue = CGFloat(truncating: number)
            } else if let value = message.body as? Double {
                heightValue = CGFloat(value)
            } else if let value = message.body as? CGFloat {
                heightValue = value
            } else {
                heightValue = nil
            }

            guard let height = heightValue, height.isFinite else { return }

            DispatchQueue.main.async { [onHeightChange] in
                onHeightChange(height)
            }
            return
        }

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
#if DEBUG
    private static var composerControlsSendCount = 0
#endif

    private let webView: WKWebView
    private var isReady = false
    private var pendingBaseState: AssistantComposerWebBaseState?
    private var pendingControlsState: AssistantComposerWebControlsState?
    private var pendingActivityState: AssistantComposerWebActivityState?
    private var pendingAccentCSS: String?
    private var lastAppliedBaseState: AssistantComposerWebBaseState?
    private var lastAppliedControlsState: AssistantComposerWebControlsState?
    private var lastAppliedActivityState: AssistantComposerWebActivityState?
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
        userContentController.add(coordinator, name: "composerHeightDidChange")

        let webView = AssistantInteractiveWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = CGColor.clear
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
        if lastAppliedBaseState != state.base {
            lastAppliedBaseState = state.base
            sendBaseState(state.base)
        }
        if lastAppliedControlsState != state.controls {
            lastAppliedControlsState = state.controls
            sendControlsState(state.controls)
        }
        if lastAppliedActivityState != state.activity {
            lastAppliedActivityState = state.activity
            sendActivityState(state.activity)
        }
    }

    private func handleReady() {
        isReady = true
        webView.evaluateJavaScript("chatBridge.setViewMode('composer')", completionHandler: nil)
        if let pendingAccentCSS {
            webView.evaluateJavaScript(pendingAccentCSS, completionHandler: nil)
            self.pendingAccentCSS = nil
        }
        if let pendingBaseState {
            sendBaseState(pendingBaseState)
            self.pendingBaseState = nil
        }
        if let pendingControlsState {
            sendControlsState(pendingControlsState)
            self.pendingControlsState = nil
        }
        if let pendingActivityState {
            sendActivityState(pendingActivityState)
            self.pendingActivityState = nil
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

    private func sendBaseState(_ state: AssistantComposerWebBaseState) {
        guard isReady else {
            pendingBaseState = state
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

    private func sendControlsState(_ state: AssistantComposerWebControlsState) {
        guard isReady else {
            pendingControlsState = state
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: state.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setComposerControls?.(\(jsonString));",
            completionHandler: nil
        )

#if DEBUG
        Self.composerControlsSendCount += 1
        if ProcessInfo.processInfo.environment["OPENASSIST_DEBUG_COMPOSER_CONTROLS"] == "1" {
            NSLog(
                "AssistantComposerWebView controls update #%d availability=%@",
                Self.composerControlsSendCount,
                state.availability.rawValue
            )
        }
#endif
    }

    private func sendActivityState(_ state: AssistantComposerWebActivityState) {
        guard isReady else {
            pendingActivityState = state
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: state.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setComposerActivity?.(\(jsonString));",
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
        pendingBaseState = lastAppliedBaseState
        pendingControlsState = lastAppliedControlsState
        pendingActivityState = lastAppliedActivityState
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
