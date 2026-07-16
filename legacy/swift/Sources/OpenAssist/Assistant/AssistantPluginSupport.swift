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
    let iconRootPath: String?
    let iconDataURL: String?

    var id: String { pluginID }

    init(
        pluginID: String,
        displayName: String,
        summary: String?,
        needsSetup: Bool,
        iconPath: String?,
        iconRootPath: String?,
        iconDataURL: String? = nil
    ) {
        self.pluginID = pluginID
        self.displayName = displayName
        self.summary = summary
        self.needsSetup = needsSetup
        self.iconPath = iconPath
        self.iconRootPath = iconRootPath
        self.iconDataURL = iconDataURL
            ?? assistantPluginIconDataURL(for: iconPath, allowedRootPath: iconRootPath)
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID
        case displayName
        case summary
        case needsSetup
        case iconPath
        case iconRootPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pluginID = try container.decode(String.self, forKey: .pluginID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let summary = try container.decodeIfPresent(String.self, forKey: .summary)
        let needsSetup = try container.decode(Bool.self, forKey: .needsSetup)
        let iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        let iconRootPath = try container.decodeIfPresent(String.self, forKey: .iconRootPath)
        self.init(
            pluginID: pluginID,
            displayName: displayName,
            summary: summary,
            needsSetup: needsSetup,
            iconPath: iconPath,
            iconRootPath: iconRootPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(needsSetup, forKey: .needsSetup)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encodeIfPresent(iconRootPath, forKey: .iconRootPath)
    }
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
private let assistantCodexPluginIconAllowedExtensions: Set<String> = [
    "png",
    "jpg",
    "jpeg",
    "gif",
    "webp",
    "bmp",
    "tif",
    "tiff",
    "svg",
    "icns",
]
private let assistantCodexPluginIconMaxBytes = 512 * 1024
private let assistantCodexPluginIconDataURLCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 128
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
}()

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

func assistantPluginIconDataURL(
    for path: String?,
    allowedRootPath: String? = nil
) -> String? {
    guard
        let fileURL = assistantNormalizedPluginIconFileURL(path),
        let cacheKey = assistantPluginIconCacheKey(
            for: fileURL,
            allowedRootPath: allowedRootPath
        )
    else {
        return nil
    }

    if let cached = assistantCodexPluginIconDataURLCache.object(forKey: cacheKey) {
        return cached as String
    }

    guard assistantPluginIconIsAllowed(fileURL, allowedRootPath: allowedRootPath) else { return nil }
    guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return nil }
    let mimeType = assistantPluginIconMIMEType(for: fileURL.pathExtension)
    let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
    assistantCodexPluginIconDataURLCache.setObject(dataURL as NSString, forKey: cacheKey, cost: data.count)
    return dataURL
}

private func assistantNormalizedPluginIconFileURL(_ path: String?) -> URL? {
    guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    if let url = URL(string: trimmed), url.isFileURL {
        return url.standardizedFileURL
    }

    let expandedPath = NSString(string: trimmed).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath).standardizedFileURL
}

private func assistantPluginIconCacheKey(
    for fileURL: URL,
    allowedRootPath: String?
) -> NSString? {
    let rootKey = assistantNormalizedPluginIconFileURL(allowedRootPath)?
        .path
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
        ?? "noroot"
    return "\(rootKey)|\(fileURL.path)" as NSString
}

private func assistantPluginIconIsAllowed(
    _ fileURL: URL,
    allowedRootPath: String?
) -> Bool {
    let pathExtension = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard assistantCodexPluginIconAllowedExtensions.contains(pathExtension) else { return false }

    guard
        let allowedRootURL = assistantNormalizedPluginIconFileURL(allowedRootPath),
        assistantPluginIconPath(fileURL.path, isWithin: allowedRootURL.path)
    else {
        return false
    }

    let resourceValues = try? fileURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
    ])
    guard resourceValues?.isRegularFile == true else { return false }
    guard let fileSize = resourceValues?.fileSize, fileSize > 0, fileSize <= assistantCodexPluginIconMaxBytes
    else {
        return false
    }

    return true
}

private func assistantPluginIconPath(
    _ candidatePath: String,
    isWithin allowedRootPath: String
) -> Bool {
    if candidatePath == allowedRootPath {
        return true
    }
    let normalizedRoot = allowedRootPath.hasSuffix("/") ? allowedRootPath : allowedRootPath + "/"
    return candidatePath.hasPrefix(normalizedRoot)
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
