import Foundation

enum AssistantExternalMarkdownFileError: LocalizedError {
    case missingFile
    case unreadableFile
    case unwritableFile

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "Open Assist could not find that Markdown file anymore."
        case .unreadableFile:
            return "Open Assist could not read that Markdown file."
        case .unwritableFile:
            return "Open Assist could not save that Markdown file."
        }
    }
}

struct AssistantExternalMarkdownFileState: Equatable, Sendable {
    let fileURL: URL
    let fileName: String
    let savedText: String
    let draftText: String
    let lastSavedAt: Date?
    let canSave: Bool

    var filePath: String { fileURL.path }
    var directoryPath: String { fileURL.deletingLastPathComponent().path }
    var isDirty: Bool { draftText != savedText }

    static func load(from fileURL: URL) throws -> AssistantExternalMarkdownFileState {
        let standardizedURL = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw AssistantExternalMarkdownFileError.missingFile
        }
        guard let text = try? String(contentsOf: standardizedURL, encoding: .utf8) else {
            throw AssistantExternalMarkdownFileError.unreadableFile
        }

        return AssistantExternalMarkdownFileState(
            fileURL: standardizedURL,
            fileName: standardizedURL.lastPathComponent,
            savedText: normalizeExternalMarkdownLineEndings(text),
            draftText: normalizeExternalMarkdownLineEndings(text),
            lastSavedAt: (try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate),
            canSave: FileManager.default.isWritableFile(atPath: standardizedURL.path)
        )
    }

    func updatingDraft(_ text: String) -> AssistantExternalMarkdownFileState {
        AssistantExternalMarkdownFileState(
            fileURL: fileURL,
            fileName: fileName,
            savedText: savedText,
            draftText: normalizeExternalMarkdownLineEndings(text),
            lastSavedAt: lastSavedAt,
            canSave: canSave
        )
    }

    func saving() throws -> AssistantExternalMarkdownFileState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AssistantExternalMarkdownFileError.missingFile
        }
        guard canSave else {
            throw AssistantExternalMarkdownFileError.unwritableFile
        }

        let normalizedDraft = normalizeExternalMarkdownLineEndings(draftText)
        do {
            try normalizedDraft.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw AssistantExternalMarkdownFileError.unwritableFile
        }

        return AssistantExternalMarkdownFileState(
            fileURL: fileURL,
            fileName: fileName,
            savedText: normalizedDraft,
            draftText: normalizedDraft,
            lastSavedAt: (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate),
            canSave: FileManager.default.isWritableFile(atPath: fileURL.path)
        )
    }
}

private func normalizeExternalMarkdownLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}
