import AppKit
import SwiftUI

struct AssistantMemorySuggestionReviewSheet: View {
    @ObservedObject var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Suggestions")
                        .font(.system(size: 18, weight: .bold))
                    Text("Review these lessons before they become long-term assistant memory.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            if assistant.pendingMemorySuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No memory suggestions waiting for review.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When the assistant finds a useful rule or a repeated mistake, it will show up here for review.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.pendingMemorySuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(suggestion.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(suggestion.kind.label)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(suggestion.memoryType.label)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AppVisualTheme.accentTint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(AppVisualTheme.accentTint.opacity(0.12))
                                        )
                                }

                                Text(suggestion.summary)
                                    .font(.system(size: 13, weight: .medium))

                                Text(suggestion.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let sourceExcerpt = suggestion.sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !sourceExcerpt.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Source")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(sourceExcerpt)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(AppVisualTheme.surfaceFill(0.04))
                                    )
                                }

                                HStack(spacing: 8) {
                                    Button("Ignore") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.ignoreMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Lesson") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.acceptMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(AppVisualTheme.surfaceFill(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(AppChromeBackground())
    }
}

struct AssistantMemoryInspectorSheet: View {
    @ObservedObject var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var showInvalidated = false

    private var snapshot: AssistantMemoryInspectorSnapshot? {
        assistant.memoryInspectorSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot?.title ?? "Memory")
                        .font(.system(size: 18, weight: .bold))

                    if let subtitle = snapshot?.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let snapshot {
                    AssistantMemoryInspectorPill(
                        title: snapshot.kind == .thread ? "Thread" : "Project",
                        tint: snapshot.kind == .thread ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.78)
                    )
                }

                Button("Done") {
                    assistant.dismissMemoryInspector()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            if let snapshot {
                HStack {
                    Toggle("Show invalidated", isOn: $showInvalidated)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))

                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        overviewCard(for: snapshot)

                        switch snapshot.kind {
                        case .thread:
                            threadContent(snapshot)
                        case .project:
                            projectContent(snapshot)
                        }

                        if showInvalidated {
                            invalidatedContent(snapshot)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No memory is available for this item right now.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Try again after opening a thread or project that already has saved memory.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 520)
        .background(AppChromeBackground())
    }

    @ViewBuilder
    private func overviewCard(for snapshot: AssistantMemoryInspectorSnapshot) -> some View {
        AssistantMemoryInspectorSectionCard(title: "Overview") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AssistantMemoryInspectorPill(
                        title: snapshot.kind == .thread ? "Read-only inspector" : "Project brain",
                        tint: AppVisualTheme.accentTint
                    )

                    if let linkedFolderPath = snapshot.linkedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                        AssistantMemoryInspectorPill(title: "Linked folder", tint: AppVisualTheme.foreground(0.76))
                        Text(linkedFolderPath)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppVisualTheme.foreground(0.68))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                if let memoryFileURL = snapshot.memoryFileURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scratchpad file")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(memoryFileURL.path)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppVisualTheme.foreground(0.66))
                            .textSelection(.enabled)
                            .lineLimit(3)

                        if let modifiedAt = fileModifiedDate(for: memoryFileURL) {
                            Text("Updated \(formattedTimestamp(modifiedAt))")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func threadContent(_ snapshot: AssistantMemoryInspectorSnapshot) -> some View {
        if let threadDocument = snapshot.threadDocument, threadDocument.hasMeaningfulContent {
            AssistantMemoryInspectorSectionCard(title: "Thread Scratchpad") {
                VStack(alignment: .leading, spacing: 12) {
                    threadScratchpadSection(
                        title: "Current task",
                        text: threadDocument.currentTask
                    )
                    threadScratchpadList(
                        title: "Active facts",
                        items: threadDocument.activeFacts
                    )
                    threadScratchpadList(
                        title: "Important references",
                        items: threadDocument.importantReferences
                    )
                    threadScratchpadList(
                        title: "Session preferences",
                        items: threadDocument.sessionPreferences
                    )
                    threadScratchpadList(
                        title: "Candidate lessons",
                        items: threadDocument.candidateLessons
                    )
                    threadScratchpadList(
                        title: "Stale notes",
                        items: threadDocument.staleNotes
                    )
                }
            }
        } else {
            AssistantMemoryInspectorSectionCard(title: "Thread Scratchpad") {
                emptyState(
                    title: "No scratchpad saved yet",
                    detail: "This thread does not have useful notes in its current memory.md file yet."
                )
            }
        }

        if !snapshot.pendingSuggestions.isEmpty {
            AssistantMemoryInspectorSectionCard(title: "Pending Review") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.pendingSuggestions) { suggestion in
                        suggestionCard(suggestion)
                    }
                }
            }
        }

        AssistantMemoryInspectorSectionCard(title: "Active Thread Memory") {
            memoryEntriesSection(
                entries: snapshot.threadActiveEntries,
                emptyTitle: "No active long-term thread memory",
                emptyDetail: "This thread does not currently have saved long-term memories."
            )
        }

        if let projectSummary = snapshot.projectSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            AssistantMemoryInspectorSectionCard(title: "Project Summary") {
                summaryCard(
                    text: projectSummary,
                    tint: AppVisualTheme.accentTint,
                    label: "Derived summary"
                )
            }
        }

        if !snapshot.projectActiveEntries.isEmpty {
            AssistantMemoryInspectorSectionCard(title: "Project Memory That Applies Here") {
                memoryEntriesSection(
                    entries: snapshot.projectActiveEntries,
                    emptyTitle: "No active project memory",
                    emptyDetail: "There are no saved project-wide lessons for this thread yet."
                )
            }
        }
    }

    @ViewBuilder
    private func projectContent(_ snapshot: AssistantMemoryInspectorSnapshot) -> some View {
        AssistantMemoryInspectorSectionCard(title: "Project Summary") {
            if let projectSummary = snapshot.projectSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                summaryCard(
                    text: projectSummary,
                    tint: AppVisualTheme.accentTint,
                    label: "Derived summary"
                )
            } else {
                emptyState(
                    title: "No project summary yet",
                    detail: "The project brain has not produced a summary yet."
                )
            }
        }

        AssistantMemoryInspectorSectionCard(title: "Thread Digests") {
            if snapshot.threadDigests.isEmpty {
                emptyState(
                    title: "No thread digests yet",
                    detail: "Thread digests appear after a project-linked thread reaches a checkpoint."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.threadDigests, id: \.threadID) { digest in
                        digestCard(digest)
                    }
                }
            }
        }

        if !snapshot.pendingSuggestions.isEmpty {
            AssistantMemoryInspectorSectionCard(title: "Pending Review") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.pendingSuggestions) { suggestion in
                        suggestionCard(suggestion)
                    }
                }
            }
        }

        AssistantMemoryInspectorSectionCard(title: "Active Project Memory") {
            memoryEntriesSection(
                entries: snapshot.projectActiveEntries,
                emptyTitle: "No active project lessons",
                emptyDetail: "This project does not have saved long-term lessons yet."
            )
        }
    }

    @ViewBuilder
    private func invalidatedContent(_ snapshot: AssistantMemoryInspectorSnapshot) -> some View {
        if snapshot.kind == .thread, !snapshot.threadInvalidatedEntries.isEmpty {
            AssistantMemoryInspectorSectionCard(title: "Invalidated Thread Memory") {
                memoryEntriesSection(
                    entries: snapshot.threadInvalidatedEntries,
                    emptyTitle: "No invalidated thread memory",
                    emptyDetail: "Old thread memories will appear here when they are replaced."
                )
            }
        }

        if !snapshot.projectInvalidatedEntries.isEmpty {
            AssistantMemoryInspectorSectionCard(
                title: snapshot.kind == .thread ? "Invalidated Project Memory" : "Invalidated Project Lessons"
            ) {
                memoryEntriesSection(
                    entries: snapshot.projectInvalidatedEntries,
                    emptyTitle: "No invalidated project memory",
                    emptyDetail: "Old project lessons will appear here when they become stale."
                )
            }
        }
    }

    @ViewBuilder
    private func threadScratchpadSection(title: String, text: String) -> some View {
        if let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.82))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(AppVisualTheme.foreground(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func threadScratchpadList(title: String, items: [String]) -> some View {
        let normalizedItems = items.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        if !normalizedItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.82))

                ForEach(normalizedItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(AppVisualTheme.surfaceFill(0.32))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(item)
                            .font(.system(size: 12))
                            .foregroundStyle(AppVisualTheme.foreground(0.76))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memoryEntriesSection(
        entries: [AssistantMemoryEntry],
        emptyTitle: String,
        emptyDetail: String
    ) -> some View {
        if entries.isEmpty {
            emptyState(title: emptyTitle, detail: emptyDetail)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entries) { entry in
                    memoryEntryCard(entry)
                }
            }
        }
    }

    private func summaryCard(text: String, tint: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AssistantMemoryInspectorPill(title: label, tint: tint)
                Spacer()
            }

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AppVisualTheme.foreground(0.80))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
        )
    }

    private func digestCard(_ digest: AssistantProjectThreadDigest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(digest.threadTitle)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        AssistantMemoryInspectorPill(title: "Thread digest", tint: AppVisualTheme.accentTint)
                        AssistantMemoryInspectorPill(title: "Updated \(formattedTimestamp(digest.updatedAt))", tint: AppVisualTheme.foreground(0.72))
                    }
                }
                Spacer()
            }

            Text(digest.summary)
                .font(.system(size: 12))
                .foregroundStyle(AppVisualTheme.foreground(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
        )
    }

    private func memoryEntryCard(_ entry: AssistantMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                AssistantMemoryInspectorPill(title: entry.memoryType.label, tint: AppVisualTheme.accentTint)
                AssistantMemoryInspectorPill(title: memoryScopeLabel(for: entry), tint: AppVisualTheme.foreground(0.74))
                AssistantMemoryInspectorPill(
                    title: entry.state == .active ? "Active" : "Invalidated",
                    tint: entry.state == .active ? .green.opacity(0.88) : .orange.opacity(0.92)
                )
                AssistantMemoryInspectorPill(title: "Updated \(formattedTimestamp(entry.updatedAt))", tint: AppVisualTheme.foreground(0.72))
            }

            Text(entry.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !entry.keywords.isEmpty {
                Text(entry.keywords.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppVisualTheme.foreground(0.48))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
        )
    }

    private func suggestionCard(_ suggestion: AssistantMemorySuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(suggestion.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                AssistantMemoryInspectorPill(title: "Pending review", tint: .orange.opacity(0.92))
                AssistantMemoryInspectorPill(title: suggestion.kind.label, tint: AppVisualTheme.accentTint)
                AssistantMemoryInspectorPill(title: suggestion.memoryType.label, tint: AppVisualTheme.foreground(0.74))
                AssistantMemoryInspectorPill(title: suggestionScopeLabel(for: suggestion), tint: AppVisualTheme.foreground(0.72))
                AssistantMemoryInspectorPill(title: "Created \(formattedTimestamp(suggestion.createdAt))", tint: AppVisualTheme.foreground(0.72))
            }

            Text(suggestion.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let sourceExcerpt = suggestion.sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Source")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(sourceExcerpt)
                        .font(.system(size: 11))
                        .foregroundStyle(AppVisualTheme.foreground(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppVisualTheme.surfaceFill(0.035))
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
        )
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.74))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoryScopeLabel(for entry: AssistantMemoryEntry) -> String {
        if let identityKey = entry.identityKey?.lowercased(),
           identityKey.hasPrefix("assistant-project:") {
            return "Project-scoped"
        }
        if entry.threadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "Thread-scoped"
        }
        return "Session-scoped"
    }

    private func suggestionScopeLabel(for suggestion: AssistantMemorySuggestion) -> String {
        if let identityKey = suggestion.identityKey?.lowercased(),
           identityKey.hasPrefix("assistant-project:") {
            return "Project-scoped"
        }
        return "Thread-scoped"
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func fileModifiedDate(for fileURL: URL) -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct AssistantMemoryInspectorSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.84))

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 0.7)
                )
        )
    }
}

private struct AssistantMemoryInspectorPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint.opacity(0.96))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.22), lineWidth: 0.6)
                    )
            )
    }
}

struct AssistantProjectFilterRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let symbol: String
    var folderMissing: Bool = false
    var textScale: CGFloat = 1.0

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * textScale
    }

    var body: some View {
        HStack(alignment: .center, spacing: scaled(8)) {
            Image(systemName: symbol)
                .font(.system(size: scaled(11), weight: .semibold))
                .foregroundStyle(isSelected ? AppVisualTheme.accentTint : AppVisualTheme.foreground(0.42))
                .frame(width: scaled(16))

            VStack(alignment: .leading, spacing: scaled(2)) {
                Text(title)
                    .font(.system(size: scaled(12.5), weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.94) : AppVisualTheme.foreground(0.76))
                    .lineLimit(1)

                if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(subtitle)
                        .font(.system(size: scaled(10.5), weight: .regular))
                        .foregroundStyle(AppVisualTheme.foreground(0.34))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: scaled(6))

            if folderMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: scaled(10), weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.92))
            }
        }
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(8), style: .continuous)
                .fill(isSelected ? AppVisualTheme.foreground(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: scaled(8), style: .continuous))
    }
}

struct AssistantSessionRow: View {
    enum ActivityState: Equatable {
        case idle
        case running
        case waiting
        case failed
    }

    let session: AssistantSessionSummary
    let isSelected: Bool
    var activityState: ActivityState = .idle
    var textScale: CGFloat = 1.0

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * textScale
    }

    private var relativeTimestamp: String? {
        guard let updatedAt = session.updatedAt ?? session.createdAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))

        switch seconds {
        case 0..<60:
            return "now"
        case 60..<(60 * 60):
            return "\(max(1, seconds / 60))m"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(max(1, seconds / (60 * 60)))h"
        case (60 * 60 * 24)..<(60 * 60 * 24 * 7):
            return "\(max(1, seconds / (60 * 60 * 24)))d"
        case (60 * 60 * 24 * 7)..<(60 * 60 * 24 * 30):
            return "\(max(1, seconds / (60 * 60 * 24 * 7)))w"
        default:
            let months = seconds / (60 * 60 * 24 * 30)
            return months >= 1 ? "\(months)mo" : {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                return formatter.string(from: updatedAt)
            }()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(4)) {
            HStack(alignment: .center, spacing: scaled(10)) {
                Text(session.title)
                    .font(.system(size: scaled(13), weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppVisualTheme.foreground(0.96) : AppVisualTheme.foreground(0.78))
                    .lineLimit(1)
                    .contentTransition(.opacity)

                Spacer(minLength: scaled(4))

                switch activityState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppVisualTheme.accentTint)
                        .scaleEffect(0.7 * textScale)
                case .waiting:
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: scaled(10), weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.92))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: scaled(10), weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.92))
                }
            }

            HStack(spacing: scaled(6)) {
                if let projectName = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(projectName)
                        .font(.system(size: scaled(10), weight: .semibold))
                        .foregroundStyle(AppVisualTheme.accentTint.opacity(0.94))
                        .padding(.horizontal, scaled(7))
                        .padding(.vertical, scaled(3))
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppVisualTheme.accentTint.opacity(0.14))
                        )
                        .lineLimit(1)
                }

                if session.projectFolderMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: scaled(9.5), weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.92))
                }

                Spacer(minLength: scaled(4))

                if let relativeTimestamp {
                    Text(relativeTimestamp)
                        .font(.system(size: scaled(11), weight: .regular))
                        .foregroundStyle(AppVisualTheme.foreground(isSelected ? 0.44 : 0.30))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(4.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(8), style: .continuous)
                .fill(isSelected ? AppVisualTheme.foreground(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: scaled(8), style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: session.title)
        .animation(.easeInOut(duration: 0.18), value: relativeTimestamp)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}


struct AssistantStatusBadge: View {
    let title: String
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.95))
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppVisualTheme.foreground(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                )
        )
    }
}

struct AssistantTopBarActionButton: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint.opacity(0.94))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.14), lineWidth: 0.6)
                )
        )
    }
}

struct AssistantChatBubble: View {
    let message: AssistantChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantRow
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppVisualTheme.primaryText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    )
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(AppVisualTheme.foreground(0.3))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 8)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: roleIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.tint)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(message.tint.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.roleLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.9))

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(AppVisualTheme.foreground(0.4))
                }

                AssistantMarkdownText(
                    contentID: message.id.uuidString,
                    text: message.text,
                    role: message.role,
                    isStreaming: message.isStreaming,
                    selectionMessageID: message.id.uuidString,
                    selectionMessageText: message.text,
                    selectionTracker: AssistantTextSelectionTracker.shared
                )
                    .textSelection(.enabled)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.clear)
        .padding(.trailing, 40)
    }

    private var roleIcon: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .permission: return "lock.shield.fill"
        case .system: return "server.rack"
        default: return "bubble.left.fill"
        }
    }
}

struct AssistantMarkdownText: View {
    let contentID: String
    let text: String
    let role: AssistantTranscriptRole
    var isStreaming: Bool = false
    var preferredMaxWidth: CGFloat? = nil
    var selectionMessageID: String? = nil
    var selectionMessageText: String? = nil
    var selectionTracker: AssistantTextSelectionTracker? = nil
    @AppStorage("assistantChatTextScale") private var textScale: Double = 1.0

    @ViewBuilder
    private func responsiveWidth<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let preferredMaxWidth {
            content()
                .frame(maxWidth: preferredMaxWidth, alignment: .leading)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isStreaming {
                renderedText
                    .overlay(alignment: .bottomLeading) {
                        StreamingShimmerOverlay()
                    }
            } else {
                renderedText
            }
        }
    }

    @ViewBuilder
    private var renderedText: some View {
        responsiveWidth {
            AssistantMarkdownWebView(
                contentID: contentID,
                text: text,
                isStreaming: isStreaming,
                textScale: CGFloat(textScale)
            )
        }
    }
}

struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(AppVisualTheme.surfaceFill(visible ? 0.7 : 0.0))
            .frame(width: 2, height: 16)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

private struct StreamingShimmerOverlay: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: max(0, phase - 0.15)),
                .init(color: AppVisualTheme.foreground(0.08), location: phase),
                .init(color: .clear, location: min(1, phase + 0.15))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 24)
        .blendMode(.screen)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.15
            }
        }
    }
}

struct AssistantTypingDots: View {
    @State private var activeIndex = 0
    private let timer = Timer.publish(every: 0.34, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppVisualTheme.surfaceFill(activeIndex == index ? 0.80 : 0.24))
                    .frame(width: 6, height: 6)
                    .scaleEffect(activeIndex == index ? 1.0 : 0.72)
                    .animation(.easeInOut(duration: 0.18), value: activeIndex)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

struct AssistantMarkdownSegmentsView: View {
    let text: String
    let contentID: String
    var preferredMaxWidth: CGFloat? = nil
    var selectionMessageID: String? = nil
    var selectionMessageText: String? = nil
    var selectionTracker: AssistantTextSelectionTracker? = nil
    var textScale: CGFloat = 1.0

    @ViewBuilder
    private func responsiveWidth<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let preferredMaxWidth {
            content()
                .frame(maxWidth: preferredMaxWidth, alignment: .leading)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        responsiveWidth {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AssistantMarkdownSegment.parse(from: text)) { segment in
                    switch segment.kind {
                    case .markdown(let value):
                        AssistantRichTextView(
                            contentID: "\(contentID)-segment-\(segment.id)",
                            text: value,
                            mode: .finalMarkdown,
                            variant: .chat(textScale: textScale),
                            preferredMaxWidth: preferredMaxWidth,
                            selectionMessageID: selectionMessageID,
                            selectionMessageText: selectionMessageText,
                            selectionTracker: selectionTracker
                        )
                    case .codeBlock(let language, let code):
                        AssistantCodeBlockCard(
                            code: code,
                            language: language,
                            textScale: textScale,
                            preferredMaxWidth: preferredMaxWidth
                        )
                    }
                }
            }
        }
    }
}

private struct AssistantCodeBlockCard: View {
    let code: String
    let language: String?
    let textScale: CGFloat
    let preferredMaxWidth: CGFloat?

    @State private var isCopyHovered = false

    private var normalizedLanguage: String? {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var displayLanguage: String {
        normalizedLanguage?.capitalized ?? "Code"
    }

    private var cardMaxWidth: CGFloat {
        if let preferredMaxWidth {
            return max(280, min(preferredMaxWidth * 0.92, preferredMaxWidth - 16))
        }
        return 760
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.46))

                    Text(displayLanguage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppVisualTheme.foreground(0.66))
                }

                Spacer(minLength: 8)

                Button {
                    copyAssistantTextToPasteboard(code)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                        Text("Copy")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(AppVisualTheme.foreground(isCopyHovered ? 0.86 : 0.46))
                    .animation(.easeInOut(duration: 0.15), value: isCopyHovered)
                }
                .buttonStyle(.plain)
                .onHover { isCopyHovered = $0 }
                .help("Copy code block")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppVisualTheme.surfaceFill(0.035))

            Divider()
                .background(AppVisualTheme.surfaceFill(0.06))

            AssistantHighlightedCodeView(
                code: code,
                language: language,
                fontSize: max(11, 12.5 * textScale)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: cardMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.07), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Highlighted Code View

private struct AssistantHighlightedCodeView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat

    @State private var measuredHeight: CGFloat = 20

    var body: some View {
        AssistantHighlightedCodeNSView(
            code: code,
            language: language,
            fontSize: fontSize,
            measuredHeight: $measuredHeight
        )
        .frame(height: max(18, measuredHeight))
    }
}

private struct AssistantHighlightedCodeNSView: NSViewRepresentable {
    let code: String
    let language: String?
    let fontSize: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> HighlightedCodeContainer {
        let container = HighlightedCodeContainer()
        container.onHeightChanged = { height in
            context.coordinator.updateHeight(height)
        }
        container.apply(code: code, language: language, fontSize: fontSize)
        return container
    }

    func updateNSView(_ container: HighlightedCodeContainer, context: Context) {
        container.onHeightChanged = { height in
            context.coordinator.updateHeight(height)
        }
        container.apply(code: code, language: language, fontSize: fontSize)
    }

    final class Coordinator {
        @Binding private var measuredHeight: CGFloat
        private var lastReportedHeight: CGFloat = 0

        init(measuredHeight: Binding<CGFloat>) {
            _measuredHeight = measuredHeight
        }

        func updateHeight(_ height: CGFloat) {
            let rounded = ceil(height)
            guard abs(rounded - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = rounded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measuredHeight = rounded
            }
        }
    }
}

private final class HighlightedCodeContainer: NSView {
    var onHeightChanged: ((CGFloat) -> Void)?

    private let textView: NSTextView = {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        return tv
    }()

    private var currentCode = ""
    private var currentLanguage: String?
    private var currentFontSize: CGFloat = 0
    private var lastMeasuredHeight: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, lastMeasuredHeight))
        // Only re-measure if width actually changed
        guard abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        measureHeight()
    }

    func apply(code: String, language: String?, fontSize: CGFloat) {
        guard code != currentCode || language != currentLanguage || fontSize != currentFontSize else { return }
        currentCode = code
        currentLanguage = language
        currentFontSize = fontSize

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baseColor = NSColor.labelColor.withAlphaComponent(0.86)
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let attributed: NSAttributedString
        if lang == "json" || lang == "jsonc" {
            attributed = AssistantSyntaxHighlighter.highlightJSON(code: code, font: font, baseColor: baseColor)
        } else if lang == "yaml" || lang == "yml" {
            attributed = AssistantSyntaxHighlighter.highlightYAML(code: code, font: font, baseColor: baseColor)
        } else {
            attributed = AssistantSyntaxHighlighter.highlight(code: code, language: language, font: font, baseColor: baseColor)
        }

        textView.textStorage?.setAttributedString(attributed)
        lastLayoutWidth = 0 // Force re-measure on next layout
    }

    private func measureHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = ceil(usedRect.height + 2)
        guard abs(height - lastMeasuredHeight) > 0.5 else { return }
        lastMeasuredHeight = height
        onHeightChanged?(height)
    }
}

// MARK: - Session Instructions Popover

struct SessionInstructionsPopover: View {
    @Binding var instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Session Instructions")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("These instructions apply only to this session. They are combined with your global instructions from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor).opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.8)
                        )
                )

            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text("Active for this session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        instructions = ""
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

@MainActor
struct AssistantChatMessage: Identifiable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let timestamp: Date
    let emphasis: Bool
    let isStreaming: Bool

    var roleLabel: String {
        switch role {
        case .assistant: return "Assistant"
        case .user: return "You"
        case .permission: return "Permission"
        case .error: return "Error"
        case .status: return "Status"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    var tint: Color {
        switch role {
        case .assistant:
            return AppVisualTheme.accentTint
        case .user:
            return AppVisualTheme.baseTint
        case .permission:
            return .orange
        case .error:
            return .red
        case .status, .system, .tool:
            return Color(red: 0.42, green: 0.76, blue: 0.95)
        }
    }

    var alignment: HorizontalAlignment {
        switch role {
        case .user:
            return .trailing
        default:
            return .leading
        }
    }

    var fillOpacity: Double {
        switch role {
        case .user:
            return 0.16
        case .assistant:
            return 0.11
        case .error:
            return 0.13
        default:
            return 0.09
        }
    }

    var strokeOpacity: Double {
        emphasis ? 0.34 : 0.22
    }

    static func grouped(from entries: [AssistantTranscriptEntry]) -> [AssistantChatMessage] {
        entries.compactMap { entry in
            guard let text = entry.text.assistantNonEmpty else { return nil }
            return AssistantChatMessage(
                id: entry.id,
                role: entry.role,
                text: text,
                timestamp: entry.createdAt,
                emphasis: entry.emphasis,
                isStreaming: entry.isStreaming
            )
        }
    }
}

enum AssistantTextRenderingStyle {
    case plain
    case markdown
}

enum AssistantTextRenderingPolicy {
    static func style(for text: String, isStreaming _: Bool) -> AssistantTextRenderingStyle {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        if normalized.contains("```") || normalized.contains("`") {
            return .markdown
        }

        if normalized.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil {
            return .markdown
        }

        if normalized.range(of: #"(^|[\s])(\*\*|__|~~)[^\n]+(\*\*|__|~~)(?=$|[\s])"#, options: [.regularExpression]) != nil {
            return .markdown
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#")
                || line.hasPrefix("> ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("|") {
                return .markdown
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return .markdown
            }
        }

        return .plain
    }
}

enum AssistantVisibleTextSanitizer {
    static func clean(_ rawValue: String?) -> String? {
        guard var text = rawValue?.replacingOccurrences(of: "\r\n", with: "\n").assistantNonEmpty else {
            return nil
        }

        text = removingAnalysisBlocks(from: text)

        if let closingRange = text.range(of: "</analysis>", options: [.caseInsensitive]) {
            let prefix = text[..<closingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = text[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            text = preferredVisibleSlice(prefix: String(prefix), suffix: String(suffix))
        }

        if let openingRange = text.range(of: "<analysis>", options: [.caseInsensitive]) {
            text = String(text[..<openingRange.lowerBound])
        }

        text = text
            .removingAssistantAttachmentPlaceholders()
            .replacingOccurrences(of: "<analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "<proposed_plan>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</proposed_plan>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.assistantNonEmpty
    }

    private static func removingAnalysisBlocks(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<analysis\b[^>]*>[\s\S]*?</analysis>"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredVisibleSlice(prefix: String, suffix: String) -> String {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeInternalScratchpad(normalizedSuffix), !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        if !normalizedSuffix.isEmpty && normalizedPrefix.isEmpty {
            return normalizedSuffix
        }

        if !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        return normalizedSuffix
    }

    private static func looksLikeInternalScratchpad(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "need ",
            "let's ",
            "wait:",
            "maybe ",
            "we should ",
            "i should ",
            "final answer",
            "output final",
            "plan-only",
            "ensure "
        ]
        return markers.contains(where: lowered.contains)
    }
}

struct AssistantMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case codeBlock(language: String?, code: String)
    }

    let id: Int
    let kind: Kind

    static func parse(from text: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var currentMarkdown: [String] = []
        var insideCodeBlock = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var nextIndex = 0

        func flushMarkdown() {
            let value = currentMarkdown.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .markdown(value)))
                nextIndex += 1
            }
            currentMarkdown.removeAll()
        }

        func flushCodeBlock() {
            let value = codeLines.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .codeBlock(language: codeLanguage, code: value)))
                nextIndex += 1
            }
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if insideCodeBlock {
                    flushCodeBlock()
                    insideCodeBlock = false
                } else {
                    flushMarkdown()
                    insideCodeBlock = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if insideCodeBlock {
                codeLines.append(line)
            } else {
                currentMarkdown.append(line)
            }
        }

        if insideCodeBlock {
            flushCodeBlock()
        } else {
            flushMarkdown()
        }

        if segments.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                segments.append(AssistantMarkdownSegment(id: 0, kind: .markdown(fallback)))
            }
        }

        return segments
    }
}

// MARK: - Smooth Mouse-Wheel Scrolling

/// Intercepts discrete (mouse-wheel) scroll events on the hosting NSScrollView
/// and replaces them with short animated offsets so scrolling feels smooth,
/// matching the trackpad experience.
struct SmoothMouseScrollModifier: NSViewRepresentable {
    let onUserScroll: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            Self.install(on: v, onUserScroll: onUserScroll)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.install(on: nsView, onUserScroll: onUserScroll)
        }
    }

    private static func install(on view: NSView, onUserScroll: (() -> Void)?) {
        guard let scrollView = Self.findScrollView(from: view) else { return }
        let id = NSUserInterfaceItemIdentifier("smoothScrollInterceptor")
        if let interceptor = scrollView.subviews.first(where: { $0.identifier == id }) as? SmoothScrollInterceptorView {
            interceptor.onUserScroll = onUserScroll
            return
        }

        let interceptor = SmoothScrollInterceptorView(scrollView: scrollView)
        interceptor.identifier = id
        interceptor.onUserScroll = onUserScroll
        scrollView.addSubview(interceptor)
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = v as? NSScrollView { return sv }
            current = v.superview
        }
        return nil
    }
}

private final class SmoothScrollInterceptorView: NSView {
    private weak var scrollView: NSScrollView?
    private var targetOffsetY: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var isAnimating = false
    private let animationRate: CGFloat = 0.18 // lower = smoother/slower catch-up
    private let lineHeight: CGFloat = 40 // pixels per discrete scroll tick
    var onUserScroll: (() -> Void)?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        self.targetOffsetY = scrollView.contentView.bounds.origin.y
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLink()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView,
              !event.momentumPhase.contains(.changed),
              !event.phase.contains(.changed),
              event.phase == [] && event.momentumPhase == [] else {
            // Trackpad / momentum — pass through unchanged
            super.scrollWheel(with: event)
            return
        }

        // Discrete mouse-wheel event
        onUserScroll?()

        let clip = scrollView.contentView
        let docHeight = scrollView.documentView?.frame.height ?? clip.bounds.height
        let maxY = max(docHeight - clip.bounds.height, 0)

        if !isAnimating {
            targetOffsetY = clip.bounds.origin.y
        }

        targetOffsetY -= event.scrollingDeltaY * lineHeight / 3.0
        targetOffsetY = min(max(targetOffsetY, 0), maxY)

        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard !isAnimating else { return }
        isAnimating = true

        let link = AutoDisplayLink { [weak self] in
            self?.tick()
        }
        link.start()
        displayLink = nil // keep a ref via the class below
        self.autoDisplayLink = link
    }

    private var autoDisplayLink: AutoDisplayLink?

    private func tick() {
        guard let scrollView, isAnimating else {
            stopAnimation()
            return
        }

        let clip = scrollView.contentView
        let current = clip.bounds.origin.y
        let diff = targetOffsetY - current

        if abs(diff) < 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetOffsetY))
            scrollView.reflectScrolledClipView(clip)
            stopAnimation()
            return
        }

        let step = diff * animationRate
        let newY = current + step
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
    }

    private func stopAnimation() {
        isAnimating = false
        autoDisplayLink?.stop()
        autoDisplayLink = nil
    }

    private func stopDisplayLink() {
        stopAnimation()
    }
}

/// Minimal CVDisplayLink wrapper that fires a closure each frame on the main thread.
private final class AutoDisplayLink {
    private var displayLink: CVDisplayLink?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    deinit { stop() }

    func start() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, ctx -> CVReturn in
            let link = Unmanaged<AutoDisplayLink>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { link.callback() }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }
}

struct ChatScrollInteractionMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll

        DispatchQueue.main.async {
            guard let hostView = nsView.superview else { return }
            context.coordinator.attachIfNeeded(to: hostView)
        }
    }

    final class Coordinator {
        var onUserScroll: () -> Void
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit {
            removeObservers()
        }

        func attachIfNeeded(to hostView: NSView) {
            guard let scrollView = findScrollView(in: hostView) else { return }
            guard observedScrollView !== scrollView else { return }

            removeObservers()
            observedScrollView = scrollView

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            observedScrollView = nil
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            for subview in view.subviews {
                if let scrollView = findScrollView(in: subview) {
                    return scrollView
                }
            }

            return nil
        }
    }
}

// MARK: - Composer Text View (Enter to send, Shift+Enter for newline)

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.92)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(
            width: assistantComposerTextHorizontalInset,
            height: assistantComposerTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = assistantComposerLineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        applyAssistantComposerAppearance(to: textView)
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        applyAssistantComposerAppearance(to: textView)
        if let textView = textView as? SubmittableTextView {
            textView.onSubmit = onSubmit
            textView.onToggleMode = onToggleMode
            textView.onPasteAttachment = onPasteAttachment
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAssistantComposerAppearance(to: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAssistantComposerAppearance(to: self)
    }

    override func paste(_ sender: Any?) {
        if let attachment = AssistantAttachmentSupport.attachment(fromPasteboard: NSPasteboard.general) {
            onPasteAttachment?(attachment)
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)
        let isTab = event.keyCode == 48

        if isReturn && !isShift {
            onSubmit?()
            return
        }
        if isTab && isShift {
            onToggleMode?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Context Usage Bar

struct ContextUsageBar: View {
    let fraction: Double

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppVisualTheme.surfaceFill(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
    }
}

// MARK: - Context Usage Circle

struct ContextUsageCircle: View {
    let usage: TokenUsageSnapshot
    @State private var isHovering = false

    private var fraction: Double {
        usage.contextUsageFraction ?? 0
    }

    private var ringColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    private var percentText: String {
        "\(Int(round(fraction * 100)))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppVisualTheme.surfaceStroke(0.08), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentText)
                .font(.system(size: 6, weight: .semibold, design: .monospaced))
                .foregroundStyle(ringColor.opacity(0.9))
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .overlay(alignment: .topTrailing) {
            if isHovering {
                ContextUsageHoverCard(
                    title: usage.exactContextSummary,
                    detail: usage.contextTooltipDetail
                )
                .offset(x: -4, y: -52)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .zIndex(isHovering ? 10 : 0)
    }
}

private struct ContextUsageHoverCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppVisualTheme.primaryText)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppVisualTheme.foreground(0.74))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.7)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
        .fixedSize()
    }
}

// MARK: - Account Badge Circle

struct AccountBadgeCircle: View {
    let snapshot: AssistantAccountSnapshot
    @State private var isHovering = false

    private var planLabel: String {
        snapshot.planType?.capitalized ?? ""
    }

    private var badgeColor: Color {
        switch snapshot.planType?.lowercased() {
        case "pro": return AppVisualTheme.accentTint
        case "plus": return .purple
        default: return AppVisualTheme.foreground(0.50)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(badgeColor.opacity(0.15))
                .overlay(
                    Circle()
                        .stroke(badgeColor.opacity(0.30), lineWidth: 1)
                )
            Image(systemName: "person.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(badgeColor.opacity(0.85))
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .overlay(alignment: .topTrailing) {
            if isHovering {
                AccountHoverCard(snapshot: snapshot, tint: badgeColor)
                    .offset(x: -4, y: -56)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .zIndex(isHovering ? 10 : 0)
    }
}

private struct AccountHoverCard: View {
    let snapshot: AssistantAccountSnapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let email = snapshot.email {
                Text(email)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.primaryText)
            }
            if let plan = snapshot.planType {
                Text(plan.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.10), lineWidth: 0.7)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
        .fixedSize()
    }
}

// MARK: - Rate Limits View

struct RateLimitsView: View {
    let limits: AccountRateLimits
    var isExpanded: Bool = true

    private var visibleBuckets: [AccountRateLimitBucket] {
        limits.allBuckets.filter { $0.primary != nil || $0.secondary != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 6 : 4) {
            ForEach(visibleBuckets) { bucket in
                VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
                    if visibleBuckets.count > 1 {
                        Text(bucket.isDefaultCodex ? "Codex" : bucket.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.foreground(0.42))
                    }

                    if let primary = bucket.primary {
                        rateLimitRow(window: primary, label: primary.windowLabel.isEmpty ? "Usage" : primary.windowLabel)
                    }
                    if let secondary = bucket.secondary {
                        rateLimitRow(window: secondary, label: secondary.windowLabel.isEmpty ? "Limit" : secondary.windowLabel)
                    }
                }
            }
        }
    }

    private func rateLimitRow(window: RateLimitWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.50))
                Spacer()
                Text("\(window.usedPercent)% used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(window.usedPercent > 80 ? .red.opacity(0.8) : AppVisualTheme.foreground(0.45))
                if isExpanded, let resets = window.resetsInLabel {
                    Text("resets \(resets)")
                        .font(.system(size: 9))
                        .foregroundStyle(AppVisualTheme.foreground(0.30))
                }
            }
            ContextUsageBar(fraction: Double(window.usedPercent) / 100.0)
                .frame(height: isExpanded ? 3 : 2)
        }
        .help(!isExpanded && window.resetsInLabel != nil ? "Resets \(window.resetsInLabel!)" : "")
    }
}

// MARK: - Subagent Strip

struct SubagentStrip: View {
    let subagents: [SubagentState]

    private var activeAgents: [SubagentState] {
        subagents.filter { $0.status.isActive }
    }

    private var completedCount: Int {
        subagents.filter { !$0.status.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.50))
                Text("\(activeAgents.count) active agent\(activeAgents.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.foreground(0.65))
                if completedCount > 0 {
                    Text("· \(completedCount) done")
                        .font(.system(size: 10))
                        .foregroundStyle(AppVisualTheme.foreground(0.35))
                }
                Spacer()
            }

            ForEach(activeAgents) { agent in
                HStack(spacing: 6) {
                    Image(systemName: agent.status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(agentTint(agent.status))
                    Text(agent.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppVisualTheme.foreground(0.70))
                    if let prompt = agent.prompt?.prefix(50), !prompt.isEmpty {
                        Text(String(prompt))
                            .font(.system(size: 10))
                            .foregroundStyle(AppVisualTheme.foreground(0.30))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(agent.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(agentTint(agent.status).opacity(0.7))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppVisualTheme.surfaceFill(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppVisualTheme.surfaceStroke(0.06), lineWidth: 0.5)
                )
        )
    }

    private func agentTint(_ status: SubagentStatus) -> Color {
        switch status {
        case .spawning, .running: return .blue
        case .waiting: return .orange
        case .completed: return .green
        case .errored: return .red
        case .closed: return .gray
        }
    }
}

// MARK: - Scroll tracking

struct ScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
