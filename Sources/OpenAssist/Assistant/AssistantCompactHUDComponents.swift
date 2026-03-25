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
                        .fill(tint.opacity(0.14))
                        .frame(width: 26, height: 26)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.90))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(AppVisualTheme.foreground(0.82))

                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.50))
                        .lineLimit(1)
                }
            }

            Spacer()

            if let onOpenMainWindow {
                Button(action: onOpenMainWindow) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.54))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.foreground(0.06))
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.54))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(AppVisualTheme.foreground(0.06))
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
            .fill(AppVisualTheme.foreground(0.06))
            .frame(height: 0.5)
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
                    .font(.system(size: 8, weight: .semibold))
            }

            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(AppVisualTheme.foreground(0.62))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.foreground(0.06), lineWidth: 0.5)
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
                    .fill(isEnabled ? tint.opacity(0.82) : AppVisualTheme.foreground(0.06))

                Circle()
                    .stroke(isEnabled ? tint.opacity(0.30) : AppVisualTheme.foreground(0.06), lineWidth: 0.5)

                Image(systemName: symbol)
                    .font(.system(size: max(10, size * 0.33), weight: .bold))
                    .foregroundStyle(isEnabled ? AppVisualTheme.foreground(0.96) : AppVisualTheme.foreground(0.30))
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
                        .font(.system(size: 10, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(tint.opacity(0.90))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.14), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct OrbIconOnlySecondaryButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(0.88))
                .padding(7)
                .background(
                    Circle()
                        .fill(tint.opacity(0.10))
                        .overlay(
                            Circle()
                                .stroke(tint.opacity(0.12), lineWidth: 0.5)
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
            AssistantToolbarCircleButtonLabel(
                symbol: symbol,
                tint: isActive ? tint : AppVisualTheme.primaryText,
                size: size,
                emphasized: isActive
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
                    .font(.system(size: 12, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isProminent ? AppVisualTheme.foreground(0.96) : tint.opacity(0.90))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isProminent ? tint.opacity(0.24) : tint.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isProminent ? tint.opacity(0.28) : AppVisualTheme.foreground(0.06), lineWidth: 0.5)
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
        Capsule(style: .continuous)
            .fill(AppVisualTheme.surfaceFill(0.92))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.5)
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
        let isDark = AppVisualTheme.isDarkAppearance
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let solidFill = isDark
            ? Color(red: 0.055, green: 0.058, blue: 0.072).opacity(0.98)
            : AppVisualTheme.windowBackground.opacity(0.99)

        return content
            .background {
                ZStack {
                    shape
                        .fill(solidFill)

                    if tokens.useMaterial, isDark {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.36)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.5)
            }
    }
}

struct OrbInsetSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let fillOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillColor = isDark
            ? AppVisualTheme.foreground(fillOpacity * 0.50)
            : AppVisualTheme.controlBackground.opacity(0.98)

        return content
            .background {
                shape
                    .fill(fillColor)
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(AppVisualTheme.foreground(0.06), lineWidth: 0.5)
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
        let isDark = AppVisualTheme.isDarkAppearance
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let solidFill = isDark
            ? Color(red: 0.045, green: 0.048, blue: 0.062).opacity(0.98)
            : AppVisualTheme.windowBackground.opacity(0.99)

        return content
            .background {
                ZStack {
                    shape
                        .fill(solidFill)

                    if tokens.useMaterial, isDark {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.24)
                    }

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tokens.surfaceTop.opacity(0.20),
                                    tokens.surfaceBottom.opacity(0.30)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(AppVisualTheme.foreground(0.07), lineWidth: 0.5)
            }
    }
}

struct NotchInsetSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let fillOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillColor = isDark
            ? AppVisualTheme.surfaceFill(0.96)
            : AppVisualTheme.controlBackground.opacity(0.98)

        return content
            .background {
                shape
                    .fill(fillColor)
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(AppVisualTheme.foreground(0.06), lineWidth: 0.5)
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
            .fill(AppVisualTheme.surfaceFill(0.92))
            .overlay {
                shape
                    .stroke(AppVisualTheme.foreground(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(width: width * 0.42, height: 2)
                    .blur(radius: reduceMotion ? 0 : 2)
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
            .fill(tint.opacity(glowOn ? 0.40 : 0.16))
            .frame(width: width * 0.62, height: 2.5)
            .blur(radius: reduceMotion ? 1.5 : 4)
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
                HStack(spacing: 6) {
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.90))
                        .lineLimit(1)

                    if session.isTemporary {
                        CompactTemporaryBadge(compact: true)
                    }
                }

                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.50))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isSelected && !isBusy {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.56))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AppVisualTheme.foreground(0.08) : AppVisualTheme.foreground(0.03))
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
                .frame(width: 6, height: 6)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return .green.opacity(0.80)
        case .waitingForApproval, .waitingForInput: return .orange.opacity(0.80)
        case .completed: return Color(white: 0.46)
        case .failed: return .red.opacity(0.80)
        case .idle, .unknown: return Color(white: 0.32)
        }
    }
}

struct CompactTemporaryBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: compact ? 7.5 : 8.5, weight: .semibold))
            Text("Temporary")
                .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.orange.opacity(0.94))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange.opacity(0.15))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 0.6)
                )
        )
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
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.88))

                if let detail = (item.hudDetail ?? item.detail)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbInsetSurface(tint: tint, cornerRadius: 10, fillOpacity: 0.06)
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
