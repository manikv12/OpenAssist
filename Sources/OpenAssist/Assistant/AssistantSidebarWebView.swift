import AppKit
import SwiftUI
import WebKit

struct AssistantSidebarWebNavItem: Equatable {
    let id: String
    let label: String
    let symbol: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "label": label,
            "symbol": symbol,
        ]
    }
}

struct AssistantSidebarWebProject: Equatable {
    let id: String
    let name: String
    let symbol: String
    let subtitle: String
    let kind: String
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let parentID: String?
    let menuTitle: String
    let hasLinkedFolder: Bool
    let hasCustomIcon: Bool
    let folderMissing: Bool

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "name": name,
            "symbol": symbol,
            "subtitle": subtitle,
            "kind": kind,
            "depth": depth,
            "isSelected": isSelected,
            "isExpanded": isExpanded,
            "menuTitle": menuTitle,
            "hasLinkedFolder": hasLinkedFolder,
            "hasCustomIcon": hasCustomIcon,
            "folderMissing": folderMissing,
        ]
        if let parentID, !parentID.isEmpty {
            json["parentId"] = parentID
        }
        return json
    }
}

struct AssistantSidebarWebHiddenProject: Equatable {
    let id: String
    let name: String
    let symbol: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "symbol": symbol,
        ]
    }
}

struct AssistantSidebarWebSession: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let timeLabel: String?
    let activityState: String?
    let isSelected: Bool
    let isTemporary: Bool
    let projectID: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "subtitle": subtitle,
            "isSelected": isSelected,
            "isTemporary": isTemporary,
        ]
        if let timeLabel, !timeLabel.isEmpty {
            json["timeLabel"] = timeLabel
        }
        if let activityState, !activityState.isEmpty {
            json["activityState"] = activityState
        }
        if let projectID, !projectID.isEmpty {
            json["projectId"] = projectID
        }
        return json
    }
}

struct AssistantSidebarWebNote: Equatable {
    let id: String
    let noteID: String
    let ownerKind: String
    let ownerID: String
    let title: String
    let subtitle: String
    let sourceLabel: String
    let isSelected: Bool
    let isArchivedThread: Bool
    let threadID: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "noteId": noteID,
            "ownerKind": ownerKind,
            "ownerId": ownerID,
            "title": title,
            "subtitle": subtitle,
            "sourceLabel": sourceLabel,
            "isSelected": isSelected,
            "isArchivedThread": isArchivedThread,
        ]
        if let threadID, !threadID.isEmpty {
            json["threadId"] = threadID
        }
        return json
    }
}

struct AssistantSidebarWebState: Equatable {
    let projectFilterKind: String
    let projectFilterID: String?
    let selectedPane: String
    let isCollapsed: Bool
    let collapsedPreviewPane: String?
    let canCreateThread: Bool
    let canCollapse: Bool
    let projectsTitle: String
    let projectsHelperText: String?
    let threadsTitle: String
    let threadsHelperText: String?
    let archivedTitle: String
    let archivedHelperText: String?
    let notesTitle: String
    let notesHelperText: String?
    let projectsExpanded: Bool
    let threadsExpanded: Bool
    let archivedExpanded: Bool
    let notesExpanded: Bool
    let canLoadMoreThreads: Bool
    let canLoadMoreArchived: Bool
    let archivedCount: Int
    let hiddenProjectCount: Int
    let selectedNotesProjectID: String?
    let notesScope: String
    let canCreateProjectNote: Bool
    let navItems: [AssistantSidebarWebNavItem]
    let allProjects: [AssistantSidebarWebProject]
    let hiddenProjects: [AssistantSidebarWebHiddenProject]
    let projects: [AssistantSidebarWebProject]
    let threads: [AssistantSidebarWebSession]
    let archived: [AssistantSidebarWebSession]
    let notes: [AssistantSidebarWebNote]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "projectFilterKind": projectFilterKind,
            "selectedPane": selectedPane,
            "isCollapsed": isCollapsed,
            "canCreateThread": canCreateThread,
            "canCollapse": canCollapse,
            "projectsTitle": projectsTitle,
            "threadsTitle": threadsTitle,
            "archivedTitle": archivedTitle,
            "notesTitle": notesTitle,
            "projectsExpanded": projectsExpanded,
            "threadsExpanded": threadsExpanded,
            "archivedExpanded": archivedExpanded,
            "notesExpanded": notesExpanded,
            "canLoadMoreThreads": canLoadMoreThreads,
            "canLoadMoreArchived": canLoadMoreArchived,
            "archivedCount": archivedCount,
            "hiddenProjectCount": hiddenProjectCount,
            "notesScope": notesScope,
            "canCreateProjectNote": canCreateProjectNote,
            "navItems": navItems.map { $0.toJSON() },
            "allProjects": allProjects.map { $0.toJSON() },
            "hiddenProjects": hiddenProjects.map { $0.toJSON() },
            "projects": projects.map { $0.toJSON() },
            "threads": threads.map { $0.toJSON() },
            "archived": archived.map { $0.toJSON() },
            "notes": notes.map { $0.toJSON() },
        ]
        if let projectFilterID, !projectFilterID.isEmpty {
            json["projectFilterId"] = projectFilterID
        }
        if let projectsHelperText, !projectsHelperText.isEmpty {
            json["projectsHelperText"] = projectsHelperText
        }
        if let threadsHelperText, !threadsHelperText.isEmpty {
            json["threadsHelperText"] = threadsHelperText
        }
        if let archivedHelperText, !archivedHelperText.isEmpty {
            json["archivedHelperText"] = archivedHelperText
        }
        if let notesHelperText, !notesHelperText.isEmpty {
            json["notesHelperText"] = notesHelperText
        }
        if let collapsedPreviewPane, !collapsedPreviewPane.isEmpty {
            json["collapsedPreviewPane"] = collapsedPreviewPane
        }
        if let selectedNotesProjectID, !selectedNotesProjectID.isEmpty {
            json["selectedNotesProjectId"] = selectedNotesProjectID
        }
        return json
    }
}

struct AssistantSidebarWebView: NSViewRepresentable {
    let state: AssistantSidebarWebState
    var textScale: CGFloat = 1.0
    var accentColor: Color? = nil
    let onCommand: (String, [String: Any]?) -> Void

    func makeCoordinator() -> AssistantSidebarWebCoordinator {
        AssistantSidebarWebCoordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> AssistantSidebarWebContainerView {
        let container = AssistantSidebarWebContainerView(coordinator: context.coordinator)
        container.applyState(state)
        container.applyTextScale(textScale)
        if let accentColor {
            container.applyAccentColor(accentColor)
        }
        return container
    }

    func updateNSView(_ container: AssistantSidebarWebContainerView, context: Context) {
        container.coordinator = context.coordinator
        container.applyState(state)
        container.applyTextScale(textScale)
        if let accentColor {
            container.applyAccentColor(accentColor)
        }
    }
}

final class AssistantSidebarWebCoordinator: NSObject, WKScriptMessageHandler {
    var onCommand: (String, [String: Any]?) -> Void

    init(onCommand: @escaping (String, [String: Any]?) -> Void) {
        self.onCommand = onCommand
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "sidebarCommand",
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

final class AssistantSidebarWebContainerView: NSView {
    var coordinator: AssistantSidebarWebCoordinator

    private static var cachedHTMLString: String?

    private let webView: WKWebView
    private var isReady = false
    private var pendingState: AssistantSidebarWebState?
    private var pendingAccentCSS: String?
    private var pendingTextScale: CGFloat?
    private var lastAppliedState: AssistantSidebarWebState?
    private var lastAppliedAccentCSS: String?
    private var lastAppliedTextScale: CGFloat?
    private var outsideClickMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(coordinator: AssistantSidebarWebCoordinator) {
        self.coordinator = coordinator

        let config = WKWebViewConfiguration()
        let userContentController = config.userContentController
        let initialModeScript = WKUserScript(
            source: "window.__OPENASSIST_INITIAL_VIEW_MODE = 'sidebar';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(initialModeScript)
        userContentController.add(coordinator, name: "sidebarCommand")

        let webView = AssistantInteractiveWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true
        webView.navigationDelegate = self
        addSubview(webView)

        let readyHandler = AssistantSidebarReadyHandler { [weak self] in
            self?.handleReady()
        }
        webView.configuration.userContentController.add(readyHandler, name: "ready")

        loadTemplate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopOutsideClickMonitor()
        removeWindowObservers()
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshOutsideClickMonitor()
        refreshWindowObservers()
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func applyState(_ state: AssistantSidebarWebState) {
        guard lastAppliedState != state else { return }
        lastAppliedState = state
        sendState(state)
    }

    private func handleReady() {
        isReady = true
        webView.evaluateJavaScript("chatBridge.setViewMode('sidebar')", completionHandler: nil)
        if let pendingAccentCSS {
            webView.evaluateJavaScript(pendingAccentCSS, completionHandler: nil)
            self.pendingAccentCSS = nil
        }
        if let pendingTextScale {
            sendTextScale(pendingTextScale)
            self.pendingTextScale = nil
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

    private func sendState(_ state: AssistantSidebarWebState) {
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
            "chatBridge.setViewMode('sidebar'); chatBridge.setSidebarState(\(jsonString));",
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

    func applyTextScale(_ scale: CGFloat) {
        let nextScale = max(0.8, scale)
        guard lastAppliedTextScale != nextScale else { return }
        lastAppliedTextScale = nextScale
        guard isReady else {
            pendingTextScale = nextScale
            return
        }
        sendTextScale(nextScale)
    }

    private func sendTextScale(_ scale: CGFloat) {
        webView.evaluateJavaScript(
            "chatBridge.setTextScale(\(Double(scale)))",
            completionHandler: nil
        )
    }

    private func refreshOutsideClickMonitor() {
        stopOutsideClickMonitor()
        guard window != nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard let window = self.window, event.window === window else { return event }

            let pointInSelf = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(pointInSelf) {
                return event
            }

            self.requestContextMenuDismiss()
            return event
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func refreshWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        let notificationCenter = NotificationCenter.default
        windowObservers.append(
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.requestContextMenuDismiss()
            }
        )
    }

    private func removeWindowObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in windowObservers {
            notificationCenter.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func requestContextMenuDismiss() {
        guard isReady else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new Event('openassist:close-sidebar-context-menu'));",
            completionHandler: nil
        )
    }
}

extension AssistantSidebarWebContainerView: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        loadTemplate()
    }
}

private final class AssistantSidebarReadyHandler: NSObject, WKScriptMessageHandler {
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
