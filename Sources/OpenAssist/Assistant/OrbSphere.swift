import SwiftUI

struct OrbSphere: View {
    let phase: AssistantHUDPhase
    let level: CGFloat
    let time: TimeInterval

    private let sphereSize: CGFloat = 48
    private let containerSize: CGFloat = 64

    var body: some View {
        let pulse = pulseScale
        let c = colors
        let speed = animSpeed
        let motion = motionAmplitude
        let highlightTravel = highlightTravelDistance

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            c.primary.opacity(0.44),
                            c.secondary.opacity(0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 28
                    )
                )
                .frame(width: containerSize, height: containerSize)
                .blur(radius: 10)
                .scaleEffect((1.02 + ((pulse - 1.0) * 0.65)) * glowBreathingScale)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.36),
                                c.secondary.opacity(0.58),
                                c.primary.opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.20), c.primary.opacity(0.72), Color.clear],
                            center: UnitPoint(
                                x: 0.42 + (sin(time * speed * 0.26) * highlightTravel * 1.4),
                                y: 0.34 + (cos(time * speed * 0.20) * highlightTravel * 1.1)
                            ),
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: 44, height: 44)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.33)) * motion * 0.88,
                        y: CGFloat(cos(time * speed * 0.24)) * motion * 0.62
                    )
                    .blur(radius: 7.0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [c.secondary.opacity(0.94), c.accent.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 22
                        )
                    )
                    .frame(width: 36, height: 36)
                    .offset(
                        x: CGFloat(cos(time * speed * 0.50)) * motion * 0.78,
                        y: CGFloat(sin(time * speed * 0.38)) * motion * 0.54
                    )
                    .blur(radius: 6.0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.26), c.accent.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 16
                        )
                    )
                    .frame(width: 28, height: 28)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.62)) * motion * 0.58,
                        y: CGFloat(cos(time * speed * 0.46)) * motion * 0.64
                    )
                    .blur(radius: 4.8)

                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.26),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 30, height: 16)
                    .offset(y: 14)
                    .blur(radius: 6)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.26),
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            center: UnitPoint(
                                x: 0.34 + sin(time * speed * 0.18) * highlightTravel,
                                y: 0.28 + cos(time * speed * 0.14) * highlightTravel
                            ),
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: sphereSize, height: sphereSize)
            }
            .frame(width: sphereSize, height: sphereSize)
            .clipShape(Circle())

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.36, y: 0.28),
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: sphereSize, height: sphereSize)
                .blendMode(.screen)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.82),
                            Color.white.opacity(0.18),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.30, y: 0.22),
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: sphereSize, height: sphereSize)
                .offset(x: -1, y: -1)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            c.primary.opacity(0.42),
                            Color.white.opacity(0.28),
                            c.secondary.opacity(0.30),
                            Color.white.opacity(0.14),
                            c.primary.opacity(0.42)
                        ],
                        center: .center
                    ),
                    lineWidth: 1.0
                )
                .frame(width: sphereSize, height: sphereSize)
                .rotationEffect(rimRotation)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.clear,
                            Color.black.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .frame(width: sphereSize, height: sphereSize)
        }
        .frame(width: containerSize, height: containerSize)
        .offset(y: floatOffset)
        .scaleEffect(pulse)
    }

    // MARK: Animation

    private var floatOffset: CGFloat {
        switch phase {
        case .thinking: return CGFloat(sin(time * 2.4)) * 1.2
        case .acting: return CGFloat(sin(time * 2.8)) * 1.0
        case .streaming: return CGFloat(sin(time * 2.6)) * 1.1
        case .listening: return CGFloat(sin(time * 2.0)) * 0.8
        default: return 0
        }
    }

    private var pulseScale: CGFloat {
        switch phase {
        case .idle:
            return 1.0
        case .listening:
            return 1.0 + min(level * 0.055, 0.055) + CGFloat(sin(time * 1.6)) * 0.008
        case .thinking:
            return 1.0 + CGFloat(sin(time * 2.5)) * 0.018
        case .acting:
            return 1.002 + CGFloat(sin(time * 3.0)) * 0.020
        case .waitingForPermission:
            return 1.0 + CGFloat(sin(time * 0.8)) * 0.006
        case .streaming:
            return 1.002 + CGFloat(sin(time * 2.7)) * 0.016
        case .success:
            return 1.008 + CGFloat(sin(time * 0.7)) * 0.003
        case .failed:
            return 1.0 + CGFloat(sin(time * 2.2)) * 0.010
        }
    }

    /// Controls how fast the internal blobs drift.
    private var animSpeed: Double {
        switch phase {
        case .idle: return 0.0
        case .listening: return 1.35 + Double(min(level, 1)) * 0.55
        case .thinking: return 1.05
        case .acting: return 1.45
        case .waitingForPermission: return 0.55
        case .streaming: return 1.20
        case .success: return 0.80
        case .failed: return 1.65
        }
    }

    private var motionAmplitude: CGFloat {
        switch phase {
        case .idle:
            return 0.0
        case .listening:
            return 3.2 + min(level * 1.4, 1.4)
        case .thinking:
            return 2.9
        case .acting:
            return 3.4
        case .waitingForPermission:
            return 2.1
        case .streaming:
            return 3.0
        case .success:
            return 2.0
        case .failed:
            return 2.8
        }
    }

    private var highlightTravelDistance: CGFloat {
        switch phase {
        case .idle:
            return 0.0
        case .success:
            return 0.04
        case .listening, .acting, .streaming:
            return 0.06
        case .thinking, .waitingForPermission, .failed:
            return 0.05
        }
    }

    private var glowBreathingScale: CGFloat {
        switch phase {
        case .thinking: return 1.0 + CGFloat(sin(time * 2.8)) * 0.05
        case .acting: return 1.0 + CGFloat(sin(time * 3.2)) * 0.05
        case .streaming: return 1.0 + CGFloat(sin(time * 3.0)) * 0.04
        default: return 1.0
        }
    }

    private var rimRotation: Angle {
        switch phase {
        case .thinking: return .degrees(time * 30)
        case .acting: return .degrees(time * 40)
        case .streaming: return .degrees(time * 35)
        default: return .zero
        }
    }

    // MARK: Colors

    private struct OrbColors {
        let primary: Color
        let secondary: Color
        let accent: Color
    }

    private var colors: OrbColors {
        switch phase {
        case .idle:
            return OrbColors(
                primary: AppVisualTheme.accentTint,
                secondary: AppVisualTheme.accentTint.opacity(0.65),
                accent: Color.white.opacity(0.30)
            )
        case .listening:
            return OrbColors(
                primary: Color(red: 0.0, green: 0.75, blue: 0.95),
                secondary: Color(red: 0.20, green: 0.30, blue: 0.90),
                accent: Color(red: 0.10, green: 0.85, blue: 0.80)
            )
        case .thinking:
            return OrbColors(
                primary: Color(red: 0.50, green: 0.30, blue: 0.95),
                secondary: Color(red: 0.75, green: 0.35, blue: 0.90),
                accent: Color(red: 0.35, green: 0.20, blue: 0.80)
            )
        case .acting:
            return OrbColors(
                primary: Color(red: 0.10, green: 0.82, blue: 0.72),
                secondary: Color(red: 0.25, green: 0.90, blue: 0.55),
                accent: Color(red: 0.06, green: 0.52, blue: 0.48)
            )
        case .waitingForPermission:
            return OrbColors(
                primary: Color(red: 0.95, green: 0.60, blue: 0.10),
                secondary: Color(red: 0.95, green: 0.80, blue: 0.20),
                accent: Color(red: 0.72, green: 0.38, blue: 0.05)
            )
        case .streaming:
            return OrbColors(
                primary: Color(red: 0.28, green: 0.65, blue: 0.98),
                secondary: Color(red: 0.45, green: 0.80, blue: 0.98),
                accent: Color(red: 0.18, green: 0.42, blue: 0.85)
            )
        case .success:
            return OrbColors(
                primary: Color(red: 0.20, green: 0.85, blue: 0.45),
                secondary: Color(red: 0.45, green: 0.92, blue: 0.55),
                accent: Color(red: 0.15, green: 0.60, blue: 0.35)
            )
        case .failed:
            return OrbColors(
                primary: Color(red: 0.92, green: 0.20, blue: 0.20),
                secondary: Color(red: 0.95, green: 0.35, blue: 0.15),
                accent: Color(red: 0.65, green: 0.10, blue: 0.12)
            )
        }
    }

    static func phaseColor(for phase: AssistantHUDPhase) -> Color {
        switch phase {
        case .idle: return AppVisualTheme.accentTint
        case .listening: return Color(red: 0.0, green: 0.75, blue: 0.95)
        case .thinking: return Color(red: 0.45, green: 0.25, blue: 0.90)
        case .acting: return Color(red: 0.10, green: 0.82, blue: 0.72)
        case .waitingForPermission: return .orange
        case .streaming: return Color(red: 0.22, green: 0.60, blue: 0.95)
        case .success: return Color(red: 0.15, green: 0.80, blue: 0.40)
        case .failed: return .red
        }
    }
}

// MARK: - Done Detail Markdown

