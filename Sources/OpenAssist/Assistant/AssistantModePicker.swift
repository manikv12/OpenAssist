import SwiftUI

extension AssistantInteractionMode {
    @MainActor
    var displayTint: Color {
        switch self {
        case .conversational:
            return .blue
        case .plan:
            return .orange
        case .agentic:
            return AppVisualTheme.accentTint
        }
    }

    var nextMode: AssistantInteractionMode {
        let allModes = Self.allCases
        guard let currentIndex = allModes.firstIndex(of: self) else {
            return .conversational
        }
        let nextIndex = allModes.index(after: currentIndex)
        return nextIndex == allModes.endIndex ? allModes[allModes.startIndex] : allModes[nextIndex]
    }
}

struct AssistantModePicker: View {
    enum Style {
        case standard
        case compact
        case micro

        var iconSize: CGFloat {
            switch self {
            case .standard: return 9
            case .compact: return 8
            case .micro: return 7.25
            }
        }

        var textSize: CGFloat {
            switch self {
            case .standard: return 11
            case .compact: return 9.5
            case .micro: return 8.75
            }
        }

        var chevronSize: CGFloat {
            switch self {
            case .standard: return 7
            case .compact: return 6
            case .micro: return 5.25
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .standard: return 8
            case .compact: return 7
            case .micro: return 6
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .standard: return 4
            case .compact: return 3
            case .micro: return 2.5
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .standard: return 6
            case .compact: return 6
            case .micro: return 5
            }
        }

        var fillOpacity: Double {
            switch self {
            case .standard: return 0.07
            case .compact: return 0.07
            case .micro: return 0.045
            }
        }

        var strokeOpacity: Double {
            switch self {
            case .standard: return 0.0
            case .compact: return 0.0
            case .micro: return 0.055
            }
        }

        var textOpacity: Double {
            switch self {
            case .standard: return 0.55
            case .compact: return 0.55
            case .micro: return 0.50
            }

        }

        var chevronOpacity: Double {
            switch self {
            case .standard: return 0.25
            case .compact: return 0.25
            case .micro: return 0.20
            }
        }
    }

    let selection: AssistantInteractionMode
    var style: Style = .standard
    var onSelect: (AssistantInteractionMode) -> Void

    var body: some View {
        Menu {
            ForEach(AssistantInteractionMode.allCases, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(spacing: 8) {
                        Label(mode.label, systemImage: mode.icon)
                        if mode == selection {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection.icon)
                    .font(.system(size: style.iconSize, weight: .semibold))
                    .foregroundStyle(selection.displayTint)
                Text(selection.label)
                    .font(.system(size: style.textSize, weight: .medium))
                    .foregroundStyle(.white.opacity(style.textOpacity))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: style.chevronSize, weight: .bold))
                    .foregroundStyle(.white.opacity(style.chevronOpacity))
            }
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(style.fillOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(style.strokeOpacity), lineWidth: 0.6)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(selection.hint). Shift-Tab switches mode.")
    }
}
