import AppKit
import SwiftUI

@MainActor
enum AppVisualTheme {
    private static var palette: ColorPalette { SettingsStore.shared.colorTheme.palette }
    static var isDarkAppearance: Bool {
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static var baseTint: Color { palette.baseTint }
    static var accentTint: Color { palette.accentTint }
    static var canvasBase: Color { palette.canvasBase }
    static var canvasDeep: Color { palette.canvasDeep }
    static var sidebarTint: Color { palette.sidebarTint }
    static var sidebarChromeTint: Color {
        switch SettingsStore.shared.colorTheme {
        case .noirGold:
            return Color(red: 0.10, green: 0.11, blue: 0.14)
        default:
            return palette.sidebarTint
        }
    }
    static var sidebarSurfaceTop: Color {
        switch SettingsStore.shared.colorTheme {
        case .noirGold:
            return Color(red: 0.11, green: 0.11, blue: 0.14)
        default:
            return palette.surfaceTop
        }
    }
    static var sidebarSurfaceBottom: Color {
        switch SettingsStore.shared.colorTheme {
        case .noirGold:
            return Color(red: 0.05, green: 0.06, blue: 0.08)
        default:
            return palette.surfaceBottom
        }
    }
    static var panelTint: Color { palette.panelTint }
    static var rowSelection: Color { palette.rowSelection }
    static var historyTint: Color { palette.historyTint }
    static var aiStudioTint: Color { palette.aiStudioTint }
    static var settingsTint: Color { palette.settingsTint }
    static var primaryText: Color { Color(nsColor: .labelColor) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }
    static var quaternaryText: Color { Color(nsColor: .quaternaryLabelColor) }
    static var separatorColor: Color { Color(nsColor: .separatorColor) }
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var windowBackdropNSColor: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(isDarkAppearance ? 0.86 : 0.92)
    }
    static var textBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var controlBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var selectedContentBackground: Color { Color(nsColor: .selectedContentBackgroundColor) }
    static let mutedText = Color(nsColor: .secondaryLabelColor)

    private static func clampedOpacity(_ opacity: Double) -> Double {
        min(1, max(0, opacity))
    }

    static func foreground(_ opacity: Double) -> Color {
        primaryText.opacity(clampedOpacity(opacity))
    }

    static func secondaryForeground(_ opacity: Double) -> Color {
        secondaryText.opacity(clampedOpacity(opacity))
    }

    static func tertiaryForeground(_ opacity: Double) -> Color {
        tertiaryText.opacity(clampedOpacity(opacity))
    }

    static func quaternaryForeground(_ opacity: Double) -> Color {
        quaternaryText.opacity(clampedOpacity(opacity))
    }

    static func surfaceFill(_ opacity: Double) -> Color {
        controlBackground.opacity(clampedOpacity(opacity))
    }

    static func windowFill(_ opacity: Double) -> Color {
        windowBackground.opacity(clampedOpacity(opacity))
    }

    static func surfaceStroke(_ opacity: Double) -> Color {
        separatorColor.opacity(clampedOpacity(opacity))
    }

    static func glassTokens(style: AppChromeStyle, reduceTransparency: Bool) -> AppGlassTokens {
        let materialEnabled = !reduceTransparency
        let p = palette
        let darkMode = isDarkAppearance

        func lightModeTokens(
            highContrast: Bool
        ) -> AppGlassTokens {
            let glowRedOpacity = materialEnabled ? (highContrast ? 0.16 : 0.10) : 0.08
            let glowBlueOpacity = materialEnabled ? (highContrast ? 0.18 : 0.12) : 0.08
            return AppGlassTokens(
                canvasBase: windowBackground,
                canvasDeep: textBackground,
                surfaceTop: Color(nsColor: .textBackgroundColor),
                surfaceBottom: Color(nsColor: .controlBackgroundColor),
                glowRed: p.glowWarm.opacity(glowRedOpacity),
                glowBlue: p.glowCool.opacity(glowBlueOpacity),
                strokeTop: Color.white.opacity(materialEnabled ? (highContrast ? 0.18 : 0.14) : 0.10),
                strokeMid: Color.white.opacity(materialEnabled ? (highContrast ? 0.08 : 0.05) : 0.04),
                strokeBottom: Color.black.opacity(materialEnabled ? (highContrast ? 0.12 : 0.10) : 0.08),
                backgroundMaterial: .underPageBackground,
                surfaceMaterial: .hudWindow,
                backgroundBlendingMode: .behindWindow,
                surfaceBlendingMode: .withinWindow,
                useMaterial: materialEnabled,
                materialOpacity: materialEnabled ? (highContrast ? 0.72 : 0.64) : 0.0,
                cardShadowColor: Color.black.opacity(materialEnabled ? (highContrast ? 0.14 : 0.10) : 0.08),
                cardShadowRadius: materialEnabled ? (highContrast ? 12 : 10) : 8,
                cardShadowYOffset: materialEnabled ? (highContrast ? 7 : 5) : 4,
                cardCornerRadius: highContrast ? 16 : 14,
                modalCornerRadius: highContrast ? 20 : 16
            )
        }

        if !darkMode {
            switch style {
            case .glassHighContrast:
                return lightModeTokens(highContrast: true)
            case .classic:
                return lightModeTokens(highContrast: false)
            }
        }

        switch style {
        case .glassHighContrast:
            return AppGlassTokens(
                canvasBase: p.canvasBase,
                canvasDeep: p.canvasDeep,
                surfaceTop: p.surfaceTop,
                surfaceBottom: p.surfaceBottom,
                glowRed: p.glowWarm.opacity(materialEnabled ? 0.20 : 0.14),
                glowBlue: p.glowCool.opacity(materialEnabled ? 0.25 : 0.18),
                strokeTop: Color.white.opacity(materialEnabled ? 0.20 : 0.14),
                strokeMid: Color.white.opacity(materialEnabled ? 0.07 : 0.05),
                strokeBottom: Color.black.opacity(materialEnabled ? 0.30 : 0.34),
                backgroundMaterial: .underPageBackground,
                surfaceMaterial: .hudWindow,
                backgroundBlendingMode: .behindWindow,
                surfaceBlendingMode: .withinWindow,
                useMaterial: materialEnabled,
                materialOpacity: materialEnabled ? 0.86 : 0.0,
                cardShadowColor: Color.black.opacity(materialEnabled ? 0.34 : 0.28),
                cardShadowRadius: materialEnabled ? 14 : 10,
                cardShadowYOffset: materialEnabled ? 8 : 5,
                cardCornerRadius: 16,
                modalCornerRadius: 20
            )
        case .classic:
            return AppGlassTokens(
                canvasBase: p.canvasBase,
                canvasDeep: p.canvasDeep,
                surfaceTop: p.surfaceTop,
                surfaceBottom: p.surfaceBottom,
                glowRed: p.glowWarm.opacity(materialEnabled ? 0.10 : 0.07),
                glowBlue: p.glowCool.opacity(materialEnabled ? 0.16 : 0.10),
                strokeTop: Color.white.opacity(materialEnabled ? 0.16 : 0.11),
                strokeMid: Color.white.opacity(materialEnabled ? 0.05 : 0.03),
                strokeBottom: Color.black.opacity(materialEnabled ? 0.24 : 0.28),
                backgroundMaterial: .underPageBackground,
                surfaceMaterial: .hudWindow,
                backgroundBlendingMode: .behindWindow,
                surfaceBlendingMode: .behindWindow,
                useMaterial: materialEnabled,
                materialOpacity: materialEnabled ? 0.80 : 0.0,
                cardShadowColor: Color.black.opacity(materialEnabled ? 0.24 : 0.20),
                cardShadowRadius: materialEnabled ? 9 : 7,
                cardShadowYOffset: materialEnabled ? 5 : 3,
                cardCornerRadius: 14,
                modalCornerRadius: 16
            )
        }
    }

    @MainActor
    static func adaptiveMaterialFill(
        style: AppChromeStyle? = nil,
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    ) -> AnyShapeStyle {
        let resolvedStyle = style ?? SettingsStore.shared.appChromeStyle
        let tokens = glassTokens(style: resolvedStyle, reduceTransparency: reduceTransparency)
        if tokens.useMaterial {
            return AnyShapeStyle(.regularMaterial)
        }
        return AnyShapeStyle(tokens.surfaceBottom.opacity(0.94))
    }
}

enum AssistantChromeSymbol {
    static let attachment = "paperclip"
    static let attachmentCount = "photo.stack.fill"
    static let model = "cpu.fill"
    static let reasoning = "brain.head.profile"
    static let speedStandard = "gauge.with.needle"
    static let speedFast = "bolt.fill"
    static let action = "terminal"
}

struct AssistantGlyphBadge: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 18
    var cornerRadius: CGFloat? = nil
    var fillOpacity: Double = 0.16
    var strokeOpacity: Double = 0.24
    var symbolScale: CGFloat = 0.50
    var symbolWeight: Font.Weight = .semibold

    var body: some View {
        let radius = cornerRadius ?? max(5, side * 0.30)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(tint.opacity(fillOpacity * 0.75))
            .overlay {
                shape
                    .stroke(tint.opacity(strokeOpacity * 0.6), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: max(8.5, side * symbolScale), weight: symbolWeight))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint.opacity(0.94))
            }
            .frame(width: side, height: side)
    }
}

struct AssistantToolbarCircleButtonLabel: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24
    var isEnabled = true
    var emphasized = false

    var body: some View {
        ZStack {
            Circle()
                .fill(emphasized ? tint.opacity(0.18) : AppVisualTheme.surfaceFill(0.62))
                .overlay(
                    Circle()
                        .stroke(emphasized ? tint.opacity(0.16) : AppVisualTheme.surfaceStroke(0.38), lineWidth: 0.5)
                )

            Image(systemName: symbol)
                .font(.system(size: max(10, size * 0.40), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    isEnabled
                        ? (emphasized ? AppVisualTheme.foreground(0.95) : tint.opacity(0.85))
                        : AppVisualTheme.quaternaryForeground(0.72)
                )
        }
        .frame(width: size, height: size)
    }
}

struct AppGlassTokens {
    let canvasBase: Color
    let canvasDeep: Color
    let surfaceTop: Color
    let surfaceBottom: Color
    let glowRed: Color
    let glowBlue: Color
    let strokeTop: Color
    let strokeMid: Color
    let strokeBottom: Color
    let backgroundMaterial: NSVisualEffectView.Material
    let surfaceMaterial: NSVisualEffectView.Material
    let backgroundBlendingMode: NSVisualEffectView.BlendingMode
    let surfaceBlendingMode: NSVisualEffectView.BlendingMode
    let useMaterial: Bool
    let materialOpacity: Double
    let cardShadowColor: Color
    let cardShadowRadius: CGFloat
    let cardShadowYOffset: CGFloat
    let cardCornerRadius: CGFloat
    let modalCornerRadius: CGFloat
}

private struct AppLiquidGlassEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = emphasized
    }
}

struct AppChromeBackground: View {
    var tint: Color = AppVisualTheme.baseTint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        ZStack {
            tokens.canvasDeep

            if tokens.useMaterial {
                AppLiquidGlassEffectView(
                    material: tokens.backgroundMaterial,
                    blendingMode: tokens.backgroundBlendingMode
                )
                .opacity(tokens.materialOpacity)
            } else {
                tokens.canvasBase.opacity(0.94)
            }

            LinearGradient(
                colors: [
                    tokens.canvasDeep.opacity(0.96),
                    tokens.surfaceBottom.opacity(0.82),
                    tint.opacity(0.20),
                    tokens.canvasBase.opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    tokens.glowRed.opacity(0.12),
                    tokens.glowBlue.opacity(0.10),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            RadialGradient(
                colors: [
                    tokens.glowRed.opacity(0.94),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 24,
                endRadius: 980
            )
            RadialGradient(
                colors: [
                    tokens.glowRed.opacity(0.50),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [
                    tokens.glowBlue.opacity(0.94),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 22,
                endRadius: 960
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(tokens.useMaterial ? 0.04 : 0.03),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 780
            )
        }
        .overlay(
            LinearGradient(
                colors: [
                    isDark ? Color.black.opacity(0.03) : Color.white.opacity(0.18),
                    isDark ? Color.black.opacity(0.18) : Color.black.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }
}

struct AppSplitChromeBackground: View {
    var leadingPaneFraction: CGFloat = 0.32
    var leadingPaneMaxWidth: CGFloat = 340
    var leadingPaneWidth: CGFloat? = nil
    var leadingTint: Color = AppVisualTheme.sidebarTint
    var trailingTint: Color = AppVisualTheme.windowBackground
    var accent: Color = AppVisualTheme.accentTint
    var leadingPaneTransparent = false
    var showsLeadingDivider = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let sidebarSurfaceTop = AppVisualTheme.sidebarSurfaceTop
        let sidebarSurfaceBottom = AppVisualTheme.sidebarSurfaceBottom
        let sidebarTint = SettingsStore.shared.colorTheme == .noirGold
            ? AppVisualTheme.sidebarChromeTint
            : leadingTint

        GeometryReader { proxy in
            let calculatedWidth = proxy.size.width * leadingPaneFraction
            let dynamicWidth = min(leadingPaneMaxWidth, max(200, calculatedWidth))
            let maxAllowedWidth = max(180, proxy.size.width - 220)
            let leadingWidth =
                leadingPaneWidth.map { min(maxAllowedWidth, max(0, $0)) }
                ?? min(maxAllowedWidth, max(180, dynamicWidth))

            ZStack {
                if !tokens.useMaterial {
                    tokens.canvasDeep.opacity(0.88)
                }

                HStack(spacing: 0) {
                    Group {
                        ZStack {
                            if tokens.useMaterial {
                                AppLiquidGlassEffectView(
                                    material: .sidebar,
                                    blendingMode: tokens.backgroundBlendingMode
                                )
                                .opacity(leadingPaneTransparent ? 0.64 : 0.80)
                            } else {
                                sidebarSurfaceBottom.opacity(leadingPaneTransparent ? 0.80 : 0.94)
                            }

                            LinearGradient(
                                colors: [
                                    sidebarSurfaceTop.opacity(leadingPaneTransparent ? 0.52 : 0.68),
                                    sidebarTint.opacity(leadingPaneTransparent ? 0.08 : 0.12),
                                    sidebarSurfaceBottom.opacity(leadingPaneTransparent ? 0.80 : 0.94)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                    .frame(width: leadingWidth)
                    .overlay(alignment: .trailing) {
                        if showsLeadingDivider {
                            Rectangle()
                                .fill(
                                    AppVisualTheme.surfaceStroke(
                                        leadingPaneTransparent ? 0.24 : 0.32)
                                )
                                .frame(width: 0.5)
                        }
                    }

                    ZStack {
                        if tokens.useMaterial {
                            AppLiquidGlassEffectView(
                                material: tokens.backgroundMaterial,
                                blendingMode: tokens.backgroundBlendingMode
                            )
                            .opacity(0.82)
                        }

                        LinearGradient(
                            colors: [
                                tokens.canvasBase.opacity(tokens.useMaterial ? 0.20 : 0.98),
                                tokens.surfaceBottom.opacity(tokens.useMaterial ? 0.14 : 0.84),
                                tokens.canvasDeep.opacity(tokens.useMaterial ? 0.22 : 0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        trailingTint.opacity(tokens.useMaterial ? 0.18 : 0.14)

                        RadialGradient(
                            colors: [
                                tokens.glowRed.opacity(0.92),
                                Color.clear
                            ],
                            center: .bottomLeading,
                            startRadius: 24,
                            endRadius: 860
                        )

                        RadialGradient(
                            colors: [
                                tokens.glowBlue.opacity(0.92),
                                Color.clear
                            ],
                            center: .topTrailing,
                            startRadius: 18,
                            endRadius: 820
                        )

                        LinearGradient(
                            colors: [
                                tokens.glowRed.opacity(0.24),
                                tokens.glowBlue.opacity(0.20),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )

                        LinearGradient(
                            colors: [
                                accent.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        LinearGradient(
                            colors: [
                                isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.05),
                                isDark ? Color.black.opacity(0.14) : Color.black.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottom
                        )
                    }
                }

            }
            .overlay(
                LinearGradient(
                    colors: [
                        isDark ? Color.black.opacity(0.03) : Color.white.opacity(0.14),
                        isDark ? Color.black.opacity(0.13) : Color.black.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
    }
}

struct AppIconBadge: View {
    let symbol: String
    var tint: Color = AppVisualTheme.accentTint
    var size: CGFloat = 30
    var symbolSize: CGFloat = 13
    var isEmphasized = false

    var body: some View {
        let cornerRadius = max(6, size * 0.28)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(isEmphasized ? 0.22 : 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(tint.opacity(isEmphasized ? 0.28 : 0.18), lineWidth: 0.5)
                )

            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(tint.opacity(isEmphasized ? 0.96 : 0.88))
        }
        .frame(width: size, height: size)
    }
}

struct PermissionStateBadge: View {
    let granted: Bool
    var grantedLabel: String = "Allowed"
    var missingLabel: String = "Needs Access"

    var body: some View {
        let tint = granted ? Color.green : AppVisualTheme.baseTint
        let label = granted ? grantedLabel : missingLabel
        let symbol = granted ? "checkmark.circle.fill" : "hand.raised.fill"

        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint.opacity(0.96))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 0.7)
                )
        )
    }
}

struct AppSidebarSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppVisualTheme.secondaryForeground(0.72))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppVisualTheme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.40))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppVisualTheme.surfaceStroke(0.36), lineWidth: 0.5)
        )
    }
}

private struct AppThemedSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let tint: Color
    let strokeOpacity: Double
    let tintOpacity: Double

    func body(content: Content) -> some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let style = SettingsStore.shared.appChromeStyle
        let tokens = AppVisualTheme.glassTokens(
            style: style,
            reduceTransparency: reduceTransparency
        )
        let isGlass = style == .glassHighContrast
        let resolvedCornerRadius = max(cornerRadius, tokens.cardCornerRadius)
        let fillTopOpacity = isGlass ? (tokens.useMaterial ? 0.34 : 0.80) : (tokens.useMaterial ? 0.58 : 0.82)
        let fillBottomOpacity = isGlass ? (tokens.useMaterial ? 0.50 : 0.92) : 0.94

        content
            .background(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tokens.surfaceTop.opacity(fillTopOpacity),
                                tint.opacity(isGlass ? (0.12 + (tintOpacity * 0.65)) : (0.18 + (tintOpacity * 0.72))),
                                tokens.surfaceBottom.opacity(fillBottomOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if tokens.useMaterial {
                            AppLiquidGlassEffectView(
                                material: tokens.surfaceMaterial,
                                blendingMode: tokens.surfaceBlendingMode
                            )
                            .opacity(isGlass ? 0.88 : (tokens.materialOpacity * 0.44))
                            .clipShape(
                                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                            )
                        }
                    }
                    .overlay(
                        LinearGradient(
                            colors: [
                                isDark ? Color.white.opacity(isGlass ? 0.08 : 0.04) : Color.black.opacity(isGlass ? 0.06 : 0.03),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .stroke(AppVisualTheme.surfaceStroke(isGlass ? max(strokeOpacity * 0.40, 0.06) : strokeOpacity * 0.30), lineWidth: 0.5)
            )
    }
}

private struct AppSidebarSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let isDark = AppVisualTheme.isDarkAppearance
        let style = SettingsStore.shared.appChromeStyle
        let tokens = AppVisualTheme.glassTokens(
            style: style,
            reduceTransparency: reduceTransparency
        )
        let isGlass = style == .glassHighContrast
        let resolvedCornerRadius = max(cornerRadius, tokens.cardCornerRadius)

        content
            .background(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tokens.surfaceTop.opacity(isGlass && tokens.useMaterial ? 0.30 : 0.62),
                                tint.opacity(isGlass ? 0.14 : 0.18),
                                tokens.surfaceBottom.opacity(isGlass && tokens.useMaterial ? 0.44 : 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if tokens.useMaterial {
                            AppLiquidGlassEffectView(
                                material: tokens.surfaceMaterial,
                                blendingMode: tokens.surfaceBlendingMode
                            )
                            .opacity(isGlass ? 0.84 : 0.40)
                            .clipShape(
                                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                            )
                        }
                    }
                    .overlay(
                        LinearGradient(
                            colors: [
                                isDark ? tint.opacity(isGlass ? 0.10 : 0.14) : Color.black.opacity(isGlass ? 0.05 : 0.03),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
                    .overlay(
                        RadialGradient(
                            colors: [
                                tokens.glowBlue.opacity(isGlass ? 0.24 : 0.14),
                                Color.clear
                            ],
                            center: .topTrailing,
                            startRadius: 20,
                            endRadius: 360
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                tokens.strokeTop.opacity(isGlass ? 0.24 : 0.16),
                                tokens.strokeBottom.opacity(0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.45
                    )
            )
            .shadow(
                color: tokens.cardShadowColor.opacity(0.78),
                radius: max(4, tokens.cardShadowRadius * 0.72),
                x: 0,
                y: max(2, tokens.cardShadowYOffset * 0.66)
            )
    }
}

extension View {
    @MainActor
    func appThemedSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        strokeOpacity: Double = 0.14,
        tintOpacity: Double = 0.02
    ) -> some View {
        modifier(
            AppThemedSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint ?? AppVisualTheme.baseTint,
                strokeOpacity: strokeOpacity,
                tintOpacity: tintOpacity
            )
        )
    }

    @MainActor
    func appSidebarSurface(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil
    ) -> some View {
        modifier(
            AppSidebarSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint ?? AppVisualTheme.sidebarTint
            )
        )
    }

    @MainActor
    func appScrollbars(tint: Color? = nil) -> some View {
        background(AppScrollBarTintView(tint: tint ?? AppVisualTheme.baseTint))
    }
}

struct AppScrollBarTintView: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let hostView = nsView.superview else { return }
            applyScrollStyling(in: hostView, tint: NSColor(tint))
        }
    }

    private func applyScrollStyling(in view: NSView, tint: NSColor) {
        if let scrollView = view as? NSScrollView {
            configure(scrollView: scrollView, tint: tint)
        }
        for subview in view.subviews {
            applyScrollStyling(in: subview, tint: tint)
        }
    }

    private func configure(scrollView: NSScrollView, tint: NSColor) {
        guard let scroller = scrollView.verticalScroller else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scroller.wantsLayer = true
        scroller.layer?.cornerRadius = max(3, scroller.bounds.width * 0.5)
        scroller.layer?.backgroundColor = tint.withAlphaComponent(0.30).cgColor
        scroller.alphaValue = 0.98
    }
}
