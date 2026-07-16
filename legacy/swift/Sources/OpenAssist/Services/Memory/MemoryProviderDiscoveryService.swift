import Foundation

struct MemoryDiscoveredProvider: Identifiable, Hashable, Sendable {
    let id: String
    let kind: MemoryProviderKind
    let name: String
    let detail: String
    let sourceCount: Int
}

struct MemoryDiscoveredSourceFolder: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let providerID: String
}

struct MemoryDiscoveredSource: Identifiable, Hashable, Sendable {
    let id: String
    let provider: MemoryProviderKind
    let rootURL: URL
    let displayName: String
    let detail: String
}

struct MemoryProviderDiscoveryResult: Hashable, Sendable {
    let providers: [MemoryDiscoveredProvider]
    let sourceFolders: [MemoryDiscoveredSourceFolder]
    let sources: [MemoryDiscoveredSource]
}

final class MemoryProviderDiscoveryService {
    static let shared = MemoryProviderDiscoveryService()

    private struct ProviderSpec {
        let kind: MemoryProviderKind
        let detail: String
        let candidateRelativePaths: [String]
    }

    // Session indexing intentionally focuses on provider transcript artifacts only.
    private static let sessionFileExtensions: Set<String> = [
        "jsonl", "ndjson", "json", "db", "sqlite", "sqlite3", "vscdb"
    ]

    private static let sessionFilenameNeedles: [String] = [
        "conversation", "conversations", "chat", "history", "session", "sessions",
        "prompt", "message", "messages", "rollout", "thread", "store", "composer"
    ]

    private static let excludedDirectoryNames: Set<String> = [
        "cache", "caches", "tmp", "temp", "logs", "node_modules", ".git",
        "gpucache", "code cache", "indexeddb", "service worker", "blob_storage"
    ]

    private static let providerSpecs: [ProviderSpec] = [
        ProviderSpec(
            kind: .codex,
            detail: "Local Codex sessions and conversation artifacts.",
            candidateRelativePaths: [
                ".codex/sessions",
                ".codex/archived_sessions",
                "Library/Application Support/Codex/sessions",
                "Library/Application Support/Codex/archived_sessions"
            ]
        ),
        ProviderSpec(
            kind: .opencode,
            detail: "OpenCode local sessions and indexing files.",
            candidateRelativePaths: [
                ".local/state/opencode",
                ".opencode",
                "Library/Application Support/OpenCode/sessions"
            ]
        ),
        ProviderSpec(
            kind: .claude,
            detail: "Claude desktop and CLI local conversation exports.",
            candidateRelativePaths: [
                ".claude",
                ".claude/projects",
                ".claude/tasks"
            ]
        ),
        ProviderSpec(
            kind: .copilot,
            detail: "GitHub Copilot and Copilot Chat local data stores.",
            candidateRelativePaths: [
                ".config/github-copilot/sessions",
                "Library/Application Support/Code/User/globalStorage/github.copilot-chat"
            ]
        ),
        ProviderSpec(
            kind: .cursor,
            detail: "Cursor editor conversation and workspace memory data.",
            candidateRelativePaths: [
                ".cursor/chats",
                "Library/Application Support/Cursor/User/workspaceStorage"
            ]
        ),
        ProviderSpec(
            kind: .kimi,
            detail: "Kimi local app conversation and cache exports.",
            candidateRelativePaths: [
                ".kimi/sessions",
                ".kimi/history"
            ]
        ),
        ProviderSpec(
            kind: .gemini,
            detail: "Gemini local app history and workspace exports.",
            candidateRelativePaths: [
                ".gemini/sessions",
                ".gemini/history"
            ]
        ),
        ProviderSpec(
            kind: .windsurf,
            detail: "Windsurf editor workspace and chat history data.",
            candidateRelativePaths: [
                ".windsurf/chats",
                ".windsurf/User/workspaceStorage",
                "Library/Application Support/Windsurf/User/workspaceStorage"
            ]
        ),
        ProviderSpec(
            kind: .codeium,
            detail: "Codeium local extension storage and metadata.",
            candidateRelativePaths: [
                ".codeium/windsurf",
                ".codeium/sessions",
                "Library/Application Support/Code/User/globalStorage/codeium.codeium"
            ]
        )
    ]

    private let homeURL: URL
    private let fileManager: FileManager
    private let maxDepth: Int
    private let maxVisitedEntriesPerCandidate: Int

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        maxDepth: Int = 5,
        maxVisitedEntriesPerCandidate: Int = 2_500
    ) {
        self.homeURL = homeURL
        self.fileManager = fileManager
        self.maxDepth = max(1, maxDepth)
        self.maxVisitedEntriesPerCandidate = max(100, maxVisitedEntriesPerCandidate)
    }

    func discover(
        enabledProviders: Set<String>? = nil,
        enabledSourceFolders: Set<String>? = nil
    ) -> MemoryProviderDiscoveryResult {
        let normalizedProviderFilter: Set<String>? = enabledProviders.map { Set($0.map(normalizeIdentifier)) }
        let normalizedFolderFilter: Set<String>? = enabledSourceFolders.map { Set($0.map(normalizePath)) }

        var sourcesByProvider: [MemoryProviderKind: [MemoryDiscoveredSource]] = [:]
        var seenPaths = Set<String>()

        for spec in Self.providerSpecs {
            let providerID = spec.kind.rawValue
            if let filter = normalizedProviderFilter, !filter.contains(providerID) {
                continue
            }

            var providerSources: [MemoryDiscoveredSource] = []
            for candidatePath in spec.candidateRelativePaths {
                let rootURL = homeURL
                    .appendingPathComponent(candidatePath, isDirectory: true)
                    .standardizedFileURL
                let rootPath = normalizePath(rootURL.path)

                guard !rootPath.isEmpty else { continue }
                guard seenPaths.insert("\(providerID)|\(rootPath)").inserted else { continue }
                guard fileManager.directoryExists(atPath: rootPath) else { continue }
                guard containsParseableArtifacts(in: rootURL) else { continue }
                if let filter = normalizedFolderFilter, !filter.contains(rootPath) {
                    continue
                }

                providerSources.append(
                    MemoryDiscoveredSource(
                        id: "\(providerID):\(rootPath)",
                        provider: spec.kind,
                        rootURL: rootURL,
                        displayName: spec.kind.displayName,
                        detail: spec.detail
                    )
                )
            }

            if !providerSources.isEmpty {
                sourcesByProvider[spec.kind] = providerSources
            }
        }

        let providers = sourcesByProvider
            .map { (kind, sources) in
                MemoryDiscoveredProvider(
                    id: kind.rawValue,
                    kind: kind,
                    name: kind.displayName,
                    detail: Self.providerSpecs.first(where: { $0.kind == kind })?.detail ?? "\(kind.displayName) provider",
                    sourceCount: sources.count
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let allSources = sourcesByProvider
            .values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                lhs.rootURL.path.localizedCaseInsensitiveCompare(rhs.rootURL.path) == .orderedAscending
            }

        let sourceFolders = allSources.map { source in
            let path = normalizePath(source.rootURL.path)
            return MemoryDiscoveredSourceFolder(
                id: path,
                name: folderName(for: source),
                path: path,
                providerID: source.provider.rawValue
            )
        }

        return MemoryProviderDiscoveryResult(
            providers: providers,
            sourceFolders: sourceFolders,
            sources: allSources
        )
    }

    private func folderName(for source: MemoryDiscoveredSource) -> String {
        let lastComponent = source.rootURL.lastPathComponent
        if !lastComponent.isEmpty {
            return "\(source.provider.displayName) - \(lastComponent)"
        }
        return "\(source.provider.displayName) Source"
    }

    private func normalizeIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizePath(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    }

    private func containsParseableArtifacts(in rootURL: URL) -> Bool {
        let rootPath = rootURL.path
        let rootDepth = rootPath.split(separator: "/").count
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .nameKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        var visited = 0
        for case let candidateURL as URL in enumerator {
            visited += 1
            if visited > maxVisitedEntriesPerCandidate {
                break
            }

            guard let values = try? candidateURL.resourceValues(forKeys: Set(keys)) else { continue }
            let depth = candidateURL.path.split(separator: "/").count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            if values.isDirectory == true {
                let name = (values.name ?? candidateURL.lastPathComponent).lowercased()
                if Self.excludedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard let fileName = values.name?.lowercased() else { continue }
            guard isSessionFile(named: fileName, path: candidateURL.path.lowercased()) else { continue }

            if let size = values.fileSize, size > 10_000_000 {
                continue
            }
            return true
        }
        return false
    }

    private func isSessionFile(named fileName: String, path: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard Self.sessionFileExtensions.contains(ext) else {
            return false
        }

        if fileName.hasPrefix("rollout-") {
            return true
        }

        if Self.sessionFilenameNeedles.contains(where: { fileName.contains($0) }) {
            return true
        }

        let sessionPathNeedles = [
            "/sessions/",
            "/archived_sessions/",
            "/chats/",
            "/conversations/",
            "/projects/",
            "/workspacestorage/"
        ]
        return sessionPathNeedles.contains(where: { path.contains($0) })
    }
}

private extension FileManager {
    func directoryExists(atPath path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}
