import AppKit
import SwiftUI

@MainActor
final class AssistantSelectionActionHUDManager {
    static let shared = AssistantSelectionActionHUDManager()

    private enum Layout {
        static let actionSize = NSSize(width: 248, height: 54)
        static let composerSize = NSSize(width: 344, height: 170)
        static let loadingSize = NSSize(width: 296, height: 122)
        static let resultSize = NSSize(width: 396, height: 248)
        static let compactResultSize = NSSize(width: 352, height: 178)
        static let screenMargin: CGFloat = 10
        static let anchorGap: CGFloat = 10
        static let cornerRadius: CGFloat = 20
    }

    enum Mode {
        case actions
        case questionComposer
        case loading
        case result
    }

    final class ViewModel: ObservableObject {
        @Published var mode: Mode = .actions
        @Published var panelSize: NSSize = Layout.actionSize
        @Published var title: String = ""
        @Published var selectedPreview: String = ""
        @Published var bodyText: String = ""
        @Published var questionDraft: String = ""
        @Published var isError = false
        @Published var isStreaming = false

        var onExplain: (() -> Void)?
        var onAsk: (() -> Void)?
        var onSubmitQuestion: ((String) -> Void)?
        var onCancelQuestion: (() -> Void)?
        var onClose: (() -> Void)?
        var onOpenSettings: (() -> Void)?
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
        onAsk: @escaping () -> Void
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .actions
        viewModel.title = ""
        viewModel.selectedPreview = ""
        viewModel.bodyText = ""
        viewModel.questionDraft = ""
        viewModel.isError = false
        viewModel.isStreaming = false
        viewModel.onExplain = onExplain
        viewModel.onAsk = onAsk
        viewModel.onSubmitQuestion = nil
        viewModel.onCancelQuestion = nil
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onOpenSettings = nil
        render(size: Layout.actionSize, makeKey: false)
    }

    func showQuestionComposer(
        anchorRect: NSRect,
        selectedPreview: String,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .questionComposer
        viewModel.title = "Ask About Selection"
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = ""
        viewModel.questionDraft = ""
        viewModel.isError = false
        viewModel.isStreaming = false
        viewModel.onSubmitQuestion = onSubmit
        viewModel.onCancelQuestion = onCancel
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onOpenSettings = nil
        render(size: Layout.composerSize, makeKey: true)
    }

    func showLoading(
        anchorRect: NSRect,
        selectedPreview: String,
        title: String
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .loading
        viewModel.title = title
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = ""
        viewModel.isError = false
        viewModel.isStreaming = true
        render(size: Layout.loadingSize, makeKey: false)
    }

    func showResult(
        anchorRect: NSRect,
        selectedPreview: String,
        title: String,
        bodyText: String,
        isError: Bool,
        isStreaming: Bool,
        onAsk: (() -> Void)?,
        onClose: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.anchorRect = anchorRect
        viewModel.mode = .result
        viewModel.title = title
        viewModel.selectedPreview = selectedPreview
        viewModel.bodyText = bodyText
        viewModel.isError = isError
        viewModel.isStreaming = isStreaming
        viewModel.onAsk = onAsk
        viewModel.onClose = onClose
        viewModel.onOpenSettings = onOpenSettings
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
                width: min(widthLimit, 380),
                height: min(heightLimit, 180)
            )
        case .loading:
            size = NSSize(
                width: min(widthLimit, 320),
                height: min(heightLimit, 120)
            )
        case .result:
            size = NSSize(
                width: min(widthLimit, 420),
                height: min(heightLimit, viewModel.isError ? 200 : 280)
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

    private var isCompactActionsMode: Bool {
        viewModel.mode == .actions
    }

    private var panelCornerRadius: CGFloat {
        isCompactActionsMode ? 16 : 20
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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.14, blue: 0.17).opacity(0.985),
                                Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.985)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.7)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AppVisualTheme.foreground(0.035),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 56)
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
            y: isCompactActionsMode ? 0 : 12
        )
    }

    private var actionsView: some View {
        HStack(spacing: 8) {
            bubbleButton(title: "Explain", symbol: "text.alignleft") {
                viewModel.onExplain?()
            }

            bubbleButton(title: "Ask", symbol: "questionmark.bubble") {
                viewModel.onAsk?()
            }
        }
        .frame(width: viewModel.panelSize.width, alignment: .center)
    }

    private var questionComposerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: false)

            previewCard

            TextField("Example: What does this mean here?", text: $viewModel.questionDraft)
                .textFieldStyle(.roundedBorder)
                .focused($questionFieldFocused)

            HStack(spacing: 8) {
                Button("Cancel") {
                    viewModel.onCancelQuestion?()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.foreground(0.06))
                )

                Spacer()

                Button("Ask") {
                    let question = viewModel.questionDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    viewModel.onSubmitQuestion?(question)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.accentTint.opacity(0.82))
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
            DispatchQueue.main.async {
                questionFieldFocused = true
            }
        }
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: false)

            previewCard

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppVisualTheme.foreground(0.85))

                Text("Using an available AI provider to explain this text.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.82))
            }
        }
        .frame(
            width: viewModel.panelSize.width,
            height: viewModel.panelSize.height,
            alignment: .topLeading
        )
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: viewModel.title, showsClose: true)

            previewCard

            ScrollView {
                Text(viewModel.bodyText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppVisualTheme.foreground(viewModel.isError ? 0.86 : 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: viewModel.isError ? 92 : .infinity,
                alignment: .topLeading
            )
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppVisualTheme.foreground(0.05), lineWidth: 0.6)
                    )
            )

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
                            .fill(AppVisualTheme.foreground(0.06))
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
    }

    private var previewCard: some View {
        Text(viewModel.selectedPreview)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(AppVisualTheme.foreground(0.62))
            .lineLimit(viewModel.mode == .result && viewModel.isError ? 2 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppVisualTheme.foreground(0.04), lineWidth: 0.6)
                    )
            )
    }

    private func header(title: String, showsClose: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.92))

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

    private func bubbleButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        HoverButton(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

private struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.16, green: 0.17, blue: 0.21).opacity(isHovered ? 1.0 : 0.92))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppVisualTheme.foreground(isHovered ? 0.22 : 0.14), lineWidth: 0.6)
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
