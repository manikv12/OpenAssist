import Foundation

struct AssistantCodexPromptInputItem: Equatable, Sendable {
    enum Kind: String, Sendable {
        case text
        case skill
        case mention
    }

    let kind: Kind
    let text: String?
    let name: String?
    let path: String?

    static func text(_ value: String) -> AssistantCodexPromptInputItem {
        AssistantCodexPromptInputItem(kind: .text, text: value, name: nil, path: nil)
    }

    static func skill(name: String, path: String) -> AssistantCodexPromptInputItem {
        AssistantCodexPromptInputItem(kind: .skill, text: nil, name: name, path: path)
    }

    static func mention(name: String, path: String) -> AssistantCodexPromptInputItem {
        AssistantCodexPromptInputItem(kind: .mention, text: nil, name: name, path: path)
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = ["type": kind.rawValue]
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            json["text"] = text
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            json["name"] = name
        }
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            json["path"] = path
        }
        return json
    }
}

struct AssistantCodexPluginSkill: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let path: String
    let summary: String?

    var id: String { path.isEmpty ? name.lowercased() : path.lowercased() }
}

struct AssistantCodexPluginApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    var mentionPath: String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "app://\(trimmed)"
    }
}

struct AssistantCodexPluginAppStatus: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let installURL: String?
    let isAccessible: Bool
    let isEnabled: Bool
    let pluginDisplayNames: [String]

    var needsSetup: Bool {
        !isAccessible || !isEnabled
    }
}

struct AssistantCodexPluginMCPServer: Identifiable, Equatable, Sendable {
    let name: String

    var id: String { name.lowercased() }
}

struct AssistantCodexPluginMCPServerStatus: Identifiable, Equatable, Sendable {
    let name: String
    let authStatus: String?
    let toolCount: Int
    let resourceCount: Int
    let resourceTemplateCount: Int

    var id: String { name.lowercased() }

    var needsSetup: Bool {
        authStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "notloggedin"
    }
}

struct AssistantCodexPluginSummary: Identifiable, Equatable, Sendable {
    let id: String
    let pluginName: String
    let displayName: String
    let iconPath: String?
    let marketplaceName: String
    let marketplacePath: String
    let source: String?
    let summary: String?
    let isInstalled: Bool
    let isEnabled: Bool
    let installPolicy: String?
    let authPolicy: String?
    let interfaceKind: String?
}

struct AssistantCodexPluginDetail: Identifiable, Equatable, Sendable {
    let id: String
    let pluginName: String
    let displayName: String
    let iconPath: String?
    let marketplaceName: String
    let marketplacePath: String
    let summary: String?
    let description: String?
    let skills: [AssistantCodexPluginSkill]
    let apps: [AssistantCodexPluginApp]
    let mcpServers: [AssistantCodexPluginMCPServer]
    let starterPrompts: [String]
}

struct AssistantComposerPluginSelection: Identifiable, Equatable, Codable, Sendable {
    let pluginID: String
    let displayName: String
    let summary: String?
    let needsSetup: Bool
    let iconPath: String?

    var id: String { pluginID }
}

enum AssistantCodexPluginReadinessState: String, Equatable, Sendable {
    case ready
    case needsSetup
    case available
}

struct AssistantCodexPluginReadiness: Equatable, Sendable {
    let state: AssistantCodexPluginReadinessState
    let appStatuses: [AssistantCodexPluginAppStatus]
    let mcpStatuses: [AssistantCodexPluginMCPServerStatus]

    var isReady: Bool {
        state == .ready
    }
}

private let assistantCodexPluginWordJoiners = CharacterSet(charactersIn: "-_")
private let assistantCodexPluginIconDataURLCache = NSCache<NSString, NSString>()

func assistantDisplayPluginName(
    pluginName: String,
    fallbackDisplayName: String? = nil
) -> String {
    if let fallbackDisplayName = fallbackDisplayName?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty {
        return fallbackDisplayName
    }

    let trimmed = pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Plugin" }

    let components = trimmed.components(separatedBy: assistantCodexPluginWordJoiners)
        .filter { !$0.isEmpty }
    guard !components.isEmpty else { return trimmed.capitalized }
    return components.map { component in
        if component.count <= 3 {
            return component.uppercased()
        }
        return component.prefix(1).uppercased() + component.dropFirst()
    }.joined(separator: " ")
}

func assistantPluginIconDataURL(for path: String?) -> String? {
    guard let normalizedPath = assistantNormalizedPluginIconPath(path) else { return nil }

    let cacheKey = normalizedPath as NSString
    if let cached = assistantCodexPluginIconDataURLCache.object(forKey: cacheKey) {
        return cached as String
    }

    let fileURL: URL
    if let url = URL(string: normalizedPath), url.isFileURL {
        fileURL = url
    } else {
        fileURL = URL(fileURLWithPath: normalizedPath)
    }

    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let mimeType = assistantPluginIconMIMEType(for: fileURL.pathExtension)
    let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
    assistantCodexPluginIconDataURLCache.setObject(dataURL as NSString, forKey: cacheKey, cost: data.count)
    return dataURL
}

private func assistantNormalizedPluginIconPath(_ path: String?) -> String? {
    guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    if let url = URL(string: trimmed), url.isFileURL {
        return url.absoluteString
    }

    return NSString(string: trimmed).expandingTildeInPath
}

private func assistantPluginIconMIMEType(for pathExtension: String) -> String {
    switch pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "svg":
        return "image/svg+xml"
    case "jpg", "jpeg":
        return "image/jpeg"
    case "gif":
        return "image/gif"
    case "webp":
        return "image/webp"
    case "bmp":
        return "image/bmp"
    case "tif", "tiff":
        return "image/tiff"
    case "icns":
        return "image/icns"
    default:
        return "image/png"
    }
}
