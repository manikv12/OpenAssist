import Foundation

/// Resolves the on-disk locations OpenAssist uses for managing extensions.
enum AssistantExtensionPaths {
    /// `~/Library/Application Support/OpenAssist/Extensions`
    static func extensionsDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    /// `~/Library/Application Support/OpenAssist/Extensions/<id>`
    static func extensionDirectory(id: String, fileManager: FileManager = .default) -> URL {
        extensionsDirectory(fileManager: fileManager).appendingPathComponent(id, isDirectory: true)
    }

    /// `~/Library/Application Support/OpenAssist/Extensions/state.json`
    /// Records which extensions are enabled across launches.
    static func stateFile(fileManager: FileManager = .default) -> URL {
        extensionsDirectory(fileManager: fileManager).appendingPathComponent("state.json")
    }

    static func ensureDirectoryExists(fileManager: FileManager = .default) throws {
        let dir = extensionsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Loads and validates the manifest at `<dir>/extension.json`.
    static func loadManifest(at directory: URL, fileManager: FileManager = .default) throws -> AssistantExtensionManifest {
        let manifestURL = directory.appendingPathComponent("extension.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw AssistantExtensionError.manifestNotFound(manifestURL)
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(AssistantExtensionManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
}
