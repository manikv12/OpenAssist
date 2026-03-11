import AppKit
import SwiftUI

private enum HUDLayout {
    static let waveformWidth: CGFloat = 100
    static let waveformHeight: CGFloat = 34
    static let toastWidth: CGFloat = 360
    static let toastHeight: CGFloat = 38
    static let correctionWidth: CGFloat = 520
    static let correctionHeight: CGFloat = 44
    static let toastVerticalGap: CGFloat = 12
    static let correctionDecisionTimeout: TimeInterval = 30
    /// Fixed offset from the bottom of the screen so the HUD always sits
    /// above the Dock region, even on screens that don't host the Dock.
    static let dockReserve: CGFloat = 80
}

private enum HUDCorrectionDecision {
    case accept
    case reject
    case timedOut
}

@MainActor
final class WaveformHUDManager {
    private var waveformPanel: NSPanel?
    private var toastPanel: NSPanel?
    private var correctionPanel: NSPanel?
    private let waveformModel = WaveformModel()
    private let toastModel = HUDToastModel()
    private let correctionModel = HUDCorrectionDecisionModel()
    private var toastHideWorkItem: DispatchWorkItem?
    private var correctionHideWorkItem: DispatchWorkItem?
    private var correctionDecisionToken = UUID()
    private var correctionAcceptHandler: (() -> Void)?
    private var correctionRejectHandler: (() -> Void)?

    func show() {
        if waveformPanel == nil {
            createWaveformPanel()
        }
        guard let waveformPanel else { return }
        waveformModel.reset()
        waveformModel.startAnimating()
        repositionWaveformPanel()
        waveformPanel.orderFrontRegardless()
    }

    func hide() {
        waveformModel.stopAnimating()
        waveformModel.reset()
        waveformPanel?.orderOut(nil)
        dismissCorrectionDecisionUI()
    }

    func updateLevel(_ level: Float) {
        waveformModel.updateLevel(level)
    }

    func flashEvent(message: String, symbolName: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if toastPanel == nil {
            createToastPanel()
        }

        guard let toastPanel else { return }

        toastHideWorkItem?.cancel()
        toastModel.symbolName = symbolName
        toastModel.message = trimmed
        repositionToastPanel()
        toastPanel.orderFrontRegardless()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.toastPanel?.orderOut(nil)
            }
        }
        toastHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hideWorkItem)
    }

    func presentCorrectionDecision(
        source: String,
        replacement: String,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedReplacement.isEmpty else { return }

        if correctionPanel == nil {
            createCorrectionPanel()
        }
        guard let correctionPanel else { return }

        dismissCorrectionDecisionUI()
        correctionAcceptHandler = onAccept
        correctionRejectHandler = onReject

        correctionModel.source = trimmedSource
        correctionModel.replacement = trimmedReplacement

        let token = UUID()
        correctionDecisionToken = token
        correctionModel.onAcceptTap = { [weak self] in
            self?.completeCorrectionDecision(token: token, decision: .accept)
        }
        correctionModel.onRejectTap = { [weak self] in
            self?.completeCorrectionDecision(token: token, decision: .reject)
        }

        repositionCorrectionPanel()
        correctionPanel.orderFrontRegardless()
        correctionPanel.makeKeyAndOrderFront(nil)

        let hideWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.completeCorrectionDecision(token: token, decision: .timedOut)
            }
        }
        correctionHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + HUDLayout.correctionDecisionTimeout,
            execute: hideWorkItem
        )
    }

    private func createWaveformPanel() {
        let frame = NSRect(x: 0, y: 0, width: HUDLayout.waveformWidth, height: HUDLayout.waveformHeight)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let hosting = NSHostingController(rootView: WaveformPanelView(model: waveformModel))
        hosting.view.frame = frame
        panel.contentViewController = hosting
        self.waveformPanel = panel
    }

    private func createToastPanel() {
        let frame = NSRect(x: 0, y: 0, width: HUDLayout.toastWidth, height: HUDLayout.toastHeight)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let hosting = NSHostingController(rootView: HUDToastView(model: toastModel))
        hosting.view.frame = frame
        panel.contentViewController = hosting
        toastPanel = panel
    }

    private func createCorrectionPanel() {
        let frame = NSRect(x: 0, y: 0, width: HUDLayout.correctionWidth, height: HUDLayout.correctionHeight)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let hosting = NSHostingController(rootView: HUDCorrectionDecisionView(model: correctionModel))
        hosting.view.frame = frame
        panel.contentViewController = hosting
        correctionPanel = panel
    }

    private func repositionWaveformPanel() {
        guard let waveformPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let x = screen.frame.midX - (waveformPanel.frame.width * 0.5)
        let y = screen.frame.minY + HUDLayout.dockReserve

        let newOrigin = NSPoint(x: x, y: y)
        if waveformPanel.frame.origin != newOrigin {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            waveformPanel.setFrameOrigin(newOrigin)
            CATransaction.commit()
        }
    }

    private func repositionToastPanel() {
        guard let toastPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let x = screen.frame.midX - (toastPanel.frame.width * 0.5)
        let y = screen.frame.minY + HUDLayout.dockReserve + HUDLayout.waveformHeight + HUDLayout.toastVerticalGap
        let newOrigin = NSPoint(x: x, y: y)
        
        if toastPanel.frame.origin != newOrigin {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            toastPanel.setFrameOrigin(newOrigin)
            CATransaction.commit()
        }
    }

    private func repositionCorrectionPanel() {
        guard let correctionPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let x = screen.frame.midX - (correctionPanel.frame.width * 0.5)
        let y = screen.frame.minY + HUDLayout.dockReserve + HUDLayout.waveformHeight + HUDLayout.toastVerticalGap
        let newOrigin = NSPoint(x: x, y: y)
        
        if correctionPanel.frame.origin != newOrigin {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            correctionPanel.setFrameOrigin(newOrigin)
            CATransaction.commit()
        }
    }

    private func completeCorrectionDecision(token: UUID, decision: HUDCorrectionDecision) {
        guard token == correctionDecisionToken else { return }

        let onAccept = correctionAcceptHandler
        let onReject = correctionRejectHandler
        dismissCorrectionDecisionUI()

        switch decision {
        case .accept:
            onAccept?()
        case .reject:
            onReject?()
        case .timedOut:
            break
        }
    }

    private func dismissCorrectionDecisionUI() {
        correctionHideWorkItem?.cancel()
        correctionHideWorkItem = nil
        correctionAcceptHandler = nil
        correctionRejectHandler = nil
        correctionModel.onAcceptTap = nil
        correctionModel.onRejectTap = nil
        correctionPanel?.orderOut(nil)
    }
}

@MainActor
final class WaveformModel: ObservableObject {
    @Published var level: Double = 0
    @Published var phase: Double = 0
    @Published var impulse: Double = 0

    private var targetLevel: Double = 0
    private var animationTimer: Timer?

    func reset() {
        level = 0
        phase = 0
        impulse = 0
        targetLevel = 0
    }

    func updateLevel(_ value: Float) {
        targetLevel = max(0, min(1, Double(value)))
    }

    func startAnimating() {
        guard animationTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        let delta = targetLevel - level
        let attack: Double = 0.14
        let release: Double = 0.08
        level += delta * (delta > 0 ? attack : release)

        let spike = max(0, delta)
        impulse = max(spike, impulse * 0.85)
        targetLevel *= 0.93

        // Gentle, smooth phase progression
        phase += 0.12 + (level * 0.30) + (impulse * 0.15)
    }
}

struct WaveformPanelView: View {
    @ObservedObject var model: WaveformModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            SoundWaveLine(level: model.level, phase: model.phase, impulse: model.impulse, theme: settings.waveformTheme)
                .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            HUDCapsuleBackground(tint: AppVisualTheme.baseTint)
        )
        .frame(width: HUDLayout.waveformWidth, height: HUDLayout.waveformHeight, alignment: .center)
    }
}

struct WaveformThemePreview: View {
    let theme: WaveformTheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 8, height: 8)

            SoundWaveLine(
                level: 0.48,
                phase: 1.2,
                impulse: 0.12,
                theme: theme
            )
            .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            HUDCapsuleBackground(tint: AppVisualTheme.baseTint)
        )
        .frame(height: 34)
        .frame(width: 188, height: 34, alignment: .leading)
    }
}

@MainActor
final class HUDToastModel: ObservableObject {
    @Published var symbolName: String = "checkmark.circle.fill"
    @Published var message: String = ""
}

struct HUDToastView: View {
    @ObservedObject var model: HUDToastModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)

            Image(systemName: model.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)

            Text(model.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            HUDCapsuleBackground(tint: AppVisualTheme.accentTint)
        )
        .frame(width: HUDLayout.toastWidth, height: HUDLayout.toastHeight, alignment: .center)
    }
}

@MainActor
final class HUDCorrectionDecisionModel: ObservableObject {
    @Published var source: String = ""
    @Published var replacement: String = ""
    var onAcceptTap: (() -> Void)?
    var onRejectTap: (() -> Void)?
}

struct HUDCorrectionDecisionView: View {
    @ObservedObject var model: HUDCorrectionDecisionModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)

            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)

            Text("Save correction:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(model.source) -> \(model.replacement)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            Button("Reject") {
                model.onRejectTap?()
            }
            .buttonStyle(HUDPillActionButtonStyle(kind: .reject))

            Button("Accept") {
                model.onAcceptTap?()
            }
            .buttonStyle(HUDPillActionButtonStyle(kind: .accept))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            HUDCapsuleBackground(tint: AppVisualTheme.accentTint)
        )
        .frame(width: HUDLayout.correctionWidth, height: HUDLayout.correctionHeight, alignment: .center)
    }
}

struct HUDCapsuleBackground: View {
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
                        tokens.surfaceTop.opacity(0.80),
                        tint.opacity(0.24),
                        tokens.surfaceBottom.opacity(0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if tokens.useMaterial {
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                        .opacity(0.56)
                }
            }
            .overlay(
                LinearGradient(
                    colors: [
                        tokens.glowRed.opacity(0.22),
                        tokens.glowBlue.opacity(0.18),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                RadialGradient(
                    colors: [
                        tokens.glowBlue.opacity(0.22),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 12,
                    endRadius: 180
                )
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tokens.strokeTop.opacity(0.14), lineWidth: 0.45)
            )
    }
}

private struct HUDPillActionButtonStyle: ButtonStyle {
    enum Kind {
        case accept
        case reject
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(backgroundColor.opacity(configuration.isPressed ? 0.65 : 1))
            )
            .overlay(
                Capsule()
                    .stroke(strokeColor.opacity(configuration.isPressed ? 0.65 : 1), lineWidth: 0.8)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .accept:
            return Color.green
        case .reject:
            return Color.red
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .accept:
            return Color.green.opacity(0.12)
        case .reject:
            return Color.red.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .accept:
            return Color.green.opacity(0.36)
        case .reject:
            return Color.red.opacity(0.36)
        }
    }
}

struct SoundWaveLine: View {
    let level: Double
    let phase: Double
    let impulse: Double
    let theme: WaveformTheme

    private let barCount = 7
    private let barSpacing: CGFloat = 3.0

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                BarView(index: index, barCount: barCount, level: level, phase: phase, impulse: impulse, theme: theme)
            }
        }
        .frame(height: 24, alignment: .center)
    }
}

struct BarView: View {
    let index: Int
    let barCount: Int
    let level: Double
    let phase: Double
    let impulse: Double
    let theme: WaveformTheme

    var body: some View {
        Capsule()
            .fill(barGradient)
            .frame(width: 4.0, height: calculateHeight())
    }

    private var barGradient: LinearGradient {
        let mix = min(1, level + impulse * 0.3)
        // Increase opacity for a more vibrant, colourful look while keeping it professional
        let opacity = 0.75 + mix * 0.25
        let t = Double(index) / Double(max(1, barCount - 1))
        let tint = barTint(at: t)
        
        return LinearGradient(
            colors: [
                tint.opacity(opacity * 0.5),
                tint.opacity(opacity)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func barTint(at t: Double) -> Color {
        switch theme {
        case .vibrantSpectrum:
            let blue = (r: 0.26, g: 0.52, b: 0.96)
            let red = (r: 0.92, g: 0.26, b: 0.21)
            let yellow = (r: 0.98, g: 0.74, b: 0.02)
            let green = (r: 0.20, g: 0.66, b: 0.33)
            return interpolate(t: t, colors: [blue, red, yellow, green])
            
        case .professionalTech:
            let cyan = (r: 0.15, g: 0.85, b: 1.0)
            let indigo = (r: 0.35, g: 0.35, b: 0.95)
            let violet = (r: 0.75, g: 0.25, b: 0.85)
            return interpolate(t: t, colors: [cyan, indigo, violet])
            
        case .monochrome:
            let white = (r: 1.0, g: 1.0, b: 1.0)
            let gray = (r: 0.6, g: 0.6, b: 0.6)
            return interpolate(t: t, colors: [white, gray, white, gray])
            
        case .neonLagoon:
            let c1 = (r: 0.00, g: 1.00, b: 0.53) // #00FF87
            let c2 = (r: 0.38, g: 0.94, b: 1.00) // #60EFFF
            return interpolate(t: t, colors: [c1, c2])
            
        case .sunsetCandy:
            let c1 = (r: 1.00, g: 0.06, b: 0.48) // #FF0F7B
            let c2 = (r: 0.97, g: 0.61, b: 0.16) // #F89B29
            return interpolate(t: t, colors: [c1, c2])
            
        case .cosmicPop:
            let c1 = (r: 0.25, g: 0.79, b: 1.00) // #40C9FF
            let c2 = (r: 0.91, g: 0.11, b: 1.00) // #E81CFF
            return interpolate(t: t, colors: [c1, c2])
            
        case .mintBlush:
            let c1 = (r: 0.66, g: 1.00, b: 0.41) // #A9FF68
            let c2 = (r: 1.00, g: 0.54, b: 0.54) // #FF8989
            return interpolate(t: t, colors: [c1, c2])
        }
    }
    
    private func interpolate(t: Double, colors: [(r: Double, g: Double, b: Double)]) -> Color {
        if colors.count == 1 {
            let c = colors[0]
            return Color(red: c.r, green: c.g, blue: c.b)
        }
        
        let segment = 1.0 / Double(colors.count - 1)
        
        for i in 0..<(colors.count - 1) {
            let startT = Double(i) * segment
            let endT = Double(i + 1) * segment
            
            if t <= endT || i == colors.count - 2 {
                let p = max(0, min(1, (t - startT) / segment))
                let c1 = colors[i]
                let c2 = colors[i+1]
                return Color(
                    red: c1.r + (c2.r - c1.r) * p,
                    green: c1.g + (c2.g - c1.g) * p,
                    blue: c1.b + (c2.b - c1.b) * p
                )
            }
        }
        
        let last = colors.last!
        return Color(red: last.r, green: last.g, blue: last.b)
    }

    private func calculateHeight() -> CGFloat {
        let t = Double(index) / Double(max(1, barCount - 1))

        let speed = phase * 0.15
        let centerOffset = abs(t - 0.5) * 2.0
        let bellCurve = exp(-pow(centerOffset / 0.7, 2))

        let wave = sin((t * 2.5 + speed + Double(index) * 0.6) * .pi * 2.0)
        let intensity = 0.18 + (level * 0.85) + (impulse * 0.3)

        let minHeight: CGFloat = 5.0
        let maxHeight: CGFloat = 22.0
        let diff = maxHeight - minHeight

        let heightVariation = CGFloat(abs(wave)) * CGFloat(intensity) * CGFloat(bellCurve) * diff
        return min(maxHeight, minHeight + heightVariation)
    }
}
