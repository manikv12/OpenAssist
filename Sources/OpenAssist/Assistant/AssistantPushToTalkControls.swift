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
        let pulseScale = 1.0 + (visualLevel * 0.06)
        let ringScale = 1.0 + (visualLevel * 0.18)
        let ringOpacity = isActive ? (0.10 + (visualLevel * 0.18)) : 0.0
        let baseFillTop = isActive ? accentColor.opacity(0.30) : AppVisualTheme.foreground(0.10)
        let baseFillBottom = isActive ? accentColor.opacity(0.14) : AppVisualTheme.foreground(0.05)
        let symbolColor = isEnabled
            ? (isActive ? AppVisualTheme.foreground(0.96) : AppVisualTheme.foreground(0.72))
            : AppVisualTheme.foreground(0.34)

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
                    .scaleEffect(pulseScale)
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
                            isActive ? accentColor.opacity(0.34) : AppVisualTheme.foreground(0.10),
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
        .animation(.easeOut(duration: 0.14), value: isActive)
        .animation(.easeOut(duration: 0.08), value: visualLevel)
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

struct AssistantLiveVoiceButton: View {
    let snapshot: AssistantLiveVoiceSessionSnapshot
    let level: CGFloat
    var isEnabled: Bool = true
    var accentColor: Color = Color(red: 0.0, green: 0.75, blue: 0.95)
    var size: CGFloat = 28
    var onTap: () -> Void

    private var isActive: Bool {
        snapshot.isActive
    }

    private var visualLevel: CGFloat {
        if snapshot.isListening {
            return min(1, max(level, 0.20))
        }
        if snapshot.isSpeaking {
            return 0.42
        }
        if snapshot.phase == .sending || snapshot.phase == .transcribing {
            return 0.28
        }
        if snapshot.phase == .waitingForPermission {
            return 0.22
        }
        return isActive ? 0.16 : 0.0
    }

    private var symbolName: String {
        switch snapshot.phase {
        case .idle, .ended:
            return "mic.fill"
        case .speaking:
            return "speaker.slash.fill"
        case .waitingForPermission:
            return "hand.raised.fill"
        case .paused:
            return "mic.badge.xmark.fill"
        case .listening, .transcribing, .sending:
            return "waveform"
        }
    }

    private var helpText: String {
        if !isEnabled {
            return "Live voice is unavailable here right now."
        }

        switch snapshot.phase {
        case .idle, .ended:
            return "Start live voice."
        case .speaking:
            return "Stop the spoken reply and keep the live voice loop running."
        case .listening:
            return "Live voice is listening."
        case .transcribing:
            return "Live voice is transcribing your turn."
        case .sending:
            return "Live voice is sending your request."
        case .waitingForPermission:
            return "Live voice is waiting for approval."
        case .paused:
            return "Live voice is paused."
        }
    }

    var body: some View {
        let pulseScale = 1.0 + (visualLevel * 0.06)
        let ringScale = 1.0 + (visualLevel * 0.18)
        let ringOpacity = isActive ? (0.10 + (visualLevel * 0.18)) : 0.0
        let baseFillTop = isActive ? accentColor.opacity(0.30) : AppVisualTheme.foreground(0.10)
        let baseFillBottom = isActive ? accentColor.opacity(0.14) : AppVisualTheme.foreground(0.05)
        let symbolColor = isEnabled
            ? (isActive ? AppVisualTheme.foreground(0.96) : AppVisualTheme.foreground(0.72))
            : AppVisualTheme.foreground(0.34)

        Button(action: onTap) {
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
                        .scaleEffect(pulseScale)
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
                                isActive ? accentColor.opacity(0.34) : AppVisualTheme.foreground(0.10),
                                lineWidth: 0.9
                            )
                    )
                    .frame(width: size, height: size)
                    .shadow(color: isActive ? accentColor.opacity(0.18) : Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

                Image(systemName: symbolName)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .scaleEffect(isActive ? 1.02 : 1.0)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .opacity(isEnabled ? 1.0 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(helpText)
        .accessibilityLabel("Live voice")
        .accessibilityValue(snapshot.displayText)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .animation(.easeOut(duration: 0.08), value: visualLevel)
    }
}
