import Foundation

/// Manifest describing a process-based extension that OpenAssist can host.
///
/// Extensions live in the user's extensions directory (see ``AssistantExtensionPaths``)
/// or in any folder added via the CLI. Each extension folder contains a
/// `extension.json` file conforming to this schema. Extensions are external
/// processes (Node, Python, native binaries) — OpenAssist supervises them but
/// does not load their code in-process.
struct AssistantExtensionManifest: Codable, Equatable {
    enum EntryKind: String, Codable {
        case process
        case mcp
    }

    struct Entry: Codable, Equatable {
        var kind: EntryKind
        var command: String
        var args: [String]
        var workingDirectory: String?
        var env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case kind = "type"
            case command, args, workingDirectory, env
        }
    }

    struct Health: Codable, Equatable {
        /// Optional HTTP URL the extension exposes; OpenAssist polls it to
        /// confirm the process came up. Use `{port}` placeholders if you
        /// pass the port via env.
        var url: String?
        /// Number of seconds to wait before the first health probe.
        var startupGraceSeconds: Double?
        /// Interval between probes once the extension is running.
        var intervalSeconds: Double?
    }

    struct UI: Codable, Equatable {
        /// URL the helper exposes for an embedded UI (e.g. tablet dashboard).
        /// May contain `{port}` placeholders that the extension fills in.
        var url: String?
        /// Suggested display title for the embedded UI tab.
        var title: String?
    }

    var id: String
    var name: String
    var version: String
    var description: String?
    var entry: Entry
    var capabilities: [String]?
    var health: Health?
    var ui: UI?

    /// Validate the manifest's required fields. Throws ``AssistantExtensionError``
    /// when invariants are violated so the caller can surface a clean message.
    func validate() throws {
        if id.isEmpty { throw AssistantExtensionError.invalidManifest("id is required") }
        if name.isEmpty { throw AssistantExtensionError.invalidManifest("name is required") }
        if entry.command.isEmpty {
            throw AssistantExtensionError.invalidManifest("entry.command is required")
        }
    }
}

enum AssistantExtensionError: Error, CustomStringConvertible {
    case invalidManifest(String)
    case manifestNotFound(URL)
    case spawnFailed(String)
    case duplicateID(String)

    var description: String {
        switch self {
        case .invalidManifest(let reason): return "Invalid extension manifest: \(reason)"
        case .manifestNotFound(let url): return "extension.json not found at \(url.path)"
        case .spawnFailed(let reason): return "Failed to spawn extension: \(reason)"
        case .duplicateID(let id): return "Extension id \(id) is already registered"
        }
    }
}
