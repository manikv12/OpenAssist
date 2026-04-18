import AppKit
import QuickLookUI
import SwiftUI
import WebKit

// MARK: - SwiftUI View

struct AssistantChatWebView: NSViewRepresentable {
    let messages: [AssistantChatWebMessage]
    let runtimePanel: AssistantChatWebRuntimePanel?
    let reviewPanel: AssistantChatWebCodeReviewPanel?
    let rewindState: AssistantChatWebRewindState?
    let threadNoteState: AssistantChatWebThreadNoteState?
    let activeWorkState: AssistantChatWebActiveWorkState?
    let activeTurnState: AssistantChatWebActiveTurnState?
    let showTypingIndicator: Bool
    let typingTitle: String
    let typingDetail: String
    let textScale: CGFloat
    let canLoadOlderHistory: Bool
    var accentColor: Color? = nil
    let onScrollStateChanged: (Bool, Bool) -> Void  // (isPinned, isScrolledUp)
    let onLoadOlderHistory: () -> Void
    let onLoadActivityDetails: (String) -> Void
    let onCollapseActivityDetails: (String) -> Void
    let onSelectRuntimeBackend: (String) -> Void
    let onOpenRuntimeSettings: () -> Void
    let onUndoMessage: (String) -> Void
    let onEditMessage: (String) -> Void
    let onUndoCodeCheckpoint: () -> Void
    let onRedoHistoryMutation: () -> Void
    let onRestoreCodeCheckpoint: (String) -> Void
    let onCloseCodeReviewPanel: () -> Void
    let onThreadNoteCommand: (AssistantChatWebThreadNoteCommand, AssistantChatWebContainerView?) -> Void
    var noteAssetResolver: AssistantNoteAssetURLSchemeHandler.Resolver? = nil
    var onTextSelected: ((String, String, String, CGRect) -> Void)? = nil
    var onContainerReady: ((AssistantChatWebContainerView) -> Void)? = nil

    func makeCoordinator() -> AssistantChatWebCoordinator {
        AssistantChatWebCoordinator(
            onScrollStateChanged: onScrollStateChanged,
            onLoadOlderHistory: onLoadOlderHistory,
            onLoadActivityDetails: onLoadActivityDetails,
            onCollapseActivityDetails: onCollapseActivityDetails,
            onSelectRuntimeBackend: onSelectRuntimeBackend,
            onOpenRuntimeSettings: onOpenRuntimeSettings,
            onUndoMessage: onUndoMessage,
            onEditMessage: onEditMessage,
            onUndoCodeCheckpoint: onUndoCodeCheckpoint,
            onRedoHistoryMutation: onRedoHistoryMutation,
            onRestoreCodeCheckpoint: onRestoreCodeCheckpoint,
            onCloseCodeReviewPanel: onCloseCodeReviewPanel,
            onThreadNoteCommand: onThreadNoteCommand
        )
    }

    func makeNSView(context: Context) -> AssistantChatWebContainerView {
        let container = AssistantChatWebContainerView(
            coordinator: context.coordinator,
            noteAssetResolver: noteAssetResolver
        )
        context.coordinator.onTextSelected = onTextSelected
        context.coordinator.webViewContainer = container
        container.applyMessages(messages)
        container.applyRuntimePanel(runtimePanel)
        container.applyReviewPanel(reviewPanel)
        container.applyRewindState(rewindState)
        container.applyThreadNoteState(threadNoteState)
        container.applyActiveWorkState(activeWorkState)
        container.applyActiveTurnState(activeTurnState)
        container.applyTypingIndicator(
            showTypingIndicator, title: typingTitle, detail: typingDetail)
        container.applyTextScale(textScale)
        container.applyCanLoadOlder(canLoadOlderHistory)
        if let accent = accentColor {
            container.applyAccentColor(accent)
        }
        onContainerReady?(container)
        return container
    }

    func updateNSView(_ container: AssistantChatWebContainerView, context: Context) {
        container.coordinator = context.coordinator
        context.coordinator.onScrollStateChanged = onScrollStateChanged
        context.coordinator.onLoadOlderHistory = onLoadOlderHistory
        context.coordinator.onLoadActivityDetails = onLoadActivityDetails
        context.coordinator.onCollapseActivityDetails = onCollapseActivityDetails
        context.coordinator.onSelectRuntimeBackend = onSelectRuntimeBackend
        context.coordinator.onOpenRuntimeSettings = onOpenRuntimeSettings
        context.coordinator.onUndoMessage = onUndoMessage
        context.coordinator.onEditMessage = onEditMessage
        context.coordinator.onUndoCodeCheckpoint = onUndoCodeCheckpoint
        context.coordinator.onRedoHistoryMutation = onRedoHistoryMutation
        context.coordinator.onRestoreCodeCheckpoint = onRestoreCodeCheckpoint
        context.coordinator.onCloseCodeReviewPanel = onCloseCodeReviewPanel
        context.coordinator.onThreadNoteCommand = onThreadNoteCommand
        context.coordinator.onTextSelected = onTextSelected
        container.updateNoteAssetResolver(noteAssetResolver)
        container.applyMessages(messages)
        container.applyRuntimePanel(runtimePanel)
        container.applyReviewPanel(reviewPanel)
        container.applyRewindState(rewindState)
        container.applyThreadNoteState(threadNoteState)
        container.applyActiveWorkState(activeWorkState)
        container.applyActiveTurnState(activeTurnState)
        container.applyTypingIndicator(
            showTypingIndicator, title: typingTitle, detail: typingDetail)
        container.applyTextScale(textScale)
        container.applyCanLoadOlder(canLoadOlderHistory)
        if let accent = accentColor {
            container.applyAccentColor(accent)
        }
    }
}

// MARK: - Message Model for Web

struct AssistantChatWebMessage: Equatable {
    let id: String
    let type: String  // "user", "assistant", "activity", "activityGroup", "activitySummary", "system"
    let text: String?
    let isStreaming: Bool
    let timestamp: Date
    let turnID: String?
    let images: [AssistantChatWebInlineImage]?
    let emphasis: Bool
    let canUndo: Bool
    let canEdit: Bool
    let rewriteAnchorID: String?
    let providerLabel: String?
    let selectedPlugins: [AssistantComposerWebPlugin]?

    // Activity
    let activityIcon: String?
    let activityTitle: String?
    let activityDetail: String?
    let activityStatus: String?  // "running", "completed", "failed"
    let activityStatusLabel: String?
    let detailSections: [AssistantChatWebDetailSection]?
    let activityTargets: [AssistantChatWebActivityTarget]?

    // Activity group
    let groupItems: [AssistantChatWebActivityGroupItem]?
    let loadActivityDetailsID: String?
    let collapseActivityDetailsID: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "type": type,
            "isStreaming": isStreaming,
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
        ]
        if let text { json["text"] = text }
        if let turnID { json["turnID"] = turnID }
        if emphasis { json["emphasis"] = true }
        if canUndo { json["canUndo"] = true }
        if canEdit { json["canEdit"] = true }
        if let rewriteAnchorID { json["rewriteAnchorID"] = rewriteAnchorID }
        if let providerLabel { json["providerLabel"] = providerLabel }
        if let selectedPlugins, !selectedPlugins.isEmpty {
            json["selectedPlugins"] = selectedPlugins.map { $0.toJSON() }
        }

        if let images, !images.isEmpty {
            json["images"] = images.map(\.dataURL)
        }

        if let activityIcon { json["activityIcon"] = activityIcon }
        if let activityTitle { json["activityTitle"] = activityTitle }
        if let activityDetail { json["activityDetail"] = activityDetail }
        if let activityStatus { json["activityStatus"] = activityStatus }
        if let activityStatusLabel { json["activityStatusLabel"] = activityStatusLabel }
        if let detailSections, !detailSections.isEmpty {
            json["detailSections"] = detailSections.map { $0.toJSON() }
        }
        if let activityTargets, !activityTargets.isEmpty {
            json["activityTargets"] = activityTargets.map { $0.toJSON() }
        }

        if let groupItems, !groupItems.isEmpty {
            json["groupItems"] = groupItems.map { $0.toJSON() }
        }
        if let loadActivityDetailsID {
            json["loadActivityDetailsID"] = loadActivityDetailsID
        }
        if let collapseActivityDetailsID {
            json["collapseActivityDetailsID"] = collapseActivityDetailsID
        }

        return json
    }
}

struct AssistantChatWebInlineImage: Equatable {
    let digest: String
    let dataURL: String

    static func == (lhs: AssistantChatWebInlineImage, rhs: AssistantChatWebInlineImage) -> Bool {
        lhs.digest == rhs.digest
    }

    static func payloads(from images: [Data]?) -> [AssistantChatWebInlineImage]? {
        guard let images, !images.isEmpty else { return nil }
        return images.map(Self.payload(from:))
    }

    private static func payload(from data: Data) -> AssistantChatWebInlineImage {
        let digest = MemoryIdentifier.stableHexDigest(data: data)
        if let cachedDataURL = AssistantChatWebInlineImageDataURLCache.shared.dataURL(for: digest) {
            return AssistantChatWebInlineImage(digest: digest, dataURL: cachedDataURL)
        }

        let dataURL = makeDataURL(from: data)
        AssistantChatWebInlineImageDataURLCache.shared.store(
            dataURL,
            for: digest,
            cost: data.count
        )
        return AssistantChatWebInlineImage(digest: digest, dataURL: dataURL)
    }

    private static func makeDataURL(from data: Data) -> String {
        let base64 = data.base64EncodedString()
        if data.count > 8 {
            let bytes = [UInt8](data.prefix(8))
            if bytes[0] == 0x89 && bytes[1] == 0x50 {
                return "data:image/png;base64,\(base64)"
            }
        }
        return "data:image/jpeg;base64,\(base64)"
    }
}

private final class AssistantChatWebInlineImageDataURLCache {
    static let shared = AssistantChatWebInlineImageDataURLCache()

    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.countLimit = 192
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func dataURL(for digest: String) -> String? {
        cache.object(forKey: digest as NSString) as String?
    }

    func store(_ dataURL: String, for digest: String, cost: Int) {
        cache.setObject(dataURL as NSString, forKey: digest as NSString, cost: cost)
    }
}

struct AssistantChatWebActivityGroupItem: Equatable {
    let id: String
    let icon: String?
    let title: String
    let detail: String?
    let status: String
    let statusLabel: String?
    let timestamp: Date
    let detailSections: [AssistantChatWebDetailSection]?
    let activityTargets: [AssistantChatWebActivityTarget]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "status": status,
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
        ]
        if let icon { json["icon"] = icon }
        if let detail { json["detail"] = detail }
        if let statusLabel { json["statusLabel"] = statusLabel }
        if let detailSections, !detailSections.isEmpty {
            json["detailSections"] = detailSections.map { $0.toJSON() }
        }
        if let activityTargets, !activityTargets.isEmpty {
            json["activityTargets"] = activityTargets.map { $0.toJSON() }
        }
        return json
    }
}

struct AssistantChatWebActivityTarget: Equatable {
    let kind: String
    let label: String
    let detail: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "kind": kind,
            "label": label,
        ]
        if let detail, !detail.isEmpty {
            json["detail"] = detail
        }
        return json
    }
}

struct AssistantChatWebDetailSection: Equatable {
    let title: String
    let text: String

    func toJSON() -> [String: Any] {
        [
            "title": title,
            "text": text,
        ]
    }
}

struct AssistantChatWebCodeReviewFile: Equatable {
    let path: String
    let changeKind: String
    let isBinary: Bool

    func toJSON() -> [String: Any] {
        [
            "path": path,
            "changeKind": changeKind,
            "isBinary": isBinary,
        ]
    }
}

struct AssistantChatWebCodeReviewCheckpoint: Equatable {
    let id: String
    let checkpointNumber: Int
    let createdAt: Date
    let summary: String
    let patch: String
    let turnStatus: String
    let ignoredTouchedPaths: [String]
    let changedFiles: [AssistantChatWebCodeReviewFile]
    let associatedMessageID: String?
    let associatedTurnID: String?
    let associatedUserMessageID: String?
    let associatedUserAnchorID: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "checkpointNumber": checkpointNumber,
            "createdAt": createdAt.timeIntervalSince1970 * 1000,
            "summary": summary,
            "patch": patch,
            "turnStatus": turnStatus,
            "ignoredTouchedPaths": ignoredTouchedPaths,
            "changedFiles": changedFiles.map { $0.toJSON() },
        ]
        if let associatedMessageID {
            json["associatedMessageID"] = associatedMessageID
        }
        if let associatedTurnID {
            json["associatedTurnID"] = associatedTurnID
        }
        if let associatedUserMessageID {
            json["associatedUserMessageID"] = associatedUserMessageID
        }
        if let associatedUserAnchorID {
            json["associatedUserAnchorID"] = associatedUserAnchorID
        }
        return json
    }
}

struct AssistantChatWebRewindState: Equatable {
    let kind: String
    let canStepBackward: Bool
    let redoHostMessageID: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "kind": kind,
            "canStepBackward": canStepBackward,
        ]
        if let redoHostMessageID {
            json["redoHostMessageID"] = redoHostMessageID
        }
        return json
    }
}

struct AssistantChatWebThreadNoteItem: Equatable {
    let id: String
    let title: String
    let noteType: String
    let updatedAtLabel: String?
    let ownerKind: String
    let ownerID: String
    let sourceLabel: String

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "noteType": noteType,
            "ownerKind": ownerKind,
            "ownerId": ownerID,
            "sourceLabel": sourceLabel,
        ]
        if let updatedAtLabel {
            json["updatedAtLabel"] = updatedAtLabel
        }
        return json
    }
}

struct AssistantChatWebThreadNoteAIPreview: Equatable {
    let mode: String
    let sourceKind: String
    let markdown: String
    let isError: Bool

    func toJSON() -> [String: Any] {
        [
            "mode": mode,
            "sourceKind": sourceKind,
            "markdown": markdown,
            "isError": isError,
        ]
    }
}

struct AssistantChatWebProjectNoteTransferPreview: Equatable {
    let targetProjectID: String
    let targetNoteID: String
    let targetNoteTitle: String
    let suggestedHeadingPath: [String]
    let insertedMarkdown: String
    let reason: String
    let fallbackToEnd: Bool
    let sourceFingerprint: String
    let targetFingerprint: String
    let isError: Bool
    let warningMessage: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "targetProjectId": targetProjectID,
            "targetNoteId": targetNoteID,
            "targetNoteTitle": targetNoteTitle,
            "suggestedHeadingPath": suggestedHeadingPath,
            "insertedMarkdown": insertedMarkdown,
            "reason": reason,
            "fallbackToEnd": fallbackToEnd,
            "sourceFingerprint": sourceFingerprint,
            "targetFingerprint": targetFingerprint,
            "isError": isError,
        ]
        if let warningMessage {
            json["warningMessage"] = warningMessage
        }
        return json
    }
}

struct AssistantChatWebProjectNoteTransferOutcome: Equatable {
    let id: String
    let kind: String
    let message: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "message": message,
        ]
    }
}

struct AssistantChatWebBatchSourceNoteSelection: Codable, Equatable {
    let ownerKind: String
    let ownerID: String
    let noteID: String

    private enum CodingKeys: String, CodingKey {
        case ownerKind
        case ownerID = "ownerId"
        case noteID = "noteId"
    }
}

struct AssistantChatWebBatchNotePlanSourceNote: Equatable {
    let ownerKind: String
    let ownerID: String
    let noteID: String
    let title: String
    let noteType: String
    let sourceLabel: String
    let markdown: String

    func toJSON() -> [String: Any] {
        [
            "ownerKind": ownerKind,
            "ownerId": ownerID,
            "noteId": noteID,
            "title": title,
            "noteType": noteType,
            "sourceLabel": sourceLabel,
            "markdown": markdown,
        ]
    }
}

struct AssistantChatWebBatchNotePlanResolvedTarget: Codable, Equatable {
    let kind: String
    let tempID: String?
    let ownerKind: String?
    let ownerID: String?
    let noteID: String?
    let title: String
    let sourceLabel: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case tempID = "tempId"
        case ownerKind
        case ownerID = "ownerId"
        case noteID = "noteId"
        case title
        case sourceLabel
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "kind": kind,
            "title": title,
        ]
        if let tempID {
            json["tempId"] = tempID
        }
        if let ownerKind {
            json["ownerKind"] = ownerKind
        }
        if let ownerID {
            json["ownerId"] = ownerID
        }
        if let noteID {
            json["noteId"] = noteID
        }
        if let sourceLabel {
            json["sourceLabel"] = sourceLabel
        }
        return json
    }
}

struct AssistantChatWebBatchNotePlanProposedNote: Codable, Equatable {
    let tempID: String
    let title: String
    let noteType: String
    let markdown: String
    let sourceNoteTargets: [AssistantChatWebBatchNotePlanResolvedTarget]
    let accepted: Bool

    private enum CodingKeys: String, CodingKey {
        case tempID = "tempId"
        case title
        case noteType
        case markdown
        case sourceNoteTargets
        case accepted
    }

    func toJSON() -> [String: Any] {
        [
            "tempId": tempID,
            "title": title,
            "noteType": noteType,
            "markdown": markdown,
            "sourceNoteTargets": sourceNoteTargets.map { $0.toJSON() },
            "accepted": accepted,
        ]
    }
}

struct AssistantChatWebBatchNotePlanProposedLink: Codable, Equatable {
    let fromTempID: String
    let toTarget: AssistantChatWebBatchNotePlanResolvedTarget
    let accepted: Bool

    private enum CodingKeys: String, CodingKey {
        case fromTempID = "fromTempId"
        case toTarget
        case accepted
    }

    func toJSON() -> [String: Any] {
        [
            "fromTempId": fromTempID,
            "toTarget": toTarget.toJSON(),
            "accepted": accepted,
        ]
    }
}

struct AssistantChatWebBatchNotePlanPreview: Equatable {
    let previewID: String
    let sourceNotes: [AssistantChatWebBatchNotePlanSourceNote]
    let proposedNotes: [AssistantChatWebBatchNotePlanProposedNote]
    let proposedLinks: [AssistantChatWebBatchNotePlanProposedLink]
    let graph: AssistantChatWebThreadNoteGraph?
    let warnings: [String]
    let sourceFingerprint: String
    let targetFingerprint: String
    let isError: Bool

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "previewId": previewID,
            "sourceNotes": sourceNotes.map { $0.toJSON() },
            "proposedNotes": proposedNotes.map { $0.toJSON() },
            "proposedLinks": proposedLinks.map { $0.toJSON() },
            "warnings": warnings,
            "sourceFingerprint": sourceFingerprint,
            "targetFingerprint": targetFingerprint,
            "isError": isError,
        ]
        if let graph {
            json["graph"] = graph.toJSON()
        }
        return json
    }
}

struct AssistantChatWebThreadNoteSource: Equatable {
    let ownerKind: String
    let ownerID: String
    let ownerTitle: String
    let sourceLabel: String

    func toJSON() -> [String: Any] {
        [
            "ownerKind": ownerKind,
            "ownerId": ownerID,
            "ownerTitle": ownerTitle,
            "sourceLabel": sourceLabel,
        ]
    }
}

struct AssistantChatWebThreadNoteRelationshipItem: Equatable {
    let ownerKind: String
    let ownerID: String
    let noteID: String
    let title: String
    let sourceLabel: String
    let isMissing: Bool
    let occurrenceCount: Int

    func toJSON() -> [String: Any] {
        [
            "ownerKind": ownerKind,
            "ownerId": ownerID,
            "noteId": noteID,
            "title": title,
            "sourceLabel": sourceLabel,
            "isMissing": isMissing,
            "occurrenceCount": occurrenceCount,
        ]
    }
}

struct AssistantChatWebThreadNoteGraph: Equatable {
    let mermaidCode: String
    let nodeCount: Int
    let edgeCount: Int

    func toJSON() -> [String: Any] {
        [
            "mermaidCode": mermaidCode,
            "nodeCount": nodeCount,
            "edgeCount": edgeCount,
        ]
    }
}

struct AssistantChatWebThreadNoteHistoryItem: Equatable {
    let id: String
    let title: String
    let savedAtLabel: String
    let preview: String
    let markdown: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "savedAtLabel": savedAtLabel,
            "preview": preview,
            "markdown": markdown,
        ]
    }
}

struct AssistantChatWebThreadDeletedNoteItem: Equatable {
    let id: String
    let title: String
    let deletedAtLabel: String
    let preview: String
    let markdown: String

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "deletedAtLabel": deletedAtLabel,
            "preview": preview,
            "markdown": markdown,
        ]
    }
}

struct AssistantChatWebThreadNoteState: Equatable {
    let threadID: String?
    let ownerKind: String?
    let ownerID: String?
    let ownerTitle: String
    let presentation: String
    let notesScope: String?
    let workspaceProjectID: String?
    let workspaceProjectTitle: String?
    let workspaceOwnerSubtitle: String?
    let canCreateNote: Bool
    let owningThreadID: String?
    let owningThreadTitle: String?
    let availableSources: [AssistantChatWebThreadNoteSource]
    let notes: [AssistantChatWebThreadNoteItem]
    let selectedNoteID: String?
    let selectedNoteTitle: String
    let text: String
    let isOpen: Bool
    let isExpanded: Bool
    let viewMode: String
    let hasAnyNotes: Bool
    let isSaving: Bool
    let isGeneratingAIDraft: Bool
    let isGeneratingProjectTransferPreview: Bool
    let isGeneratingBatchNotePlanPreview: Bool
    let aiDraftMode: String?
    let lastSavedAtLabel: String?
    let canEdit: Bool
    let placeholder: String
    let aiDraftPreview: AssistantChatWebThreadNoteAIPreview?
    let projectNoteTransferPreview: AssistantChatWebProjectNoteTransferPreview?
    let projectNoteTransferOutcome: AssistantChatWebProjectNoteTransferOutcome?
    let batchNotePlanPreview: AssistantChatWebBatchNotePlanPreview?
    let outgoingLinks: [AssistantChatWebThreadNoteRelationshipItem]
    let backlinks: [AssistantChatWebThreadNoteRelationshipItem]
    let graph: AssistantChatWebThreadNoteGraph?
    let canNavigateBack: Bool
    let previousLinkedNoteTitle: String?
    let historyVersions: [AssistantChatWebThreadNoteHistoryItem]
    let recentlyDeletedNotes: [AssistantChatWebThreadDeletedNoteItem]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "threadId": threadID ?? NSNull(),
            "ownerKind": ownerKind ?? NSNull(),
            "ownerId": ownerID ?? NSNull(),
            "ownerTitle": ownerTitle,
            "presentation": presentation,
            "notesScope": notesScope ?? NSNull(),
            "workspaceProjectId": workspaceProjectID ?? NSNull(),
            "workspaceProjectTitle": workspaceProjectTitle ?? NSNull(),
            "workspaceOwnerSubtitle": workspaceOwnerSubtitle ?? NSNull(),
            "canCreateNote": canCreateNote,
            "owningThreadId": owningThreadID ?? NSNull(),
            "owningThreadTitle": owningThreadTitle ?? NSNull(),
            "availableSources": availableSources.map { $0.toJSON() },
            "notes": notes.map { $0.toJSON() },
            "selectedNoteId": selectedNoteID ?? NSNull(),
            "selectedNoteTitle": selectedNoteTitle,
            "text": text,
            "isOpen": isOpen,
            "isExpanded": isExpanded,
            "viewMode": viewMode,
            "hasAnyNotes": hasAnyNotes,
            "isSaving": isSaving,
            "isGeneratingAIDraft": isGeneratingAIDraft,
            "isGeneratingProjectTransferPreview": isGeneratingProjectTransferPreview,
            "isGeneratingBatchNotePlanPreview": isGeneratingBatchNotePlanPreview,
            "aiDraftMode": aiDraftMode ?? NSNull(),
            "lastSavedAtLabel": lastSavedAtLabel ?? NSNull(),
            "canEdit": canEdit,
            "placeholder": placeholder,
            "outgoingLinks": outgoingLinks.map { $0.toJSON() },
            "backlinks": backlinks.map { $0.toJSON() },
            "graph": graph?.toJSON() ?? NSNull(),
            "canNavigateBack": canNavigateBack,
            "previousLinkedNoteTitle": previousLinkedNoteTitle ?? NSNull(),
            "historyVersions": historyVersions.map { $0.toJSON() },
            "recentlyDeletedNotes": recentlyDeletedNotes.map { $0.toJSON() },
        ]
        if let aiDraftPreview {
            json["aiDraftPreview"] = aiDraftPreview.toJSON()
        } else {
            json["aiDraftPreview"] = NSNull()
        }
        if let projectNoteTransferPreview {
            json["projectNoteTransferPreview"] = projectNoteTransferPreview.toJSON()
        } else {
            json["projectNoteTransferPreview"] = NSNull()
        }
        if let projectNoteTransferOutcome {
            json["projectNoteTransferOutcome"] = projectNoteTransferOutcome.toJSON()
        } else {
            json["projectNoteTransferOutcome"] = NSNull()
        }
        if let batchNotePlanPreview {
            json["batchNotePlanPreview"] = batchNotePlanPreview.toJSON()
        } else {
            json["batchNotePlanPreview"] = NSNull()
        }
        return json
    }
}

struct AssistantChatWebActiveWorkState: Equatable {
    let title: String
    let detail: String?
    let activeCalls: [AssistantChatWebActiveWorkItem]
    let recentCalls: [AssistantChatWebActiveWorkItem]
    let subagents: [AssistantChatWebActiveWorkSubagent]

    var hasVisibleContent: Bool {
        !activeCalls.isEmpty
            || !recentCalls.isEmpty
            || !subagents.isEmpty
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "title": title,
            "activeCalls": activeCalls.map { $0.toJSON() },
            "recentCalls": recentCalls.map { $0.toJSON() },
            "subagents": subagents.map { $0.toJSON() },
        ]
        if let detail, !detail.isEmpty {
            json["detail"] = detail
        }
        return json
    }
}

struct AssistantChatWebActiveTurnState: Equatable {
    let phase: String
    let canCancel: Bool
    let providerLabel: String?
    let hasPendingToolApproval: Bool
    let hasPendingInput: Bool

    var isActive: Bool {
        phase != "idle"
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "phase": phase,
            "canCancel": canCancel,
            "hasPendingToolApproval": hasPendingToolApproval,
            "hasPendingInput": hasPendingInput,
        ]
        if let providerLabel, !providerLabel.isEmpty {
            json["providerLabel"] = providerLabel
        }
        return json
    }
}

enum AssistantChatWebStreamEvent: Equatable {
    case replaceMessages([AssistantChatWebMessage])
    case responseTextDelta(messageID: String, text: String, isStreaming: Bool)
    case upsertMessage(message: AssistantChatWebMessage, afterMessageID: String?)
    case removeMessage(messageID: String)
    case setActiveWorkState(AssistantChatWebActiveWorkState?)
    case setTypingState(visible: Bool, title: String, detail: String)
    case setActiveTurnState(AssistantChatWebActiveTurnState?)

    func toJSON() -> [String: Any] {
        switch self {
        case .replaceMessages(let messages):
            return [
                "kind": "replaceMessages",
                "messages": messages.map { $0.toJSON() },
            ]
        case .responseTextDelta(let messageID, let text, let isStreaming):
            return [
                "kind": "responseTextDelta",
                "messageID": messageID,
                "text": text,
                "isStreaming": isStreaming,
            ]
        case .upsertMessage(let message, let afterMessageID):
            var json: [String: Any] = [
                "kind": "upsertMessage",
                "message": message.toJSON(),
            ]
            if let afterMessageID {
                json["afterMessageID"] = afterMessageID
            }
            return json
        case .removeMessage(let messageID):
            return [
                "kind": "removeMessage",
                "messageID": messageID,
            ]
        case .setActiveWorkState(let state):
            return [
                "kind": "setActiveWorkState",
                "state": state?.toJSON() ?? NSNull()
            ]
        case .setTypingState(let visible, let title, let detail):
            return [
                "kind": "setTypingState",
                "state": [
                    "visible": visible,
                    "title": title,
                    "detail": detail,
                ],
            ]
        case .setActiveTurnState(let state):
            return [
                "kind": "setActiveTurnState",
                "state": state?.toJSON() ?? NSNull(),
            ]
        }
    }
}

struct AssistantChatWebActiveWorkItem: Equatable {
    let id: String
    let title: String
    let kind: String?
    let status: String
    let statusLabel: String
    let detail: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "status": status,
            "statusLabel": statusLabel,
        ]
        if let kind, !kind.isEmpty {
            json["kind"] = kind
        }
        if let detail, !detail.isEmpty {
            json["detail"] = detail
        }
        return json
    }
}

struct AssistantChatWebActiveWorkSubagent: Equatable {
    let id: String
    let name: String
    let role: String?
    let status: String
    let statusLabel: String
    let detail: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "name": name,
            "status": status,
            "statusLabel": statusLabel,
        ]
        if let role, !role.isEmpty {
            json["role"] = role
        }
        if let detail, !detail.isEmpty {
            json["detail"] = detail
        }
        return json
    }
}

private func assistantChatWebWorkStatus(from rawStatus: String?) -> (status: String, label: String) {
    let normalized = rawStatus?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty?
        .replacingOccurrences(of: "-", with: " ")
        .lowercased()

    switch normalized {
    case "completed", "done", "succeeded", "success":
        return ("completed", "Completed")
    case "failed", "error", "errored", "interrupted", "cancelled", "canceled":
        return ("failed", "Needs Attention")
    case "waiting":
        return ("running", "Waiting")
    case "pending":
        return ("running", "Pending")
    case "in progress", "inprogress":
        return ("running", "Running")
    case let value? where !value.isEmpty:
        return ("running", value.capitalized)
    default:
        return ("running", "Running")
    }
}

private func assistantChatWebWorkKind(from rawKind: String?) -> String? {
    guard let normalized = rawKind?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty else {
        return nil
    }

    switch normalized {
    case "collabAgentToolCall":
        return "subagent"
    default:
        return normalized
    }
}

extension AssistantChatWebActiveWorkItem {
    init(toolCall: AssistantToolCallState) {
        let resolvedStatus = assistantChatWebWorkStatus(from: toolCall.status)
        self.init(
            id: toolCall.id,
            title: toolCall.title,
            kind: assistantChatWebWorkKind(from: toolCall.kind),
            status: resolvedStatus.status,
            statusLabel: resolvedStatus.label,
            detail: toolCall.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
    }
}

extension AssistantChatWebActiveWorkSubagent {
    init(subagent: SubagentState) {
        let resolvedStatus = assistantChatWebWorkStatus(from: subagent.statusText)
        self.init(
            id: subagent.id,
            name: subagent.displayName,
            role: subagent.roleLabel,
            status: resolvedStatus.status,
            statusLabel: subagent.statusText,
            detail: subagent.promptPreview
        )
    }
}

struct AssistantChatWebThreadNoteCommand {
    let type: String
    let threadID: String?
    let ownerKind: String?
    let ownerID: String?
    let noteID: String?
    let historyVersionID: String?
    let deletedNoteID: String?
    let text: String?
    let title: String?
    let isOpen: Bool?
    let isExpanded: Bool?
    let viewMode: String?
    let selectedText: String?
    let requestKind: String?
    let draftMode: String?
    let currentDraftMarkdown: String?
    let styleInstruction: String?
    let renderError: String?
    let viewportRect: CGRect?
    let scope: String?
    let sourceSelectionFrom: Int?
    let sourceSelectionTo: Int?
    let targetProjectID: String?
    let targetNoteID: String?
    let placementChoice: String?
    let transferMode: String?
    let sourceFingerprint: String?
    let targetFingerprint: String?
    let sourceNoteTitle: String?
    let sourceTextAfterMove: String?
    let requestID: String?
    let outputMode: String?
    let captureMode: String?
    let captureSegmentCount: Int?
    let filename: String?
    let mimeType: String?
    let dataURL: String?
    let previewID: String?
    let sourceNotes: [AssistantChatWebBatchSourceNoteSelection]
    let proposedNotes: [AssistantChatWebBatchNotePlanProposedNote]
    let proposedLinks: [AssistantChatWebBatchNotePlanProposedLink]

    init(
        type: String,
        threadID: String?,
        ownerKind: String?,
        ownerID: String?,
        noteID: String?,
        historyVersionID: String?,
        deletedNoteID: String?,
        text: String?,
        title: String?,
        isOpen: Bool?,
        isExpanded: Bool?,
        viewMode: String?,
        selectedText: String?,
        requestKind: String?,
        draftMode: String?,
        currentDraftMarkdown: String?,
        styleInstruction: String?,
        renderError: String?,
        viewportRect: CGRect?,
        scope: String?,
        sourceSelectionFrom: Int?,
        sourceSelectionTo: Int?,
        targetProjectID: String?,
        targetNoteID: String?,
        placementChoice: String?,
        transferMode: String?,
        sourceFingerprint: String?,
        targetFingerprint: String?,
        sourceNoteTitle: String?,
        sourceTextAfterMove: String?,
        requestID: String?,
        outputMode: String?,
        captureMode: String?,
        captureSegmentCount: Int?,
        filename: String?,
        mimeType: String?,
        dataURL: String?,
        previewID: String?,
        sourceNotes: [AssistantChatWebBatchSourceNoteSelection],
        proposedNotes: [AssistantChatWebBatchNotePlanProposedNote],
        proposedLinks: [AssistantChatWebBatchNotePlanProposedLink]
    ) {
        self.type = type
        self.threadID = threadID
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.noteID = noteID
        self.historyVersionID = historyVersionID
        self.deletedNoteID = deletedNoteID
        self.text = text
        self.title = title
        self.isOpen = isOpen
        self.isExpanded = isExpanded
        self.viewMode = viewMode
        self.selectedText = selectedText
        self.requestKind = requestKind
        self.draftMode = draftMode
        self.currentDraftMarkdown = currentDraftMarkdown
        self.styleInstruction = styleInstruction
        self.renderError = renderError
        self.viewportRect = viewportRect
        self.scope = scope
        self.sourceSelectionFrom = sourceSelectionFrom
        self.sourceSelectionTo = sourceSelectionTo
        self.targetProjectID = targetProjectID
        self.targetNoteID = targetNoteID
        self.placementChoice = placementChoice
        self.transferMode = transferMode
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.sourceNoteTitle = sourceNoteTitle
        self.sourceTextAfterMove = sourceTextAfterMove
        self.requestID = requestID
        self.outputMode = outputMode
        self.captureMode = captureMode
        self.captureSegmentCount = captureSegmentCount
        self.filename = filename
        self.mimeType = mimeType
        self.dataURL = dataURL
        self.previewID = previewID
        self.sourceNotes = sourceNotes
        self.proposedNotes = proposedNotes
        self.proposedLinks = proposedLinks
    }

    init?(body: Any) {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }
        self.type = type
        self.threadID = (payload["threadId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.ownerKind = (payload["ownerKind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.ownerID = (payload["ownerId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.noteID = (payload["noteId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.historyVersionID = (payload["historyVersionId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.deletedNoteID = (payload["deletedNoteId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.text = payload["text"] as? String
        self.title = payload["title"] as? String
        self.isOpen = payload["isOpen"] as? Bool
        self.isExpanded = payload["isExpanded"] as? Bool
        self.viewMode = payload["viewMode"] as? String
        self.selectedText = payload["selectedText"] as? String
        self.requestKind = payload["requestKind"] as? String
        self.draftMode = payload["draftMode"] as? String
        self.currentDraftMarkdown = payload["currentDraftMarkdown"] as? String
        self.styleInstruction = payload["styleInstruction"] as? String
        self.renderError = payload["renderError"] as? String
        self.scope = (payload["scope"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.sourceSelectionFrom = (payload["sourceSelectionFrom"] as? NSNumber)?.intValue
        self.sourceSelectionTo = (payload["sourceSelectionTo"] as? NSNumber)?.intValue
        self.targetProjectID = (payload["targetProjectId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.targetNoteID = (payload["targetNoteId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.placementChoice = (payload["placementChoice"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.transferMode = (payload["transferMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.sourceFingerprint = (payload["sourceFingerprint"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.targetFingerprint = (payload["targetFingerprint"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.sourceNoteTitle = payload["sourceNoteTitle"] as? String
        self.sourceTextAfterMove = payload["sourceTextAfterMove"] as? String
        self.requestID = (payload["requestId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.outputMode = (payload["outputMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.captureMode = (payload["captureMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.captureSegmentCount = (payload["captureSegmentCount"] as? NSNumber)?.intValue
        self.filename = (payload["filename"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.mimeType = (payload["mimeType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.dataURL = (payload["dataUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.previewID = (payload["previewId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
        self.sourceNotes = Self.decodePayloadArray(
            AssistantChatWebBatchSourceNoteSelection.self,
            from: payload["sourceNotes"]
        ) ?? []
        self.proposedNotes = Self.decodePayloadArray(
            AssistantChatWebBatchNotePlanProposedNote.self,
            from: payload["proposedNotes"]
        ) ?? []
        self.proposedLinks = Self.decodePayloadArray(
            AssistantChatWebBatchNotePlanProposedLink.self,
            from: payload["proposedLinks"]
        ) ?? []
        if let rectInfo = payload["rect"] as? [String: Any] {
            self.viewportRect = CGRect(
                x: rectInfo["x"] as? Double ?? 0,
                y: rectInfo["y"] as? Double ?? 0,
                width: rectInfo["width"] as? Double ?? 0,
                height: rectInfo["height"] as? Double ?? 0
            )
        } else {
            self.viewportRect = nil
        }
    }

    private static func decodePayloadArray<T: Decodable>(
        _ type: T.Type,
        from value: Any?
    ) -> [T]? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []) else {
            return nil
        }
        return try? JSONDecoder().decode([T].self, from: data)
    }
}

struct AssistantChatWebThreadNoteImageUploadResult: Equatable {
    let requestID: String
    let ok: Bool
    let message: String?
    let url: String?
    let relativePath: String?

    func toJSON() -> [String: Any] {
        [
            "requestId": requestID,
            "ok": ok,
            "message": message ?? NSNull(),
            "url": url ?? NSNull(),
            "relativePath": relativePath ?? NSNull(),
        ]
    }
}

struct AssistantChatWebThreadNoteScreenshotCaptureResult: Equatable {
    let requestID: String
    let ok: Bool
    let cancelled: Bool
    let message: String?
    let captureMode: String?
    let segmentCount: Int?
    let filename: String?
    let mimeType: String?
    let dataURL: String?

    func toJSON() -> [String: Any] {
        [
            "requestId": requestID,
            "ok": ok,
            "cancelled": cancelled,
            "message": message ?? NSNull(),
            "captureMode": captureMode ?? NSNull(),
            "segmentCount": segmentCount ?? NSNull(),
            "filename": filename ?? NSNull(),
            "mimeType": mimeType ?? NSNull(),
            "dataUrl": dataURL ?? NSNull(),
        ]
    }
}

struct AssistantChatWebThreadNoteScreenshotProcessingResult: Equatable {
    let requestID: String
    let ok: Bool
    let message: String?
    let outputMode: String?
    let markdown: String?
    let rawText: String?
    let usedVision: Bool

    func toJSON() -> [String: Any] {
        [
            "requestId": requestID,
            "ok": ok,
            "message": message ?? NSNull(),
            "outputMode": outputMode ?? NSNull(),
            "markdown": markdown ?? NSNull(),
            "rawText": rawText ?? NSNull(),
            "usedVision": usedVision,
        ]
    }
}

struct AssistantChatWebRuntimeBackendOption: Equatable {
    let id: String
    let label: String
    let isSelected: Bool
    let isDisabled: Bool

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "label": label,
            "isSelected": isSelected,
            "isDisabled": isDisabled,
        ]
    }
}

struct AssistantChatWebRuntimePanel: Equatable {
    let tone: String
    let statusSummary: String
    let statusDetail: String?
    let accountSummary: String?
    let backendHelpText: String?
    let backends: [AssistantChatWebRuntimeBackendOption]
    let setupButtonTitle: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "tone": tone,
            "statusSummary": statusSummary,
            "backends": backends.map { $0.toJSON() },
        ]
        if let statusDetail {
            json["statusDetail"] = statusDetail
        }
        if let accountSummary {
            json["accountSummary"] = accountSummary
        }
        if let backendHelpText {
            json["backendHelpText"] = backendHelpText
        }
        if let setupButtonTitle {
            json["setupButtonTitle"] = setupButtonTitle
        }
        return json
    }
}

struct AssistantChatWebCodeReviewPanel: Equatable {
    let repoLabel: String
    let repoRootPath: String
    let currentCheckpointPosition: Int
    let selectedCheckpointID: String
    let hasActiveTurn: Bool
    let actionsLocked: Bool
    let embedded: Bool
    let checkpoints: [AssistantChatWebCodeReviewCheckpoint]

    func toJSON() -> [String: Any] {
        [
            "repoLabel": repoLabel,
            "repoRootPath": repoRootPath,
            "currentCheckpointPosition": currentCheckpointPosition,
            "selectedCheckpointID": selectedCheckpointID,
            "hasActiveTurn": hasActiveTurn,
            "actionsLocked": actionsLocked,
            "embedded": embedded,
            "checkpoints": checkpoints.map { $0.toJSON() },
        ]
    }
}

extension AssistantChatWebCodeReviewPanel {
    init?(
        state: AssistantCodeReviewPanelState, hasActiveTurn: Bool, actionsLocked: Bool = false,
        embedded: Bool = false
    ) {
        guard !state.checkpoints.isEmpty else { return nil }
        self.init(
            repoLabel: state.repoLabel,
            repoRootPath: state.repoRootPath,
            currentCheckpointPosition: state.currentCheckpointPosition,
            selectedCheckpointID: state.selectedCheckpointID,
            hasActiveTurn: hasActiveTurn,
            actionsLocked: actionsLocked,
            embedded: embedded,
            checkpoints: state.checkpoints.map { checkpoint in
                AssistantChatWebCodeReviewCheckpoint(
                    id: checkpoint.id,
                    checkpointNumber: checkpoint.checkpointNumber,
                    createdAt: checkpoint.createdAt,
                    summary: checkpoint.summary,
                    patch: checkpoint.patch,
                    turnStatus: checkpoint.turnStatus.rawValue,
                    ignoredTouchedPaths: checkpoint.ignoredTouchedPaths,
                    changedFiles: checkpoint.changedFiles.map { file in
                        AssistantChatWebCodeReviewFile(
                            path: file.path,
                            changeKind: file.changeKind.rawValue,
                            isBinary: file.isBinary
                        )
                    },
                    associatedMessageID: checkpoint.associatedMessageID,
                    associatedTurnID: checkpoint.associatedTurnID,
                    associatedUserMessageID: checkpoint.associatedUserMessageID,
                    associatedUserAnchorID: checkpoint.associatedUserAnchorID
                )
            }
        )
    }

    init?(
        trackingState: AssistantCodeTrackingState, hasActiveTurn: Bool, actionsLocked: Bool = false,
        embedded: Bool = false
    ) {
        guard trackingState.availability == .available,
            let repoRootPath = trackingState.repoRootPath,
            let repoLabel = trackingState.repoLabel,
            !trackingState.checkpoints.isEmpty
        else {
            return nil
        }

        let nextCheckpointID =
            trackingState.checkpoints.indices.contains(trackingState.currentCheckpointPosition + 1)
            ? trackingState.checkpoints[trackingState.currentCheckpointPosition + 1].id
            : nil
        let selectedCheckpointID =
            trackingState.currentCheckpoint?.id
            ?? nextCheckpointID
            ?? trackingState.latestCheckpoint?.id
            ?? trackingState.checkpoints.last?.id
        guard let selectedCheckpointID else { return nil }

        self.init(
            repoLabel: repoLabel,
            repoRootPath: repoRootPath,
            currentCheckpointPosition: trackingState.currentCheckpointPosition,
            selectedCheckpointID: selectedCheckpointID,
            hasActiveTurn: hasActiveTurn,
            actionsLocked: actionsLocked,
            embedded: embedded,
            checkpoints: trackingState.checkpoints.map { checkpoint in
                AssistantChatWebCodeReviewCheckpoint(
                    id: checkpoint.id,
                    checkpointNumber: checkpoint.checkpointNumber,
                    createdAt: checkpoint.createdAt,
                    summary: checkpoint.summary,
                    patch: checkpoint.patch,
                    turnStatus: checkpoint.turnStatus.rawValue,
                    ignoredTouchedPaths: checkpoint.ignoredTouchedPaths,
                    changedFiles: checkpoint.changedFiles.map { file in
                        AssistantChatWebCodeReviewFile(
                            path: file.path,
                            changeKind: file.changeKind.rawValue,
                            isBinary: file.isBinary
                        )
                    },
                    associatedMessageID: checkpoint.associatedMessageID,
                    associatedTurnID: checkpoint.associatedTurnID,
                    associatedUserMessageID: checkpoint.associatedUserMessageID,
                    associatedUserAnchorID: checkpoint.associatedUserAnchorID
                )
            }
        )
    }
}

struct AssistantChatWebRenderContext {
    let pendingPermissionRequest: AssistantPermissionRequest?
    let activeRuntimeSessionID: String?
    let hasActiveTurn: Bool
    let sessionStatusByNormalizedID: [String: AssistantSessionStatus]
    let sessionWorkingDirectoryByNormalizedID: [String: String]

    func sessionStatus(for sessionID: String?) -> AssistantSessionStatus? {
        guard
            let normalizedSessionID = sessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !normalizedSessionID.isEmpty
        else {
            return nil
        }
        return sessionStatusByNormalizedID[normalizedSessionID]
    }

    func shouldShowLiveRunningState(for sessionID: String?) -> Bool {
        assistantSessionOwnsLiveRuntimeState(
            sessionID: sessionID,
            activeRuntimeSessionID: activeRuntimeSessionID
        ) && hasActiveTurn
    }

    func sessionWorkingDirectory(for sessionID: String?) -> String? {
        guard
            let normalizedSessionID = sessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !normalizedSessionID.isEmpty
        else {
            return nil
        }
        return sessionWorkingDirectoryByNormalizedID[normalizedSessionID]
    }
}

private func assistantChatWebDetailSections(
    from rawDetails: String?
) -> [AssistantChatWebDetailSection] {
    guard
        let trimmed = rawDetails?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .assistantNonEmpty
    else {
        return []
    }

    guard let separatorRange = trimmed.range(of: "\n\n") else {
        return [
            AssistantChatWebDetailSection(
                title: "Details",
                text: trimmed
            )
        ]
    }

    let request = String(trimmed[..<separatorRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let response = String(trimmed[separatorRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var sections: [AssistantChatWebDetailSection] = []
    if let request = request.assistantNonEmpty {
        sections.append(
            AssistantChatWebDetailSection(
                title: "Request",
                text: request
            )
        )
    }
    if let response = response.assistantNonEmpty {
        sections.append(
            AssistantChatWebDetailSection(
                title: "Response",
                text: response
            )
        )
    }

    return sections
}

private func assistantPermissionActivityPresentation(
    text: String?,
    request: AssistantPermissionRequest?
) -> (title: String, detail: String?, detailSections: [AssistantChatWebDetailSection]?) {
    let title =
        request?.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines).assistantNonEmpty
        ?? "Permission Request"
    let rawText = text?.trimmingCharacters(in: .whitespacesAndNewlines).assistantNonEmpty
    let summaryText = request?.rawPayloadSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        .assistantNonEmpty
    let rationaleText = request?.rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
        .assistantNonEmpty

    let inlineCandidates: [String?] = [summaryText, rationaleText, rawText]
    let preferredInlineDetail = inlineCandidates.compactMap { candidate -> String? in
        guard let candidate else { return nil }
        guard !assistantLooksLikeUnifiedDiff(candidate), !candidate.contains("\n") else {
            return nil
        }
        return assistantFormattedActivityDetailText(candidate)
    }.first

    let shouldSummarizeAsFileChanges =
        request?.toolKind == "fileChange"
        || assistantLooksLikeUnifiedDiff(rawText)
        || assistantLooksLikeUnifiedDiff(summaryText)

    let detail =
        preferredInlineDetail
        ?? (shouldSummarizeAsFileChanges ? "Review the proposed file changes." : nil)

    let expandedCandidates: [String?] = [rawText, summaryText, rationaleText]
    let expandedDetailsSource = expandedCandidates.compactMap { candidate -> String? in
        guard let candidate else { return nil }
        if assistantLooksLikeUnifiedDiff(candidate) || candidate.count > 160
            || candidate.contains("\n")
        {
            return candidate
        }
        return nil
    }.first

    let detailSections = assistantChatWebDetailSections(from: expandedDetailsSource)
    return (
        title,
        detail,
        detailSections.isEmpty ? nil : detailSections
    )
}

private func assistantChatWebActivityTargets(
    from openTargets: [AssistantActivityOpenTarget]
) -> [AssistantChatWebActivityTarget] {
    openTargets.map {
        AssistantChatWebActivityTarget(
            kind: $0.kind.rawValue,
            label: $0.label,
            detail: $0.detail
        )
    }
}

// MARK: - Coordinator

final class AssistantChatWebCoordinator: NSObject, WKScriptMessageHandler {
    var onScrollStateChanged: (Bool, Bool) -> Void
    var onLoadOlderHistory: () -> Void
    var onLoadActivityDetails: (String) -> Void
    var onCollapseActivityDetails: (String) -> Void
    var onSelectRuntimeBackend: (String) -> Void
    var onOpenRuntimeSettings: () -> Void
    var onUndoMessage: (String) -> Void
    var onEditMessage: (String) -> Void
    var onUndoCodeCheckpoint: () -> Void
    var onRedoHistoryMutation: () -> Void
    var onRestoreCodeCheckpoint: (String) -> Void
    var onCloseCodeReviewPanel: () -> Void
    var onThreadNoteCommand: (AssistantChatWebThreadNoteCommand, AssistantChatWebContainerView?) -> Void
    var onTextSelected: ((String, String, String, CGRect) -> Void)?  // selectedText, messageID, parentText, screenRect
    weak var webViewContainer: AssistantChatWebContainerView?
    private let imageQuickLookController = AssistantChatImageQuickLookController()

    init(
        onScrollStateChanged: @escaping (Bool, Bool) -> Void,
        onLoadOlderHistory: @escaping () -> Void,
        onLoadActivityDetails: @escaping (String) -> Void,
        onCollapseActivityDetails: @escaping (String) -> Void,
        onSelectRuntimeBackend: @escaping (String) -> Void,
        onOpenRuntimeSettings: @escaping () -> Void,
        onUndoMessage: @escaping (String) -> Void,
        onEditMessage: @escaping (String) -> Void,
        onUndoCodeCheckpoint: @escaping () -> Void,
        onRedoHistoryMutation: @escaping () -> Void,
        onRestoreCodeCheckpoint: @escaping (String) -> Void,
        onCloseCodeReviewPanel: @escaping () -> Void,
        onThreadNoteCommand: @escaping (AssistantChatWebThreadNoteCommand, AssistantChatWebContainerView?) -> Void
    ) {
        self.onScrollStateChanged = onScrollStateChanged
        self.onLoadOlderHistory = onLoadOlderHistory
        self.onLoadActivityDetails = onLoadActivityDetails
        self.onCollapseActivityDetails = onCollapseActivityDetails
        self.onSelectRuntimeBackend = onSelectRuntimeBackend
        self.onOpenRuntimeSettings = onOpenRuntimeSettings
        self.onUndoMessage = onUndoMessage
        self.onEditMessage = onEditMessage
        self.onUndoCodeCheckpoint = onUndoCodeCheckpoint
        self.onRedoHistoryMutation = onRedoHistoryMutation
        self.onRestoreCodeCheckpoint = onRestoreCodeCheckpoint
        self.onCloseCodeReviewPanel = onCloseCodeReviewPanel
        self.onThreadNoteCommand = onThreadNoteCommand
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "scrollState":
            if let body = message.body as? [String: Any],
                let isPinned = body["isPinned"] as? Bool,
                let isScrolledUp = body["isScrolledUp"] as? Bool
            {
                DispatchQueue.main.async { [self] in
                    onScrollStateChanged(isPinned, isScrolledUp)
                }
            }
        case "loadOlderHistory":
            DispatchQueue.main.async { [self] in
                onLoadOlderHistory()
            }
        case "loadActivityDetails":
            if let renderItemID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onLoadActivityDetails(renderItemID)
                }
            }
        case "collapseActivityDetails":
            if let renderItemID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onCollapseActivityDetails(renderItemID)
                }
            }
        case "selectRuntimeBackend":
            if let backendID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onSelectRuntimeBackend(backendID)
                }
            }
        case "openRuntimeSettings":
            DispatchQueue.main.async { [self] in
                onOpenRuntimeSettings()
            }
        case "linkClicked":
            if let urlString = message.body as? String {
                handleLinkClick(urlString)
            }
        case "copyText":
            if let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "openImage":
            if let body = message.body as? [String: Any],
                let dataURLString = body["dataUrl"] as? String
            {
                let suggestedName = body["suggestedName"] as? String
                openImageInQuickLook(dataURLString: dataURLString, suggestedName: suggestedName)
            }
        case "textSelected":
            if message.body is NSNull {
                DispatchQueue.main.async { [self] in
                    onTextSelected?("", "", "", .zero)
                }
            } else if let body = message.body as? [String: Any],
                let selectedText = body["selectedText"] as? String,
                let messageID = body["messageID"] as? String,
                let parentText = body["parentMessageText"] as? String,
                let rectInfo = body["rect"] as? [String: Double]
            {
                // Rect from JS is relative to WKWebView viewport
                let viewRect = CGRect(
                    x: rectInfo["x"] ?? 0,
                    y: rectInfo["y"] ?? 0,
                    width: rectInfo["width"] ?? 0,
                    height: rectInfo["height"] ?? 0
                )
                // Convert to screen coordinates using the webView
                DispatchQueue.main.async { [self] in
                    let screenRect = webViewContainer?.convertToScreen(viewRect) ?? viewRect
                    onTextSelected?(selectedText, messageID, parentText, screenRect)
                }
            }
        case "undoMessage":
            if let anchorID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onUndoMessage(anchorID)
                }
            }
        case "editMessage":
            if let anchorID = message.body as? String {
                DispatchQueue.main.async { [self] in
                    onEditMessage(anchorID)
                }
            }
        case "undoCodeCheckpoint":
            CrashReporter.logInfo("Assistant chat web received undoCodeCheckpoint")
            DispatchQueue.main.async { [self] in
                onUndoCodeCheckpoint()
            }
        case "redoHistoryMutation":
            CrashReporter.logInfo("Assistant chat web received redoHistoryMutation")
            DispatchQueue.main.async { [self] in
                onRedoHistoryMutation()
            }
        case "restoreCodeCheckpoint":
            if let checkpointID = message.body as? String {
                CrashReporter.logInfo(
                    "Assistant chat web received restoreCodeCheckpoint checkpointID=\(checkpointID)"
                )
                DispatchQueue.main.async { [self] in
                    onRestoreCodeCheckpoint(checkpointID)
                }
            }
        case "closeCodeReviewPanel":
            DispatchQueue.main.async { [self] in
                onCloseCodeReviewPanel()
            }
        case "threadNoteCommand":
            if let command = AssistantChatWebThreadNoteCommand(body: message.body) {
                DispatchQueue.main.async { [self] in
                    onThreadNoteCommand(command, webViewContainer)
                }
            }
        default:
            break
        }
    }

    func handleLinkClick(_ urlString: String) {
        if let target = AssistantNoteLinkCodec.parseTarget(from: urlString) {
            let command = AssistantChatWebThreadNoteCommand(
                type: "openLinkedNote",
                threadID: nil,
                ownerKind: target.ownerKind.rawValue,
                ownerID: target.ownerID,
                noteID: target.noteID,
                historyVersionID: nil,
                deletedNoteID: nil,
                text: nil,
                title: nil,
                isOpen: nil,
                isExpanded: nil,
                viewMode: nil,
                selectedText: nil,
                requestKind: nil,
                draftMode: nil,
                currentDraftMarkdown: nil,
                styleInstruction: nil,
                renderError: nil,
                viewportRect: nil,
                scope: nil,
                sourceSelectionFrom: nil,
                sourceSelectionTo: nil,
                targetProjectID: nil,
                targetNoteID: nil,
                placementChoice: nil,
                transferMode: nil,
                sourceFingerprint: nil,
                targetFingerprint: nil,
                sourceNoteTitle: nil,
                sourceTextAfterMove: nil,
                requestID: nil,
                outputMode: nil,
                captureMode: nil,
                captureSegmentCount: nil,
                filename: nil,
                mimeType: nil,
                dataURL: nil,
                previewID: nil,
                sourceNotes: [],
                proposedNotes: [],
                proposedLinks: []
            )
            DispatchQueue.main.async { [self] in
                onThreadNoteCommand(command, webViewContainer)
            }
            return
        }

        AssistantWorkspaceFileOpener.openLink(urlString)
    }

    private func openImageInQuickLook(dataURLString: String, suggestedName: String?) {
        guard let imageFile = temporaryImageFile(from: dataURLString, suggestedName: suggestedName)
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.imageQuickLookController.present(
                fileURL: imageFile,
                title: suggestedName,
                parentWindow: self?.webViewContainer?.window
            )
        }
    }

    private func temporaryImageFile(from dataURLString: String, suggestedName: String?) -> URL? {
        guard let commaIndex = dataURLString.firstIndex(of: ",") else { return nil }

        let metadata = String(dataURLString[..<commaIndex])
        let encodedPayload = String(dataURLString[dataURLString.index(after: commaIndex)...])

        guard metadata.hasPrefix("data:"),
            metadata.contains(";base64"),
            let imageData = Data(base64Encoded: encodedPayload)
        else {
            return nil
        }

        let mimeType = String(metadata.dropFirst(5).split(separator: ";").first ?? "")
        let fileExtension: String
        switch mimeType.lowercased() {
        case "image/png":
            fileExtension = "png"
        case "image/jpeg", "image/jpg":
            fileExtension = "jpg"
        case "image/gif":
            fileExtension = "gif"
        case "image/tiff":
            fileExtension = "tiff"
        case "image/webp":
            fileExtension = "webp"
        default:
            fileExtension = "png"
        }

        let baseName =
            (suggestedName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .assistantNonEmpty) ?? "chat-image"
        let uniqueName = "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"

        let previewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAssist-PreviewImages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: previewsDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = previewsDirectory.appendingPathComponent(uniqueName)
        do {
            try imageData.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            return nil
        }
    }
}

@MainActor
private final class AssistantChatImageQuickLookController: NSWindowController {
    // swiftlint:disable:next force_unwrapping
    private let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)!
    private let containerView = NSVisualEffectView(frame: .zero)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        super.init(window: panel)

        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 16
        containerView.layer?.masksToBounds = true

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.autostarts = false
        previewView.shouldCloseWithWindow = false

        containerView.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(
                equalTo: containerView.leadingAnchor, constant: 14),
            previewView.trailingAnchor.constraint(
                equalTo: containerView.trailingAnchor, constant: -14),
            previewView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),
            previewView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -14),
        ])

        panel.contentView = containerView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(fileURL: URL, title: String?, parentWindow: NSWindow?) {
        previewView.previewItem = fileURL as NSURL
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).assistantNonEmpty {
            window?.title = title
        } else {
            window?.title = fileURL.lastPathComponent
        }

        resizeWindowToFitImage(at: fileURL, parentWindow: parentWindow)

        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func resizeWindowToFitImage(at fileURL: URL, parentWindow: NSWindow?) {
        guard let window else { return }

        let imageSize = NSImage(contentsOf: fileURL)?.size ?? NSSize(width: 960, height: 640)
        let clampedWidth = min(max(imageSize.width + 80, 460), 980)
        let clampedHeight = min(max(imageSize.height + 80, 320), 760)
        let targetSize = NSSize(width: clampedWidth, height: clampedHeight)

        if let parentFrame = parentWindow?.frame {
            let origin = NSPoint(
                x: parentFrame.midX - targetSize.width / 2,
                y: parentFrame.midY - targetSize.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: targetSize), display: false)
        } else {
            window.setContentSize(targetSize)
            window.center()
        }
    }
}

// MARK: - Container View

final class AssistantChatWebContainerView: NSView, WKNavigationDelegate, WKUIDelegate {
    var coordinator: AssistantChatWebCoordinator

    private let webView: WKWebView
    private var noteAssetSchemeHandler: AssistantNoteAssetURLSchemeHandler?
    private var isReady = false
    private var pendingMessages: [AssistantChatWebMessage]?
    private var pendingTyping: (Bool, String, String)?
    private var pendingTextScale: CGFloat?
    private var pendingCanLoadOlderHistory: Bool?
    private var pendingRuntimePanel: AssistantChatWebRuntimePanel?
    private var pendingReviewPanel: AssistantChatWebCodeReviewPanel?
    private var pendingRewindState: AssistantChatWebRewindState?
    private var pendingThreadNoteState: AssistantChatWebThreadNoteState?
    private var pendingThreadNoteImageUploadResults: [AssistantChatWebThreadNoteImageUploadResult] = []
    private var pendingThreadNoteScreenshotCaptureResults: [AssistantChatWebThreadNoteScreenshotCaptureResult] = []
    private var pendingThreadNoteScreenshotProcessingResults: [AssistantChatWebThreadNoteScreenshotProcessingResult] = []
    private var pendingActiveWorkState: AssistantChatWebActiveWorkState?
    private var pendingActiveTurnState: AssistantChatWebActiveTurnState?
    private var pendingAccentCSS: String?
    private var requestedMessages: [AssistantChatWebMessage] = []
    private var requestedTyping: (Bool, String, String) = (false, "", "")
    private var requestedActiveWorkState: AssistantChatWebActiveWorkState?
    private var requestedActiveTurnState: AssistantChatWebActiveTurnState?
    private var lastAppliedTyping: (Bool, String, String)?
    private var lastAppliedTextScale: CGFloat?
    private var lastAppliedCanLoadOlderHistory: Bool?
    private var lastAppliedRuntimePanel: AssistantChatWebRuntimePanel?
    private var hasAppliedRuntimePanel = false
    private var lastAppliedReviewPanel: AssistantChatWebCodeReviewPanel?
    private var hasAppliedReviewPanel = false
    private var lastAppliedRewindState: AssistantChatWebRewindState?
    private var hasAppliedRewindState = false
    private var lastAppliedThreadNoteState: AssistantChatWebThreadNoteState?
    private var hasAppliedThreadNoteState = false
    private var lastAppliedActiveWorkState: AssistantChatWebActiveWorkState?
    private var hasAppliedActiveWorkState = false
    private var lastAppliedActiveTurnState: AssistantChatWebActiveTurnState?
    private var hasAppliedActiveTurnState = false
    private var lastAppliedAccentCSS: String?

    // Throttling for streaming updates
    private var throttleTimer: Timer?
    private var lastRenderedMessages: [AssistantChatWebMessage] = []
    private static let throttleInterval: TimeInterval = 1.0 / 60.0

    init(
        coordinator: AssistantChatWebCoordinator,
        noteAssetResolver: AssistantNoteAssetURLSchemeHandler.Resolver? = nil
    ) {
        self.coordinator = coordinator

        let config = WKWebViewConfiguration()
        if let noteAssetResolver {
            let schemeHandler = AssistantNoteAssetURLSchemeHandler(resolver: noteAssetResolver)
            config.setURLSchemeHandler(schemeHandler, forURLScheme: AssistantNoteAssetSupport.urlScheme)
            self.noteAssetSchemeHandler = schemeHandler
        }
        let uc = config.userContentController
        uc.add(coordinator, name: "scrollState")
        uc.add(coordinator, name: "loadOlderHistory")
        uc.add(coordinator, name: "loadActivityDetails")
        uc.add(coordinator, name: "collapseActivityDetails")
        uc.add(coordinator, name: "selectRuntimeBackend")
        uc.add(coordinator, name: "openRuntimeSettings")
        uc.add(coordinator, name: "linkClicked")
        uc.add(coordinator, name: "copyText")
        uc.add(coordinator, name: "openImage")
        uc.add(coordinator, name: "textSelected")
        uc.add(coordinator, name: "undoMessage")
        uc.add(coordinator, name: "editMessage")
        uc.add(coordinator, name: "undoCodeCheckpoint")
        uc.add(coordinator, name: "redoHistoryMutation")
        uc.add(coordinator, name: "restoreCodeCheckpoint")
        uc.add(coordinator, name: "closeCodeReviewPanel")
        uc.add(coordinator, name: "threadNoteCommand")

        let webView = AssistantInteractiveWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true

        webView.navigationDelegate = self
        webView.uiDelegate = self
        addSubview(webView)

        // Ready handler
        let readyHandler = ReadyHandler { [weak self] in
            guard let self else { return }
            self.isReady = true
            if let msgs = self.pendingMessages {
                self.sendMessages(msgs)
                self.pendingMessages = nil
            }
            if let t = self.pendingTyping {
                self.sendTypingIndicator(t.0, title: t.1, detail: t.2)
                self.pendingTyping = nil
            }
            if let s = self.pendingTextScale {
                self.sendTextScale(s)
                self.pendingTextScale = nil
            }
            if let js = self.pendingAccentCSS {
                self.webView.evaluateJavaScript(js, completionHandler: nil)
                self.pendingAccentCSS = nil
            }
            if let canLoadOlderHistory = self.pendingCanLoadOlderHistory {
                self.webView.evaluateJavaScript(
                    "chatBridge.setCanLoadOlder(\(canLoadOlderHistory))", completionHandler: nil)
                self.pendingCanLoadOlderHistory = nil
            }
            if let runtimePanel = self.pendingRuntimePanel {
                self.sendRuntimePanel(runtimePanel)
                self.pendingRuntimePanel = nil
            }
            if let reviewPanel = self.pendingReviewPanel {
                self.sendReviewPanel(reviewPanel)
                self.pendingReviewPanel = nil
            }
            if let rewindState = self.pendingRewindState {
                self.sendRewindState(rewindState)
                self.pendingRewindState = nil
            }
            if let threadNoteState = self.pendingThreadNoteState {
                self.sendThreadNoteState(threadNoteState)
                self.pendingThreadNoteState = nil
            }
            if !self.pendingThreadNoteImageUploadResults.isEmpty {
                let pendingResults = self.pendingThreadNoteImageUploadResults
                self.pendingThreadNoteImageUploadResults.removeAll()
                for result in pendingResults {
                    self.sendThreadNoteImageUploadResult(result)
                }
            }
            if !self.pendingThreadNoteScreenshotCaptureResults.isEmpty {
                let pendingResults = self.pendingThreadNoteScreenshotCaptureResults
                self.pendingThreadNoteScreenshotCaptureResults.removeAll()
                for result in pendingResults {
                    self.sendThreadNoteScreenshotCaptureResult(result)
                }
            }
            if !self.pendingThreadNoteScreenshotProcessingResults.isEmpty {
                let pendingResults = self.pendingThreadNoteScreenshotProcessingResults
                self.pendingThreadNoteScreenshotProcessingResults.removeAll()
                for result in pendingResults {
                    self.sendThreadNoteScreenshotProcessingResult(result)
                }
            }
            if let activeWorkState = self.pendingActiveWorkState {
                self.sendActiveWorkState(activeWorkState)
                self.pendingActiveWorkState = nil
            }
            if let activeTurnState = self.pendingActiveTurnState {
                self.sendActiveTurnState(activeTurnState)
                self.pendingActiveTurnState = nil
            }
        }
        uc.add(readyHandler, name: "ready")

        loadTemplate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+F → toggle find bar in React
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
            webView.evaluateJavaScript("chatBridge.toggleFind?.()", completionHandler: nil)
            return true
        }
        // Cmd+G → find next, Shift+Cmd+G → find prev
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "g" {
            let direction = event.modifierFlags.contains(.shift) ? "prev" : "next"
            webView.evaluateJavaScript(
                "chatBridge.findNavigate?.('\(direction)')", completionHandler: nil)
            return true
        }
        // Escape → close find
        if event.keyCode == 53 {  // Escape
            webView.evaluateJavaScript("chatBridge.closeFind?.()", completionHandler: nil)
            // Don't return true — let Escape propagate for other uses
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Convert a rect from WKWebView viewport coordinates to screen coordinates.
    func convertToScreen(_ viewportRect: CGRect) -> CGRect {
        guard let window = webView.window else { return viewportRect }

        // WKWebView viewport rect (origin top-left) → webView local (flipped)
        let localRect = NSRect(
            x: viewportRect.origin.x,
            y: viewportRect.origin.y,
            width: viewportRect.width,
            height: viewportRect.height
        )

        // Convert from webView's coordinate space to window coordinates
        let windowRect = webView.convert(localRect, to: nil)

        // Convert from window coordinates to screen coordinates
        return window.convertToScreen(windowRect)
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func updateNoteAssetResolver(_ resolver: AssistantNoteAssetURLSchemeHandler.Resolver?) {
        guard let resolver else {
            return
        }

        noteAssetSchemeHandler?.updateResolver(resolver)
    }

    // MARK: - Template Loading

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        loadTemplate()
    }

    private func loadTemplate() {
        let url: URL? =
            Bundle.main.url(forResource: "markdown-chat", withExtension: "html")
            ?? Bundle(identifier: "OpenAssist_OpenAssist")?.url(
                forResource: "markdown-chat", withExtension: "html")
            ?? {
                let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
                let candidates = [
                    execDir.appendingPathComponent(
                        "OpenAssist_OpenAssist.bundle/markdown-chat.html"),
                    execDir.appendingPathComponent("markdown-chat.html"),
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }()

        guard let url, let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    // MARK: - Public API

    func applyMessages(_ messages: [AssistantChatWebMessage]) {
        guard messages != requestedMessages else { return }
        requestedMessages = messages

        if shouldBatchStreamEvents() {
            scheduleStreamingFlush()
            return
        }

        if throttleTimer != nil {
            flushStreamingState()
            invalidateThrottleTimer()
        }

        sendMessages(messages)
    }

    func applyReviewPanel(_ reviewPanel: AssistantChatWebCodeReviewPanel?) {
        if hasAppliedReviewPanel, lastAppliedReviewPanel == reviewPanel {
            return
        }
        hasAppliedReviewPanel = true
        lastAppliedReviewPanel = reviewPanel
        sendReviewPanel(reviewPanel)
    }

    func applyRuntimePanel(_ runtimePanel: AssistantChatWebRuntimePanel?) {
        if hasAppliedRuntimePanel, lastAppliedRuntimePanel == runtimePanel {
            return
        }
        hasAppliedRuntimePanel = true
        lastAppliedRuntimePanel = runtimePanel
        sendRuntimePanel(runtimePanel)
    }

    func applyRewindState(_ rewindState: AssistantChatWebRewindState?) {
        if hasAppliedRewindState, lastAppliedRewindState == rewindState {
            return
        }
        hasAppliedRewindState = true
        lastAppliedRewindState = rewindState
        sendRewindState(rewindState)
    }

    func applyThreadNoteState(_ threadNoteState: AssistantChatWebThreadNoteState?) {
        if hasAppliedThreadNoteState, lastAppliedThreadNoteState == threadNoteState {
            return
        }
        hasAppliedThreadNoteState = true
        lastAppliedThreadNoteState = threadNoteState
        sendThreadNoteState(threadNoteState)
    }

    func applyThreadNoteImageUploadResult(_ result: AssistantChatWebThreadNoteImageUploadResult) {
        sendThreadNoteImageUploadResult(result)
    }

    func applyThreadNoteScreenshotCaptureResult(
        _ result: AssistantChatWebThreadNoteScreenshotCaptureResult
    ) {
        sendThreadNoteScreenshotCaptureResult(result)
    }

    func applyThreadNoteScreenshotProcessingResult(
        _ result: AssistantChatWebThreadNoteScreenshotProcessingResult
    ) {
        sendThreadNoteScreenshotProcessingResult(result)
    }

    func applyActiveWorkState(_ activeWorkState: AssistantChatWebActiveWorkState?) {
        requestedActiveWorkState = activeWorkState

        if shouldBatchStreamEvents() {
            scheduleStreamingFlush()
            return
        }

        if throttleTimer != nil {
            flushStreamingState()
            invalidateThrottleTimer()
        }

        if hasAppliedActiveWorkState, lastAppliedActiveWorkState == activeWorkState {
            return
        }
        hasAppliedActiveWorkState = true
        lastAppliedActiveWorkState = activeWorkState
        sendActiveWorkState(activeWorkState)
    }

    func applyTypingIndicator(_ visible: Bool, title: String, detail: String) {
        let nextTyping = (visible, title, detail)
        requestedTyping = nextTyping

        if shouldBatchStreamEvents() {
            scheduleStreamingFlush()
            return
        }

        if throttleTimer != nil {
            flushStreamingState()
            invalidateThrottleTimer()
        }

        if let lastAppliedTyping,
            lastAppliedTyping == nextTyping
        {
            return
        }
        lastAppliedTyping = nextTyping
        sendTypingIndicator(visible, title: title, detail: detail)
    }

    func applyActiveTurnState(_ activeTurnState: AssistantChatWebActiveTurnState?) {
        requestedActiveTurnState = activeTurnState

        if shouldBatchStreamEvents() {
            scheduleStreamingFlush()
            return
        }

        if throttleTimer != nil {
            flushStreamingState()
            invalidateThrottleTimer()
        }

        if hasAppliedActiveTurnState, lastAppliedActiveTurnState == activeTurnState {
            return
        }
        hasAppliedActiveTurnState = true
        lastAppliedActiveTurnState = activeTurnState
        sendActiveTurnState(activeTurnState)
    }

    func applyTextScale(_ scale: CGFloat) {
        guard lastAppliedTextScale != scale else { return }
        lastAppliedTextScale = scale
        sendTextScale(scale)
    }

    func applyAccentColor(_ color: Color) {
        let js = AssistantWebViewThemeBridge.accentJavaScript(color)
        guard lastAppliedAccentCSS != js else { return }
        lastAppliedAccentCSS = js
        guard isReady else {
            pendingAccentCSS = js
            return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func applyCanLoadOlder(_ canLoad: Bool) {
        guard lastAppliedCanLoadOlderHistory != canLoad else { return }
        lastAppliedCanLoadOlderHistory = canLoad
        guard isReady else {
            pendingCanLoadOlderHistory = canLoad
            return
        }
        webView.evaluateJavaScript("chatBridge.setCanLoadOlder(\(canLoad))", completionHandler: nil)
    }

    func scrollToBottom(animated: Bool) {
        guard isReady else { return }
        webView.evaluateJavaScript("chatBridge.scrollToBottom(\(animated))", completionHandler: nil)
    }

    func revealMessage(id: String, animated: Bool, expand: Bool) {
        guard isReady,
            let encodedID = try? JSONEncoder().encode(id),
            let idString = String(data: encodedID, encoding: .utf8)
        else {
            return
        }
        webView.evaluateJavaScript(
            "chatBridge.revealMessage?.(\(idString), \(animated), \(expand))",
            completionHandler: nil
        )
    }

    // MARK: - Throttled Streaming

    private func shouldBatchStreamEvents() -> Bool {
        if requestedActiveTurnState?.isActive == true {
            return true
        }
        return AssistantChatWebStreamingUpdatePlanner.hasStreamingMessages(requestedMessages)
    }

    private func scheduleStreamingFlush() {
        if throttleTimer == nil {
            flushStreamingState()
            throttleTimer = Timer.scheduledTimer(
                withTimeInterval: Self.throttleInterval,
                repeats: true
            ) { [weak self] _ in
                self?.flushStreamingState()
            }
        }
    }

    private func invalidateThrottleTimer() {
        throttleTimer?.invalidate()
        throttleTimer = nil
    }

    private func flushStreamingState() {
        let events = AssistantChatWebStreamingUpdatePlanner.incrementalEvents(
            from: lastRenderedMessages,
            to: requestedMessages,
            previousActiveWorkState: lastAppliedActiveWorkState,
            nextActiveWorkState: requestedActiveWorkState,
            previousTyping: lastAppliedTyping,
            nextTyping: requestedTyping,
            previousActiveTurnState: lastAppliedActiveTurnState,
            nextActiveTurnState: requestedActiveTurnState
        )

        guard !events.isEmpty else {
            if !shouldBatchStreamEvents() {
                invalidateThrottleTimer()
            }
            return
        }

        sendStreamEvents(events, renderedMessages: requestedMessages)

        if !shouldBatchStreamEvents() {
            invalidateThrottleTimer()
        }
    }

    // MARK: - JS Communication

    private func sendMessages(_ messages: [AssistantChatWebMessage]) {
        guard isReady else {
            pendingMessages = messages
            return
        }
        let jsonArray = messages.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }
        lastRenderedMessages = messages
        webView.evaluateJavaScript("chatBridge.setMessages(\(jsonString))", completionHandler: nil)
    }

    private func sendStreamEvents(
        _ events: [AssistantChatWebStreamEvent],
        renderedMessages: [AssistantChatWebMessage]
    ) {
        guard isReady else {
            pendingMessages = renderedMessages
            pendingTyping = requestedTyping
            pendingActiveWorkState = requestedActiveWorkState
            pendingActiveTurnState = requestedActiveTurnState
            return
        }

        let jsonArray = events.map { $0.toJSON() }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonString = String(data: data, encoding: .utf8) else {
            sendMessages(renderedMessages)
            sendActiveWorkState(requestedActiveWorkState)
            sendTypingIndicator(requestedTyping.0, title: requestedTyping.1, detail: requestedTyping.2)
            sendActiveTurnState(requestedActiveTurnState)
            return
        }

        lastRenderedMessages = renderedMessages
        lastAppliedActiveWorkState = requestedActiveWorkState
        hasAppliedActiveWorkState = true
        lastAppliedTyping = requestedTyping
        lastAppliedActiveTurnState = requestedActiveTurnState
        hasAppliedActiveTurnState = true
        webView.evaluateJavaScript(
            "chatBridge.applyStreamEvents?.(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendTypingIndicator(_ visible: Bool, title: String, detail: String) {
        guard isReady else {
            pendingTyping = (visible, title, detail)
            return
        }
        guard let titleJSON = try? JSONEncoder().encode(title),
            let detailJSON = try? JSONEncoder().encode(detail),
            let titleStr = String(data: titleJSON, encoding: .utf8),
            let detailStr = String(data: detailJSON, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "chatBridge.setTypingIndicator(\(visible),\(titleStr),\(detailStr))",
            completionHandler: nil
        )
    }

    private func sendTextScale(_ scale: CGFloat) {
        guard isReady else {
            pendingTextScale = scale
            return
        }
        webView.evaluateJavaScript("chatBridge.setTextScale(\(scale))", completionHandler: nil)
    }

    private func sendReviewPanel(_ reviewPanel: AssistantChatWebCodeReviewPanel?) {
        guard isReady else {
            pendingReviewPanel = reviewPanel
            return
        }

        guard let reviewPanel else {
            webView.evaluateJavaScript(
                "chatBridge.setCodeReviewPanel(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: reviewPanel.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }
        webView.evaluateJavaScript(
            "chatBridge.setCodeReviewPanel(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendRuntimePanel(_ runtimePanel: AssistantChatWebRuntimePanel?) {
        guard isReady else {
            pendingRuntimePanel = runtimePanel
            return
        }

        guard let runtimePanel else {
            webView.evaluateJavaScript("chatBridge.setRuntimePanel(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: runtimePanel.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setRuntimePanel(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendRewindState(_ rewindState: AssistantChatWebRewindState?) {
        guard isReady else {
            pendingRewindState = rewindState
            return
        }

        guard let rewindState else {
            webView.evaluateJavaScript("chatBridge.setRewindState(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rewindState.toJSON()),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setRewindState(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendThreadNoteState(_ threadNoteState: AssistantChatWebThreadNoteState?) {
        guard isReady else {
            pendingThreadNoteState = threadNoteState
            return
        }

        guard let threadNoteState else {
            webView.evaluateJavaScript("chatBridge.setThreadNoteState(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: threadNoteState.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setThreadNoteState(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendThreadNoteImageUploadResult(_ result: AssistantChatWebThreadNoteImageUploadResult) {
        guard isReady else {
            pendingThreadNoteImageUploadResults.append(result)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.handleThreadNoteImageUploadResult?.(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendThreadNoteScreenshotCaptureResult(
        _ result: AssistantChatWebThreadNoteScreenshotCaptureResult
    ) {
        guard isReady else {
            pendingThreadNoteScreenshotCaptureResults.append(result)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.handleThreadNoteScreenshotCaptureResult?.(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendThreadNoteScreenshotProcessingResult(
        _ result: AssistantChatWebThreadNoteScreenshotProcessingResult
    ) {
        guard isReady else {
            pendingThreadNoteScreenshotProcessingResults.append(result)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.handleThreadNoteScreenshotProcessingResult?.(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendActiveWorkState(_ activeWorkState: AssistantChatWebActiveWorkState?) {
        guard isReady else {
            pendingActiveWorkState = activeWorkState
            return
        }

        guard let activeWorkState, activeWorkState.hasVisibleContent else {
            webView.evaluateJavaScript("chatBridge.setActiveWorkState(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: activeWorkState.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setActiveWorkState(\(jsonString))",
            completionHandler: nil
        )
    }

    private func sendActiveTurnState(_ activeTurnState: AssistantChatWebActiveTurnState?) {
        guard isReady else {
            pendingActiveTurnState = activeTurnState
            return
        }

        guard let activeTurnState else {
            webView.evaluateJavaScript("chatBridge.setActiveTurnState?.(null)", completionHandler: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: activeTurnState.toJSON()),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript(
            "chatBridge.setActiveTurnState?.(\(jsonString))",
            completionHandler: nil
        )
    }

    // MARK: - Navigation Delegate

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowedContentTypes = AssistantAttachmentSupport.imageContentTypes

        let finishSelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                completionHandler(nil)
                return
            }
            completionHandler(panel.urls)
        }

        if let window = webView.window ?? self.window {
            panel.beginSheetModal(for: window, completionHandler: finishSelection)
        } else {
            panel.begin(completionHandler: finishSelection)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url
        {
            coordinator.handleLinkClick(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func handleLinkClick(_ urlString: String) {
        coordinator.handleLinkClick(urlString)
    }

    deinit {
        invalidateThrottleTimer()
    }
}

extension AssistantChatWebMessage {
    fileprivate func withStreamingText(_ text: String?, isStreaming: Bool)
        -> AssistantChatWebMessage
    {
        AssistantChatWebMessage(
            id: id,
            type: type,
            text: text,
            isStreaming: isStreaming,
            timestamp: timestamp,
            turnID: turnID,
            images: images,
            emphasis: emphasis,
            canUndo: canUndo,
            canEdit: canEdit,
            rewriteAnchorID: rewriteAnchorID,
            providerLabel: providerLabel,
            selectedPlugins: selectedPlugins,
            activityIcon: activityIcon,
            activityTitle: activityTitle,
            activityDetail: activityDetail,
            activityStatus: activityStatus,
            activityStatusLabel: activityStatusLabel,
            detailSections: detailSections,
            activityTargets: activityTargets,
            groupItems: groupItems,
            loadActivityDetailsID: loadActivityDetailsID,
            collapseActivityDetailsID: collapseActivityDetailsID
        )
    }
}

enum AssistantChatWebStreamingUpdatePlanner {
    static func hasStreamingMessages(_ messages: [AssistantChatWebMessage]) -> Bool {
        messages.contains(where: \.isStreaming)
    }

    static func incrementalEvents(
        from previousMessages: [AssistantChatWebMessage],
        to nextMessages: [AssistantChatWebMessage],
        previousActiveWorkState: AssistantChatWebActiveWorkState?,
        nextActiveWorkState: AssistantChatWebActiveWorkState?,
        previousTyping: (Bool, String, String)?,
        nextTyping: (Bool, String, String),
        previousActiveTurnState: AssistantChatWebActiveTurnState?,
        nextActiveTurnState: AssistantChatWebActiveTurnState?
    ) -> [AssistantChatWebStreamEvent] {
        var events = messageEvents(from: previousMessages, to: nextMessages)

        if previousActiveWorkState != nextActiveWorkState {
            events.append(.setActiveWorkState(nextActiveWorkState))
        }
        if previousTyping == nil || previousTyping! != nextTyping {
            events.append(
                .setTypingState(
                    visible: nextTyping.0,
                    title: nextTyping.1,
                    detail: nextTyping.2
                )
            )
        }
        if previousActiveTurnState != nextActiveTurnState {
            events.append(.setActiveTurnState(nextActiveTurnState))
        }

        return events
    }

    private static func messageEvents(
        from previousMessages: [AssistantChatWebMessage],
        to nextMessages: [AssistantChatWebMessage]
    ) -> [AssistantChatWebStreamEvent] {
        if previousMessages.isEmpty {
            return nextMessages.isEmpty ? [] : [.replaceMessages(nextMessages)]
        }

        if previousMessages.count == nextMessages.count,
           previousMessages.elementsEqual(nextMessages, by: { $0.id == $1.id }) {
            return alignedMessageEvents(from: previousMessages, to: nextMessages)
        }

        if previousMessages.count < nextMessages.count,
           previousMessages.elementsEqual(nextMessages.prefix(previousMessages.count), by: { $0.id == $1.id }) {
            var events = alignedMessageEvents(
                from: previousMessages,
                to: Array(nextMessages.prefix(previousMessages.count))
            )

            for index in previousMessages.count..<nextMessages.count {
                let afterMessageID = index > 0 ? nextMessages[index - 1].id : nil
                events.append(
                    .upsertMessage(
                        message: nextMessages[index],
                        afterMessageID: afterMessageID
                    )
                )
            }

            return events
        }

        if previousMessages.count > nextMessages.count,
           nextMessages.elementsEqual(previousMessages.prefix(nextMessages.count), by: { $0.id == $1.id }) {
            var events = alignedMessageEvents(
                from: Array(previousMessages.prefix(nextMessages.count)),
                to: nextMessages
            )

            for message in previousMessages.suffix(previousMessages.count - nextMessages.count) {
                events.append(.removeMessage(messageID: message.id))
            }

            return events
        }

        return [.replaceMessages(nextMessages)]
    }

    private static func alignedMessageEvents(
        from previousMessages: [AssistantChatWebMessage],
        to nextMessages: [AssistantChatWebMessage]
    ) -> [AssistantChatWebStreamEvent] {
        var events: [AssistantChatWebStreamEvent] = []

        for (index, pair) in zip(previousMessages.indices, zip(previousMessages, nextMessages)) {
            let previous = pair.0
            let next = pair.1
            guard previous.id == next.id else {
                return [.replaceMessages(nextMessages)]
            }
            guard previous != next else { continue }

            if let textEvent = textEventIfEligible(previous: previous, next: next) {
                events.append(textEvent)
            } else {
                let afterMessageID = index > 0 ? nextMessages[index - 1].id : nil
                events.append(
                    .upsertMessage(
                        message: next,
                        afterMessageID: afterMessageID
                    )
                )
            }
        }

        return events
    }

    private static func textEventIfEligible(
        previous: AssistantChatWebMessage,
        next: AssistantChatWebMessage
    ) -> AssistantChatWebStreamEvent? {
        let comparablePrevious = previous.withStreamingText(
            previous.text,
            isStreaming: next.isStreaming
        )
        let comparableNext = next.withStreamingText(
            previous.text,
            isStreaming: next.isStreaming
        )

        guard comparablePrevious == comparableNext else {
            return nil
        }

        guard previous.text != next.text || previous.isStreaming != next.isStreaming else {
            return nil
        }

        return .responseTextDelta(
            messageID: next.id,
            text: next.text ?? "",
            isStreaming: next.isStreaming
        )
    }
}

// MARK: - Ready Handler

private final class ReadyHandler: NSObject, WKScriptMessageHandler {
    private let onReady: () -> Void
    init(onReady: @escaping () -> Void) { self.onReady = onReady }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "ready" { onReady() }
    }
}

// MARK: - Conversion from Timeline Items

extension AssistantChatWebMessage {
    static func from(
        renderItem: AssistantTimelineRenderItem,
        historyActions: [String: AssistantHistoryActionAvailability] = [:],
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> [AssistantChatWebMessage] {
        switch renderItem {
        case .timeline(let item):
            return [
                from(
                    timelineItem: item,
                    historyAction: historyActions[item.id],
                    renderContext: renderContext
                )
            ]
        case .activityGroup(let group):
            return [fromActivityGroup(group, renderContext: renderContext)]
        }
    }

    static func from(
        timelineItem item: AssistantTimelineItem,
        historyAction: AssistantHistoryActionAvailability? = nil,
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> AssistantChatWebMessage {
        let type: String
        let activityIcon: String?
        let activityStatus: String?
        let activityStatusLabel: String?
        let activityTitle: String?
        let activityDetail: String?
        let detailSections: [AssistantChatWebDetailSection]?
        let activityTargets: [AssistantChatWebActivityTarget]?

        switch item.kind {
        case .userMessage:
            type = "user"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
            activityTargets = nil
        case .assistantProgress, .assistantFinal:
            type = "assistant"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
            activityTargets = nil
        case .activity:
            type = "activity"
            let activity = item.activity
            let effectiveStatus = activity.map {
                displayActivityStatus(
                    $0,
                    sessionID: item.sessionID ?? $0.sessionID,
                    renderContext: renderContext
                )
            }
            activityIcon = activity.map { iconForActivityKind($0.kind) }
            activityTitle = activity?.title ?? "Action"
            activityDetail = activity?.friendlySummary
            activityStatus = effectiveStatus.map { Self.activityStatusString(for: $0) }
            activityStatusLabel = effectiveStatus?.rawValue.capitalized
            detailSections = assistantChatWebDetailSections(from: activity?.rawDetails)
            if let activity {
                activityTargets = assistantChatWebActivityTargets(
                    from: assistantActivityOpenTargets(
                        for: activity,
                        sessionCWD: renderContext?.sessionWorkingDirectory(
                            for: item.sessionID ?? activity.sessionID
                        )
                    )
                )
            } else {
                activityTargets = nil
            }
        case .permission:
            type = "activity"
            activityIcon = "permission"
            let permissionPresentation = assistantPermissionActivityPresentation(
                text: item.text,
                request: item.permissionRequest
            )
            activityTitle = permissionPresentation.title
            activityDetail = permissionPresentation.detail
            if let request = item.permissionRequest {
                let state = assistantPermissionCardState(
                    for: request,
                    pendingRequest: renderContext?.pendingPermissionRequest,
                    sessionStatus: renderContext?.sessionStatus(for: request.sessionID)
                )
                switch state {
                case .waitingForApproval:
                    activityStatus = "running"
                    activityStatusLabel = "Pending"
                case .waitingForInput:
                    activityStatus = "running"
                    activityStatusLabel = "Waiting"
                case .completed, .notActive:
                    activityStatus = "completed"
                    activityStatusLabel = "Handled"
                }
            } else {
                activityStatus = "completed"
                activityStatusLabel = "Handled"
            }
            detailSections = permissionPresentation.detailSections
            activityTargets = nil
        case .plan:
            type = "assistant"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
            activityTargets = nil
        case .system:
            type = "system"
            activityIcon = nil
            activityStatus = nil
            activityStatusLabel = nil
            activityTitle = nil
            activityDetail = nil
            detailSections = nil
            activityTargets = nil
        }

        let text: String?
        if item.kind == .plan, let planText = item.planText {
            text = planText
        } else {
            text = item.text.flatMap { AssistantVisibleTextSanitizer.clean($0) }
        }
        let providerLabel: String?
        switch item.kind {
        case .assistantProgress, .assistantFinal, .plan:
            providerLabel = item.providerBackend?.shortDisplayName
        case .system:
            providerLabel = item.providerBackend?.shortDisplayName
        case .userMessage, .activity, .permission:
            providerLabel = nil
        }

        return AssistantChatWebMessage(
            id: item.id,
            type: type,
            text: text,
            isStreaming: item.isStreaming,
            timestamp: item.sortDate,
            turnID: item.turnID?.nonEmpty,
            images: AssistantChatWebInlineImage.payloads(from: item.imageAttachments),
            emphasis: item.emphasis,
            canUndo: historyAction?.canUndo ?? false,
            canEdit: historyAction?.canEdit ?? false,
            rewriteAnchorID: historyAction?.anchorID,
            providerLabel: providerLabel,
            selectedPlugins: item.selectedPlugins?.map {
                AssistantComposerWebPlugin(
                    pluginID: $0.pluginID,
                    displayName: $0.displayName,
                    summary: $0.summary,
                    needsSetup: $0.needsSetup,
                    iconDataURL: assistantPluginIconDataURL(for: $0.iconPath)
                )
            },
            activityIcon: activityIcon,
            activityTitle: activityTitle,
            activityDetail: activityDetail,
            activityStatus: activityStatus,
            activityStatusLabel: activityStatusLabel,
            detailSections: detailSections?.isEmpty == false ? detailSections : nil,
            activityTargets: activityTargets?.isEmpty == false ? activityTargets : nil,
            groupItems: nil,
            loadActivityDetailsID: nil,
            collapseActivityDetailsID: nil
        )
    }

    static func fromActivityGroup(
        _ group: AssistantTimelineActivityGroup,
        renderContext: AssistantChatWebRenderContext? = nil
    ) -> AssistantChatWebMessage {
        let groupItems = group.items.map { item -> AssistantChatWebActivityGroupItem in
            let activity = item.activity
            let effectiveStatus =
                activity.map {
                    displayActivityStatus(
                        $0,
                        sessionID: item.sessionID ?? $0.sessionID,
                        renderContext: renderContext
                    )
                } ?? .completed
            let activityTargets = activity.map {
                assistantChatWebActivityTargets(
                    from: assistantActivityOpenTargets(
                        for: $0,
                        sessionCWD: renderContext?.sessionWorkingDirectory(
                            for: item.sessionID ?? $0.sessionID
                        )
                    )
                )
            }
            return AssistantChatWebActivityGroupItem(
                id: item.id,
                icon: activity.map { iconForActivityKind($0.kind) },
                title: activity?.title ?? "Action",
                detail: activity?.friendlySummary,
                status: activityStatusString(for: effectiveStatus),
                statusLabel: effectiveStatus.rawValue.capitalized,
                timestamp: item.sortDate,
                detailSections: assistantChatWebDetailSections(from: activity?.rawDetails),
                activityTargets: activityTargets?.isEmpty == false ? activityTargets : nil
            )
        }

        return AssistantChatWebMessage(
            id: "group-\(group.id)",
            type: "activityGroup",
            text: nil,
            isStreaming: false,
            timestamp: group.items.first?.sortDate ?? Date(),
            turnID: nil,
            images: nil,
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            providerLabel: nil,
            selectedPlugins: nil,
            activityIcon: nil,
            activityTitle: nil,
            activityDetail: nil,
            activityStatus: nil,
            activityStatusLabel: nil,
            detailSections: nil,
            activityTargets: nil,
            groupItems: groupItems,
            loadActivityDetailsID: nil,
            collapseActivityDetailsID: nil
        )
    }

    static func collapsedActivitySummary(
        renderItem: AssistantTimelineRenderItem
    ) -> AssistantChatWebMessage? {
        activitySummary(renderItem: renderItem, action: .expand)
    }

    static func expandedActivitySummary(
        renderItem: AssistantTimelineRenderItem
    ) -> AssistantChatWebMessage? {
        activitySummary(renderItem: renderItem, action: .collapse)
    }

    static func collapsedConversationSummary(
        hiddenRenderItems: [AssistantTimelineRenderItem],
        terminalRenderItem: AssistantTimelineRenderItem,
        blockID: String,
        expanded: Bool
    ) -> AssistantChatWebMessage? {
        guard !hiddenRenderItems.isEmpty else { return nil }

        let summaryRenderItems = hiddenRenderItems + [terminalRenderItem]
        let activities = hiddenRenderItems.flatMap { renderItem -> [AssistantActivityItem] in
            switch renderItem {
            case .timeline(let item):
                guard item.kind == .activity, let activity = item.activity else { return [] }
                return [activity]
            case .activityGroup(let group):
                return group.activities
            }
        }

        let firstTimestamp = hiddenRenderItems.first.map(renderItemSortDate) ?? .now
        let dominantKind =
            activities.isEmpty ? nil : collapsedActivityDominantKind(for: activities)
        let status = activities.isEmpty ? AssistantActivityStatus.completed : collapsedActivityStatus(for: activities)

        return AssistantChatWebMessage(
            id: "activity-summary-\(blockID)",
            type: "activitySummary",
            text: nil,
            isStreaming: false,
            timestamp: firstTimestamp,
            turnID: nil,
            images: nil,
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            providerLabel: nil,
            selectedPlugins: nil,
            activityIcon: dominantKind,
            activityTitle: "Worked for \(collapsedConversationDurationLabel(for: summaryRenderItems))",
            activityDetail: collapsedConversationSummaryDetail(for: summaryRenderItems, activities: activities),
            activityStatus: activityStatusString(for: status),
            activityStatusLabel: status.rawValue.capitalized,
            detailSections: nil,
            activityTargets: nil,
            groupItems: nil,
            loadActivityDetailsID: expanded ? nil : blockID,
            collapseActivityDetailsID: expanded ? blockID : nil
        )
    }

    private enum ActivitySummaryAction {
        case expand
        case collapse
    }

    private static func activitySummary(
        renderItem: AssistantTimelineRenderItem,
        action: ActivitySummaryAction
    ) -> AssistantChatWebMessage? {
        let activities: [AssistantActivityItem]
        let summaryID = "activity-summary-\(renderItem.id)"
        let timestamp: Date

        switch renderItem {
        case .timeline(let item):
            guard item.kind == .activity, let activity = item.activity else {
                return nil
            }
            activities = [activity]
            timestamp = item.sortDate
        case .activityGroup(let group):
            guard !group.activities.isEmpty else { return nil }
            activities = group.activities
            timestamp = group.sortDate
        }

        let dominantKind = collapsedActivityDominantKind(for: activities)

        return AssistantChatWebMessage(
            id: summaryID,
            type: "activitySummary",
            text: nil,
            isStreaming: false,
            timestamp: timestamp,
            turnID: nil,
            images: nil,
            emphasis: false,
            canUndo: false,
            canEdit: false,
            rewriteAnchorID: nil,
            providerLabel: nil,
            selectedPlugins: nil,
            activityIcon: dominantKind,
            activityTitle: "Worked for \(collapsedActivityDurationLabel(for: activities))",
            activityDetail: collapsedActivitySummaryDetail(for: activities),
            activityStatus: activityStatusString(for: collapsedActivityStatus(for: activities)),
            activityStatusLabel: collapsedActivityStatus(for: activities).rawValue.capitalized,
            detailSections: nil,
            activityTargets: nil,
            groupItems: nil,
            loadActivityDetailsID: action == .expand ? renderItem.id : nil,
            collapseActivityDetailsID: action == .collapse ? renderItem.id : nil
        )
    }

    private static func collapsedActivityStatus(
        for activities: [AssistantActivityItem]
    ) -> AssistantActivityStatus {
        if activities.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if activities.contains(where: { $0.status == .interrupted }) {
            return .interrupted
        }
        if activities.contains(where: { $0.status == .waiting }) {
            return .waiting
        }
        if activities.contains(where: { $0.status.isActive }) {
            return .running
        }
        return .completed
    }

    private static func collapsedActivityDominantKind(
        for activities: [AssistantActivityItem]
    ) -> String? {
        let counts = Dictionary(grouping: activities, by: \.kind).mapValues(\.count)
        return counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue > rhs.key.rawValue
            }
            return lhs.value < rhs.value
        })?.key.rawValue
    }

    private static func collapsedActivitySummaryDetail(
        for activities: [AssistantActivityItem]
    ) -> String? {
        guard !activities.isEmpty else { return nil }

        let counts = Dictionary(grouping: activities, by: \.kind).mapValues(\.count)
        var fragments: [String] = []

        if let commands = counts[.commandExecution], commands > 0 {
            fragments.append("\(commands) command\(commands == 1 ? "" : "s")")
        }
        if let fileChanges = counts[.fileChange], fileChanges > 0 {
            fragments.append("\(fileChanges) file change\(fileChanges == 1 ? "" : "s")")
        }
        if let searches = counts[.webSearch], searches > 0 {
            fragments.append("\(searches) search\(searches == 1 ? "" : "es")")
        }
        if let browserSteps = counts[.browserAutomation], browserSteps > 0 {
            fragments.append("\(browserSteps) browser step\(browserSteps == 1 ? "" : "s")")
        }
        let toolUses = (counts[.mcpToolCall] ?? 0) + (counts[.dynamicToolCall] ?? 0)
        if toolUses > 0 {
            fragments.append("\(toolUses) tool use\(toolUses == 1 ? "" : "s")")
        }
        if let subagentSteps = counts[.subagent], subagentSteps > 0 {
            fragments.append("\(subagentSteps) subagent step\(subagentSteps == 1 ? "" : "s")")
        }

        if fragments.isEmpty {
            let count = activities.count
            return "\(count) activit\(count == 1 ? "y" : "ies")"
        }

        return fragments.prefix(3).joined(separator: ", ")
    }

    private static func collapsedActivityDurationLabel(
        for activities: [AssistantActivityItem]
    ) -> String {
        let start = activities.map(\.startedAt).min() ?? .now
        let end = activities.map(\.updatedAt).max() ?? start
        let totalSeconds = max(1, Int(ceil(end.timeIntervalSince(start))))

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        if minutes > 0 {
            if seconds > 0 {
                return "\(minutes)m \(seconds)s"
            }
            return "\(minutes)m"
        }

        return "\(seconds)s"
    }

    private static func collapsedConversationDurationLabel(
        for renderItems: [AssistantTimelineRenderItem]
    ) -> String {
        let start = renderItems.map(renderItemSortDate).min() ?? .now
        let end = renderItems.map(\.lastUpdatedAt).max() ?? start
        let totalSeconds = max(1, Int(ceil(end.timeIntervalSince(start))))

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            if seconds > 0 {
                return "\(minutes)m \(seconds)s"
            }
            return "\(minutes)m"
        }

        return "\(seconds)s"
    }

    private static func collapsedConversationSummaryDetail(
        for renderItems: [AssistantTimelineRenderItem],
        activities: [AssistantActivityItem]
    ) -> String? {
        let assistantReplyCount = renderItems.reduce(into: 0) { count, renderItem in
            guard case .timeline(let item) = renderItem else { return }
            switch item.kind {
            case .assistantProgress, .assistantFinal, .plan:
                if item.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
                    count += 1
                }
            default:
                break
            }
        }

        let activityCount = activities.count
        var fragments: [String] = []

        if assistantReplyCount > 0 {
            fragments.append("\(assistantReplyCount) update\(assistantReplyCount == 1 ? "" : "s")")
        }
        if activityCount > 0 {
            fragments.append("\(activityCount) tool step\(activityCount == 1 ? "" : "s")")
        }

        return fragments.isEmpty ? nil : fragments.joined(separator: ", ")
    }

    private static func renderItemSortDate(_ renderItem: AssistantTimelineRenderItem) -> Date {
        switch renderItem {
        case .timeline(let item):
            return item.sortDate
        case .activityGroup(let group):
            return group.sortDate
        }
    }

    private static func iconForActivityKind(_ kind: AssistantActivityKind) -> String {
        // Pass the kind as a string; React maps it to an SVG icon
        kind.rawValue
    }

    private static func displayActivityStatus(
        _ activity: AssistantActivityItem,
        sessionID: String?,
        renderContext: AssistantChatWebRenderContext?
    ) -> AssistantActivityStatus {
        guard activity.status.isActive else {
            return activity.status
        }

        guard let renderContext else {
            return activity.status
        }

        guard renderContext.shouldShowLiveRunningState(for: sessionID) else {
            return .completed
        }

        return activity.status
    }

    private static func activityStatusString(for status: AssistantActivityStatus) -> String {
        switch status {
        case .completed:
            return "completed"
        case .failed, .interrupted:
            return "failed"
        case .pending, .running, .waiting:
            return "running"
        }
    }

    private static func activityStatusString(for activity: AssistantActivityItem) -> String {
        activityStatusString(for: activity.status)
    }
}
