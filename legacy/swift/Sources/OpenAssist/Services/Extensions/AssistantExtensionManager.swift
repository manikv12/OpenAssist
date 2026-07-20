import Foundation

/// Lifecycle and persistence for installed OpenAssist extensions.
///
/// Responsibilities:
///   - Discover extensions on disk under ``AssistantExtensionPaths/extensionsDirectory``
///   - Spawn the extension's entry process when enabled and reap it on stop
///   - Persist enabled state across app launches in `state.json`
///   - Probe the optional health URL declared by the manifest
///
/// Extension code never runs inside the host process — every extension is a
/// child Process. This keeps Swift / non-Swift extensions on equal footing
/// and isolates crashes to the child.
final class AssistantExtensionManager {
    struct InstalledExtension {
        var manifest: AssistantExtensionManifest
        var directory: URL
        var enabled: Bool
        var running: Bool
        var lastError: String?
    }

    private struct PersistedState: Codable {
        var enabledExtensionIDs: [String]
    }

    static let shared = AssistantExtensionManager()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "OpenAssist.ExtensionManager", qos: .utility)
    private var processes: [String: Process] = [:]
    private(set) var installed: [String: InstalledExtension] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Discovery

    /// Reload the on-disk extension list. Must be called at app startup and
    /// any time the user installs/uninstalls something via the CLI.
    @discardableResult
    func reload() -> [InstalledExtension] {
        try? AssistantExtensionPaths.ensureDirectoryExists(fileManager: fileManager)
        let dir = AssistantExtensionPaths.extensionsDirectory(fileManager: fileManager)
        let enabledIDs = Set(loadPersistedState().enabledExtensionIDs)

        var next: [String: InstalledExtension] = [:]
        let entries = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in entries {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            do {
                let manifest = try AssistantExtensionPaths.loadManifest(at: url, fileManager: fileManager)
                next[manifest.id] = InstalledExtension(
                    manifest: manifest,
                    directory: url,
                    enabled: enabledIDs.contains(manifest.id),
                    running: processes[manifest.id]?.isRunning ?? false,
                    lastError: nil
                )
            } catch {
                // Ignore unreadable folders so a single bad manifest can't break discovery.
                continue
            }
        }
        installed = next
        return Array(next.values)
    }

    // MARK: - Persistence

    private func loadPersistedState() -> PersistedState {
        let url = AssistantExtensionPaths.stateFile(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState(enabledExtensionIDs: [])
        }
        return state
    }

    private func savePersistedState() {
        let enabled = installed.values.filter { $0.enabled }.map { $0.manifest.id }.sorted()
        let state = PersistedState(enabledExtensionIDs: enabled)
        let url = AssistantExtensionPaths.stateFile(fileManager: fileManager)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Enable / Disable

    func setEnabled(id: String, enabled: Bool) throws {
        guard var ext = installed[id] else {
            throw AssistantExtensionError.invalidManifest("Unknown extension id: \(id)")
        }
        ext.enabled = enabled
        installed[id] = ext
        savePersistedState()
        if enabled {
            try start(id: id)
        } else {
            stop(id: id)
        }
    }

    // MARK: - Lifecycle

    /// Spawn every enabled extension. Safe to call repeatedly.
    func startEnabled() {
        for ext in installed.values where ext.enabled && !ext.running {
            try? start(id: ext.manifest.id)
        }
    }

    /// Stop every running extension. Used on application terminate.
    func stopAll() {
        for id in Array(processes.keys) {
            stop(id: id)
        }
    }

    func start(id: String) throws {
        guard let ext = installed[id] else {
            throw AssistantExtensionError.invalidManifest("Unknown extension id: \(id)")
        }
        if let existing = processes[id], existing.isRunning { return }

        let process = Process()
        if let working = ext.manifest.entry.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: (working as NSString).expandingTildeInPath)
        } else {
            process.currentDirectoryURL = ext.directory
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ext.manifest.entry.command] + ext.manifest.entry.args

        var env = ProcessInfo.processInfo.environment
        env["OPENASSIST_EXTENSION_ID"] = ext.manifest.id
        env["OPENASSIST_EXTENSION_DIR"] = ext.directory.path
        for (k, v) in ext.manifest.entry.env ?? [:] { env[k] = v }
        process.environment = env

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                if self.processes[id] === proc {
                    self.processes[id] = nil
                    if var current = self.installed[id] {
                        current.running = false
                        if proc.terminationStatus != 0 {
                            current.lastError = "Exited with status \(proc.terminationStatus)"
                        }
                        self.installed[id] = current
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw AssistantExtensionError.spawnFailed(error.localizedDescription)
        }
        processes[id] = process
        if var current = installed[id] {
            current.running = true
            current.lastError = nil
            installed[id] = current
        }
    }

    func stop(id: String) {
        guard let process = processes[id] else { return }
        if process.isRunning {
            process.terminate()
        }
        processes[id] = nil
        if var current = installed[id] {
            current.running = false
            installed[id] = current
        }
    }
}
