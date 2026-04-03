import AppKit
import SwiftUI

@MainActor
final class AssistantSelectionActionHUDManager {
    static let shared = AssistantSelectionActionHUDManager()

    private enum Layout {
        static let actionSize = NSSize(width: 332, height: 52)
        static let composerSize = NSSize(width: 442, height: 308)
        static let loadingSize = NSSize(width: 352, height: 214)
        static let resultSize = NSSize(width: 462, height: 388)
        static let compactResultSize = NSSize(width: 404, height: 252)
        static let screenMargin: CGFloat = 10
        static let anchorGap: CGFloat = 10
        static let cornerRadius: CGFloat = 18
    }

    enum Mode {
        case actions
        case questionComposer
        case loading
        case result
    }

    struct RuntimeControls {
        let providerOptions: [AssistantRuntimeBackend]
        let selectedProvider: AssistantRuntimeBackend
        let isProviderSelectionDisabled: Bool
        let modelOptions: [AssistantModelOption]
        let selectedModelID: String?
        let selectedModelSummary: String
        let isModelLoading: Bool
    }

    final class ViewModel: ObservableObject {
        @Published var mode: Mode = .actions
        @Published var panelSize: NSSize = Layout.actionSize
        @Published var title: String = ""
        @Published var metaText: String = ""
        @Published var selectedPreview: String = ""
        @Published var bodyText: String = ""
        @Published var questionDraft: String = ""
        @Published var isError = false
        @Published var isStreaming = false
        @Published var runtimeControls: RuntimeControls?
        @Published var conversationTurns: [SelectionAskConversationTurn] = []

        var onExplain: (() -> Void)?
        var onAsk: (() -> Void)?
        var onAddToNote: (() -> Void)?
        var onGenerateChart: (() -> Void)?
        var onSubmitQuestion: ((String) -> Void)?
        var onCancelQuestion: (() -> Void)?
        var onClose: (() -> Void)?
        var onOpenSettings: (() -> Void)?
        var onChooseProvider: ((AssistantRuntimeBackend) -> Void)?
        var onChooseModel: ((String) -> Void)?
    }

    private final class HUDPanel: NSPanel {
        var allowsKeyStatus = false

        override var canBecomeKey: Bool { allowsKeyStatus }
        override var canBecomeMain: Bool { allowsKeyStatus }
    }

    private let viewModel = ViewModel()
    private var panel: HUDPanel?
    private var anchorRect = NSRect.zero
    private var appObservers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            },
            center.addObserver(
                forName: NSApplication.didHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        ]
    }

    deinit {
        let center = NotificationCenter.default
        for observer in appObservers {
            center.removeObserver(observer)
        }
    }

    var retainsPresentationWithoutSelection: Bool {
        guard panel?.isVisible == true else { return false }
        switch viewModel.mode {
        case .questionComposer, .loading, .result:
            return true
        case .actions:
            return false
        }
    }

    func show(
        anchorRect: NSRect,
        onExplain: @escaping () -> Void,
        onAsk: @escaping () -> Void,
        onAddToNote: @escaping () -> Void,
        onGenerateChart: @escaping () -> Void
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .actions
        viewModel.title = ""
        viewModel.metaText = ""
        viewModel.selectedPreview = ""
        viewModel.bodyText = ""
        viewModel.questionDraft = ""
        viewModel.isError = false
        viewModel.isStreaming = false
        viewModel.runtimeControls = nil
        viewModel.conversationTurns = []
        viewModel.onExplain = onExplain
        viewModel.onAsk = onAsk
        viewModel.onAddToNote = onAddToNote
        viewModel.onGenerateChart = onGenerateChart
        viewModel.onSubmitQuestion = nil
        viewModel.onCancelQuestion = nil
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onOpenSettings = nil
        viewModel.onChooseProvider = nil
        viewModel.onChooseModel = nil
        render(size: Layout.actionSize, makeKey: false)
    }

    func showQuestionComposer(
        anchorRect: NSRect,
        selectedPreview: String,
        metaText: String = "",
        conversationTurns: [SelectionAskConversationTurn] = [],
        runtimeControls: RuntimeControls? = nil,
        onChooseProvider: ((AssistantRuntimeBackend) -> Void)? = nil,
        onChooseModel: ((String) -> Void)? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .questionComposer
        viewModel.title = "Side Assistant"
        viewModel.metaText = metaText
        viewModel.runtimeControls = runtimeControls
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = ""
        viewModel.questionDraft = ""
        viewModel.isError = false
        viewModel.isStreaming = false
        viewModel.conversationTurns = conversationTurns
        viewModel.onSubmitQuestion = onSubmit
        viewModel.onCancelQuestion = onCancel
        viewModel.onAddToNote = nil
        viewModel.onGenerateChart = nil
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onOpenSettings = nil
        viewModel.onChooseProvider = onChooseProvider
        viewModel.onChooseModel = onChooseModel
        render(size: Layout.composerSize, makeKey: true)
    }

    func updateQuestionComposerRuntimeControls(
        _ runtimeControls: RuntimeControls,
        metaText: String? = nil
    ) {
        guard viewModel.mode == .questionComposer else { return }
        viewModel.runtimeControls = runtimeControls
        if let metaText {
            viewModel.metaText = metaText
        }
    }

    func showLoading(
        anchorRect: NSRect,
        selectedPreview: String,
        title: String,
        metaText: String = "",
        conversationTurns: [SelectionAskConversationTurn] = []
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .loading
        viewModel.title = title
        viewModel.metaText = metaText
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = ""
        viewModel.isError = false
        viewModel.isStreaming = true
        viewModel.runtimeControls = nil
        viewModel.conversationTurns = conversationTurns
        viewModel.onAddToNote = nil
        viewModel.onGenerateChart = nil
        viewModel.onChooseProvider = nil
        viewModel.onChooseModel = nil
        render(size: Layout.loadingSize, makeKey: false)
    }

    func showResult(
        anchorRect: NSRect,
        selectedPreview: String,
        title: String,
        bodyText: String,
        metaText: String = "",
        conversationTurns: [SelectionAskConversationTurn] = [],
        isError: Bool,
        isStreaming: Bool,
        onAsk: (() -> Void)?,
        onClose: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .result
        viewModel.title = title
        viewModel.metaText = metaText
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = bodyText
        viewModel.isError = isError
        viewModel.isStreaming = isStreaming
        viewModel.runtimeControls = nil
        viewModel.conversationTurns = conversationTurns
        viewModel.onAsk = onAsk
        viewModel.onAddToNote = nil
        viewModel.onGenerateChart = nil
        viewModel.onClose = onClose
        viewModel.onOpenSettings = onOpenSettings
        viewModel.onChooseProvider = nil
        viewModel.onChooseModel = nil
        render(size: isError ? Layout.compactResultSize : Layout.resultSize, makeKey: false)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func render(size: NSSize, makeKey: Bool) {
        let size = responsiveSize(for: size)
        let panel = ensurePanel()
        viewModel.panelSize = size
        panel.allowsKeyStatus = makeKey
        panel.setFrame(resolvedFrame(for: size, anchorRect: anchorRect), display: true)
        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    private func ensurePanel() -> HUDPanel {
        if let panel {
            return panel
        }

        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Layout.actionSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = NSHostingController(
            rootView: AssistantSelectionActionHUDRootView(viewModel: viewModel)
        )
        self.panel = panel
        return panel
    }

    private func responsiveSize(for preferredSize: NSSize) -> NSSize {
        guard let screen = screen(containing: anchorRect) ?? NSScreen.main else {
            return preferredSize
        }

        let visibleFrame = screen.visibleFrame
        let widthLimit = max(220, visibleFrame.width - (Layout.screenMargin * 2))
        let heightLimit = max(100, visibleFrame.height - (Layout.screenMargin * 2))

        let size: NSSize
        switch viewModel.mode {
        case .actions:
            size = NSSize(
                width: min(preferredSize.width, widthLimit),
                height: preferredSize.height
            )
        case .questionComposer:
            size = NSSize(
                width: min(widthLimit, 458),
                height: min(heightLimit, viewModel.conversationTurns.isEmpty ? 324 : 430)
            )
        case .loading:
            size = NSSize(
                width: min(widthLimit, 364),
                height: min(heightLimit, viewModel.conversationTurns.isEmpty ? 226 : 320)
            )
        case .result:
            size = NSSize(
                width: min(widthLimit, viewModel.isError ? 412 : 470),
                height: min(
                    heightLimit,
                    viewModel.isError
                        ? (viewModel.conversationTurns.isEmpty ? 264 : 364)
                        : (viewModel.conversationTurns.isEmpty ? 392 : 500)
                )
            )
        }

        return NSSize(width: round(size.width), height: round(size.height))
    }

    private func resolvedFrame(for size: NSSize, anchorRect: NSRect) -> NSRect {
        guard let screen = screen(containing: anchorRect) ?? NSScreen.main else {
            return NSRect(origin: anchorRect.origin, size: size)
        }

        let visibleFrame = screen.visibleFrame
        let x = max(
            visibleFrame.minX + Layout.screenMargin,
            min(
                anchorRect.midX - (size.width / 2),
                visibleFrame.maxX - size.width - Layout.screenMargin
            )
        )

        let aboveY = anchorRect.maxY + Layout.anchorGap
        let belowY = anchorRect.minY - size.height - Layout.anchorGap
        let y: CGFloat

        if aboveY + size.height <= visibleFrame.maxY - Layout.screenMargin {
            y = aboveY
        } else if belowY >= visibleFrame.minY + Layout.screenMargin {
            y = belowY
        } else {
            y = max(
                visibleFrame.minY + Layout.screenMargin,
                min(
                    aboveY,
                    visibleFrame.maxY - size.height - Layout.screenMargin
                )
            )
        }

        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) }
    }
}

private struct AssistantSelectionActionHUDRootView: View {
    @ObservedObject var viewModel: AssistantSelectionActionHUDManager.ViewModel
    @FocusState private var questionFieldFocused: Bool
    @State private var isSelectedPreviewExpanded = false

    private var isCompactActionsMode: Bool {
        viewModel.mode == .actions
    }

    private var panelCornerRadius: CGFloat {
        isCompactActionsMode ? 18 : 18
    }

    var body: some View {
        Group {
            switch viewModel.mode {
            case .actions:
                actionsView
            case .questionComposer:
                questionComposerView
            case .loading:
                loadingView
            case .result:
                resultView
            }
        }
        .padding(isCompactActionsMode ? 0 : 10)
        .background {
            if isCompactActionsMode {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.125, green: 0.13, blue: 0.15).opacity(0.985),
                                Color(red: 0.095, green: 0.10, blue: 0.12).opacity(0.985)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.8)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.038),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 44)
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(AppVisualTheme.baseTint.opacity(0.08))
                            .frame(width: 1)
                            .padding(.vertical, 18)
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isCompactActionsMode ? 0 : panelCornerRadius,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isCompactActionsMode ? 0 : 0.28),
            radius: isCompactActionsMode ? 0 : 20,
            x: 0,
            y: isCompactActionsMode ? 0 : 10
        )
    }

    private var actionsView: some View {
        HStack(spacing: 6) {
            actionButton(
                title: "Explain",
                symbol: "text.alignleft",
                tint: AppVisualTheme.baseTint
            ) {
                viewModel.onExplain?()
            }

            actionButton(
                title: "Ask",
                symbol: "questionmark.bubble",
                tint: AppVisualTheme.accentTint
            ) {
                viewModel.onAsk?()
            }

            actionMenu(
                title: "Add to Note",
                symbol: "note.text.badge.plus",
                tint: Color(red: 0.40, green: 0.72, blue: 0.58)
            ) {
                if let onAddToNote = viewModel.onAddToNote {
                    Button("Add Selection") {
                        onAddToNote()
                    }
                }
                if let onGenerateChart = viewModel.onGenerateChart {
                    Button("Generate Chart") {
                        onGenerateChart()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.09), lineWidth: 0.8)
                )
        )
        .frame(width: viewModel.panelSize.width, alignment: .center)
    }

    private var questionComposerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: false)

            if viewModel.runtimeControls != nil {
                runtimeControlsRow
            }

            selectionPreviewDisclosure(
                lineLimit: viewModel.conversationTurns.isEmpty ? 4 : 2
            )

            if !viewModel.conversationTurns.isEmpty {
                conversationHistoryCard(maxHeight: 132)
            }

            sectionCard(
                title: "Your Question",
                symbol: "bubble.left.and.pencil",
                tint: AppVisualTheme.baseTint
            ) {
                ZStack(alignment: .leading) {
                    if viewModel.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Ask what it means or what you could say next.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.52))
                            .padding(.horizontal, 12)
                    }

                    TextField("", text: $viewModel.questionDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                        .submitLabel(.send)
                        .onSubmit {
                            submitQuestionDraft()
                        }
                        .focused($questionFieldFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppVisualTheme.surfaceFill(0.07),
                                    AppVisualTheme.surfaceFill(0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppVisualTheme.foreground(0.14), lineWidth: 0.9)
                        )
                )

                Text("Ask a quick follow-up. It keeps the side chat short and focused.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.68))
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    viewModel.onCancelQuestion?()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppVisualTheme.foreground(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.7)
                        )
                )

                Spacer()

                Button("Ask") {
                    submitQuestionDraft()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppVisualTheme.accentTint.opacity(0.84),
                                    AppVisualTheme.baseTint.opacity(0.74)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .foregroundStyle(AppVisualTheme.primaryText)
                .disabled(
                    viewModel.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .opacity(
                    viewModel.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? 0.55
                        : 1
                )
            }
        }
        .frame(
            width: viewModel.panelSize.width,
            height: viewModel.panelSize.height,
            alignment: .topLeading
        )
        .onAppear {
            isSelectedPreviewExpanded = false
            DispatchQueue.main.async {
                questionFieldFocused = true
            }
        }
    }

    private func submitQuestionDraft() {
        let question = viewModel.questionDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        viewModel.onSubmitQuestion?(question)
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: false)

            selectionPreviewDisclosure(
                lineLimit: viewModel.conversationTurns.isEmpty ? 4 : 2
            )

            if !viewModel.conversationTurns.isEmpty {
                conversationHistoryCard(maxHeight: 118)
            }

            sectionCard(
                title: "Side Assistant",
                symbol: "sparkles",
                tint: AppVisualTheme.baseTint,
                tone: .dark
            ) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppVisualTheme.foreground(0.85))

                    Text("Thinking through your question.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.82))
                        .lineSpacing(2)
                }
            }
        }
        .frame(
            width: viewModel.panelSize.width,
            height: viewModel.panelSize.height,
            alignment: .topLeading
        )
        .onAppear {
            isSelectedPreviewExpanded = false
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: true)

            selectionPreviewDisclosure(
                lineLimit: viewModel.conversationTurns.isEmpty ? (viewModel.isError ? 3 : 4) : 2
            )

            if !viewModel.conversationTurns.isEmpty {
                conversationHistoryCard(maxHeight: viewModel.isError ? 132 : 214)
            }

            if viewModel.isError || viewModel.conversationTurns.isEmpty {
                sectionCard(
                    title: viewModel.isError ? "Problem" : "Side Assistant",
                    symbol: viewModel.isError ? "exclamationmark.triangle.fill" : "bubble.left.and.text.bubble.right.fill",
                    tint: viewModel.isError ? .orange : AppVisualTheme.baseTint,
                    tone: .dark
                ) {
                    ScrollView {
                        Text(viewModel.bodyText)
                            .font(.system(size: 14.5, weight: .regular))
                            .foregroundStyle(AppVisualTheme.foreground(viewModel.isError ? 0.86 : 0.92))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: viewModel.isError ? 88 : 188,
                        maxHeight: viewModel.isError ? 112 : .infinity,
                        alignment: .topLeading
                    )
                }
            }

            HStack(spacing: 8) {
                if let onOpenSettings = viewModel.onOpenSettings {
                    Button("Open Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.foreground(0.06))
                    )
                }

                if let onAsk = viewModel.onAsk, !viewModel.isError {
                    Button("Ask Follow-up") {
                        onAsk()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.baseTint.opacity(0.18))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppVisualTheme.baseTint.opacity(0.28), lineWidth: 0.8)
                            )
                    )
                }

                Spacer()

                if viewModel.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppVisualTheme.foreground(0.70))
                        Text("Streaming")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.60))
                    }
                }
            }
        }
        .frame(
            width: viewModel.panelSize.width,
            height: viewModel.panelSize.height,
            alignment: .topLeading
        )
        .onAppear {
            isSelectedPreviewExpanded = false
        }
    }

    private func selectionPreviewDisclosure(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: isSelectedPreviewExpanded ? 10 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isSelectedPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.96))

                        Text(isSelectedPreviewExpanded ? "Hide Selection" : "Show Selection")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.86))
                    }

                    Spacer()

                    Image(systemName: isSelectedPreviewExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.58))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelectedPreviewExpanded {
                Text(viewModel.selectedPreview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.80))
                    .lineSpacing(2.5)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppVisualTheme.surfaceFill(0.05),
                            AppVisualTheme.surfaceFill(0.025)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.8)
                )
        )
    }

    private func conversationHistoryCard(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                sectionBadge(
                    title: "Conversation",
                    symbol: "bubble.left.and.text.bubble.right",
                    tint: AppVisualTheme.baseTint
                )

                if hasHiddenConversationTurns {
                    Text("Latest exchange")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.52))
                }

                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(visibleConversationTurns.enumerated()), id: \.offset) { _, turn in
                        conversationTurnRow(turn)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.8)
                )
        )
    }

    private func conversationTurnRow(_ turn: SelectionAskConversationTurn) -> some View {
        let isUser = turn.role == .user

        return HStack(alignment: .top, spacing: 0) {
            if isUser {
                Spacer(minLength: 42)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(isUser ? "You" : "Side Assistant")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(
                        isUser
                            ? AppVisualTheme.accentTint.opacity(0.96)
                            : AppVisualTheme.foreground(0.76)
                    )

                Text(turn.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.95))
                    .lineSpacing(3.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                isUser
                                    ? AppVisualTheme.accentTint.opacity(0.14)
                                    : Color.black.opacity(0.88)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        isUser
                                            ? AppVisualTheme.accentTint.opacity(0.18)
                                            : AppVisualTheme.foreground(0.10),
                                        lineWidth: 0.8
                                    )
                            )
                    )
            }
            .frame(maxWidth: 308, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 42)
            }
        }
    }

    private var visibleConversationTurns: [SelectionAskConversationTurn] {
        Array(viewModel.conversationTurns.suffix(2))
    }

    private var hasHiddenConversationTurns: Bool {
        viewModel.conversationTurns.count > visibleConversationTurns.count
    }

    private var runtimeControlsRow: some View {
        guard let runtimeControls = viewModel.runtimeControls else {
            return AnyView(EmptyView())
        }

        let providerTitle = runtimeControls.selectedProvider.shortDisplayName
        let modelTitle = runtimeSelectedModelSummary(runtimeControls)

        return AnyView(
            HStack(spacing: 8) {
                runtimeMenu(
                    title: "Provider",
                    value: providerTitle,
                    tint: providerTint(for: runtimeControls.selectedProvider),
                    disabled: runtimeControls.isProviderSelectionDisabled
                ) {
                    ForEach(runtimeControls.providerOptions, id: \.self) { backend in
                        Button {
                            var updatedControls = runtimeControls
                            updatedControls = AssistantSelectionActionHUDManager.RuntimeControls(
                                providerOptions: runtimeControls.providerOptions,
                                selectedProvider: backend,
                                isProviderSelectionDisabled: runtimeControls.isProviderSelectionDisabled,
                                modelOptions: [],
                                selectedModelID: nil,
                                selectedModelSummary: "Loading models...",
                                isModelLoading: true
                            )
                            viewModel.runtimeControls = updatedControls
                            viewModel.onChooseProvider?(backend)
                        } label: {
                            if backend == runtimeControls.selectedProvider {
                                Label(backend.shortDisplayName, systemImage: "checkmark")
                            } else {
                                Text(backend.shortDisplayName)
                            }
                        }
                    }
                }

                runtimeMenu(
                    title: "Model",
                    value: modelTitle,
                    tint: AppVisualTheme.baseTint,
                    disabled: runtimeControls.modelOptions.isEmpty
                ) {
                    ForEach(runtimeControls.modelOptions.filter { !$0.hidden }) { model in
                        Button {
                            viewModel.runtimeControls = AssistantSelectionActionHUDManager.RuntimeControls(
                                providerOptions: runtimeControls.providerOptions,
                                selectedProvider: runtimeControls.selectedProvider,
                                isProviderSelectionDisabled: runtimeControls.isProviderSelectionDisabled,
                                modelOptions: runtimeControls.modelOptions,
                                selectedModelID: model.id,
                                selectedModelSummary: model.displayName,
                                isModelLoading: false
                            )
                            viewModel.onChooseModel?(model.id)
                        } label: {
                            if model.id == runtimeControls.selectedModelID {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        )
    }

    private func runtimeMenu<Content: View>(
        title: String,
        value: String,
        tint: Color,
        disabled: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.48))
                    Text(value)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(disabled ? 0.48 : 0.90))
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.34))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 0.8)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(disabled)
        .opacity(disabled ? 0.68 : 1)
        .help(title)
    }

    private func runtimeSelectedModelSummary(
        _ runtimeControls: AssistantSelectionActionHUDManager.RuntimeControls
    ) -> String {
        if let selectedModelID = runtimeControls.selectedModelID,
           let selectedModel = runtimeControls.modelOptions.first(where: { $0.id == selectedModelID })
        {
            return selectedModel.displayName
        }

        let summary = runtimeControls.selectedModelSummary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !summary.isEmpty {
            return summary
        }
        return runtimeControls.isModelLoading ? "Loading models..." : "Select model"
    }

    private func providerTint(for backend: AssistantRuntimeBackend) -> Color {
        Color(red: backend.brandHue.red, green: backend.brandHue.green, blue: backend.brandHue.blue)
    }

    private func header(title: String, showsClose: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.95))

                if !viewModel.metaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !(viewModel.mode == .questionComposer && viewModel.runtimeControls != nil)
                {
                    Text(viewModel.metaText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.70))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppVisualTheme.foreground(0.06))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.7)
                                )
                        )
                }
            }

            Spacer()

            if showsClose {
                Button {
                    viewModel.onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.62))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.foreground(0.05))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private enum SectionCardTone {
        case standard
        case dark
    }

    private func sectionCard<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        tone: SectionCardTone = .standard,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionBadge(title: title, symbol: symbol, tint: tint)
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    tone == .dark
                        ? LinearGradient(
                            colors: [
                                Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.98),
                                Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.98)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [
                                tint.opacity(0.06),
                                AppVisualTheme.surfaceFill(0.035)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            tone == .dark
                                ? AppVisualTheme.foreground(0.11)
                                : AppVisualTheme.foreground(0.08),
                            lineWidth: 0.8
                        )
                )
                .overlay(alignment: .top) {
                    if tone == .dark {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.032),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 34)
                    }
                }
        )
    }

    private func sectionBadge(
        title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.96))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.90))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 0.8)
                )
        )
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        HoverButton(action: action, tint: tint) {
            actionLabel(title: title, symbol: symbol)
        }
    }

    private func actionMenu<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            actionLabel(title: title, symbol: symbol, showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.07),
                            Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 0.8)
                )
        )
    }

    private func actionLabel(
        title: String,
        symbol: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.56))
            }
        }
        .foregroundStyle(AppVisualTheme.foreground(0.92))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct HoverButton<Label: View>: View {
    let action: () -> Void
    let tint: Color
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(isHovered ? 0.14 : 0.07),
                                    Color(red: 0.14, green: 0.15, blue: 0.18).opacity(isHovered ? 0.96 : 0.94)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(tint.opacity(isHovered ? 0.28 : 0.16), lineWidth: 0.8)
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
