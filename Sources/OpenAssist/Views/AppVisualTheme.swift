import AppKit
import SwiftUI

@MainActor
enum AppVisualTheme {
    private static var palette: ColorPalette { SettingsStore.shared.colorTheme.palette }
    static var baseTint: Color { palette.baseTint }
    static var accentTint: Color { palette.accentTint }
    static var canvasBase: Color { palette.canvasBase }
    static var canvasDeep: Color { palette.canvasDeep }
    static var sidebarTint: Color { palette.sidebarTint }
    static var panelTint: Color { palette.panelTint }
    static var rowSelection: Color { palette.rowSelection }
    static var historyTint: Color { palette.historyTint }
    static var aiStudioTint: Color { palette.aiStudioTint }
    static var settingsTint: Color { palette.settingsTint }
    static let mutedText = Color.white.opacity(0.68)

    static func glassTokens(style: AppChromeStyle, reduceTransparency: Bool) -> AppGlassTokens {
        let materialEnabled = !reduceTransparency
        let p = palette

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
                    Color.black.opacity(0.03),
                    Color.black.opacity(0.18)
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
    var trailingTint: Color = Color.black
    var accent: Color = AppVisualTheme.accentTint
    var leadingPaneTransparent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        GeometryReader { proxy in
            let calculatedWidth = proxy.size.width * leadingPaneFraction
            let dynamicWidth = min(leadingPaneMaxWidth, max(200, calculatedWidth))
            let preferredWidth = leadingPaneWidth ?? dynamicWidth
            let maxAllowedWidth = max(180, proxy.size.width - 220)
            let leadingWidth = min(maxAllowedWidth, max(180, preferredWidth))

            ZStack {
                tokens.canvasDeep.opacity(0.92)

                HStack(spacing: 0) {
                    Group {
                        ZStack {
                            if tokens.useMaterial {
                                AppLiquidGlassEffectView(
                                    material: .sidebar,
                                    blendingMode: tokens.backgroundBlendingMode
                                )
                                .opacity(leadingPaneTransparent ? 0.66 : 0.82)
                            } else {
                                tokens.surfaceBottom.opacity(0.90)
                            }

                            LinearGradient(
                                colors: [
                                    tokens.surfaceTop.opacity(leadingPaneTransparent ? 0.42 : 0.66),
                                    leadingTint.opacity(leadingPaneTransparent ? 0.14 : 0.22),
                                    tokens.surfaceBottom.opacity(0.93)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            LinearGradient(
                                colors: [
                                    leadingTint.opacity(leadingPaneTransparent ? 0.05 : 0.10),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            if !leadingPaneTransparent {
                                RadialGradient(
                                    colors: [
                                        tokens.glowBlue.opacity(0.48),
                                        tokens.glowRed.opacity(0.22),
                                        Color.clear
                                    ],
                                    center: .topTrailing,
                                    startRadius: 20,
                                    endRadius: 520
                                )
                            }
                        }
                    }
                    .frame(width: leadingWidth)
                    .overlay(alignment: .trailing) {
                        if !leadingPaneTransparent {
                            LinearGradient(
                                colors: [
                                    tokens.strokeTop.opacity(0.32),
                                    tokens.strokeMid.opacity(0.26),
                                    tokens.strokeBottom.opacity(0.30)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(width: 1)
                        }
                    }

                    ZStack {
                        if tokens.useMaterial {
                            AppLiquidGlassEffectView(
                                material: tokens.backgroundMaterial,
                                blendingMode: tokens.backgroundBlendingMode
                            )
                            .opacity(0.34)
                        }

                        LinearGradient(
                            colors: [
                                tokens.canvasBase.opacity(0.98),
                                tokens.surfaceBottom.opacity(0.84),
                                tokens.canvasDeep.opacity(0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        trailingTint.opacity(0.14)

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
                                Color.white.opacity(0.03),
                                Color.black.opacity(0.14)
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
                        Color.black.opacity(0.03),
                        Color.black.opacity(0.13)
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
        let cornerRadius = max(8, size * 0.30)
        let baseTop = Color(red: 0.12, green: 0.15, blue: 0.21)
        let baseBottom = Color(red: 0.08, green: 0.10, blue: 0.15)
        let tintTop = tint.opacity(isEmphasized ? 0.94 : 0.82)
        let tintBottom = tint.opacity(isEmphasized ? 0.76 : 0.62)
        let symbolColor = Color.white.opacity(0.98)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [baseTop, baseBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tintTop, tintBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .saturation(isEmphasized ? 1.18 : 1.10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.05),
                                    Color.black.opacity(0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.45), lineWidth: 0.6)
                )

            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(symbolColor)
                .shadow(color: Color.black.opacity(0.28), radius: 1.2, x: 0, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(
            color: Color.black.opacity(isEmphasized ? 0.24 : 0.18),
            radius: isEmphasized ? 3.5 : 2.5,
            x: 0,
            y: 1.5
        )
    }
}

struct AppSidebarSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppVisualTheme.mutedText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.07),
                            AppVisualTheme.baseTint.opacity(0.16),
                            Color.black.opacity(0.26)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.45)
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
                                Color.white.opacity(isGlass ? 0.18 : 0.10),
                                Color.white.opacity(isGlass ? 0.05 : 0.03),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
                    .overlay(
                        LinearGradient(
                            colors: [
                                tint.opacity(isGlass ? (0.08 + (tintOpacity * 0.45)) : (0.11 + tintOpacity)),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [
                                tokens.glowRed.opacity(isGlass ? 0.22 : 0.12),
                                tokens.glowBlue.opacity(isGlass ? 0.18 : 0.10),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(height: max(54, resolvedCornerRadius * 2.6))
                        .clipShape(
                            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                        )
                    }
                    .overlay(
                        RadialGradient(
                            colors: [
                                tokens.glowRed.opacity(isGlass ? 0.34 : 0.18),
                                Color.clear
                            ],
                            center: .bottomLeading,
                            startRadius: 16,
                            endRadius: 420
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
                    .overlay(
                        RadialGradient(
                            colors: [
                                tokens.glowBlue.opacity(isGlass ? 0.32 : 0.18),
                                Color.clear
                            ],
                            center: .topTrailing,
                            startRadius: 18,
                            endRadius: 420
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(isGlass ? 0.02 : 0.01),
                                Color.black.opacity(isGlass ? 0.14 : 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                tokens.strokeTop.opacity(isGlass ? max(strokeOpacity * 0.55, 0.08) : strokeOpacity * 0.46),
                                tokens.strokeMid.opacity(strokeOpacity * 0.28),
                                tokens.strokeBottom.opacity(strokeOpacity * 0.40)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.45
                    )
            )
            .shadow(
                color: tokens.cardShadowColor,
                radius: tokens.cardShadowRadius,
                x: 0,
                y: tokens.cardShadowYOffset
            )
    }
}

private struct AppSidebarSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
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
                                tint.opacity(isGlass ? 0.10 : 0.14),
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
