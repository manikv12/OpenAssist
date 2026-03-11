import SwiftUI

struct AssistantPushToTalkButton: View {
    let isListening: Bool
    let level: CGFloat
    var isEnabled: Bool = true
    var accentColor: Color = Color(red: 0.0, green: 0.75, blue: 0.95)
    var size: CGFloat = 28
    var onPressChanged: (Bool) -> Void

    @State private var isPointerHeld = false

    private var isActive: Bool {
        isListening || isPointerHeld
    }

    private var visualLevel: CGFloat {
        let idleLift: CGFloat = isPointerHeld ? 0.18 : 0.0
        return min(1, max(level, isListening ? 0.18 : idleLift))
    }

    private var helpText: String {
        if isEnabled {
            return "Hold to talk. Release to paste."
        }
        return "Voice input is unavailable here right now."
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 1.0 + (visualLevel * 0.06) + (CGFloat(sin(time * 5.0)) * (isActive ? 0.02 : 0.0))
            let ringScale = 1.0 + (visualLevel * 0.18)
            let ringOpacity = 0.10 + (visualLevel * 0.18)
            let baseFillTop = isActive ? accentColor.opacity(0.30) : Color.white.opacity(0.10)
            let baseFillBottom = isActive ? accentColor.opacity(0.14) : Color.white.opacity(0.05)
            let symbolColor = isEnabled
                ? (isActive ? Color.white.opacity(0.96) : Color.white.opacity(0.72))
                : Color.white.opacity(0.34)

            ZStack {
                if isActive {
                    Circle()
                        .stroke(accentColor.opacity(ringOpacity), lineWidth: 1.0)
                        .frame(width: size + 5, height: size + 5)
                        .scaleEffect(ringScale)

                    Circle()
                        .fill(accentColor.opacity(0.10 + (visualLevel * 0.12)))
                        .frame(width: size + 2, height: size + 2)
                        .blur(radius: 6)
                        .scaleEffect(pulse)
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                baseFillTop,
                                baseFillBottom
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                isActive ? accentColor.opacity(0.34) : Color.white.opacity(0.10),
                                lineWidth: 0.9
                            )
                    )
                    .frame(width: size, height: size)
                    .shadow(color: isActive ? accentColor.opacity(0.18) : Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .scaleEffect(isActive ? 1.02 : 1.0)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .opacity(isEnabled ? 1.0 : 0.62)
            .gesture(pressGesture)
            .help(helpText)
            .accessibilityLabel("Push to talk")
            .accessibilityValue(isListening ? "Listening" : "Ready")
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard isEnabled, !isPointerHeld else { return }
                isPointerHeld = true
                onPressChanged(true)
            }
            .onEnded { _ in
                guard isPointerHeld else { return }
                isPointerHeld = false
                onPressChanged(false)
            }
    }
}
