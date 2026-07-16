import AppKit
import UniformTypeIdentifiers

enum AssistantAttachmentSupport {
    static let imageContentTypes: [UTType] = [
        .image
    ]

    static let allowedContentTypes: [UTType] = [
        .image,
        .plainText,
        .json,
        .yaml,
        .xml,
        .html,
        .sourceCode,
        .pdf,
        .data
    ]

    static func openFilePicker(
        allowedContentTypes: [UTType] = Self.allowedContentTypes,
        onComplete: @escaping @MainActor ([AssistantAttachment]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedContentTypes
        panel.begin { response in
            guard response == .OK else { return }
            let attachments = panel.urls.compactMap { attachment(from: $0) }
            Task { @MainActor in
                onComplete(attachments)
            }
        }
    }

    static func handleDrop(
        _ providers: [NSItemProvider],
        onAttachment: @escaping @MainActor (AssistantAttachment) -> Void
    ) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let resolvedURL: URL? = {
                        if let url = item as? URL { return url }
                        if let nsurl = item as? NSURL { return nsurl as URL }
                        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                        return nil
                    }()
                    guard let url = resolvedURL,
                          let attachment = attachment(from: url) else { return }
                    Task { @MainActor in
                        onAttachment(attachment)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { item, _ in
                    guard let image = item as? NSImage,
                          let attachment = attachment(from: image) else { return }
                    Task { @MainActor in
                        onAttachment(attachment)
                    }
                }
            }
        }
    }

    static func attachment(fromPasteboard pasteboard: NSPasteboard) -> AssistantAttachment? {
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let firstImage = images.first,
           let attachment = attachment(from: firstImage) {
            return attachment
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let attachment = attachment(from: url) {
                    return attachment
                }
            }
        }

        return nil
    }

    static func attachment(from image: NSImage, filename: String = "pasted-image.png") -> AssistantAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return AssistantAttachment(filename: filename, data: png, mimeType: "image/png")
    }

    static func attachment(fromDataURL rawValue: String, suggestedFilename: String? = nil) -> AssistantAttachment? {
        guard let commaIndex = rawValue.firstIndex(of: ",") else { return nil }

        let metadata = String(rawValue[..<commaIndex])
        let encodedPayload = String(rawValue[rawValue.index(after: commaIndex)...])

        guard metadata.hasPrefix("data:"),
              metadata.contains(";base64"),
              let data = Data(base64Encoded: encodedPayload) else {
            return nil
        }

        let mimeType = String(metadata.dropFirst(5).split(separator: ";").first ?? "application/octet-stream")
        let filename = normalizedAttachmentFilename(
            suggestedFilename,
            mimeType: mimeType,
            defaultStem: mimeType.hasPrefix("image/") ? "pasted-image" : "pasted-file"
        )

        return AssistantAttachment(filename: filename, data: data, mimeType: mimeType)
    }

    static func attachment(from url: URL) -> AssistantAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return AssistantAttachment(
            filename: url.lastPathComponent,
            data: data,
            mimeType: mimeType(forExtension: url.pathExtension.lowercased())
        )
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "txt", "md", "log": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "xml": return "text/xml"
        case "yaml", "yml": return "text/yaml"
        case "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h", "m", "rb", "sh", "zsh", "bash":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }

    private static func normalizedAttachmentFilename(
        _ rawFilename: String?,
        mimeType: String,
        defaultStem: String
    ) -> String {
        let trimmedName = rawFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")

        let fallbackExtension =
            UTType(mimeType: mimeType)?.preferredFilenameExtension
            ?? fallbackExtension(for: mimeType)

        guard let trimmedName, !trimmedName.isEmpty else {
            if let fallbackExtension {
                return "\(defaultStem).\(fallbackExtension)"
            }
            return defaultStem
        }

        if URL(fileURLWithPath: trimmedName).pathExtension.isEmpty,
           let fallbackExtension {
            return "\(trimmedName).\(fallbackExtension)"
        }

        return trimmedName
    }

    private static func fallbackExtension(for mimeType: String) -> String? {
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
        case "application/pdf":
            return "pdf"
        case "application/json":
            return "json"
        case "text/plain":
            return "txt"
        case "text/html":
            return "html"
        case "text/xml":
            return "xml"
        case "text/yaml":
            return "yaml"
        default:
            return nil
        }
    }
}
