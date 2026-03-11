import SwiftUI

struct AssistantBetaWindowView: View {
    @ObservedObject var model: AssistantBetaWindowModel
    var actions: AssistantBetaWindowActions = AssistantBetaWindowActions()

    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            AppSplitChromeBackground(
                leadingPaneFraction: 0.23,
                leadingPaneMaxWidth: 320,
                leadingTint: AppVisualTheme.sidebarTint,
                trailingTint: .black,
                accent: AppVisualTheme.accentTint
            )

            HStack(spacing: 18) {
                sessionsColumn
                    .frame(width: 300)

                mainColumn
                    .frame(maxWidth: .infinity)

                detailsColumn
                    .frame(width: 320)
            }
            .padding(20)
        }
        .frame(minWidth: 1180, minHeight: 760)
        .tint(AppVisualTheme.accentTint)
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconBadge(symbol: "clock.arrow.circlepath", tint: AppVisualTheme.accentTint, size: 34, symbolSize: 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent Sessions")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("Open an old task, resume it, or quickly start a new one.")
                        .font(.caption)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }

                Spacer(minLength: 0)

                Button {
                    actions.onRefreshSessions?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(AssistantBetaIconButtonStyle(isBusy: model.isRefreshingSessions))
                .disabled(model.isRefreshingSessions)
                .help("Refresh sessions")
            }

            Button {
                actions.onNewTask?()
                composerFocused = true
            } label: {
                Label("New Task", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AssistantBetaPrimaryButtonStyle())

            ScrollView {
                if model.sessions.isEmpty {
                    AssistantBetaEmptyCard(
                        symbol: "tray",
                        title: "No sessions yet",
                        message: "When a task starts, it will appear here so the user can open it again later."
                    )
                    .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.sessions) { session in
                            Button {
                                model.selectSession(session)
                                actions.onSelectSession?(session)
                            } label: {
                                AssistantBetaSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSession?.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .appScrollbars()
        }
        .padding(18)
        .appSidebarSurface(cornerRadius: 22, tint: AppVisualTheme.sidebarTint)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerCard

            if !model.banners.isEmpty {
                VStack(spacing: 10) {
                    ForEach(model.banners) { banner in
                        AssistantBetaBannerCard(
                            banner: banner,
                            onAction: { handleBannerAction(banner) }
                        )
                    }
                }
            }

            transcriptCard
                .frame(maxHeight: .infinity)

            composerCard
        }
    }

    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionDetailCard

            if let installHelp = model.installHelp {
                installHelpCard(installHelp)
            }

            voiceDraftCard
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconBadge(symbol: "sparkles.rectangle.stack", tint: AppVisualTheme.accentTint, size: 38, symbolSize: 15, isEmphasized: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.97))

                    Text("A calm control room for typed tasks, voice drafts, live progress, and session history.")
                        .font(.subheadline)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    Button("Settings") {
                        actions.onOpenSettings?()
                    }
                    .buttonStyle(AssistantBetaSecondaryButtonStyle())

                    Button("New Task") {
                        actions.onNewTask?()
                        composerFocused = true
                    }
                    .buttonStyle(AssistantBetaPrimaryButtonStyle())
                }
            }

            HStack(spacing: 10) {
                AssistantBetaStatChip(
                    symbol: "waveform.and.mic",
                    label: model.isRuntimeBusy ? "Busy" : "Ready",
                    tint: model.isRuntimeBusy ? .orange : .green
                )

                AssistantBetaStatChip(
                    symbol: "clock.arrow.circlepath",
                    label: "\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")",
                    tint: AppVisualTheme.accentTint
                )

                if let selectedSession = model.selectedSession {
                    AssistantBetaStatChip(
                        symbol: "bolt.horizontal.circle",
                        label: selectedSession.status.rawValue.capitalized,
                        tint: color(for: selectedSession.status)
                    )
                }
            }
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 22, tint: AppVisualTheme.accentTint, strokeOpacity: 0.18, tintOpacity: 0.05)
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Activity")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("Keep responses short here. Full logic can stay in the runtime later.")
                        .font(.caption)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }

                Spacer(minLength: 0)

                if model.isSending {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            ScrollView {
                if model.transcriptItems.isEmpty {
                    AssistantBetaEmptyCard(
                        symbol: "message",
                        title: model.transcriptEmptyTitle,
                        message: model.transcriptEmptyMessage
                    )
                    .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.transcriptItems) { item in
                            AssistantBetaTranscriptRow(item: item)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .appScrollbars()
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 22, tint: AppVisualTheme.baseTint, strokeOpacity: 0.16, tintOpacity: 0.035)
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Task Composer")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("The app can drop a voice draft here, and the user can edit it before sending.")
                        .font(.caption)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }

                Spacer(minLength: 0)

                if case .listening(let message) = model.voiceDraftState {
                    AssistantBetaMiniPill(symbol: "mic.fill", label: message, tint: .orange)
                } else if case .captured = model.voiceDraftState {
                    AssistantBetaMiniPill(symbol: "checkmark.circle.fill", label: "Voice draft ready", tint: .green)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.07),
                                AppVisualTheme.baseTint.opacity(0.18),
                                Color.black.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    )

                if model.draftText.isEmpty {
                    Text(model.composerPlaceholder)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.44))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $model.draftText)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 108)
                    .background(Color.clear)
            }

            HStack(spacing: 10) {
                Button {
                    actions.onSend?(model.trimmedDraftText)
                } label: {
                    Label(model.isSending ? "Sending..." : "Send to Assistant", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AssistantBetaPrimaryButtonStyle())
                .disabled(!model.canSend)

                Button("Open Settings") {
                    actions.onOpenSettings?()
                }
                .buttonStyle(AssistantBetaSecondaryButtonStyle())
            }
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 22, tint: AppVisualTheme.accentTint, strokeOpacity: 0.16, tintOpacity: 0.04)
    }

    private var sessionDetailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconBadge(symbol: "sidebar.right", tint: AppVisualTheme.accentTint, size: 32, symbolSize: 13)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Session Details")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("Open one session, see its summary, then resume it if needed.")
                        .font(.caption)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
            }

            if let detail = model.resolvedSessionDetail, let session = model.selectedSession {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.headline)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(detail.summary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))

                    AssistantBetaMiniPill(
                        symbol: "bolt.horizontal.circle.fill",
                        label: detail.statusLine,
                        tint: color(for: session.status)
                    )

                    if !detail.facts.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(detail.facts) { fact in
                                HStack(alignment: .top) {
                                    Text(fact.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppVisualTheme.mutedText)
                                        .frame(width: 88, alignment: .leading)

                                    Text(fact.value)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.86))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(12)
                        .appThemedSurface(cornerRadius: 16, tint: AppVisualTheme.baseTint, strokeOpacity: 0.12, tintOpacity: 0.02)
                    }

                    if !detail.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppVisualTheme.mutedText)

                            ForEach(detail.notes, id: \.self) { note in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(AppVisualTheme.accentTint.opacity(0.9))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 6)

                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.82))
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(detail.primaryActionTitle) {
                            actions.onResumeSession?(session)
                        }
                        .buttonStyle(AssistantBetaPrimaryButtonStyle())

                        Button(detail.secondaryActionTitle) {
                            actions.onOpenSession?(session)
                        }
                        .buttonStyle(AssistantBetaSecondaryButtonStyle())
                    }
                }
            } else {
                AssistantBetaEmptyCard(
                    symbol: "square.on.square",
                    title: "Select a session",
                    message: "When the user picks a session on the left, the details and resume actions show here."
                )
            }
        }
        .padding(18)
        .appThemedSurface(cornerRadius: 22, tint: AppVisualTheme.baseTint, strokeOpacity: 0.15, tintOpacity: 0.03)
    }

    private func installHelpCard(_ installHelp: AssistantBetaInstallHelp) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconBadge(symbol: "arrow.down.circle", tint: .orange, size: 32, symbolSize: 13)

                VStack(alignment: .leading, spacing: 3) {
                    Text(installHelp.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(installHelp.message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(installHelp.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black.opacity(0.82))
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.86))
                            )

                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(installHelp.primaryButtonTitle) {
                    actions.onInstallHelp?()
                }
                .buttonStyle(AssistantBetaPrimaryButtonStyle(tint: .orange))

                if let secondaryTitle = installHelp.secondaryButtonTitle {
                    Button(secondaryTitle) {
                        actions.onOpenSettings?()
                    }
                    .buttonStyle(AssistantBetaSecondaryButtonStyle())
                }
            }
        }
        .padding(18)
        .appThemedSurface(cornerRadius: 22, tint: .orange, strokeOpacity: 0.14, tintOpacity: 0.045)
    }

    private var voiceDraftCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconBadge(symbol: "waveform.and.mic", tint: AppVisualTheme.accentTint, size: 32, symbolSize: 13)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice Draft")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text("Simple status area for voice capture. The main app can wire transcription later.")
                        .font(.caption)
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
            }

            AssistantBetaVoiceDraftStatus(state: model.voiceDraftState)
        }
        .padding(18)
        .appThemedSurface(cornerRadius: 22, tint: AppVisualTheme.accentTint, strokeOpacity: 0.15, tintOpacity: 0.03)
    }

    private func handleBannerAction(_ banner: AssistantBetaBanner) {
        switch banner.action {
        case .installHelp:
            actions.onInstallHelp?()
        case .openSettings:
            actions.onOpenSettings?()
        case .none:
            break
        }
    }

    private func color(for status: AssistantBetaSessionState) -> Color {
        switch status {
        case .ready:
            return AppVisualTheme.accentTint
        case .running:
            return .green
        case .waiting:
            return .orange
        case .completed:
            return .mint
        case .failed:
            return .red
        }
    }
}

private struct AssistantBetaSessionRow: View {
    let session: AssistantBetaSessionSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)

                    Text(session.subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                statusDot
            }

            HStack(spacing: 8) {
                AssistantBetaMiniPill(symbol: "desktopcomputer", label: session.sourceLabel, tint: AppVisualTheme.accentTint)

                if let badge = session.badges.first {
                    AssistantBetaMiniPill(symbol: "tag.fill", label: badge, tint: statusColor)
                }
            }

            Text(relativeFormatter.localizedString(for: session.updatedAt, relativeTo: .now))
                .font(.caption2)
                .foregroundStyle(AppVisualTheme.mutedText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            (isSelected ? statusColor.opacity(0.22) : Color.white.opacity(0.06)),
                            Color.black.opacity(isSelected ? 0.18 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.22 : 0.09),
                            Color.black.opacity(0.20)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.18 : 0.10), radius: isSelected ? 8 : 5, x: 0, y: 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .shadow(color: statusColor.opacity(0.65), radius: 4, x: 0, y: 0)
    }

    private var statusColor: Color {
        switch session.status {
        case .ready:
            return AppVisualTheme.accentTint
        case .running:
            return .green
        case .waiting:
            return .orange
        case .completed:
            return .mint
        case .failed:
            return .red
        }
    }

    private var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }
}

private struct AssistantBetaTranscriptRow: View {
    let item: AssistantBetaTranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconBadge(
                symbol: roleSymbol,
                tint: roleTint,
                size: 28,
                symbolSize: 11,
                isEmphasized: item.isStreaming
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Spacer(minLength: 10)

                    Text(timeFormatter.string(from: item.timestamp))
                        .font(.caption2)
                        .foregroundStyle(AppVisualTheme.mutedText)

                    Button {
                        copyAssistantTextToPasteboard(item.body)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help(copyHelpText)
                }

                Text(item.body)
                    .font(.system(size: 14.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let footnote, !footnote.isEmpty {
                    AssistantBetaMiniPill(
                        symbol: item.isStreaming ? "ellipsis.circle.fill" : "info.circle.fill",
                        label: footnote,
                        tint: roleTint
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appThemedSurface(cornerRadius: 18, tint: roleTint, strokeOpacity: 0.12, tintOpacity: 0.03)
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(item.body)
            }
        }
    }

    private var footnote: String? {
        item.footnote
    }

    private var copyHelpText: String {
        switch item.role {
        case .user:
            return "Copy user message"
        case .assistant:
            return "Copy assistant message"
        case .system, .tool:
            return "Copy message"
        }
    }

    private var roleSymbol: String {
        switch item.role {
        case .system:
            return "server.rack"
        case .user:
            return "person.fill"
        case .assistant:
            return "sparkles"
        case .tool:
            return "wrench.adjustable"
        }
    }

    private var roleTint: Color {
        switch item.role {
        case .system:
            return .blue
        case .user:
            return AppVisualTheme.baseTint
        case .assistant:
            return AppVisualTheme.accentTint
        case .tool:
            return .orange
        }
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }
}

private struct AssistantBetaBannerCard: View {
    let banner: AssistantBetaBanner
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconBadge(symbol: banner.symbol, tint: tint, size: 30, symbolSize: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.96))

                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
            }

            Spacer(minLength: 0)

            if let actionTitle = banner.actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(AssistantBetaSecondaryButtonStyle())
            }
        }
        .padding(14)
        .appThemedSurface(cornerRadius: 18, tint: tint, strokeOpacity: 0.14, tintOpacity: 0.04)
    }

    private var tint: Color {
        switch banner.tone {
        case .info:
            return AppVisualTheme.accentTint
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct AssistantBetaVoiceDraftStatus: View {
    let state: AssistantBetaVoiceDraftState

    var body: some View {
        switch state {
        case .idle:
            AssistantBetaEmptyCard(
                symbol: "mic.slash",
                title: "Voice is idle",
                message: "When the user speaks from the top bar, the draft text can appear here."
            )
        case .listening(let message):
            HStack(alignment: .center, spacing: 12) {
                ProgressView()
                    .scaleEffect(0.85)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .appThemedSurface(cornerRadius: 18, tint: .orange, strokeOpacity: 0.12, tintOpacity: 0.03)
        case .captured(let text):
            VStack(alignment: .leading, spacing: 8) {
                AssistantBetaMiniPill(symbol: "checkmark.circle.fill", label: "Draft captured", tint: .green)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .appThemedSurface(cornerRadius: 18, tint: .green, strokeOpacity: 0.12, tintOpacity: 0.03)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                AssistantBetaMiniPill(symbol: "exclamationmark.triangle.fill", label: "Voice draft failed", tint: .red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .appThemedSurface(cornerRadius: 18, tint: .red, strokeOpacity: 0.12, tintOpacity: 0.03)
        }
    }
}

private struct AssistantBetaStatChip: View {
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        AssistantBetaMiniPill(symbol: symbol, label: label, tint: tint)
    }
}

private struct AssistantBetaMiniPill: View {
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.38),
                            tint.opacity(0.20),
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
}

private struct AssistantBetaEmptyCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AppVisualTheme.accentTint.opacity(0.92))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.94))

            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.70))
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .appThemedSurface(cornerRadius: 18, tint: AppVisualTheme.baseTint, strokeOpacity: 0.10, tintOpacity: 0.02)
    }
}

private struct AssistantBetaPrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppVisualTheme.accentTint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.82 : 0.95))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(configuration.isPressed ? 0.82 : 0.96),
                                tint.opacity(configuration.isPressed ? 0.60 : 0.76)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.65)
            )
            .shadow(color: tint.opacity(configuration.isPressed ? 0.18 : 0.32), radius: configuration.isPressed ? 4 : 9, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AssistantBetaSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.76 : 0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(configuration.isPressed ? 0.09 : 0.12),
                                AppVisualTheme.baseTint.opacity(configuration.isPressed ? 0.18 : 0.24),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
            )
            .scaleEffect(configuration.isPressed ? 0.987 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AssistantBetaIconButtonStyle: ButtonStyle {
    let isBusy: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isBusy ? 0.72 : (configuration.isPressed ? 0.78 : 0.94)))
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.09),
                                AppVisualTheme.baseTint.opacity(0.18),
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
            )
            .rotationEffect(.degrees(isBusy ? 360 : 0))
            .animation(isBusy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: isBusy)
    }
}

#if DEBUG
struct AssistantBetaWindowView_Previews: PreviewProvider {
    static var previews: some View {
        AssistantBetaWindowView(model: .preview)
            .frame(width: 1360, height: 860)
    }
}
#endif
