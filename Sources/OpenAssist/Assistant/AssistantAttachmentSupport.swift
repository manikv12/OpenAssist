import AppKit
import UniformTypeIdentifiers

enum AssistantAttachmentSupport {
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

    static func openFilePicker(onComplete: @escaping @MainActor ([AssistantAttachment]) -> Void) {
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
}
