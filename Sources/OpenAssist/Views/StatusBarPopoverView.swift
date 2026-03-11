import SwiftUI

// MARK: - View Model

final class StatusBarViewModel: ObservableObject {
    @Published var uiStatus: DictationUIStatus = .ready
    @Published var isPopoverVisible: Bool = false
    @Published var isDictating: Bool = false
    @Published var currentAudioLevel: Float = 0
    @Published var isContinuousMode: Bool = false
    @Published var permissionsReady: Bool = false
    @Published var assistantEnabled: Bool = false
    @Published var assistantCanStopCurrentAction: Bool = false
    @Published var assistantStopActionLabel: String = "Stop Assistant"

    var onToggleDictation: (() -> Void)?
    var onPasteLastTranscript: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenAIMemoryStudio: (() -> Void)?
    var onOpenAssistant: (() -> Void)?
    var onSpeakAssistantTask: (() -> Void)?
    var onStopAssistant: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
}

// MARK: - Popover View

struct StatusBarPopoverView: View {
    @ObservedObject var viewModel: StatusBarViewModel

    var body: some View {
        ZStack {
            StatusBarPopoverBackground()

            VStack(alignment: .leading, spacing: 0) {
                headerSection
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)

                if viewModel.isPopoverVisible && viewModel.isDictating {
                    RecordingIndicatorView(audioLevel: viewModel.currentAudioLevel)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.bottom, 10)
                }

                Divider().overlay(Color.white.opacity(0.08))
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("Quick Actions")
                    PopoverMenuRow(
                        icon: viewModel.isContinuousMode ? "stop.circle.fill" : "mic.circle.fill",
                        label: viewModel.isContinuousMode ? "Stop Dictation" : "Start Dictation",
                        shortcut: nil,
                        iconTint: viewModel.isContinuousMode ? .red : AppVisualTheme.accentTint,
                        isDisabled: !viewModel.permissionsReady
                    ) {
                        viewModel.onToggleDictation?()
                    }

                    PopoverMenuRow(
                        icon: "doc.on.clipboard",
                        label: "Paste Last Transcript",
                        shortcut: "⌘⌥V",
                        iconTint: AppVisualTheme.accentTint
                    ) {
                        viewModel.onPasteLastTranscript?()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

                Divider().overlay(Color.white.opacity(0.08))
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 5) {
                    if viewModel.assistantEnabled {
                        sectionTitle("Assistant")
                        PopoverMenuRow(
                            icon: "sparkles.rectangle.stack.fill",
                            label: "Open Assistant",
                            iconTint: AppVisualTheme.aiStudioTint
                        ) {
                            viewModel.onOpenAssistant?()
                        }

                        PopoverMenuRow(
                            icon: "waveform",
                            label: "Speak Assistant Task",
                            iconTint: AppVisualTheme.baseTint
                        ) {
                            viewModel.onSpeakAssistantTask?()
                        }

                        if viewModel.assistantCanStopCurrentAction {
                            PopoverMenuRow(
                                icon: "stop.circle.fill",
                                label: viewModel.assistantStopActionLabel,
                                iconTint: .orange
                            ) {
                                viewModel.onStopAssistant?()
                            }
                        }

                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.vertical, 8)
                    }

                    sectionTitle("Open")
                    PopoverMenuRow(
                        icon: "clock.arrow.circlepath",
                        label: "History",
                        iconTint: AppVisualTheme.historyTint
                    ) {
                        viewModel.onOpenHistory?()
                    }

                    PopoverMenuRow(
                        icon: "brain.head.profile",
                        label: "AI Studio",
                        iconTint: AppVisualTheme.aiStudioTint
                    ) {
                        viewModel.onOpenAIMemoryStudio?()
                    }

                    PopoverMenuRow(
                        icon: "gearshape.fill",
                        label: "Settings",
                        shortcut: "⌘,",
                        iconTint: AppVisualTheme.settingsTint
                    ) {
                        viewModel.onOpenSettings?()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

                Divider().overlay(Color.white.opacity(0.08))
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("System")
                    PopoverMenuRow(
                        icon: "power",
                        label: "Quit Open Assist",
                        iconTint: .gray
                    ) {
                        viewModel.onQuit?()
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(12)
        }
        .frame(width: 312)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 9)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isDictating)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            AppIconBadge(
                symbol: "waveform",
                tint: AppVisualTheme.accentTint,
                size: 34,
                symbolSize: 15,
                isEmphasized: true
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Open Assist")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))

                HStack(spacing: 6) {
                    Text(viewModel.uiStatus.menuText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(statusPillColor)
                    Text("Quick Controls")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(AppVisualTheme.mutedText.opacity(0.92))
            .padding(.horizontal, 6)
    }

    private var statusPillColor: Color {
        switch viewModel.uiStatus {
        case .ready: return .secondary
        case .listening, .finalizing, .copiedFromHistory, .copiedToClipboard:
            return AppVisualTheme.accentTint
        case .pasteUnavailable, .accessibilityHint: return .red
        default: return .secondary
        }
    }
}

private struct StatusBarPopoverBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        ZStack {
            tokens.canvasDeep.opacity(0.95)

            if tokens.useMaterial {
                Rectangle()
                    .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                    .opacity(0.62)
            } else {
                Rectangle()
                    .fill(tokens.surfaceBottom.opacity(0.94))
            }

            LinearGradient(
                colors: [
                    tokens.surfaceTop.opacity(0.50),
                    AppVisualTheme.baseTint.opacity(0.16),
                    tokens.surfaceBottom.opacity(0.88),
                    Color.black.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    tokens.glowRed.opacity(0.84),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 22,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    tokens.glowBlue.opacity(0.84),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 18,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Menu Row

private struct PopoverMenuRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var iconTint: Color = AppVisualTheme.accentTint
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIconBadge(
                    symbol: icon,
                    tint: iconTint,
                    size: 22,
                    symbolSize: 10,
                    isEmphasized: isHovered
                )

                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(isHovered ? .white : Color.white.opacity(0.92))

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(isHovered ? Color.white.opacity(0.8) : AppVisualTheme.mutedText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    iconTint.opacity(0.20),
                                    Color.white.opacity(0.07),
                                    Color.black.opacity(0.16)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 0.45)
                        )
                        .transition(.opacity)
                }
            }
            .opacity(isDisabled ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
        }
    }
}

// MARK: - Recording Indicator

private struct RecordingIndicatorView: View {
    var audioLevel: Float
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 24, height: 24)
                    .scaleEffect(isAnimating ? 1.4 : 0.8)
                    .opacity(isAnimating ? 0 : 1)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)

                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Listening...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)

                WaveformBarsView(audioLevel: audioLevel)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appThemedSurface(cornerRadius: 10, tint: .red, strokeOpacity: 0.12, tintOpacity: 0.04)
        .onAppear {
            isAnimating = true
        }
    }
}

private struct WaveformBarsView: View {
    var audioLevel: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 5.0 + Double(i) * 0.8
                    let level = max(Double(audioLevel), (sin(phase) + 1) * 0.25)
                    let height = 4 + 12 * level

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 3, height: CGFloat(height))
                }
            }
            .frame(height: 16, alignment: .center)
        }
    }
}
