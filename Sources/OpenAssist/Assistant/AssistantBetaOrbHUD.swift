import SwiftUI

struct AssistantBetaOrbHUD: View {
    @ObservedObject var model: AssistantBetaOrbHUDModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            if model.isVisible {
                AssistantBetaOrbDock(state: model.state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.isVisible)
        .allowsHitTesting(false)
    }
}

private struct AssistantBetaOrbDock: View {
    let state: AssistantBetaOrbState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 18) {
                AssistantBetaOrbCore(
                    phase: state.phase,
                    audioLevel: state.audioLevel,
                    time: time
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(state.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.96))

                        AssistantBetaOrbPhaseChip(phase: state.phase)
                    }

                    Text(state.detail)
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)

                    AssistantBetaSpectrumStrip(
                        phase: state.phase,
                        audioLevel: state.audioLevel,
                        time: time
                    )
                    .frame(height: 22)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 760, minHeight: 108)
            .appThemedSurface(
                cornerRadius: 28,
                tint: phaseTint.opacity(0.96),
                strokeOpacity: 0.18,
                tintOpacity: 0.06
            )
        }
    }

    private var phaseTint: Color {
        switch state.phase {
        case .idle:
            return AppVisualTheme.baseTint
        case .listening:
            return .cyan
        case .thinking:
            return .blue
        case .acting:
            return .mint
        case .waiting:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct AssistantBetaOrbCore: View {
    let phase: AssistantBetaOrbPhase
    let audioLevel: Double
    let time: TimeInterval

    var body: some View {
        let pulse = pulseScale
        let shimmer = 0.6 + (sin(time * 1.4) * 0.08)

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbColors.primary.opacity(0.42),
                            orbColors.secondary.opacity(0.14),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 48
                    )
                )
                .frame(width: 86, height: 86)
                .blur(radius: 10)
                .scaleEffect(pulse * 1.04)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            orbColors.primary.opacity(0.95),
                            orbColors.secondary.opacity(0.80),
                            Color.white.opacity(0.82),
                            orbColors.primary.opacity(0.95)
                        ],
                        center: .center,
                        angle: .degrees((time * 24).truncatingRemainder(dividingBy: 360))
                    ),
                    lineWidth: 3.0
                )
                .frame(width: 62, height: 62)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            orbColors.highlight.opacity(0.96),
                            orbColors.primary.opacity(0.82),
                            orbColors.secondary.opacity(0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .fill(Color.white.opacity(0.22 * shimmer))
                        .frame(width: 24, height: 24)
                        .offset(x: -10, y: -11)
                        .blur(radius: 6)
                )
                .frame(width: 46, height: 46)
                .scaleEffect(pulse)

            Circle()
                .fill(Color.white.opacity(0.72))
                .frame(width: 7, height: 7)
                .blur(radius: 0.2)
                .offset(x: 13, y: -13)
        }
        .frame(width: 88, height: 88)
    }

    private var pulseScale: CGFloat {
        let animatedBase: CGFloat
        switch phase {
        case .idle:
            animatedBase = 1.0
        case .listening:
            animatedBase = 1.02 + CGFloat(audioLevel) * 0.12
        case .thinking:
            animatedBase = 1.03 + CGFloat((sin(time * 2.8) + 1) * 0.04)
        case .acting:
            animatedBase = 1.04 + CGFloat((sin(time * 4.4) + 1) * 0.03)
        case .waiting:
            animatedBase = 0.98 + CGFloat((sin(time * 1.3) + 1) * 0.03)
        case .error:
            animatedBase = 1.0 + CGFloat(sin(time * 9.0)) * 0.015
        }
        return max(0.94, animatedBase)
    }

    private var orbColors: (primary: Color, secondary: Color, highlight: Color) {
        switch phase {
        case .idle:
            return (AppVisualTheme.accentTint, AppVisualTheme.baseTint, .white)
        case .listening:
            return (.cyan, .blue, .white)
        case .thinking:
            return (.blue, AppVisualTheme.accentTint, .white)
        case .acting:
            return (.mint, .green, .white)
        case .waiting:
            return (.orange, .yellow, .white)
        case .error:
            return (.red, .pink, .white)
        }
    }
}

private struct AssistantBetaSpectrumStrip: View {
    let phase: AssistantBetaOrbPhase
    let audioLevel: Double
    let time: TimeInterval

    private let barCount = 24

    var body: some View {
        GeometryReader { proxy in
            let height = max(16, proxy.size.height)
            let spacing: CGFloat = 4
            let width = max(2, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    spectrumColors.primary.opacity(0.95),
                                    spectrumColors.secondary.opacity(0.70),
                                    Color.white.opacity(0.30)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: width, height: barHeight(index: index, maxHeight: height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func barHeight(index: Int, maxHeight: CGFloat) -> CGFloat {
        let normalizedIndex = Double(index) / Double(max(barCount - 1, 1))
        let base = maxHeight * 0.18
        let phaseWave = sin((time * speed) + (normalizedIndex * .pi * spread))
        let detailWave = cos((time * detailSpeed) + (normalizedIndex * .pi * 8.4))
        let voiceBoost = phase == .listening ? audioLevel * 0.70 : 0.0
        let energy = max(0.04, ((phaseWave + 1) * 0.28) + ((detailWave + 1) * 0.10) + motionFloor + voiceBoost)
        return min(maxHeight, base + CGFloat(energy) * maxHeight * 0.92)
    }

    private var motionFloor: Double {
        switch phase {
        case .idle:
            return 0.05
        case .listening:
            return 0.10
        case .thinking:
            return 0.18
        case .acting:
            return 0.22
        case .waiting:
            return 0.10
        case .error:
            return 0.20
        }
    }

    private var speed: Double {
        switch phase {
        case .idle:
            return 0.8
        case .listening:
            return 3.2
        case .thinking:
            return 2.3
        case .acting:
            return 3.8
        case .waiting:
            return 1.1
        case .error:
            return 5.0
        }
    }

    private var detailSpeed: Double {
        switch phase {
        case .idle:
            return 1.2
        case .listening:
            return 4.4
        case .thinking:
            return 3.0
        case .acting:
            return 5.2
        case .waiting:
            return 1.6
        case .error:
            return 8.6
        }
    }

    private var spread: Double {
        switch phase {
        case .idle:
            return 1.5
        case .listening:
            return 3.6
        case .thinking:
            return 2.3
        case .acting:
            return 4.0
        case .waiting:
            return 1.8
        case .error:
            return 5.6
        }
    }

    private var spectrumColors: (primary: Color, secondary: Color) {
        switch phase {
        case .idle:
            return (AppVisualTheme.accentTint, AppVisualTheme.baseTint)
        case .listening:
            return (.cyan, .blue)
        case .thinking:
            return (.blue, AppVisualTheme.accentTint)
        case .acting:
            return (.mint, .green)
        case .waiting:
            return (.orange, .yellow)
        case .error:
            return (.red, .pink)
        }
    }
}

private struct AssistantBetaOrbPhaseChip: View {
    let phase: AssistantBetaOrbPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.36),
                            tint.opacity(0.18),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
    }

    private var label: String {
        switch phase {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .acting:
            return "Acting"
        case .waiting:
            return "Waiting"
        case .error:
            return "Needs help"
        }
    }

    private var tint: Color {
        switch phase {
        case .idle:
            return AppVisualTheme.accentTint
        case .listening:
            return .cyan
        case .thinking:
            return .blue
        case .acting:
            return .mint
        case .waiting:
            return .orange
        case .error:
            return .red
        }
    }
}

#if DEBUG
struct AssistantBetaOrbHUD_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AppChromeBackground(tint: AppVisualTheme.baseTint)
            AssistantBetaOrbHUD(model: .previewListening)
        }
        .frame(width: 1200, height: 680)
    }
}
#endif
