import SwiftUI

struct OrbPopupHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var onOpenMainWindow: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 28, height: 28)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.88))

                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer()

            if let onOpenMainWindow {
                Button(action: onOpenMainWindow) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct OrbPopupDivider: View {
    let tint: Color

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.04),
                        tint.opacity(0.24),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

struct OrbInlinePill: View {
    let text: String
    var symbol: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }

            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

struct OrbFloatingActionButton: View {
    let symbol: String
    let tint: Color
    let isEnabled: Bool
    var size: CGFloat = 42
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [tint.opacity(0.96), tint.opacity(0.58)]
                                : [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(Color.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 0.8)

                Image(systemName: symbol)
                    .font(.system(size: max(10, size * 0.33), weight: .bold))
                    .foregroundStyle(isEnabled ? Color.black.opacity(0.78) : Color.white.opacity(0.32))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct OrbSecondaryActionButton: View {
    let title: String
    var symbol: String? = nil
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct OrbIconControlButton: View {
    let symbol: String
    let tint: Color
    var isActive = false
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isActive
                                ? [tint.opacity(0.26), tint.opacity(0.12)]
                                : [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(isActive ? tint.opacity(0.30) : Color.white.opacity(0.08), lineWidth: 0.6)

                Image(systemName: symbol)
                    .font(.system(size: max(10, size * 0.4), weight: .semibold))
                    .foregroundStyle(isActive ? tint : Color.white.opacity(0.52))
            }
            .frame(width: size, height: size)
            .scaleEffect(isActive ? 1.06 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isActive
            )
        }
        .buttonStyle(.plain)
    }
}

struct OrbPermissionChoiceButton: View {
    let title: String
    let tint: Color
    let isProminent: Bool
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isProminent ? Color.white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isProminent
                                ? [tint.opacity(0.38), tint.opacity(0.20)]
                                : [tint.opacity(0.12), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isProminent ? tint.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct OrbStatusCapsuleBackground: View {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tokens.surfaceTop.opacity(0.54),
                        tint.opacity(0.14),
                        tokens.surfaceBottom.opacity(0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if tokens.useMaterial {
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                        .opacity(0.36)
                }
            }
            .overlay(
                RadialGradient(
                    colors: [
                        tint.opacity(0.18),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 6,
                    endRadius: 100
                )
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tokens.strokeTop.opacity(0.18), lineWidth: 0.55)
            )
    }
}

struct OrbPopupSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(tokens.surfaceBottom.opacity(reduceTransparency ? 0.96 : 0.80))

                    if tokens.useMaterial {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.74)
                    }

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    tint.opacity(0.12),
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    tint.opacity(0.24),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 8,
                                endRadius: 240
                            )
                        )

                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppVisualTheme.baseTint.opacity(0.18),
                                    Color.clear
                                ],
                                center: .bottomTrailing,
                                startRadius: 12,
                                endRadius: 260
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(tokens.strokeTop.opacity(0.34), lineWidth: 0.9)
                    .overlay(
                        shape
                            .stroke(Color.black.opacity(0.24), lineWidth: 0.5)
                            .blur(radius: 0.3)
                    )
            }
    }
}

struct OrbInsetSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let fillOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(Color.white.opacity(fillOpacity * 0.70))

                    if !reduceTransparency {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.18)
                    }

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(fillOpacity),
                                    Color.clear,
                                    Color.black.opacity(fillOpacity * 0.40)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    .overlay(
                        shape
                            .stroke(tint.opacity(0.14), lineWidth: 0.5)
                    )
            }
    }
}

struct NotchPopupSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(Color.black.opacity(reduceTransparency ? 0.98 : 0.62))

                    if tokens.useMaterial {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(reduceTransparency ? 0.30 : 0.72)
                    }

                    shape
                        .fill(tokens.surfaceBottom.opacity(reduceTransparency ? 0.90 : 0.38))

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.05),
                                    tint.opacity(0.08),
                                    Color.black.opacity(0.30)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    tint.opacity(0.12),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 10,
                                endRadius: 220
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                    .overlay(
                        shape
                            .stroke(Color.black.opacity(0.40), lineWidth: 0.6)
                    )
            }
    }
}

struct NotchInsetSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let fillOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(Color.black.opacity(reduceTransparency ? 0.82 : 0.44))

                    if !reduceTransparency {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.40)
                    }

                    shape
                        .fill(Color.white.opacity(fillOpacity * 0.22))

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(fillOpacity * 0.55),
                                    Color.clear,
                                    Color.black.opacity(fillOpacity * 0.80)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
                    .overlay(
                        shape
                            .stroke(tint.opacity(0.12), lineWidth: 0.5)
                    )
            }
    }
}

struct HardwareNotchDockHandle: View {
    let width: CGFloat
    let height: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(12, height * 0.45), style: .continuous)

        shape
            .fill(Color.black.opacity(0.90))
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
                    .overlay(
                        shape
                            .stroke(tint.opacity(0.16), lineWidth: 0.8)
                            .blur(radius: reduceMotion ? 0 : 0.6)
                    )
            }
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.28))
                    .frame(width: width * 0.42, height: 2.2)
                    .blur(radius: reduceMotion ? 0 : 2.8)
                    .padding(.bottom, 2)
            }
            .frame(width: width, height: height)
    }
}

// Soft ambient glow that appears below the notch handle when the assistant is active.
struct NotchAmbientActivityGlow: View {
    let width: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowOn = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(tint.opacity(glowOn ? 0.52 : 0.20))
            .frame(width: width * 0.62, height: 3)
            .blur(radius: reduceMotion ? 1.5 : 5)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: glowOn
            )
            .onAppear { glowOn = true }
    }
}

extension View {
    func orbPopupSurface(tint: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(OrbPopupSurfaceModifier(tint: tint, cornerRadius: cornerRadius))
    }

    func orbInsetSurface(tint: Color, cornerRadius: CGFloat = 14, fillOpacity: Double = 0.08) -> some View {
        modifier(OrbInsetSurfaceModifier(tint: tint, cornerRadius: cornerRadius, fillOpacity: fillOpacity))
    }

    func notchPopupSurface(tint: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(NotchPopupSurfaceModifier(tint: tint, cornerRadius: cornerRadius))
    }

    func notchInsetSurface(tint: Color, cornerRadius: CGFloat = 14, fillOpacity: Double = 0.08) -> some View {
        modifier(NotchInsetSurfaceModifier(tint: tint, cornerRadius: cornerRadius, fillOpacity: fillOpacity))
    }
}

// MARK: - Session Row

struct OrbSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isSelected && !isBusy {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.60))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isSelected
                            ? [AppVisualTheme.rowSelection.opacity(0.82), AppVisualTheme.rowSelection.opacity(0.46)]
                            : [AppVisualTheme.panelTint.opacity(0.42), AppVisualTheme.panelTint.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected
                                ? AppVisualTheme.accentTint.opacity(0.30)
                                : Color.white.opacity(0.07),
                            lineWidth: 0.6
                        )
                )
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isBusy {
            BusySessionIndicator(tint: AppVisualTheme.accentTint)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return .green.opacity(0.85)
        case .waitingForApproval, .waitingForInput: return .orange.opacity(0.85)
        case .completed: return Color(white: 0.50)
        case .failed: return .red.opacity(0.85)
        case .idle, .unknown: return Color(white: 0.35)
        }
    }
}

struct BusySessionIndicator: View {
    let tint: Color

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.65)
            .tint(tint)
    }
}

struct OrbWorkingActivityRow: View {
    let item: AssistantToolCallState
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.18))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))

                if let detail = (item.hudDetail ?? item.detail)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbInsetSurface(tint: tint, cornerRadius: 14, fillOpacity: 0.08)
    }

    private var statusTint: Color {
        let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return .red
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return .green
        }
        return .orange
    }
}

