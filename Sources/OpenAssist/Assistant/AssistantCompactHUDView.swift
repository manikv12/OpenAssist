import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func assistantAlwaysAllowOptionID(for request: AssistantPermissionRequest) -> String? {
    request.options.first(where: { $0.id == "acceptForSession" })?.id
        ?? request.options.first(where: { $0.isDefault })?.id
}

// MARK: - HUD View

struct AssistantCompactHUDView: View {
    let style: AssistantCompactPresentationStyle
    @ObservedObject var model: AssistantOrbHUDModel

    var body: some View {
        Group {
            switch style {
            case .orb:
                AssistantOrbHUDView(model: model)
            case .notch:
                AssistantNotchHUDView(model: model)
            case .sidebar:
                EmptyView()
            }
        }
    }
}

struct AssistantOrbHUDView: View {
    @ObservedObject var model: AssistantOrbHUDModel
    @State private var resizeStartSize: NSSize?
    @State private var previewAttachment: AssistantAttachment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum OrbHUDAnimations {
        static let state = Animation.easeInOut(duration: 0.22)
        static let content = Animation.easeOut(duration: 0.18)
    }

    private let overlayBottomDock: CGFloat = 108

    private var showingPopup: Bool {
        (model.showDoneDetail
            || model.showWorkingDetail
            || model.pendingPermissionRequest != nil
            || model.modeSwitchSuggestion != nil) && !model.isExpanded
    }

    /// The popup content area height = total popup height minus the orb section (156pt).
    private var popupContentMaxHeight: CGFloat {
        model.popupSize.height - 156
    }

    private var expandedSessionListMaxHeight: CGFloat {
        216
    }

    private var overlayContentMaxHeight: CGFloat {
        let totalHeight =
            model.isExpanded
            ? AssistantOrbHUDModel.Layout.expandedSize.height
            : model.popupSize.height
        return max(180, totalHeight - overlayBottomDock)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeStartSize == nil { resizeStartSize = model.popupSize }
                        guard let start = resizeStartSize else { return }
                        // Dragging up (negative y in SwiftUI) → increase height
                        let newHeight = start.height - value.translation.height
                        let clamped = min(
                            max(newHeight, AssistantOrbHUDModel.Layout.minPopupSize.height),
                            AssistantOrbHUDModel.Layout.maxPopupSize.height
                        )
                        model.popupSize.height = clamped
                    }
                    .onEnded { _ in
                        resizeStartSize = nil
                        model.persistPopupSize()
                    }
            )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            overlayContent
            orbSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .frame(
            width: model.isExpanded
                ? AssistantOrbHUDModel.Layout.expandedSize.width
                : (showingPopup ? model.popupSize.width : 140),
            height: model.isExpanded
                ? AssistantOrbHUDModel.Layout.expandedSize.height
                : (showingPopup ? model.popupSize.height : 156),
            alignment: .bottom
        )
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center)) { attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(AppVisualTheme.foreground(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 720, maxHeight: 520)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 360, minHeight: 260)
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if model.isExpanded {
            sessionPopoverSection
                .frame(maxHeight: overlayContentMaxHeight)
                .padding(.bottom, overlayBottomDock)
                .transition(.opacity)
        } else if model.showDoneDetail {
            VStack(spacing: 0) {
                resizeHandle
                doneDetailPopup(maxHeight: overlayContentMaxHeight, showsFollowUpComposer: true)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.showWorkingDetail && !model.showDoneDetail
            && model.pendingPermissionRequest == nil
        {
            VStack(spacing: 0) {
                resizeHandle
                workingDetailPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.pendingPermissionRequest != nil && !model.showDoneDetail
            && !model.showWorkingDetail
        {
            VStack(spacing: 0) {
                resizeHandle
                permissionPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.modeSwitchSuggestion != nil
            && !model.showDoneDetail
            && !model.showWorkingDetail
            && model.pendingPermissionRequest == nil
        {
            VStack(spacing: 0) {
                resizeHandle
                modeSwitchPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        }
    }

    // MARK: Orb

    private var orbSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                glowColor.opacity(0.20),
                                glowColor.opacity(0.10),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 42
                        )
                    )
                    .frame(width: 90, height: 90)
                    .blur(radius: 12)
                    .opacity(reduceMotion ? 0.85 : 1.0)

                orbSphereView
            }
            .frame(height: 72)
            .onTapGesture { handleOrbTap() }
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            VStack(spacing: 3.5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(glowColor.opacity(0.92))
                        .frame(width: 5, height: 5)

                    Text(phaseLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .foregroundStyle(AppVisualTheme.foreground(0.94))
                        .contentTransition(.opacity)
                }

                if let detail = model.state.detail, !detail.isEmpty, !model.showDoneDetail,
                    !model.showWorkingDetail
                {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.72))
                        .lineLimit(2)
                        .truncationMode(model.state.phase == .success ? .tail : .middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 136)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(OrbStatusCapsuleBackground(tint: glowColor))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.5)
            )
            .animation(OrbHUDAnimations.content, value: model.state.detail)
            .animation(OrbHUDAnimations.state, value: model.state.phase)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 156, alignment: .top)
    }

    private var orbSphereView: some View {
        let paused = model.state.phase == .idle
        return TimelineView(.animation(minimumInterval: orbRefreshInterval, paused: paused)) {
            context in
            OrbSphere(
                phase: model.state.phase,
                level: CGFloat(model.level),
                time: context.date.timeIntervalSinceReferenceDate
            )
            .frame(width: 64, height: 64)
        }
    }

    private var orbRefreshInterval: Double {
        switch model.state.phase {
        case .listening, .acting, .streaming:
            return 1.0 / 24.0
        case .thinking, .waitingForPermission, .failed:
            return 1.0 / 18.0
        case .idle, .success:
            return 1.0 / 12.0
        }
    }

    // MARK: Done Detail Popup

    private func doneDetailPopup(maxHeight: CGFloat, showsFollowUpComposer: Bool) -> some View {
        let tint = Color(red: 0.20, green: 0.84, blue: 0.46)

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: "Done",
                subtitle: "Latest assistant result",
                symbol: "checkmark.circle.fill",
                tint: tint,
                onOpenMainWindow: { model.openSelectedSessionInMainWindow() }
            ) {
                model.dismissDoneDetail()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = model.doneDetailText, !detail.isEmpty {
                        OrbDoneMarkdownText(text: detail)
                    }

                    orbPreviewImageGallery(
                        model.previewImages,
                        title: "Latest screenshot",
                        maxHeight: 220
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)

            if showsFollowUpComposer {
                OrbPopupDivider(tint: tint)
                    .padding(.horizontal, 2)

                popupFollowUpComposerSection(
                    tint: tint,
                    placeholder: model.isVoiceRecording ? "Listening..." : "Follow up...",
                    enterHint: "Enter sends",
                    submit: sendDoneFollowUp
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                OrbPopupDivider(tint: tint)
                    .padding(.horizontal, 2)

                HStack(spacing: 8) {
                    Text("Close this card to return the orb to its ready state.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.60))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    OrbSecondaryActionButton(
                        title: "Open Main Window",
                        symbol: "arrow.up.right.square",
                        tint: tint
                    ) {
                        model.openSelectedSessionInMainWindow()
                    }

                    OrbSecondaryActionButton(title: "Ready", symbol: "sparkles", tint: tint) {
                        model.dismissDoneDetail()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func modeSwitchPopup(maxHeight: CGFloat) -> some View {
        let tint = AppVisualTheme.accentTint

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: "Mode switch",
                subtitle: "Quick way to continue in the right mode",
                symbol: "arrow.triangle.branch",
                tint: tint
            ) {
                model.onDismissModeSwitchSuggestion?()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: false) {
                if let suggestion = model.modeSwitchSuggestion {
                    modeSwitchInlineCard(suggestion, tint: tint)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func modeSwitchInlineCard(_ suggestion: AssistantModeSwitchSuggestion, tint: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.72))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(suggestion.choices) { choice in
                    OrbSecondaryActionButton(
                        title: choice.title,
                        symbol: choice.mode.icon,
                        tint: tint
                    ) {
                        model.interactionMode = choice.mode
                        model.onApplyModeSwitchSuggestion?(choice)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbInsetSurface(tint: tint, cornerRadius: 16, fillOpacity: 0.10)
    }

    // MARK: Working Detail Popup

    private func workingDetailPopup(maxHeight: CGFloat) -> some View {
        let tint = glowColor

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: model.workingPopupTitle.lowercased().capitalized,
                subtitle: "Live progress and quick steering",
                symbol: "waveform.path.ecg",
                tint: tint,
                onOpenMainWindow: { model.openSelectedSessionInMainWindow() }
            ) {
                model.dismissWorkingDetail()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.state.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.94))

                    if let summary = model.workingSummaryText, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    orbPreviewImageGallery(
                        model.previewImages,
                        title: "Latest screenshot",
                        maxHeight: 220
                    )

                    if let session = model.activeSessionSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active session")
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(0.6)
                                .textCase(.uppercase)
                                .foregroundStyle(tint.opacity(0.92))

                            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.90))
                            if let cwd = session.cwd?.nonEmpty {
                                Text(cwd)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(AppVisualTheme.foreground(0.50))
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .orbInsetSurface(tint: tint, cornerRadius: 16, fillOpacity: 0.10)
                    }

                    if !model.workingToolActivity.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live steps")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.52))

                            ForEach(Array(model.workingToolActivity.prefix(4))) { item in
                                OrbWorkingActivityRow(item: item, tint: tint)
                            }
                        }
                    } else {
                        Text(
                            "Detailed step output has not arrived yet, but the agent is still working."
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.48))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            VStack(spacing: 10) {
                popupFollowUpComposerSection(
                    tint: tint,
                    placeholder: model.isVoiceRecording
                        ? "Listening..."
                        : "Steer it or prepare the next follow-up...",
                    enterHint: "Enter steers now",
                    submit: sendWorkingFollowUp
                )

                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.85))
                    Text(
                        "Typing here queues your next message without stopping the current turn."
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .orbInsetSurface(tint: tint, cornerRadius: 14, fillOpacity: 0.07)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func orbPreviewImageGallery(
        _ images: [Data],
        title: String,
        maxHeight: CGFloat
    ) -> some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(AppVisualTheme.foreground(0.48))

                ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { index, imageData in
                    if let nsImage = NSImage(data: imageData) {
                        Button {
                            previewAttachment = AssistantAttachment(
                                filename: "screenshot-\(index + 1).png",
                                data: imageData,
                                mimeType: "image/png"
                            )
                        } label: {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open screenshot preview")
                    }
                }
            }
        }
    }

    // MARK: Permission Popup

    private func permissionPopup(maxHeight: CGFloat) -> some View {
        let orangeTint = Color(red: 0.95, green: 0.60, blue: 0.10)

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: permissionHeaderTitle.lowercased().capitalized,
                subtitle: "Review before the assistant continues",
                symbol: "hand.raised.fill",
                tint: orangeTint
            ) {
                model.onCancelPermission?()
            }

            OrbPopupDivider(tint: orangeTint)
                .padding(.horizontal, 2)

            if let request = model.pendingPermissionRequest {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(request.toolTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.94))

                        if let rationale = request.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.70))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let summary = request.rawPayloadSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(AppVisualTheme.foreground(0.58))
                                .lineLimit(4)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .orbInsetSurface(
                                    tint: orangeTint, cornerRadius: 14, fillOpacity: 0.08)
                        }

                        if request.hasStructuredUserInput {
                            AssistantStructuredUserInputView(
                                request: request,
                                accent: orangeTint,
                                secondaryText: AppVisualTheme.foreground(0.70),
                                fieldBackground: AppVisualTheme.foreground(0.06),
                                submitTitle: "Submit Answers",
                                cancelTitle: "Cancel Request"
                            ) { answers in
                                model.onSubmitPermissionAnswers?(answers)
                            } onCancel: {
                                model.onCancelPermission?()
                            }
                        } else {
                            VStack(spacing: 8) {
                                ForEach(request.options) { option in
                                    OrbPermissionChoiceButton(
                                        title: option.title,
                                        tint: orangeTint,
                                        isProminent: option.isDefault
                                    ) {
                                        model.onResolvePermission?(option.id)
                                    }
                                }

                                if let toolKind = request.toolKind, !toolKind.isEmpty,
                                    toolKind != "userInput", toolKind != "browserLogin"
                                {
                                    OrbPermissionChoiceButton(
                                        title: "Always Allow",
                                        tint: orangeTint,
                                        isProminent: false,
                                        icon: "checkmark.shield.fill"
                                    ) {
                                        model.onAlwaysAllowPermission?(toolKind)
                                        if let optionID = assistantAlwaysAllowOptionID(for: request)
                                        {
                                            model.onResolvePermission?(optionID)
                                        }
                                    }
                                }
                            }

                            OrbSecondaryActionButton(
                                title: "Cancel Request", symbol: "xmark",
                                tint: AppVisualTheme.foreground(0.55)
                            ) {
                                model.onCancelPermission?()
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: orangeTint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Session Popover

    private var sessionPopoverSection: some View {
        VStack(spacing: 0) {
            sessionListSection
        }
        .orbPopupSurface(tint: AppVisualTheme.baseTint, cornerRadius: 18)
    }

    // MARK: Session List

    private var sessionListSection: some View {
        VStack(spacing: 0) {
            // New session button
            compactNewSessionListButton()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if model.showDoneDetail {
                doneDetailPopup(maxHeight: 180, showsFollowUpComposer: false)
                    .padding(.top, 8)
            } else if model.pendingPermissionRequest != nil {
                permissionPopup(maxHeight: 240)
                    .padding(.top, 8)
            } else if model.showWorkingDetail {
                workingDetailPopup(maxHeight: 200)
                    .padding(.top, 8)
            } else if let suggestion = model.modeSwitchSuggestion {
                modeSwitchInlineCard(suggestion, tint: AppVisualTheme.accentTint)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            // Session list
            if model.isLoadingSessions {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(AppVisualTheme.foreground(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if model.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView(.vertical, showsIndicators: model.sessions.count > 4) {
                    VStack(spacing: 6) {
                        ForEach(model.sessions.prefix(5)) { session in
                            Button {
                                let clickCount = NSApp.currentEvent?.clickCount ?? 1
                                if clickCount >= 2 {
                                    model.showFollowUpPreview(for: session)
                                } else {
                                    model.selectSessionForReply(session)
                                }
                            } label: {
                                OrbSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    isBusy: sessionMatches(session.id, model.busySessionID)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    model.onOpenSession?(session)
                                } label: {
                                    Label("Open Conversation", systemImage: "arrow.up.right.square")
                                }

                                Button {
                                    model.showFollowUpPreview(for: session)
                                } label: {
                                    Label(
                                        "Show Follow-Up",
                                        systemImage: "bubble.left.and.bubble.right.fill")
                                }

                                if session.isTemporary {
                                    Button {
                                        model.onPromoteTemporarySession?(session.id)
                                    } label: {
                                        Label("Keep Chat", systemImage: "pin")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .frame(maxHeight: expandedSessionListMaxHeight)
            }

            // Target indicator
            if let name = model.targetSessionName {
                compactTargetIndicator(name: name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            // Message input with inline mode + model picker
            VStack(spacing: 6) {
                if !model.attachments.isEmpty {
                    orbAttachmentStrip(tint: AppVisualTheme.accentTint)
                }

                HStack(alignment: .center, spacing: 6) {
                    orbAttachmentButton(tint: AppVisualTheme.accentTint, size: 24)

                    AssistantModePicker(selection: model.interactionMode, style: .micro) { mode in
                        model.setInteractionMode(mode)
                    }

                    Spacer(minLength: 0)

                    orbModelPicker()
                }

                HStack(alignment: .center, spacing: 6) {
                    orbComposerField(
                        tint: AppVisualTheme.baseTint,
                        placeholder: model.isVoiceRecording ? "Listening..." : "Send a message...",
                        minHeight: 30,
                        maxHeight: 34,
                        cornerRadius: 13,
                        fillOpacity: 0.055,
                        submit: sendMessage
                    )
                    .layoutPriority(1)

                    HStack(spacing: 5) {
                        orbVoiceToggleButton(size: 20)
                        liveVoiceEndButton(tint: AppVisualTheme.accentTint)

                        OrbFloatingActionButton(
                            symbol: "arrow.up",
                            tint: AppVisualTheme.accentTint,
                            isEnabled: canSend && !model.isVoiceRecording,
                            size: 20
                        ) {
                            sendMessage()
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .orbInsetSurface(tint: AppVisualTheme.baseTint, cornerRadius: 13, fillOpacity: 0.042)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
    }

    // MARK: Helpers

    private func popupFollowUpComposerSection(
        tint: Color,
        placeholder: String,
        enterHint: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            if let suggestion = model.modeSwitchSuggestion {
                modeSwitchInlineCard(suggestion, tint: tint)
            }

            HStack(alignment: .center, spacing: 8) {
                orbAttachmentButton(tint: tint, size: 28)
                AssistantModePicker(selection: model.interactionMode, style: .compact) { mode in
                    model.setInteractionMode(mode)
                }
                orbModelPicker(maxWidth: 138, showsLabel: true, tint: tint)
                Spacer(minLength: 0)
            }

            if !model.attachments.isEmpty {
                orbAttachmentStrip(tint: tint)
            }

            popupComposerCard(
                tint: tint,
                placeholder: placeholder,
                submit: submit
            )
        }
    }

    private func orbModelPicker(
        maxWidth: CGFloat = 74,
        showsLabel: Bool = false,
        tint: Color? = nil
    ) -> some View {
        let effectiveTint = tint ?? AppVisualTheme.accentTint
        return Menu {
            ForEach(model.availableModels) { m in
                Button {
                    model.onChooseModel?(m.id)
                } label: {
                    Text(m.displayName)
                }
            }
        } label: {
            HStack(spacing: 5) {
                AssistantGlyphBadge(
                    symbol: AssistantChromeSymbol.model,
                    tint: effectiveTint,
                    side: showsLabel ? 16 : 14,
                    fillOpacity: 0.12,
                    strokeOpacity: 0.20,
                    symbolScale: 0.48
                )
                if showsLabel {
                    Text("Model")
                        .font(.system(size: 8.8, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.62))
                }
                Text(model.selectedModelSummary)
                    .font(.system(size: showsLabel ? 9.2 : 8.6, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(showsLabel ? 0.68 : 0.50))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.18))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.04))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: maxWidth)
        .disabled(model.availableModels.isEmpty)
    }

    private var canSend: Bool {
        !model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.attachments.isEmpty
    }

    private var orbDropTypes: [UTType] {
        [.fileURL, .image, .png, .jpeg]
    }

    private func compactTargetIndicator(name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.right.down")
                .font(.system(size: 7.5, weight: .bold))
            Text("To: \(name)")
                .lineLimit(1)
        }
        .font(.system(size: 8.8, weight: .medium))
        .foregroundStyle(AppVisualTheme.foreground(0.54))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.accentTint.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.05), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func liveVoiceEndButton(tint: Color) -> some View {
        if model.isLiveVoiceActive {
            OrbIconOnlySecondaryButton(symbol: "phone.down.fill", tint: tint) {
                model.onEndLiveVoiceSession?()
            }
        }
    }

    private var liveVoiceHintText: String {
        switch model.liveVoiceSnapshot.phase {
        case .idle, .ended:
            return "Tap mic to start live voice"
        case .listening:
            return "Auto-stops after silence"
        case .transcribing:
            return "Transcribing your turn"
        case .sending:
            return model.liveVoiceSnapshot.transcriptStatusText ?? "Waiting for the final answer"
        case .waitingForPermission:
            return model.liveVoiceSnapshot.transcriptStatusText
                ?? "Approve to continue the live turn"
        case .speaking:
            return model.liveVoiceSnapshot.transcriptStatusText ?? "Tap speaker to interrupt"
        case .paused:
            return model.liveVoiceSnapshot.transcriptStatusText
                ?? model.liveVoiceSnapshot.displayText
        }
    }

    private func handleLiveVoiceButtonTap() {
        if model.isLiveVoiceSpeaking {
            model.onStopLiveVoiceSpeaking?()
        } else {
            model.onStartLiveVoiceSession?()
        }
    }

    private func orbVoiceToggleButton(size: CGFloat = 24) -> some View {
        AssistantLiveVoiceButton(
            snapshot: model.liveVoiceSnapshot,
            level: CGFloat(model.level),
            size: size,
            onTap: handleLiveVoiceButtonTap
        )
    }

    private func handleOrbTap() {
        model.handleOrbTap()
    }

    private func sendDoneFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        model.dismissDoneDetail()
    }

    private func sendWorkingFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        model.dismissWorkingDetail()
    }

    private func sendMessage() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if model.showDoneDetail {
            model.dismissDoneDetail()
        }
        if model.showWorkingDetail {
            model.dismissWorkingDetail()
        }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.collapse()
    }

    @ViewBuilder
    private func orbComposerField(
        tint: Color,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        cornerRadius: CGFloat = 18,
        fillOpacity: Double = 0.11,
        showsSurface: Bool = true,
        submit: @escaping () -> Void
    ) -> some View {
        let textView = OrbComposerTextView(
            text: $model.messageText,
            placeholder: placeholder,
            isEnabled: !model.isVoiceRecording,
            shouldFocus: model.shouldFocusTextField,
            onSubmit: submit,
            onToggleMode: { model.cycleInteractionMode() },
            onPasteAttachment: { attachment in
                addAttachment(attachment)
            }
        )
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .onDrop(of: orbDropTypes, isTargeted: nil) { providers in
            handleAttachmentDrop(providers)
            return true
        }

        if showsSurface {
            textView
                .orbInsetSurface(tint: tint, cornerRadius: cornerRadius, fillOpacity: fillOpacity)
        } else {
            textView
        }
    }

    private func popupComposerCard(
        tint: Color,
        placeholder: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            orbComposerField(
                tint: tint,
                placeholder: placeholder,
                minHeight: 36,
                maxHeight: 72,
                cornerRadius: 18,
                fillOpacity: 0.0,
                showsSurface: false,
                submit: submit
            )
            .padding(.horizontal, 2)
            .padding(.top, 2)

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 10)

            HStack(spacing: 8) {
                Text(liveVoiceHintText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.52))
                Spacer(minLength: 0)
                orbVoiceToggleButton(size: 22)
                liveVoiceEndButton(tint: tint)
                OrbFloatingActionButton(
                    symbol: "arrow.up",
                    tint: tint,
                    isEnabled: canSend && !model.isVoiceRecording,
                    size: 26
                ) {
                    submit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .orbInsetSurface(tint: tint, cornerRadius: 20, fillOpacity: 0.08)
    }

    private func orbAttachmentStrip(tint: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    orbAttachmentChip(attachment, tint: tint)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
    }

    private func orbAttachmentChip(_ attachment: AssistantAttachment, tint: Color) -> some View {
        HStack(spacing: 6) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Button {
                    previewAttachment = attachment
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.92))
            }

            Text(attachment.filename)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.70))
                .lineLimit(1)

            Button {
                removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 0.6)
                )
        )
    }

    private func orbAttachmentButton(tint: Color, size: CGFloat = 34) -> some View {
        OrbIconControlButton(symbol: AssistantChromeSymbol.attachment, tint: tint, size: size) {
            model.onOpenAttachmentPicker?()
        }
    }

    private func addAttachment(_ attachment: AssistantAttachment) {
        model.onAddAttachment?(attachment)
    }

    private func removeAttachment(_ attachment: AssistantAttachment) {
        model.onRemoveAttachment?(attachment.id)
    }

    private func handleAttachmentDrop(_ providers: [NSItemProvider]) {
        AssistantAttachmentSupport.handleDrop(providers) { attachment in
            addAttachment(attachment)
        }
    }

    private var permissionHeaderTitle: String {
        guard let request = model.pendingPermissionRequest else { return "ACTION NEEDED" }
        if request.toolKind == "browserLogin" {
            return "LOGIN NEEDED"
        }
        let normalizedTitle = request.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTitle.contains("information") || normalizedTitle.contains("input")
            || normalizedTitle.contains("question")
        {
            return "INPUT NEEDED"
        }
        if normalizedTitle.contains("login") || normalizedTitle.contains("sign in") {
            return "LOGIN NEEDED"
        }
        return "APPROVAL NEEDED"
    }

    private var phaseLabel: String {
        switch model.state.phase {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .success: return "Done"
        case .failed: return "Error"
        case .thinking, .acting, .waitingForPermission, .streaming:
            let title = model.state.title
            if !title.isEmpty { return title }
            switch model.state.phase {
            case .thinking: return "Thinking"
            case .acting: return "Working"
            case .waitingForPermission: return "Needs Approval"
            case .streaming: return "Responding"
            default: return "Working"
            }
        }
    }

    private var glowColor: Color {
        OrbSphere.phaseColor(for: model.state.phase)
    }

    private func compactNewSessionListButton() -> some View {
        Button(action: {
            Task { await model.onNewSession?() }
        }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppVisualTheme.accentTint.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                }
                Text("New Session")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.35))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .orbInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 14, fillOpacity: 0.10)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await model.onNewTemporarySession?() }
            } label: {
                Label("New Temporary Chat", systemImage: "clock.badge.plus")
            }
        }
        .help("Click for a regular chat. Right-click for a temporary chat.")
    }

    private func sessionMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

struct AssistantNotchHUDView: View {
    @ObservedObject var model: AssistantOrbHUDModel
    @State private var previewAttachment: AssistantAttachment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let collapsedSize = NSSize(width: 320, height: 50)
        static let compactCardSize = NSSize(width: 520, height: 480)
        static let expandedTraySize = NSSize(width: 1100, height: 404)
        static let traySpacing: CGFloat = 4
        static let expandedSize = NSSize(
            width: expandedTraySize.width,
            height: collapsedSize.height + traySpacing + expandedTraySize.height
        )
    }

    private var isTrayExpanded: Bool {
        model.isExpanded
    }

    private var showingPermissionPeek: Bool {
        model.pendingPermissionRequest != nil && !isTrayExpanded
    }

    private var showingCompletionPeek: Bool {
        model.showDoneDetail && !isTrayExpanded && !showingPermissionPeek
    }

    private var showingWorkingPeek: Bool {
        model.showWorkingDetail && !isTrayExpanded && !showingPermissionPeek
            && !showingCompletionPeek
    }

    private var showingComposerPeek: Bool {
        model.showCompactComposer
            && !isTrayExpanded
            && !showingPermissionPeek
            && !showingCompletionPeek
            && !showingWorkingPeek
    }

    private var showingModeSwitchPeek: Bool {
        model.modeSwitchSuggestion != nil
            && !isTrayExpanded
            && !showingPermissionPeek
            && !showingCompletionPeek
            && !showingWorkingPeek
            && !showingComposerPeek
    }

    private var showingCompactCard: Bool {
        showingPermissionPeek || showingCompletionPeek || showingWorkingPeek || showingComposerPeek
            || showingModeSwitchPeek
    }

    private var glowColor: Color {
        OrbSphere.phaseColor(for: model.state.phase)
    }

    private var expandedTrayHeight: CGFloat {
        Layout.expandedTraySize.height
    }

    private var compactCardHeight: CGFloat {
        max(188, Layout.compactCardSize.height - Layout.collapsedSize.height - Layout.traySpacing)
    }

    private var collapsedPillWidth: CGFloat {
        Layout.collapsedSize.width
    }

    private var canHideCollapsedDock: Bool {
        model.notchDockRevealed && !isTrayExpanded && !showingCompactCard
    }

    private var canSend: Bool {
        !model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.attachments.isEmpty
    }

    @ViewBuilder
    private func liveVoiceEndButton(tint: Color) -> some View {
        if model.isLiveVoiceActive {
            OrbIconOnlySecondaryButton(symbol: "phone.down.fill", tint: tint) {
                model.onEndLiveVoiceSession?()
            }
        }
    }

    private var liveVoiceHintText: String {
        switch model.liveVoiceSnapshot.phase {
        case .idle, .ended:
            return "Tap mic to start live voice"
        case .listening:
            return "Auto-stops after silence"
        case .transcribing:
            return "Transcribing your turn"
        case .sending:
            return "Waiting for the final answer"
        case .waitingForPermission:
            return "Approve to continue the live turn"
        case .speaking:
            return "Tap speaker to interrupt"
        case .paused:
            return model.liveVoiceSnapshot.displayText
        }
    }

    private func handleLiveVoiceButtonTap() {
        if model.isLiveVoiceSpeaking {
            model.onStopLiveVoiceSpeaking?()
        } else {
            model.onStartLiveVoiceSession?()
        }
    }

    private var collapsedTitle: String {
        switch model.state.phase {
        case .idle:
            return "Assistant is ready"
        case .listening:
            return "Assistant is listening"
        case .thinking:
            return "Assistant is thinking"
        case .acting:
            return "Assistant is working"
        case .waitingForPermission:
            return "Assistant needs approval"
        case .streaming:
            return "Assistant is replying"
        case .success:
            return "Reply is ready"
        case .failed:
            return "Assistant needs attention"
        }
    }

    private var collapsedStatusSymbol: String {
        switch model.state.phase {
        case .idle:
            return "sparkles"
        case .listening:
            return "waveform"
        case .thinking:
            return "ellipsis.circle.fill"
        case .acting:
            return "bolt.fill"
        case .waitingForPermission:
            return "hand.raised.fill"
        case .streaming:
            return "text.cursor"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var collapsedBadgeTint: Color {
        model.pendingPermissionRequest != nil ? .orange : glowColor
    }

    private var bodyWidth: CGFloat {
        if isTrayExpanded {
            return Layout.expandedSize.width
        }
        if showingCompactCard {
            return Layout.compactCardSize.width
        }
        if model.notchDockRevealed {
            return Layout.collapsedSize.width
        }
        if model.notchUsesHardwareOutline {
            return max(1, model.notchDockVisibleWidth)
        }
        return max(120, model.notchDockVisibleWidth)
    }

    private var notchActiveGlowExtension: CGFloat {
        guard !model.notchDockRevealed else { return 0 }
        switch model.state.phase {
        case .idle, .success, .failed: return 0
        default: return 10
        }
    }

    private var collapsedContainerHeight: CGFloat {
        model.notchDockRevealed
            ? Layout.collapsedSize.height
            : max(2, model.notchDockVisibleHeight) + notchActiveGlowExtension
    }

    private var bodyHeight: CGFloat {
        if isTrayExpanded {
            return Layout.expandedSize.height
        }
        if showingCompactCard {
            return Layout.compactCardSize.height
        }
        return collapsedContainerHeight
    }

    private var liveSummary: String {
        if let detail = model.state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        {
            return detail
        }
        // Only show tool activity details while the assistant is actively working
        if model.state.phase.isActive {
            if let hudDetail = model.workingToolActivity.first?.hudDetail?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty {
                return hudDetail
            }
            if let activityDetail = model.workingToolActivity.first?.detail?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty {
                return activityDetail
            }
        }
        if let sessionTitle = model.activeSessionSummary?.title.nonEmpty {
            return sessionTitle
        }
        switch model.state.phase {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .acting:
            return "Working"
        case .waitingForPermission:
            return "Needs approval"
        case .streaming:
            return "Responding"
        case .success:
            return "Reply ready"
        case .failed:
            return "Needs attention"
        }
    }

    var body: some View {
        VStack(spacing: Layout.traySpacing) {
            ZStack(alignment: .top) {
                if !isTrayExpanded && !showingCompactCard {
                    hiddenDockHandle
                        .opacity(model.notchDockRevealed ? 0 : 1)
                }

                collapsedPill
                    .frame(
                        width: Layout.collapsedSize.width, height: Layout.collapsedSize.height,
                        alignment: .top
                    )
                    .opacity(
                        (!isTrayExpanded && !showingCompactCard)
                            ? (model.notchDockRevealed ? 1 : 0) : 1)
            }
            .frame(height: collapsedContainerHeight)
            .clipped()

            if isTrayExpanded {
                expandedTray
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
            } else if showingCompactCard {
                compactPeekCard
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: model.notchDockRevealed)
        .animation(.easeInOut(duration: 0.35), value: model.state.phase)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isTrayExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: showingCompactCard)
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center), arrowEdge: .top) {
            attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(AppVisualTheme.foreground(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 720, maxHeight: 520)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 360, minHeight: 260)
            }
        }
    }

    @ViewBuilder
    private var hiddenDockHandle: some View {
        let handleHeight = max(2, model.notchDockVisibleHeight)
        VStack(spacing: 0) {
            if model.notchUsesHardwareOutline, model.notchHardwareOutlineSize.width > 0,
                model.notchHardwareOutlineSize.height > 0
            {
                HardwareNotchDockHandle(
                    width: bodyWidth,
                    height: handleHeight,
                    tint: glowColor
                )
            } else {
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.88))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(glowColor.opacity(0.16), lineWidth: 0.7)
                    )
                    .overlay(alignment: .center) {
                        Capsule(style: .continuous)
                            .fill(glowColor.opacity(0.22))
                            .frame(width: bodyWidth * 0.42, height: 1.6)
                    }
                    .frame(width: bodyWidth, height: handleHeight)
            }
            if notchActiveGlowExtension > 0 {
                NotchAmbientActivityGlow(width: bodyWidth, tint: glowColor)
                    .frame(height: notchActiveGlowExtension)
                    .transition(.opacity)
            }
        }
    }

    private func handleCollapsedPillTap() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
            if isTrayExpanded {
                model.collapseExpandedTray()
                return
            }

            // If a compact notch card is already open, tapping the pill dismisses it
            if showingCompactCard {
                if model.showDoneDetail { model.hideDoneDetail() }
                if model.showWorkingDetail { model.dismissWorkingDetail() }
                if model.showCompactComposer { model.dismissCompactComposer() }
                if model.modeSwitchSuggestion != nil { model.onDismissModeSwitchSuggestion?() }
                return
            }

            if model.presentDoneDetailIfAvailable() {
                return
            }

            if model.presentWorkingDetailIfAvailable() {
                return
            }

            if model.presentCompactComposerIfAvailable() {
                return
            }

            model.expand()
        }
    }

    private var collapsedPill: some View {
        Button {
            handleCollapsedPillTap()
        } label: {
            HStack(spacing: 10) {
                notchStatusBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(collapsedTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                        .lineLimit(1)

                    Text(liveSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.56))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if model.pendingPermissionRequest != nil {
                    OrbInlinePill(text: "Needs approval", symbol: "hand.raised.fill", tint: .orange)
                } else {
                    HStack(spacing: 8) {
                        Text(livePhaseLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(collapsedBadgeTint.opacity(0.90))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(collapsedBadgeTint.opacity(0.10))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(
                                                collapsedBadgeTint.opacity(0.14), lineWidth: 0.5)
                                    )
                            )

                        if canHideCollapsedDock {
                            Button {
                                model.onHideDock?()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.62))
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(AppVisualTheme.surfaceFill(0.05))
                                            .overlay(
                                                Circle()
                                                    .stroke(
                                                        AppVisualTheme.surfaceStroke(0.08),
                                                        lineWidth: 0.5)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Hide into the notch")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(width: collapsedPillWidth, height: Layout.collapsedSize.height)
            .background {
                let isDark = AppVisualTheme.isDarkAppearance
                Capsule(style: .continuous)
                    .fill(
                        isDark
                            ? Color(red: 0.045, green: 0.048, blue: 0.062).opacity(0.98)
                            : AppVisualTheme.windowBackground.opacity(0.99)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                AppVisualTheme.surfaceStroke(isDark ? 0.08 : 0.10), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .help(isTrayExpanded ? "Collapse assistant tray" : "Show compact assistant details")
    }

    private var expandedTray: some View {
        HStack(alignment: .top, spacing: 12) {
            sessionsColumn
            liveActivityColumn
            composerColumn
        }
        .padding(14)
        .frame(width: Layout.expandedTraySize.width, height: expandedTrayHeight, alignment: .top)
        .notchPopupSurface(tint: AppVisualTheme.baseTint, cornerRadius: 28)
    }

    @ViewBuilder
    private var compactPeekCard: some View {
        if let request = model.pendingPermissionRequest {
            permissionPeekCard(request)
        } else if showingCompletionPeek, let detail = model.doneDetailText?.nonEmpty {
            completionPeekCard(detail)
        } else if showingComposerPeek {
            composerPeekCard
        } else if showingModeSwitchPeek, let suggestion = model.modeSwitchSuggestion {
            modeSwitchPeekCard(suggestion)
        } else {
            workingPeekCard
        }
    }

    private func completionPeekCard(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(
                    systemName: model.state.phase == .failed
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(model.state.phase == .failed ? Color.orange : glowColor)

                Text(model.state.phase == .failed ? "Needs attention" : "Response ready")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .fixedSize(horizontal: true, vertical: false)

                if model.selectedSessionIsTemporary {
                    CompactTemporaryBadge(compact: true)
                }

                Spacer(minLength: 0)

                OrbIconOnlySecondaryButton(
                    symbol: "rectangle.split.3x1.fill", tint: AppVisualTheme.accentTint
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                        model.expand()
                    }
                }

                OrbIconOnlySecondaryButton(
                    symbol: "arrow.up.right.square", tint: AppVisualTheme.accentTint
                ) {
                    model.openSelectedSessionInMainWindow()
                }

                compactNewSessionIconButton()

                compactKeepChatTopBarButton()

                Button {
                    model.hideDoneDetail()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.surfaceFill(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    OrbDoneMarkdownText(text: detail)

                    orbPreviewImageGallery(
                        model.previewImages,
                        title: "Latest screenshot",
                        maxHeight: 180
                    )
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            compactFollowUpComposer(
                tint: AppVisualTheme.accentTint,
                placeholder: model.isVoiceRecording ? "Listening..." : "Follow up...",
                helperText: "Send the next step from here."
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: compactCardHeight)
        .notchInsetSurface(
            tint: model.state.phase == .failed ? .orange : glowColor, cornerRadius: 22,
            fillOpacity: 0.10)
    }

    private var workingPeekCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(glowColor)

                Text("Live work")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))

                if model.selectedSessionIsTemporary {
                    CompactTemporaryBadge(compact: true)
                }

                Spacer(minLength: 0)

                if model.canStopActiveTurn {
                    OrbSecondaryActionButton(title: "Stop", symbol: "stop.fill", tint: .orange) {
                        model.onStopActiveTurn?()
                    }
                }

                OrbIconOnlySecondaryButton(
                    symbol: "rectangle.split.3x1.fill", tint: AppVisualTheme.accentTint
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                        model.expand()
                    }
                }

                OrbIconOnlySecondaryButton(
                    symbol: "arrow.up.right.square", tint: AppVisualTheme.accentTint
                ) {
                    model.openSelectedSessionInMainWindow()
                }

                compactNewSessionIconButton()

                compactKeepChatTopBarButton()

                Button {
                    model.dismissWorkingDetail()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.surfaceFill(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.state.title.isEmpty ? "Assistant" : model.state.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.94))

                        if let summary = model.workingSummaryText?.nonEmpty {
                            Text(summary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.70))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    orbPreviewImageGallery(
                        model.previewImages,
                        title: "Latest screenshot",
                        maxHeight: 180
                    )

                    if let session = model.activeSessionSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active session")
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(0.5)
                                .textCase(.uppercase)
                                .foregroundStyle(glowColor.opacity(0.92))

                            HStack(spacing: 6) {
                                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(AppVisualTheme.foreground(0.90))

                                if session.isTemporary {
                                    CompactTemporaryBadge(compact: true)
                                }
                            }

                            if let cwd = session.cwd?.nonEmpty {
                                Text(cwd)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(AppVisualTheme.foreground(0.50))
                                    .lineLimit(3)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .notchInsetSurface(tint: glowColor, cornerRadius: 18, fillOpacity: 0.08)
                    }

                    if !model.workingToolActivity.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(model.workingToolActivity.prefix(4)) { item in
                                OrbWorkingActivityRow(item: item, tint: glowColor)
                            }
                        }
                    } else {
                        Text(
                            "Detailed step output has not arrived yet, but the assistant is still working."
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.52))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            compactFollowUpComposer(
                tint: AppVisualTheme.accentTint,
                placeholder: model.isVoiceRecording
                    ? "Listening..." : "Steer it or add the next step...",
                helperText: "Sending here updates the current work."
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: compactCardHeight)
        .notchInsetSurface(tint: glowColor, cornerRadius: 22, fillOpacity: 0.10)
    }

    private var composerPeekCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint)

                Text("Follow up")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .fixedSize(horizontal: true, vertical: false)

                if model.selectedSessionIsTemporary {
                    CompactTemporaryBadge(compact: true)
                }

                Spacer(minLength: 0)

                OrbIconOnlySecondaryButton(
                    symbol: "rectangle.split.3x1.fill", tint: AppVisualTheme.accentTint
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                        model.expand()
                    }
                }

                OrbIconOnlySecondaryButton(
                    symbol: "arrow.up.right.square", tint: AppVisualTheme.accentTint
                ) {
                    model.openSelectedSessionInMainWindow()
                }

                compactNewSessionIconButton()

                compactKeepChatTopBarButton()

                Button {
                    model.dismissCompactComposer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.surfaceFill(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            compactFollowUpComposer(
                tint: AppVisualTheme.baseTint,
                placeholder: model.isVoiceRecording ? "Listening..." : "Message assistant...",
                helperText: "You can continue from the notch without opening chat."
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: compactCardHeight)
        .notchInsetSurface(tint: AppVisualTheme.baseTint, cornerRadius: 22, fillOpacity: 0.10)
    }

    private func modeSwitchPeekCard(_ suggestion: AssistantModeSwitchSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint)

                Text("Mode switch")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .fixedSize(horizontal: true, vertical: false)

                if model.selectedSessionIsTemporary {
                    CompactTemporaryBadge(compact: true)
                }

                Spacer(minLength: 0)

                OrbIconOnlySecondaryButton(
                    symbol: "rectangle.split.3x1.fill", tint: AppVisualTheme.accentTint
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                        model.expand()
                    }
                }

                compactNewSessionIconButton()

                compactKeepChatTopBarButton()

                Button {
                    model.onDismissModeSwitchSuggestion?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.surfaceFill(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            compactModeSwitchInlineCard(suggestion)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: compactCardHeight)
        .notchInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 22, fillOpacity: 0.11)
    }

    private func permissionPeekCard(_ request: AssistantPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)

                Text("Approval needed")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.92))
                    .fixedSize(horizontal: true, vertical: false)

                if model.selectedSessionIsTemporary {
                    CompactTemporaryBadge(compact: true)
                }

                Spacer(minLength: 0)

                OrbIconOnlySecondaryButton(
                    symbol: "rectangle.split.3x1.fill", tint: AppVisualTheme.accentTint
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                        model.expand()
                    }
                }

                compactNewSessionIconButton()

                compactKeepChatTopBarButton()

                Button {
                    model.onCancelPermission?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppVisualTheme.foreground(0.40))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(AppVisualTheme.surfaceFill(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.toolTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.94))

                    if let rationale = request.rationale?.nonEmpty {
                        Text(rationale)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let summary = request.rawPayloadSummary?.nonEmpty {
                        Text(summary)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(AppVisualTheme.foreground(0.58))
                            .lineLimit(nil)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .notchInsetSurface(tint: .orange, cornerRadius: 18, fillOpacity: 0.08)
                    }

                    if request.hasStructuredUserInput {
                        AssistantStructuredUserInputView(
                            request: request,
                            accent: .orange,
                            secondaryText: AppVisualTheme.foreground(0.70),
                            fieldBackground: AppVisualTheme.foreground(0.06),
                            submitTitle: "Submit Answers",
                            cancelTitle: "Cancel Request"
                        ) { answers in
                            model.onSubmitPermissionAnswers?(answers)
                        } onCancel: {
                            model.onCancelPermission?()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(request.options) { option in
                                OrbPermissionChoiceButton(
                                    title: option.title,
                                    tint: .orange,
                                    isProminent: option.isDefault
                                ) {
                                    model.onResolvePermission?(option.id)
                                }
                            }

                            if let toolKind = request.toolKind?.nonEmpty, toolKind != "userInput" {
                                OrbPermissionChoiceButton(
                                    title: "Always Allow",
                                    tint: .orange,
                                    isProminent: false,
                                    icon: "checkmark.shield.fill"
                                ) {
                                    model.onAlwaysAllowPermission?(toolKind)
                                    if let optionID = assistantAlwaysAllowOptionID(for: request) {
                                        model.onResolvePermission?(optionID)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(
            maxWidth: Layout.compactCardSize.width, maxHeight: compactCardHeight,
            alignment: .topLeading
        )
        .notchInsetSurface(tint: .orange, cornerRadius: 22, fillOpacity: 0.12)
    }

    private func compactFollowUpComposer(
        tint: Color,
        placeholder: String,
        helperText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let suggestion = model.modeSwitchSuggestion {
                compactModeSwitchInlineCard(suggestion)
            }

            if let name = model.targetSessionName {
                notchTargetIndicator(name: name)
            }

            if !model.attachments.isEmpty {
                notchAttachmentStrip(tint: tint)
            }

            HStack(alignment: .center, spacing: 8) {
                notchAttachmentButton(tint: tint)
                AssistantModePicker(selection: model.interactionMode, style: .compact) { mode in
                    model.setInteractionMode(mode)
                }
                notchModelPicker(tint: tint)
                Spacer(minLength: 0)
            }

            notchComposerField(
                tint: tint,
                placeholder: placeholder,
                minHeight: 42,
                maxHeight: 78,
                submit: sendMessage
            )

            HStack(spacing: 8) {
                Text(model.isLiveVoiceActive ? liveVoiceHintText : helperText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.54))

                Spacer(minLength: 0)

                notchVoiceToggleButton(size: 24)
                liveVoiceEndButton(tint: tint)
                OrbFloatingActionButton(
                    symbol: "arrow.up",
                    tint: tint,
                    isEnabled: canSend && !model.isVoiceRecording,
                    size: 26
                ) {
                    sendMessage()
                }
            }
        }
    }

    private func compactModeSwitchInlineCard(_ suggestion: AssistantModeSwitchSuggestion)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.70))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(suggestion.choices) { choice in
                    OrbSecondaryActionButton(
                        title: choice.title,
                        symbol: choice.mode.icon,
                        tint: AppVisualTheme.accentTint
                    ) {
                        model.interactionMode = choice.mode
                        model.onApplyModeSwitchSuggestion?(choice)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 18, fillOpacity: 0.09)
    }

    private var notchStatusBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(collapsedBadgeTint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(collapsedBadgeTint.opacity(0.16), lineWidth: 0.5)
                )

            if model.state.phase == .listening && !reduceMotion {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(collapsedBadgeTint.opacity(0.82))
                            .frame(
                                width: 2.5,
                                height: 8 + (CGFloat(index) * 3) + CGFloat(model.level * 8))
                    }
                }
            } else {
                Image(systemName: collapsedStatusSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(collapsedBadgeTint.opacity(0.90))
            }
        }
        .frame(width: 30, height: 30)
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Sessions",
                subtitle: "\(min(model.sessions.count, 5)) recent",
                symbol: "rectangle.stack.fill"
            ) {
                HStack(spacing: 8) {
                    compactNewSessionTextButton(title: "New")

                    if model.selectedSessionIsTemporary {
                        OrbSecondaryActionButton(
                            title: "Keep", symbol: "pin", tint: AppVisualTheme.accentTint
                        ) {
                            model.promoteSelectedTemporarySession()
                        }
                    }
                }
            }

            if model.isLoadingSessions {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppVisualTheme.foreground(0.52))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if model.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.42))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: model.sessions.count > 4) {
                    VStack(spacing: 8) {
                        ForEach(model.sessions.prefix(5)) { session in
                            Button {
                                model.selectSessionForReply(session)
                            } label: {
                                OrbSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    isBusy: sessionMatches(session.id, model.busySessionID)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    model.showFollowUpPreview(for: session)
                                } label: {
                                    Label(
                                        "Show Follow-Up",
                                        systemImage: "bubble.left.and.bubble.right.fill")
                                }

                                Button {
                                    model.onOpenSession?(session)
                                } label: {
                                    Label("Open Chat", systemImage: "arrow.up.right.square")
                                }

                                if session.isTemporary {
                                    Button {
                                        model.onPromoteTemporarySession?(session.id)
                                    } label: {
                                        Label("Keep Chat", systemImage: "pin")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let session = model.sessions.first(where: { $0.id == model.selectedSessionID }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                    Text(session.title.isEmpty ? "Untitled Session" : session.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.62))
                        .lineLimit(1)

                    if session.isTemporary {
                        CompactTemporaryBadge(compact: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 22, fillOpacity: 0.07)
    }

    private var liveActivityColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Agent",
                subtitle: model.state.phase == .idle ? "Ready" : "Live status",
                symbol: "waveform.path.ecg"
            ) {
                if model.canStopActiveTurn {
                    OrbSecondaryActionButton(title: "Stop", symbol: "stop.fill", tint: .orange) {
                        model.onStopActiveTurn?()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(glowColor.opacity(0.95))
                        .frame(width: 8, height: 8)
                    Text(model.state.title.isEmpty ? "Assistant" : model.state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.92))
                    Spacer(minLength: 0)
                    Text(livePhaseLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.54))
                }

                Text(liveSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .notchInsetSurface(tint: glowColor, cornerRadius: 18, fillOpacity: 0.10)

            if let request = model.pendingPermissionRequest {
                permissionCard(request)
            } else if model.showDoneDetail, let detail = model.doneDetailText?.nonEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        OrbDoneMarkdownText(text: detail)
                            .padding(12)

                        orbPreviewImageGallery(
                            model.previewImages,
                            title: "Latest screenshot",
                            maxHeight: 180
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .notchInsetSurface(tint: glowColor, cornerRadius: 18, fillOpacity: 0.09)
            } else if !model.workingToolActivity.isEmpty {
                ScrollView(.vertical, showsIndicators: model.workingToolActivity.count > 2) {
                    VStack(spacing: 8) {
                        ForEach(model.workingToolActivity.prefix(4)) { item in
                            OrbWorkingActivityRow(item: item, tint: glowColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text(idleActivityMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.46))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchInsetSurface(tint: glowColor, cornerRadius: 22, fillOpacity: 0.07)
    }

    private var composerColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Quick Reply",
                subtitle: "Stay in compact view",
                symbol: "paperplane.fill"
            ) {
                OrbSecondaryActionButton(
                    title: "Open Chat", symbol: "arrow.up.right.square",
                    tint: AppVisualTheme.accentTint
                ) {
                    model.openSelectedSessionInMainWindow()
                }
            }

            if let suggestion = model.modeSwitchSuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestion.message)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.66))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        ForEach(suggestion.choices) { choice in
                            OrbSecondaryActionButton(
                                title: choice.title,
                                symbol: choice.mode.icon,
                                tint: AppVisualTheme.accentTint
                            ) {
                                model.interactionMode = choice.mode
                                model.onApplyModeSwitchSuggestion?(choice)
                            }
                        }
                    }
                }
                .padding(12)
                .notchInsetSurface(
                    tint: AppVisualTheme.accentTint, cornerRadius: 18, fillOpacity: 0.09)
            }

            if let name = model.targetSessionName {
                notchTargetIndicator(name: name)
            }

            if !model.attachments.isEmpty {
                notchAttachmentStrip(tint: AppVisualTheme.accentTint)
            }

            HStack(alignment: .center, spacing: 8) {
                notchAttachmentButton(tint: AppVisualTheme.accentTint)
                if shouldShowNotchRuntimeMenus {
                    notchProviderPicker(tint: AppVisualTheme.accentTint)
                } else {
                    notchRuntimeStatusChip(tint: AppVisualTheme.accentTint)
                }
                AssistantModePicker(selection: model.interactionMode, style: .compact) { mode in
                    model.setInteractionMode(mode)
                }
                if shouldShowNotchRuntimeMenus {
                    notchModelPicker(tint: AppVisualTheme.accentTint)
                }
                Spacer(minLength: 0)
            }

            notchComposerCard(tint: AppVisualTheme.baseTint)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchInsetSurface(tint: AppVisualTheme.baseTint, cornerRadius: 22, fillOpacity: 0.07)
    }

    private var livePhaseLabel: String {
        switch model.state.phase {
        case .idle: return "READY"
        case .listening: return "LISTENING"
        case .thinking: return "THINKING"
        case .acting: return "WORKING"
        case .waitingForPermission: return "APPROVAL"
        case .streaming: return "WRITING"
        case .success: return "DONE"
        case .failed: return "ERROR"
        }
    }

    private var idleActivityMessage: String {
        if model.sessions.isEmpty {
            return "Start a session or send a follow-up from here."
        }
        return "Select a session or type the next instruction."
    }

    private func compactNewSessionContextMenu(startInComposer: Bool) -> some View {
        Group {
            Button {
                if startInComposer {
                    Task { await model.startNewTemporarySessionFromCompactView() }
                } else {
                    Task { await model.onNewTemporarySession?() }
                }
            } label: {
                Label("New Temporary Chat", systemImage: "clock.badge.plus")
            }
        }
    }

    private func compactNewSessionIconButton() -> some View {
        OrbIconOnlySecondaryButton(symbol: "plus", tint: AppVisualTheme.accentTint) {
            Task { await model.startNewSessionFromCompactView() }
        }
        .contextMenu { compactNewSessionContextMenu(startInComposer: true) }
        .help("Click for a regular chat. Right-click for a temporary chat.")
    }

    private func compactNewSessionTextButton(title: String) -> some View {
        OrbSecondaryActionButton(title: title, symbol: "plus", tint: AppVisualTheme.accentTint) {
            Task { await model.onNewSession?() }
        }
        .contextMenu { compactNewSessionContextMenu(startInComposer: false) }
        .help("Click for a regular chat. Right-click for a temporary chat.")
    }

    private func compactNewSessionListButton() -> some View {
        Button(action: {
            Task { await model.onNewSession?() }
        }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppVisualTheme.accentTint.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                }
                Text("New Session")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.35))
            }
            .foregroundStyle(AppVisualTheme.foreground(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .orbInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 14, fillOpacity: 0.10)
        }
        .buttonStyle(.plain)
        .contextMenu { compactNewSessionContextMenu(startInComposer: false) }
        .help("Click for a regular chat. Right-click for a temporary chat.")
    }

    @ViewBuilder
    private func compactKeepChatTopBarButton() -> some View {
        if model.selectedSessionIsTemporary {
            OrbSecondaryActionButton(title: "Keep", symbol: "pin", tint: AppVisualTheme.accentTint)
            {
                model.promoteSelectedTemporarySession()
            }
            .help("Keep this temporary chat as a regular thread.")
        }
    }

    private func sectionHeader<Trailing: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(glowColor.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.76))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.90))
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.46))
            }

            Spacer(minLength: 0)

            trailing()
        }
    }

    private func permissionCard(_ request: AssistantPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.toolTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.92))

            if let rationale = request.rationale?.nonEmpty {
                Text(rationale)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(request.options) { option in
                    OrbPermissionChoiceButton(
                        title: option.title,
                        tint: .orange,
                        isProminent: option.isDefault
                    ) {
                        model.onResolvePermission?(option.id)
                    }
                }
            }
        }
        .padding(12)
        .notchInsetSurface(tint: .orange, cornerRadius: 18, fillOpacity: 0.11)
    }

    private func notchTargetIndicator(name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.right.down")
                .font(.system(size: 8, weight: .bold))
            Text("To: \(name)")
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(AppVisualTheme.foreground(0.58))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.accentTint.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.6)
                )
        )
    }

    private var shouldShowNotchRuntimeMenus: Bool {
        !model.state.phase.isActive && model.runtimeControlsAvailability.isReady
    }

    private func notchRuntimeStatusChip(tint: Color) -> some View {
        let statusText =
            model.runtimeControlsStatusText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? model.runtimeControlsAvailability.fallbackStatusText

        return HStack(spacing: 6) {
            AssistantGlyphBadge(
                symbol: "hourglass",
                tint: runtimeStatusTint(defaultTint: tint),
                side: 16,
                fillOpacity: 0.14,
                strokeOpacity: 0.22,
                symbolScale: 0.46
            )
            Text(statusText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.60))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            runtimeStatusTint(defaultTint: tint).opacity(0.16),
                            lineWidth: 0.5
                        )
                )
        )
    }

    private func runtimeStatusTint(defaultTint: Color) -> Color {
        switch model.runtimeControlsAvailability {
        case .ready:
            return defaultTint
        case .busy:
            return AppVisualTheme.baseTint
        case .loadingModels, .switchingProvider:
            return defaultTint
        case .unavailable:
            return .orange
        }
    }

    private func notchProviderPicker(tint: Color) -> some View {
        let isDisabled =
            model.isSelectedSessionBackendPinned || model.selectableAssistantBackends.count <= 1
        let picker = Menu {
            ForEach(model.selectableAssistantBackends) { backend in
                Button {
                    model.onChooseBackend?(backend)
                } label: {
                    Text(backend.displayName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                AssistantGlyphBadge(
                    symbol: "point.3.filled.connected.trianglepath.dotted",
                    tint: tint,
                    side: 16,
                    fillOpacity: 0.14,
                    strokeOpacity: 0.22,
                    symbolScale: 0.46
                )
                Text(model.visibleAssistantBackend.shortDisplayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.60))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.18))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(isDisabled)

        return Group {
            if let helpText = model.selectedSessionBackendHelpText?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonEmpty {
                picker.help(helpText)
            } else {
                picker
            }
        }
    }

    private func notchModelPicker(tint: Color) -> some View {
        Menu {
            ForEach(model.availableModels) { option in
                Button {
                    model.onChooseModel?(option.id)
                } label: {
                    Text(option.displayName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                AssistantGlyphBadge(
                    symbol: AssistantChromeSymbol.model,
                    tint: tint,
                    side: 16,
                    fillOpacity: 0.14,
                    strokeOpacity: 0.22,
                    symbolScale: 0.48
                )
                Text(model.selectedModelSummary)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.60))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(AppVisualTheme.foreground(0.18))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppVisualTheme.surfaceFill(0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(model.availableModels.isEmpty)
    }

    @ViewBuilder
    private func notchComposerField(
        tint: Color,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        submit: @escaping () -> Void
    ) -> some View {
        OrbComposerTextView(
            text: $model.messageText,
            placeholder: placeholder,
            isEnabled: !model.isVoiceRecording,
            shouldFocus: model.shouldFocusTextField,
            onSubmit: submit,
            onToggleMode: { model.cycleInteractionMode() },
            onPasteAttachment: { attachment in
                addAttachment(attachment)
            }
        )
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .onDrop(of: [.fileURL, .image, .png, .jpeg], isTargeted: nil) { providers in
            handleAttachmentDrop(providers)
            return true
        }
        .notchInsetSurface(tint: tint, cornerRadius: 18, fillOpacity: 0.09)
    }

    private func notchComposerCard(tint: Color) -> some View {
        VStack(spacing: 10) {
            notchComposerField(
                tint: tint,
                placeholder: model.isVoiceRecording ? "Listening..." : "Send a message...",
                minHeight: 48,
                maxHeight: 92,
                submit: sendMessage
            )

            HStack(spacing: 8) {
                Text(liveVoiceHintText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.52))
                Spacer(minLength: 0)
                notchVoiceToggleButton(size: 26)
                liveVoiceEndButton(tint: tint)
                OrbFloatingActionButton(
                    symbol: "arrow.up",
                    tint: tint,
                    isEnabled: canSend && !model.isVoiceRecording,
                    size: 28
                ) {
                    sendMessage()
                }
            }
        }
        .padding(12)
        .notchInsetSurface(tint: tint, cornerRadius: 20, fillOpacity: 0.09)
    }

    private func notchVoiceToggleButton(size: CGFloat = 24) -> some View {
        AssistantLiveVoiceButton(
            snapshot: model.liveVoiceSnapshot,
            level: CGFloat(model.level),
            size: size,
            onTap: handleLiveVoiceButtonTap
        )
    }

    private func notchAttachmentStrip(tint: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage, let image = NSImage(data: attachment.data) {
                            Button {
                                previewAttachment = attachment
                            } label: {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 22, height: 22)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tint.opacity(0.92))
                        }

                        Text(attachment.filename)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppVisualTheme.foreground(0.70))
                            .lineLimit(1)

                        Button {
                            removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(AppVisualTheme.foreground(0.42))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.surfaceFill(0.08))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(tint.opacity(0.16), lineWidth: 0.6)
                            )
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func notchAttachmentButton(tint: Color) -> some View {
        OrbIconControlButton(symbol: AssistantChromeSymbol.attachment, tint: tint, size: 30) {
            model.onOpenAttachmentPicker?()
        }
    }

    private func sendMessage() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        model.shouldFocusTextField = false
    }

    private func addAttachment(_ attachment: AssistantAttachment) {
        model.onAddAttachment?(attachment)
    }

    private func removeAttachment(_ attachment: AssistantAttachment) {
        model.onRemoveAttachment?(attachment.id)
    }

    private func handleAttachmentDrop(_ providers: [NSItemProvider]) {
        AssistantAttachmentSupport.handleDrop(providers) { attachment in
            addAttachment(attachment)
        }
    }

    private var completionPeekSummary: String {
        guard let detail = model.doneDetailText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty
        else {
            return model.state.phase == .failed
                ? "The agent finished with an issue. Open the notch to review the result."
                : "The latest reply is ready. Open the notch to read it."
        }

        return
            detail
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    @ViewBuilder
    private func orbPreviewImageGallery(
        _ images: [Data],
        title: String,
        maxHeight: CGFloat
    ) -> some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(AppVisualTheme.foreground(0.48))

                ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { index, imageData in
                    if let nsImage = NSImage(data: imageData) {
                        Button {
                            previewAttachment = AssistantAttachment(
                                filename: "screenshot-\(index + 1).png",
                                data: imageData,
                                mimeType: "image/png"
                            )
                        } label: {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open screenshot preview")
                    }
                }
            }
        }
    }
}
