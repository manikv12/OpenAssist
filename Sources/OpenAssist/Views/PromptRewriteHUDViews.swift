import AppKit
import SwiftUI

struct PromptRewriteDiscussionPage: Identifiable, Equatable {
    let id: UUID
    let originalText: String
    let suggestion: PromptRewriteSuggestion
}

struct PromptRewriteLoadingView: View {
    @ObservedObject var model: PromptRewriteLoadingStateModel
    let onPause: () -> Void
    var onDragChanged: ((CGSize) -> Void)? = nil
    var onDragEnded: ((CGSize) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var animatedProgressValue: Double = 0.08

    private var state: PromptRewriteLoadingDisplayState {
        model.displayState
    }

    private var transcriptPreview: String {
        let normalized = state.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Transcription will appear here." }
        let words = normalized.split(whereSeparator: \.isWhitespace)
        if words.count <= 24 {
            return normalized
        }
        return words.prefix(24).joined(separator: " ") + "…"
    }

    private var livePreviewText: String? {
        state.partialPreviewText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private var previewBlockTitle: String {
        if state.isStreamingPreviewActive, livePreviewText != nil {
            return "Live Preview"
        }
        return "Transcript"
    }

    private var previewBlockText: String {
        if state.isStreamingPreviewActive, let livePreviewText {
            return livePreviewText
        }
        return transcriptPreview
    }

    private var stepText: String {
        let normalized = state.currentStep.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Preparing rewrite request" : normalized
    }

    private var targetProgressValue: Double {
        PromptRewriteProgressEstimate.progress(for: stepText)
    }

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                AppLogoView(size: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Refining Transcript")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.95))
                    PromptRewriteWordFlowText(
                        text: stepText,
                        font: .system(size: 11, weight: .medium),
                        foregroundColor: Color.white.opacity(0.70),
                        wordsPerSecond: 4,
                        lineLimit: 1
                    )
                }

                Spacer(minLength: 8)

                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Pause AI rewrite and insert transcribed text")
            }

            HStack(alignment: .center, spacing: 8) {
                PromptRewriteActivityBar(progress: animatedProgressValue)
                    .frame(height: 6)

                Text("\(Int((animatedProgressValue * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.top, -1)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewBlockTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))

                HStack(alignment: .top, spacing: 8) {
                    PromptRewriteAccentDot()
                        .padding(.top, 3)

                    PromptRewriteWordFlowText(
                        text: previewBlockText,
                        font: .system(size: 11.5, weight: .medium),
                        foregroundColor: Color.white.opacity(0.90),
                        wordsPerSecond: 4,
                        lineLimit: 2
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tokens.surfaceBottom.opacity(0.36))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(tokens.strokeTop.opacity(0.40), lineWidth: 0.8)
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            ZStack {
                PromptRewriteGlassSurface(cornerRadius: 20)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(reduceTransparency ? 0.30 : 0.18))
                LinearGradient(
                    colors: [
                        AppVisualTheme.accentTint.opacity(0.14),
                        Color.clear,
                        AppVisualTheme.baseTint.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onDragChanged?(value.translation)
                    }
                    .onEnded { value in
                        onDragEnded?(value.translation)
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tokens.strokeTop.opacity(0.42), lineWidth: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.30), lineWidth: 0.6)
                        .blur(radius: 0.3)
                )
        }
        .frame(
            width: PromptRewriteHUDLayout.loadingSize.width,
            height: PromptRewriteHUDLayout.loadingSize.height,
            alignment: .center
        )
        .onAppear {
            let clampedTarget = min(1, max(0.08, targetProgressValue))
            if reduceMotion {
                animatedProgressValue = clampedTarget
            } else {
                animatedProgressValue = 0.08
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.9)) {
                    animatedProgressValue = clampedTarget
                }
            }
        }
        .onChange(of: targetProgressValue) { newValue in
            let clampedTarget = min(1, max(0.08, newValue))
            if reduceMotion {
                animatedProgressValue = clampedTarget
            } else {
                let distance = abs(clampedTarget - animatedProgressValue)
                let duration = max(0.8, min(1.6, 0.7 + (distance * 1.8)))
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1.0, duration: duration)) {
                    animatedProgressValue = clampedTarget
                }
            }
        }
    }
}

struct PromptRewriteActivityBar: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPosition: CGFloat = -0.46

    var body: some View {
        GeometryReader { proxy in
            let width = max(20, proxy.size.width)
            let clampedProgress = min(1, max(0.08, CGFloat(progress)))
            let fillWidth = max(14, width * clampedProgress)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppVisualTheme.accentTint.opacity(0.45),
                                    AppVisualTheme.accentTint.opacity(0.92),
                                    Color.white.opacity(0.85)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.04),
                                            Color.white.opacity(0.33),
                                            Color.white.opacity(0.04)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(18, fillWidth * 0.38))
                                .offset(x: reduceMotion ? 0 : shimmerPosition * max(fillWidth, 18))
                        }
                        .clipShape(Capsule(style: .continuous))
                        .overlay(alignment: .trailing) {
                            Circle()
                                .fill(Color.white.opacity(0.94))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 2)
                        }
                }
        }
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            shimmerPosition = -0.46
            withAnimation(.linear(duration: 1.08).repeatForever(autoreverses: false)) {
                shimmerPosition = 1.08
            }
        }
    }
}

struct PromptRewriteAccentDot: View {
    var body: some View {
        Circle()
            .fill(AppVisualTheme.accentTint)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.36), lineWidth: 0.7)
            )
    }
}

private enum PromptRewriteProgressEstimate {
    static func progress(for stepText: String) -> Double {
        let normalized = stepText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("paused") || normalized.contains("restoring") {
            return 1
        }
        if normalized.contains("finalizing") {
            return 0.92
        }
        if normalized.contains("receiving") || normalized.contains("normalizing") {
            return 0.82
        }
        if normalized.contains("analyzing") {
            return 0.70
        }
        if normalized.contains("waiting") {
            return 0.56
        }
        if normalized.contains("sending") {
            return 0.46
        }
        if normalized.contains("connecting") {
            return 0.30
        }
        if normalized.contains("preparing") {
            return 0.14
        }
        return 0.36
    }
}

struct PromptRewriteStageChip: View {
    let title: String
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        let baseColor: Color = {
            if isCompleted {
                return Color.green
            }
            if isActive {
                return AppVisualTheme.accentTint
            }
            return Color.white
        }()
        HStack(spacing: 6) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : (isActive ? "record.circle.fill" : "circle"))
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
        }
        .foregroundStyle(baseColor.opacity(isActive || isCompleted ? 0.96 : 0.74))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(baseColor.opacity(isActive ? 0.22 : (isCompleted ? 0.16 : 0.08)))
        )
    }
}

struct PromptRewriteNowNextCard: View {
    let title: String
    let icon: String
    let text: String
    let wordsPerSecond: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white.opacity(0.76))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
            }

            PromptRewriteWordFlowText(
                text: text,
                font: .system(size: 12.5, weight: .semibold),
                foregroundColor: Color.white.opacity(0.96),
                wordsPerSecond: wordsPerSecond,
                lineLimit: 2
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )
        )
    }
}

struct PromptRewriteLoadingBlock: View {
    let title: String
    let iconName: String
    let text: String
    let wordsPerSecond: Double
    let lineLimit: Int
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white.opacity(0.78))
            } icon: {
                Image(systemName: iconName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint.opacity(0.96))
            }

            PromptRewriteWordFlowText(
                text: text,
                font: .system(size: 12.5, weight: .semibold),
                foregroundColor: Color.white.opacity(0.96),
                wordsPerSecond: wordsPerSecond,
                lineLimit: lineLimit
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tokens.surfaceBottom.opacity(0.40))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(tokens.strokeTop.opacity(0.42), lineWidth: 0.8)
                )
        )
    }
}

struct PromptRewriteLoadingStatePill: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? AppVisualTheme.accentTint : Color.white.opacity(0.52))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
        }
        .foregroundStyle(Color.white.opacity(isActive ? 0.94 : 0.72))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill((isActive ? AppVisualTheme.accentTint : Color.white).opacity(isActive ? 0.30 : 0.14))
        )
    }
}

struct PromptRewriteWordFlowText: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let wordsPerSecond: Double
    let lineLimit: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var words: [String] = []
    @State private var animationStart = Date()

    private var normalizedText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "…" : trimmed
    }

    var body: some View {
        Group {
            if reduceMotion {
                Text(normalizedText)
                    .font(font)
                    .foregroundStyle(foregroundColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(lineLimit)
            } else {
                TimelineView(.periodic(from: animationStart, by: 1.0 / 30.0)) { timeline in
                    Text(displayText(at: timeline.date))
                        .font(font)
                        .foregroundStyle(foregroundColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(lineLimit)
                        .animation(.easeOut(duration: 0.16), value: words)
                }
            }
        }
        .onAppear {
            rebuildWordTimeline(for: normalizedText)
        }
        .onChange(of: text) { _ in
            rebuildWordTimeline(for: normalizedText)
        }
    }

    private func displayText(at now: Date) -> String {
        if reduceMotion {
            return normalizedText
        }
        guard !words.isEmpty else { return normalizedText }
        let elapsed = max(0, now.timeIntervalSince(animationStart))
        let wordRate = max(2, min(wordsPerSecond, 20))
        let revealCount = min(words.count, max(1, Int((elapsed * wordRate).rounded(.down)) + 1))
        return words.prefix(revealCount).joined(separator: " ")
    }

    private func rebuildWordTimeline(for sourceText: String) {
        let tokens = sourceText.split(whereSeparator: \.isWhitespace).map(String.init)
        words = tokens.isEmpty ? ["…"] : tokens
        animationStart = Date()
    }
}

struct PromptRewriteHUDView: View {
    let pages: [PromptRewriteDiscussionPage]
    let selectedIndex: Int
    let bubbleEdge: PromptRewriteBubbleEdge
    let bubbleOffsetX: CGFloat
    let onSelectPage: (Int) -> Void
    let onChoice: (PromptRewritePreviewChoice) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isPresented = false

    private var safeSelectedIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(0, selectedIndex), pages.count - 1)
    }

    private var selectedPage: PromptRewriteDiscussionPage? {
        guard !pages.isEmpty else { return nil }
        return pages[safeSelectedIndex]
    }

    var body: some View {
        Group {
            if let selectedPage {
                compactSuggestion(for: selectedPage)
            } else {
                Text("No suggestion available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .appThemedSurface(
                        cornerRadius: 14,
                        tint: AppVisualTheme.panelTint,
                        strokeOpacity: 0.12,
                        tintOpacity: 0.03
                    )
            }
        }
        .frame(width: PromptRewriteHUDLayout.panelWidth)
        .tint(AppVisualTheme.accentTint)
        .scaleEffect(isPresented ? 1 : 0.985, anchor: bubbleEdge == .bottom ? .bottom : .top)
        .offset(y: isPresented ? 0 : (bubbleEdge == .bottom ? 8 : -8))
        .opacity(isPresented ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84, blendDuration: 0.08)) {
                isPresented = true
            }
        }
    }

    @ViewBuilder
    private func compactSuggestion(for page: PromptRewriteDiscussionPage) -> some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        HStack(alignment: .top, spacing: 11) {
            HStack(spacing: 9) {
                AppIconBadge(
                    symbol: "sparkles",
                    tint: AppVisualTheme.accentTint,
                    size: 20,
                    symbolSize: 9,
                    isEmphasized: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI suggestion")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                    if pages.count > 1 {
                        Text("\(safeSelectedIndex + 1)/\(pages.count) queued")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                }
            }
            .frame(width: 112, alignment: .leading)

            Capsule(style: .continuous)
                .fill(
                        LinearGradient(
                            colors: [
                                tokens.strokeTop.opacity(0.54),
                                tokens.strokeMid.opacity(0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                    )
                )
                .frame(width: 1, height: 26)

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(page.suggestion.suggestedText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 62)

                HStack {
                    Text("Enter inserts • Esc keeps original")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.66))

                    Spacer()

                    Button("Insert") {
                        onChoice(.useSuggested)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.accentTint.opacity(0.26))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tokens.strokeTop.opacity(0.26), lineWidth: 0.6)
                    )
                    .controlSize(.small)
                        .foregroundStyle(Color.white.opacity(0.95))
                }

                if let duration = page.suggestion.refinementDurationSeconds {
                    Text("Refined in \(formattedDuration(duration))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PromptRewriteGlassSurface(cornerRadius: PromptRewriteHUDLayout.cornerRadius)
                .contentShape(RoundedRectangle(cornerRadius: PromptRewriteHUDLayout.cornerRadius, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            onDragEnded(value.translation)
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: PromptRewriteHUDLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PromptRewriteHUDLayout.cornerRadius, style: .continuous)
                .stroke(.clear, lineWidth: 0)
        )
        .overlay(alignment: bubbleEdge == .bottom ? .bottom : .top) {
            bubbleTail
                .offset(x: bubbleOffsetX, y: bubbleEdge == .bottom ? 6 : -6)
        }
        .onExitCommand {
            onChoice(.insertOriginal)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(format: "%.0f ms", clamped * 1000)
        }
        if clamped < 10 {
            return String(format: "%.1f s", clamped)
        }
        return String(format: "%.0f s", clamped)
    }

    private var bubbleTail: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        return Circle()
            .fill(
                LinearGradient(
                    colors: [
                        tokens.surfaceTop.opacity(0.96),
                        tokens.surfaceBottom.opacity(0.98)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 12, height: 12)
    }
}

struct PromptRewriteMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct PromptRewriteGlassSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if tokens.useMaterial {
                PromptRewriteMaterialView(
                    material: tokens.surfaceMaterial,
                    blendingMode: tokens.surfaceBlendingMode
                )
                .opacity(tokens.materialOpacity * 0.48)
            } else {
                tokens.surfaceBottom.opacity(0.96)
            }
            LinearGradient(
                colors: [
                    tokens.surfaceTop.opacity(0.86),
                    AppVisualTheme.baseTint.opacity(0.20),
                    tokens.surfaceBottom.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        tokens.glowRed.opacity(0.22),
                        tokens.glowBlue.opacity(0.20),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: max(56, cornerRadius * 2.4))
                Spacer(minLength: 0)
            }
            RadialGradient(
                colors: [
                    tokens.glowRed.opacity(0.34),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 18,
                endRadius: 320
            )
            RadialGradient(
                colors: [
                    tokens.glowBlue.opacity(0.32),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 340
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(tokens.useMaterial ? 0.12 : 0.16),
                    Color.black.opacity(tokens.useMaterial ? 0.22 : 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(shape)
    }
}
