import Foundation
import UniformTypeIdentifiers
import WebKit

struct AssistantSavedNoteAsset: Equatable, Sendable {
    let relativePath: String
    let fileURL: URL
}

struct AssistantResolvedNoteAssetReference: Equatable, Sendable {
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let noteID: String
    let relativePath: String
}

enum AssistantNoteAssetSupport {
    static let urlScheme = "openassist-note-asset"

    private static let urlHost = "note"
    private static let markdownImagePattern = try! NSRegularExpression(
        pattern: #"!\[((?:\\.|[^\]])*)\]\(([^)\s]+)(?:\s+"((?:\\.|[^"])*)")?\)(?:\{width=(\d+)\})?"#
    )
    private static let fencedCodePattern = try! NSRegularExpression(
        pattern: #"(```[\s\S]*?```|~~~[\s\S]*?~~~)"#
    )

    static let supportedImageMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/tiff",
    ]

    static func isSupportedImageMimeType(_ mimeType: String?) -> Bool {
        guard let normalized = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return false
        }

        return supportedImageMimeTypes.contains(normalized)
    }

    static func noteAssetDirectoryName(forNoteFileName fileName: String) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let baseName = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        guard !baseName.isEmpty else {
            return nil
        }

        return "\(baseName).assets"
    }

    static func noteAssetDirectoryURL(
        notesDirectoryURL: URL,
        noteFileName: String
    ) -> URL? {
        guard let directoryName = noteAssetDirectoryName(forNoteFileName: noteFileName) else {
            return nil
        }

        return notesDirectoryURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func saveImageAsset(
        attachment: AssistantAttachment,
        notesDirectoryURL: URL,
        noteFileName: String,
        fileManager: FileManager = .default
    ) throws -> AssistantSavedNoteAsset {
        guard isSupportedImageMimeType(attachment.mimeType) else {
            throw AssistantNoteAssetError.unsupportedType
        }
        guard let assetDirectoryName = noteAssetDirectoryName(forNoteFileName: noteFileName) else {
            throw AssistantNoteAssetError.invalidNoteFileName
        }

        let assetDirectoryURL = notesDirectoryURL.appendingPathComponent(assetDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: assetDirectoryURL, withIntermediateDirectories: true)

        let storedFileName = storedAssetFileName(
            suggestedFilename: attachment.filename,
            mimeType: attachment.mimeType
        )
        let fileURL = assetDirectoryURL.appendingPathComponent(storedFileName, isDirectory: false)
        try attachment.data.write(to: fileURL, options: .atomic)

        return AssistantSavedNoteAsset(
            relativePath: "./\(assetDirectoryName)/\(storedFileName)",
            fileURL: fileURL
        )
    }

    static func resolveAssetFileURL(
        notesDirectoryURL: URL,
        noteFileName: String,
        relativePath: String
    ) -> URL? {
        guard let assetDirectoryURL = noteAssetDirectoryURL(
            notesDirectoryURL: notesDirectoryURL,
            noteFileName: noteFileName
        ) else {
            return nil
        }

        let normalizedRelativePath = normalizeRelativeAssetPath(relativePath)
        guard !normalizedRelativePath.isEmpty else {
            return nil
        }

        let trimmedRelativePath = normalizedRelativePath.hasPrefix("./")
            ? String(normalizedRelativePath.dropFirst(2))
            : normalizedRelativePath
        let pathComponents = trimmedRelativePath
            .split(separator: "/")
            .map(String.init)
        guard !pathComponents.isEmpty,
              pathComponents.first == assetDirectoryURL.lastPathComponent,
              !pathComponents.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            return nil
        }

        var candidateURL = notesDirectoryURL
        for component in pathComponents {
            candidateURL.appendPathComponent(component, isDirectory: false)
        }

        let resolvedPath = candidateURL.standardizedFileURL.path
        let assetRootPath = assetDirectoryURL.standardizedFileURL.path
        guard resolvedPath == assetRootPath || resolvedPath.hasPrefix(assetRootPath + "/") else {
            return nil
        }

        return candidateURL
    }

    static func displayURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        relativePath: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.queryItems = [
            URLQueryItem(name: "ownerKind", value: ownerKind.rawValue),
            URLQueryItem(name: "ownerId", value: ownerID),
            URLQueryItem(name: "noteId", value: noteID),
            URLQueryItem(name: "path", value: normalizeRelativeAssetPath(relativePath)),
        ]
        return components.url
    }

    static func resolveDisplayURL(_ url: URL) -> AssistantResolvedNoteAssetReference? {
        guard url.scheme?.caseInsensitiveCompare(urlScheme) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        let values: [String: String] = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            guard let value = item.value else {
                return nil
            }
            return (item.name, value)
        })

        guard let ownerKindRaw = values["ownerKind"],
              let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRaw),
              let ownerID = values["ownerId"],
              let noteID = values["noteId"],
              let relativePath = values["path"] else {
            return nil
        }

        let normalizedRelativePath = normalizeRelativeAssetPath(relativePath)
        guard !ownerID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
              !noteID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
              !normalizedRelativePath.isEmpty else {
            return nil
        }

        return AssistantResolvedNoteAssetReference(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID,
            relativePath: normalizedRelativePath
        )
    }

    static func rewriteMarkdownForDisplay(
        _ markdown: String,
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> String {
        rewriteMarkdownImages(in: markdown) { image in
            guard image.src.hasPrefix("./"),
                  let displayURL = displayURL(
                    ownerKind: ownerKind,
                    ownerID: ownerID,
                    noteID: noteID,
                    relativePath: image.src
                  ) else {
                return image
            }

            var updated = image
            updated.src = displayURL.absoluteString
            return updated
        }
    }

    static func rewriteMarkdownForPersistence(
        _ markdown: String,
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> String {
        rewriteMarkdownImages(in: markdown) { image in
            guard let url = URL(string: image.src),
                  let resolved = resolveDisplayURL(url),
                  resolved.ownerKind == ownerKind,
                  resolved.ownerID.caseInsensitiveCompare(ownerID) == .orderedSame,
                  resolved.noteID.caseInsensitiveCompare(noteID) == .orderedSame else {
                return image
            }

            var updated = image
            updated.src = resolved.relativePath
            return updated
        }
    }

    static func deletedAssetDirectoryName(for deletedID: String) -> String {
        let safeDeletedID = safePathComponent(deletedID)
        return safeDeletedID.isEmpty ? "\(UUID().uuidString.lowercased()).assets" : "\(safeDeletedID).assets"
    }

    private static func storedAssetFileName(
        suggestedFilename: String,
        mimeType: String
    ) -> String {
        let suggestedURL = URL(fileURLWithPath: suggestedFilename)
        let rawStem = suggestedURL.deletingPathExtension().lastPathComponent
        let safeStem = safePathComponent(rawStem).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let stem = safeStem.isEmpty ? "image" : safeStem
        let rawExtension = suggestedURL.pathExtension.lowercased()
        let fileExtension = rawExtension.isEmpty
            ? fallbackExtension(for: mimeType) ?? "bin"
            : safePathComponent(rawExtension).lowercased()
        let suffix = String(UUID().uuidString.lowercased().prefix(6))
        return "\(stem)-\(suffix).\(fileExtension)"
    }

    private static func fallbackExtension(for mimeType: String) -> String? {
        if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension,
           !preferred.isEmpty {
            return preferred
        }

        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/tiff":
            return "tiff"
        default:
            return nil
        }
    }

    private static func normalizeRelativeAssetPath(_ relativePath: String) -> String {
        let normalized = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else {
            return ""
        }

        if normalized.hasPrefix("./") {
            return normalized
        }
        if normalized.hasPrefix("/") {
            return ".\(normalized)"
        }
        return "./\(normalized)"
    }

    private static func rewriteMarkdownImages(
        in markdown: String,
        transform: (MarkdownImage) -> MarkdownImage
    ) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let segments = splitByCodeFences(normalized)
        return segments.map { segment in
            guard !segment.isCodeFence else {
                return segment.text
            }

            return rewriteMarkdownImageSegment(segment.text, transform: transform)
        }
        .joined()
    }

    private static func rewriteMarkdownImageSegment(
        _ segment: String,
        transform: (MarkdownImage) -> MarkdownImage
    ) -> String {
        let nsSegment = segment as NSString
        let matches = markdownImagePattern.matches(
            in: segment,
            range: NSRange(location: 0, length: nsSegment.length)
        )
        guard !matches.isEmpty else {
            return segment
        }

        var result = ""
        var currentLocation = 0
        for match in matches {
            let matchRange = match.range
            guard matchRange.location != NSNotFound else {
                continue
            }

            result += nsSegment.substring(with: NSRange(location: currentLocation, length: matchRange.location - currentLocation))
            let alt = substring(in: nsSegment, range: match.range(at: 1))
            let src = substring(in: nsSegment, range: match.range(at: 2))
            let title = substring(in: nsSegment, range: match.range(at: 3))
            let widthText = substring(in: nsSegment, range: match.range(at: 4))
            let updated = transform(
                MarkdownImage(
                    alt: unescapeImageText(alt),
                    src: src,
                    title: title.isEmpty ? nil : unescapeTitleText(title),
                    width: Int(widthText)
                )
            )
            result += buildMarkdownImage(updated)
            currentLocation = matchRange.location + matchRange.length
        }

        result += nsSegment.substring(from: currentLocation)
        return result
    }

    private static func splitByCodeFences(_ markdown: String) -> [MarkdownSegment] {
        let nsMarkdown = markdown as NSString
        let matches = fencedCodePattern.matches(
            in: markdown,
            range: NSRange(location: 0, length: nsMarkdown.length)
        )
        guard !matches.isEmpty else {
            return [MarkdownSegment(text: markdown, isCodeFence: false)]
        }

        var segments: [MarkdownSegment] = []
        var currentLocation = 0
        for match in matches {
            let range = match.range
            if range.location > currentLocation {
                segments.append(
                    MarkdownSegment(
                        text: nsMarkdown.substring(
                            with: NSRange(location: currentLocation, length: range.location - currentLocation)
                        ),
                        isCodeFence: false
                    )
                )
            }

            segments.append(MarkdownSegment(text: nsMarkdown.substring(with: range), isCodeFence: true))
            currentLocation = range.location + range.length
        }

        if currentLocation < nsMarkdown.length {
            segments.append(
                MarkdownSegment(
                    text: nsMarkdown.substring(from: currentLocation),
                    isCodeFence: false
                )
            )
        }

        return segments
    }

    private static func buildMarkdownImage(_ image: MarkdownImage) -> String {
        let escapedAlt = escapeImageText(image.alt)
        let escapedTitle = image.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? escapeTitleText(image.title!.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let normalizedWidth = image.width.map { max(80, $0) }
        return "![\(escapedAlt)](\(image.src)\(escapedTitle.map { " \"\($0)\"" } ?? ""))\(normalizedWidth.map { "{width=\($0)}" } ?? "")"
    }

    private static func substring(in source: NSString, range: NSRange) -> String {
        guard range.location != NSNotFound else {
            return ""
        }
        return source.substring(with: range)
    }

    private static func escapeImageText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeTitleText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unescapeImageText(_ value: String) -> String {
        value.replacingOccurrences(of: #"\\([\]\\])"#, with: "$1", options: .regularExpression)
    }

    private static func unescapeTitleText(_ value: String) -> String {
        value.replacingOccurrences(of: #"\\(["\\])"#, with: "$1", options: .regularExpression)
    }

    private static func safePathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
    }

    private struct MarkdownImage {
        var alt: String
        var src: String
        var title: String?
        var width: Int?
    }

    private struct MarkdownSegment {
        let text: String
        let isCodeFence: Bool
    }
}

enum AssistantNoteAssetError: LocalizedError {
    case unsupportedType
    case invalidNoteFileName
    case noteNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return "That image type is not supported here."
        case .invalidNoteFileName:
            return "Open Assist could not resolve the note asset folder."
        case .noteNotFound:
            return "That note could not be found."
        }
    }
}

final class AssistantNoteAssetURLSchemeHandler: NSObject, WKURLSchemeHandler {
    typealias Resolver = (AssistantResolvedNoteAssetReference) -> URL?

    private var resolver: Resolver
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        resolver: @escaping Resolver
    ) {
        self.fileManager = fileManager
        self.resolver = resolver
    }

    func updateResolver(_ resolver: @escaping Resolver) {
        self.resolver = resolver
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let requestURL = urlSchemeTask.request.url
        guard let requestURL,
              let assetReference = AssistantNoteAssetSupport.resolveDisplayURL(requestURL),
              let fileURL = resolver(assetReference),
              fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
            )
            return
        }

        let mimeType = AssistantAttachmentSupport.mimeType(forExtension: fileURL.pathExtension.lowercased())
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
