import SwiftUI

// MARK: - Main View

@MainActor
struct ScheduledJobsView: View {
    let showsHeader: Bool

    @ObservedObject private var coordinator = JobQueueCoordinator.shared
    @State private var editingState: EditingState = .none

    init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    enum EditingState: Equatable {
        case none
        case new
        case editing(String) // job ID
    }

    var body: some View {
        HStack(spacing: 0) {
            jobListColumn
            Divider().overlay(AppVisualTheme.foreground(0.07))
            rightPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Left Column: Job List

    private var jobListColumn: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Jobs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.mutedText)
                Spacer()
                Button {
                    editingState = .new
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint)
                        .frame(width: 22, height: 22)
                        .background(AppVisualTheme.accentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("New scheduled job")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(AppVisualTheme.foreground(0.07))

            if coordinator.jobs.isEmpty {
                listEmptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(coordinator.jobs) { job in
                            JobListRow(
                                job: job,
                                isRunning: coordinator.runningJobIDs.contains(job.id),
                                isSelected: editingState == .editing(job.id),
                                onToggle: {
                                    var updated = job
                                    updated.isEnabled.toggle()
                                    if updated.isEnabled {
                                        updated.nextRunAt = updated.computeNextRunDate(after: Date())
                                    }
                                    coordinator.updateJob(updated)
                                },
                                onTap: { editingState = .editing(job.id) }
                            )
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var listEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 24))
                .foregroundStyle(AppVisualTheme.mutedText.opacity(0.5))
            Text("No jobs yet")
                .font(.system(size: 12))
                .foregroundStyle(AppVisualTheme.mutedText)
            Button {
                editingState = .new
            } label: {
                Text("Add First Job")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.accentTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppVisualTheme.accentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        switch editingState {
        case .none:
            rightPanelPlaceholder
        case .new:
            JobEditPanel(
                existingJob: nil,
                onSave: { job in
                    coordinator.addJob(job)
                    editingState = .editing(job.id)
                },
                onCancel: { editingState = .none }
            )
            .id("new")
        case .editing(let jobID):
            if let job = coordinator.jobs.first(where: { $0.id == jobID }) {
                JobEditPanel(
                    existingJob: job,
                    onSave: { updated in coordinator.updateJob(updated) },
                    onDelete: {
                        coordinator.removeJob(id: jobID)
                        editingState = .none
                    },
                    onRunNow: { coordinator.runJobNow(job) },
                    onCancel: { editingState = .none }
                )
                .id(jobID)
            } else {
                rightPanelPlaceholder
            }
        }
    }

    private var rightPanelPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28))
                .foregroundStyle(AppVisualTheme.mutedText.opacity(0.4))
            Text("Select a job to edit")
                .font(.system(size: 13))
                .foregroundStyle(AppVisualTheme.mutedText)
            Text("or tap + to create a new one")
                .font(.system(size: 11))
                .foregroundStyle(AppVisualTheme.mutedText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Job List Row (compact)

private struct JobListRow: View {
    let job: ScheduledJob
    let isRunning: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: job.jobType.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.9) : typeColor)
                    .frame(width: 20, height: 20)
                    .background(
                        isSelected
                            ? typeColor.opacity(0.25)
                            : typeColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.95) : AppVisualTheme.foreground(0.78))
                        .lineLimit(1)
                    Text(job.scheduleDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.55) : AppVisualTheme.mutedText.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Toggle("", isOn: Binding(get: { job.isEnabled }, set: { _ in onToggle() }))
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                        .frame(width: 32)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? AppVisualTheme.accentTint.opacity(0.10)
                    : AppVisualTheme.foreground(0.0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AppVisualTheme.accentTint.opacity(0.20) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(job.isEnabled || isSelected ? 1.0 : 0.50)
    }

    private var typeColor: Color {
        switch job.jobType {
        case .browser: return Color(red: 0.30, green: 0.65, blue: 0.93)
        case .app:     return Color(red: 0.46, green: 0.79, blue: 0.66)
        case .system:  return Color(red: 0.90, green: 0.70, blue: 0.26)
        case .general: return Color(red: 0.72, green: 0.56, blue: 0.88)
        }
    }
}

// MARK: - Job Edit Panel (inline, right side)

struct JobEditPanel: View {
    let existingJob: ScheduledJob?
    var onSave: (ScheduledJob) -> Void
    var onDelete: (() -> Void)? = nil
    var onRunNow: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @ObservedObject private var assistant = AssistantStore.shared
    @ObservedObject private var coordinator = JobQueueCoordinator.shared

    @State private var name: String
    @State private var prompt: String
    @State private var jobType: ScheduledJobType
    @State private var recurrence: ScheduledJobRecurrence
    @State private var hour: Int
    @State private var minute: Int
    @State private var weekday: Int
    @State private var intervalMinutes: Int
    @State private var preferredModelID: String?
    @State private var reasoningEffort: AssistantReasoningEffort?
    @State private var isDirty = false
    @State private var loadedAutomationLessons: [AssistantMemoryEntry] = []

    init(
        existingJob: ScheduledJob?,
        onSave: @escaping (ScheduledJob) -> Void,
        onDelete: (() -> Void)? = nil,
        onRunNow: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.existingJob = existingJob
        self.onSave = onSave
        self.onDelete = onDelete
        self.onRunNow = onRunNow
        self.onCancel = onCancel
        _name = State(initialValue: existingJob?.name ?? "")
        _prompt = State(initialValue: existingJob?.prompt ?? "")
        _jobType = State(initialValue: existingJob?.jobType ?? .general)
        _recurrence = State(initialValue: existingJob?.recurrence ?? .daily)
        _hour = State(initialValue: existingJob?.hour ?? 9)
        _minute = State(initialValue: existingJob?.minute ?? 0)
        _weekday = State(initialValue: existingJob?.weekday ?? 2)
        _intervalMinutes = State(initialValue: existingJob?.intervalMinutes ?? 60)
        _preferredModelID = State(initialValue: existingJob?.preferredModelID)
        _reasoningEffort = State(initialValue: existingJob?.reasoningEffort)
    }

    /// Live copy of the job, updated whenever the coordinator publishes changes.
    private var liveJob: ScheduledJob? {
        guard let id = existingJob?.id else { return nil }
        return coordinator.jobs.first(where: { $0.id == id }) ?? existingJob
    }

    private var automationLessonLoadKey: String {
        guard let job = liveJob else { return "none" }
        let finishedAtKey = job.lastRunFinishedAt?.timeIntervalSinceReferenceDate.description ?? "none"
        let lessonCountKey = String(job.lastLearnedLessonCount)
        let sessionKey = job.dedicatedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "none"
        let cwdKey = liveAutomationCWD(for: job)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "none"
        return [job.id.lowercased(), finishedAtKey, lessonCountKey, sessionKey, cwdKey].joined(separator: "|")
    }

    private var isNew: Bool { existingJob == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var supportedEfforts: [AssistantReasoningEffort] {
        guard let modelID = preferredModelID,
              let model = assistant.visibleModels.first(where: { $0.id == modelID }),
              !model.supportedReasoningEfforts.isEmpty else {
            return AssistantReasoningEffort.allCases
        }
        return model.supportedReasoningEfforts.compactMap { AssistantReasoningEffort(rawValue: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().overlay(AppVisualTheme.foreground(0.07))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !isNew {
                        panelSummaryStrip
                    }

                    formSection("Job") {
                        fieldRow("Name") {
                            TextField("e.g. Morning email check", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(AppVisualTheme.foreground(0.90))
                                .onChange(of: name) { _ in isDirty = true }
                        }
                        Divider().overlay(AppVisualTheme.foreground(0.05))
                        fieldRow("Prompt") {
                            TextEditor(text: $prompt)
                                .font(.system(size: 12))
                                .foregroundStyle(AppVisualTheme.foreground(0.88))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 64)
                                .onChange(of: prompt) { _ in isDirty = true }
                        }
                        Divider().overlay(AppVisualTheme.foreground(0.05))
                        fieldRow("Type") {
                            Picker("", selection: $jobType) {
                                ForEach(ScheduledJobType.allCases, id: \.self) { t in
                                    Label(t.displayName, systemImage: t.iconName).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: jobType) { _ in isDirty = true }
                        }
                    }

                    formSection("Schedule") {
                        fieldRow("Recurrence") {
                            Picker("", selection: $recurrence) {
                                ForEach(ScheduledJobRecurrence.allCases, id: \.self) { r in
                                    Text(r.displayName).tag(r)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: recurrence) { _ in isDirty = true }
                        }

                        if recurrence.usesHourAndMinute {
                            Divider().overlay(AppVisualTheme.foreground(0.05))
                            fieldRow("Time") {
                                DatePicker(
                                    "",
                                    selection: timeBinding,
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .colorScheme(.dark)
                                .onChange(of: timeBinding.wrappedValue) { _ in isDirty = true }
                            }
                        }

                        if recurrence.usesMinuteOnly {
                            Divider().overlay(AppVisualTheme.foreground(0.05))
                            fieldRow("At minute") {
                                DatePicker(
                                    "",
                                    selection: timeBinding,
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .colorScheme(.dark)
                                .onChange(of: timeBinding.wrappedValue) { _ in isDirty = true }
                            }
                        }

                        if recurrence.usesInterval {
                            Divider().overlay(AppVisualTheme.foreground(0.05))
                            fieldRow("Interval") {
                                Stepper("\(intervalMinutes) min", value: $intervalMinutes, in: 5...1440, step: 5)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppVisualTheme.foreground(0.88))
                                    .onChange(of: intervalMinutes) { _ in isDirty = true }
                            }
                        }

                        if recurrence.usesWeekday {
                            Divider().overlay(AppVisualTheme.foreground(0.05))
                            fieldRow("Day") {
                                Picker("", selection: $weekday) {
                                    ForEach(1...7, id: \.self) { d in
                                        Text(Calendar.current.weekdaySymbols[d - 1]).tag(d)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .onChange(of: weekday) { _ in isDirty = true }
                            }
                        }

                        // Schedule preview
                        let preview = ScheduledJob.make(
                            name: "job", prompt: "p",
                            jobType: jobType, recurrence: recurrence,
                            hour: hour, minute: minute, weekday: weekday, intervalMinutes: intervalMinutes
                        )
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(AppVisualTheme.mutedText)
                            Text(preview.scheduleDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(AppVisualTheme.mutedText)
                            if let next = preview.nextRunAt {
                                Text("· \(RelativeDateTimeFormatter().localizedString(for: next, relativeTo: Date()))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppVisualTheme.mutedText.opacity(0.60))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }

                    formSection("Model & Reasoning") {
                        modelPickerRow
                        Divider().overlay(AppVisualTheme.foreground(0.05))
                        reasoningPickerRow
                    }

                    if let job = liveJob, job.lastRunAt != nil || job.lastRunStartedAt != nil {
                        formSection("Latest Run") {
                            lastRunSection(job: job)
                        }
                    }

                    if let job = liveJob {
                        formSection("Automation Memory") {
                            automationMemorySection(job: job)
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider().overlay(AppVisualTheme.foreground(0.07))
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: automationLessonLoadKey) {
            await refreshAutomationLessons()
        }
    }

    // MARK: - Panel Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Job" : name.isEmpty ? "Edit Job" : name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.90))
                    .lineLimit(1)
                if !isNew, let job = liveJob {
                    HStack(spacing: 4) {
                        if job.isEnabled {
                            Circle()
                                .fill(Color(red: 0.23, green: 0.72, blue: 0.58))
                                .frame(width: 5, height: 5)
                            Text("Active · next \(job.nextRunDescription)")
                        } else {
                            Circle()
                                .fill(AppVisualTheme.mutedText.opacity(0.5))
                                .frame(width: 5, height: 5)
                            Text("Disabled")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(AppVisualTheme.mutedText)
                }
            }
            Spacer()
            if let onRunNow, !isNew {
                Button(action: onRunNow) {
                    Label("Run Now", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppVisualTheme.accentTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppVisualTheme.accentTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var panelSummaryStrip: some View {
        if let job = liveJob {
            let summaryItems: [(String, String)] = [
                ("Type", job.jobType.displayName),
                ("Schedule", job.scheduleDescription),
                ("Next", job.nextRunAt.map(relativeTimeString) ?? "Not scheduled"),
                ("Latest", latestOutcomeLabel(for: job))
            ]

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(summaryItems, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(AppVisualTheme.mutedText.opacity(0.78))
                            Text(item.1)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AppVisualTheme.foreground(0.88))
                                .lineLimit(1)
                        }
                        .frame(width: 142, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(AppVisualTheme.foreground(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppVisualTheme.foreground(0.06), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Model Picker

    @ViewBuilder
    private var modelPickerRow: some View {
        let models = assistant.visibleModels
        fieldRow("Model") {
            if models.isEmpty {
                Text("Connect a provider first")
                    .font(.system(size: 12))
                    .foregroundStyle(AppVisualTheme.mutedText)
            } else {
                Picker("", selection: Binding(
                    get: { preferredModelID ?? "__default__" },
                    set: { newValue in
                        preferredModelID = newValue == "__default__" ? nil : newValue
                        if let e = reasoningEffort, !supportedEfforts.contains(e) { reasoningEffort = nil }
                        isDirty = true
                    }
                )) {
                    Text("Default (\(assistant.selectedModelSummary))")
                        .tag("__default__")
                    Divider()
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Reasoning Picker

    @ViewBuilder
    private var reasoningPickerRow: some View {
        fieldRow("Reasoning") {
            Picker("", selection: Binding(
                get: { reasoningEffort?.rawValue ?? "__default__" },
                set: { newValue in
                    reasoningEffort = newValue == "__default__" ? nil : AssistantReasoningEffort(rawValue: newValue)
                    isDirty = true
                }
            )) {
                Text("Default").tag("__default__")
                Divider()
                ForEach(supportedEfforts, id: \.self) { effort in
                    Text(effort.label).tag(effort.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Last Run Section

    @ViewBuilder
    private func lastRunSection(job: ScheduledJob) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("Outcome")
                    .font(.system(size: 12))
                    .foregroundStyle(AppVisualTheme.mutedText)
                    .frame(width: 72, alignment: .leading)
                HStack(spacing: 8) {
                    outcomeBadge(for: job.lastRunOutcome)
                    if job.lastLearnedLessonCount > 0 {
                        Text("\(job.lastLearnedLessonCount) lesson\(job.lastLearnedLessonCount == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.92))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let startedAt = job.lastRunStartedAt {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                runDetailRow(label: "Started", value: timestampString(startedAt))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if let finishedAt = job.lastRunFinishedAt ?? job.lastRunAt {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                runDetailRow(label: "Finished", value: timestampString(finishedAt))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if let firstIssueAt = job.lastRunFirstIssueAt {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                runDetailRow(
                    label: "First Issue",
                    value: timestampString(firstIssueAt),
                    valueColor: outcomeColor(job.lastRunOutcome)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let note = job.lastRunNote?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                HStack(alignment: .top, spacing: 10) {
                    Text("Status")
                        .font(.system(size: 12))
                        .foregroundStyle(AppVisualTheme.mutedText)
                        .frame(width: 72, alignment: .leading)
                        .padding(.top, 1)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(noteColor(note))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let summary = job.lastRunSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                HStack(alignment: .top, spacing: 10) {
                    Text("Summary")
                        .font(.system(size: 12))
                        .foregroundStyle(AppVisualTheme.mutedText)
                        .frame(width: 72, alignment: .leading)
                        .padding(.top, 1)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(AppVisualTheme.foreground(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            let attachedSessionIDs = attachedSessionIDs(for: job)
            if !attachedSessionIDs.isEmpty {
                Divider().overlay(AppVisualTheme.foreground(0.05))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(attachedSessionIDs.count == 1 ? "Session" : "Sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(AppVisualTheme.mutedText)
                            .frame(width: 72, alignment: .leading)
                            .padding(.top, 10)
                        VStack(spacing: 8) {
                            ForEach(attachedSessionIDs, id: \.self) { sessionID in
                                attachedSessionButton(sessionID: sessionID)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func automationMemorySection(job: ScheduledJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if loadedAutomationLessons.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppVisualTheme.mutedText.opacity(0.82))
                        .padding(.top, 1)
                    Text(job.lastRunAt == nil
                        ? "This automation has not learned any long-term lessons yet. After it runs, useful repeat lessons will appear here."
                        : "No active lessons are saved yet. When this automation learns a stable better approach, it will show up here for future runs.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppVisualTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ForEach(Array(loadedAutomationLessons.prefix(6).enumerated()), id: \.element.id) { index, lesson in
                    if index > 0 {
                        Divider().overlay(AppVisualTheme.foreground(0.05))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(lesson.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.foreground(0.90))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(timestampString(lesson.updatedAt))
                                .font(.system(size: 10.5))
                                .foregroundStyle(AppVisualTheme.mutedText)
                        }

                        Text(lesson.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppVisualTheme.foreground(0.84))
                            .fixedSize(horizontal: false, vertical: true)

                        if let source = lesson.metadata["lesson_source"]?.nonEmpty {
                            Text(source == "heuristic"
                                ? "Saved automatically from repeated behavior"
                                : "Saved from run summary analysis")
                                .font(.system(size: 10.5))
                                .foregroundStyle(AppVisualTheme.mutedText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func noteColor(_ note: String) -> Color {
        let lower = note.lowercased()
        if lower.contains("skip") || lower.contains("busy") { return Color(red: 0.95, green: 0.72, blue: 0.30) }
        if lower.contains("fail") || lower.contains("error") { return Color(red: 0.95, green: 0.40, blue: 0.35) }
        return AppVisualTheme.foreground(0.80)
    }

    private func outcomeColor(_ outcome: ScheduledJobRunOutcome?) -> Color {
        switch outcome {
        case .completed:
            return Color(red: 0.23, green: 0.72, blue: 0.58)
        case .failed:
            return Color(red: 0.95, green: 0.40, blue: 0.35)
        case .interrupted:
            return Color(red: 0.95, green: 0.72, blue: 0.30)
        case .none:
            return AppVisualTheme.mutedText
        }
    }

    private func latestOutcomeLabel(for job: ScheduledJob) -> String {
        job.lastRunOutcome?.displayName ?? "No runs yet"
    }

    @ViewBuilder
    private func outcomeBadge(for outcome: ScheduledJobRunOutcome?) -> some View {
        let label = outcome?.displayName ?? "Waiting"
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(outcomeColor(outcome))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(outcomeColor(outcome).opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(outcomeColor(outcome).opacity(0.22), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func runDetailRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        let resolvedValueColor = valueColor ?? AppVisualTheme.foreground(0.80)
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppVisualTheme.mutedText)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(resolvedValueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func liveAutomationCWD(for job: ScheduledJob) -> String? {
        attachedSessionIDs(for: job).compactMap(sessionSummary(for:)).compactMap(\.cwd).first
    }

    private func attachedSessionIDs(for job: ScheduledJob) -> [String] {
        [job.dedicatedSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, sessionID in
                if !result.contains(where: { $0.caseInsensitiveCompare(sessionID) == .orderedSame }) {
                    result.append(sessionID)
                }
            }
    }

    private func sessionSummary(for sessionID: String) -> AssistantSessionSummary? {
        assistant.sessions.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(sessionID.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        })
    }

    @ViewBuilder
    private func attachedSessionButton(sessionID: String) -> some View {
        let summary = sessionSummary(for: sessionID)
        Button {
            openSession(sessionID)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary?.title.nonEmpty ?? "Open attached thread")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.90))
                        .lineLimit(1)

                    Text(summary?.latestAssistantMessage?.nonEmpty
                        ?? summary?.latestUserMessage?.nonEmpty
                        ?? shortSessionIdentifier(sessionID))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppVisualTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint.opacity(0.95))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppVisualTheme.accentTint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppVisualTheme.accentTint.opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open this automation thread")
    }

    private func shortSessionIdentifier(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 18 else { return trimmed }
        return String(trimmed.prefix(18)) + "…"
    }

    private func openSession(_ sessionID: String) {
        NotificationCenter.default.post(
            name: .openAssistSwitchToSession,
            object: nil,
            userInfo: ["sessionID": sessionID]
        )
    }

    @MainActor
    private func refreshAutomationLessons() async {
        guard let job = liveJob else {
            loadedAutomationLessons = []
            return
        }

        let lessons = coordinator.automationLessons(for: job, cwd: liveAutomationCWD(for: job))
        if lessons != loadedAutomationLessons {
            loadedAutomationLessons = lessons
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            if let onDelete, !isNew {
                Button {
                    onDelete()
                } label: {
                    Text("Delete")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.95, green: 0.40, blue: 0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.95, green: 0.40, blue: 0.35).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let onCancel, isNew {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 12))
                    .foregroundStyle(AppVisualTheme.mutedText)
                    .buttonStyle(.plain)
            }
            Button {
                commitSave()
            } label: {
                Text(isNew ? "Create Job" : (isDirty ? "Save Changes" : "Saved"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(canSave && (isNew || isDirty) ? AppVisualTheme.accentTint : AppVisualTheme.mutedText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        canSave && (isNew || isDirty)
                            ? AppVisualTheme.accentTint.opacity(0.12)
                            : AppVisualTheme.foreground(0.04),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave || (!isNew && !isDirty))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func formSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppVisualTheme.mutedText.opacity(0.70))
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(AppVisualTheme.foreground(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppVisualTheme.foreground(0.06), lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppVisualTheme.mutedText)
                .frame(width: 72, alignment: .leading)
                .padding(.top, 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Binding that bridges DatePicker ↔ (hour, minute) state.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                c.hour = hour
                c.minute = minute
                c.second = 0
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour = c.hour ?? hour
                minute = c.minute ?? minute
            }
        )
    }

    private func commitSave() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimPrompt = prompt.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty, !trimPrompt.isEmpty else { return }

        var job = existingJob ?? ScheduledJob.make(
            name: trimName, prompt: trimPrompt,
            jobType: jobType, recurrence: recurrence,
            hour: hour, minute: minute, weekday: weekday, intervalMinutes: intervalMinutes
        )
        job.name = trimName
        job.prompt = trimPrompt
        job.jobType = jobType
        job.recurrence = recurrence
        job.hour = hour
        job.minute = minute
        job.weekday = weekday
        job.intervalMinutes = intervalMinutes
        job.preferredModelID = preferredModelID
        job.reasoningEffort = reasoningEffort
        job.nextRunAt = job.computeNextRunDate(after: Date())

        onSave(job)
        isDirty = false
    }
}
