import Foundation

/// Headless CLI surface for managing extensions.
///
/// Dispatched from ``AppDelegate.applicationDidFinishLaunching`` when the
/// process is launched with `--cli extension <subcommand>`. Mirrors the
/// existing `--mcp-server` pattern: prints to stdout/stderr and calls
/// `exit()` so the GUI never spins up.
enum AssistantExtensionCLI {
    static func run(arguments: [String]) -> Never {
        guard let subcommand = arguments.first else {
            printUsage()
            exit(2)
        }

        let manager = AssistantExtensionManager.shared
        manager.reload()

        switch subcommand {
        case "list":
            listExtensions(manager: manager)
            exit(0)

        case "install":
            guard let path = arguments.dropFirst().first else {
                FileHandle.standardError.write(Data("error: missing path\n".utf8))
                exit(2)
            }
            install(path: path, manager: manager)

        case "uninstall":
            guard let id = arguments.dropFirst().first else {
                FileHandle.standardError.write(Data("error: missing id\n".utf8))
                exit(2)
            }
            uninstall(id: id, manager: manager)

        case "enable":
            guard let id = arguments.dropFirst().first else {
                FileHandle.standardError.write(Data("error: missing id\n".utf8))
                exit(2)
            }
            setEnabled(id: id, enabled: true, manager: manager)

        case "disable":
            guard let id = arguments.dropFirst().first else {
                FileHandle.standardError.write(Data("error: missing id\n".utf8))
                exit(2)
            }
            setEnabled(id: id, enabled: false, manager: manager)

        case "run":
            guard let id = arguments.dropFirst().first else {
                FileHandle.standardError.write(Data("error: missing id\n".utf8))
                exit(2)
            }
            runForeground(id: id, manager: manager)

        case "path":
            print(AssistantExtensionPaths.extensionsDirectory().path)
            exit(0)

        case "help", "-h", "--help":
            printUsage()
            exit(0)

        default:
            FileHandle.standardError.write(Data("error: unknown subcommand '\(subcommand)'\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - Subcommand implementations

    private static func listExtensions(manager: AssistantExtensionManager) {
        let extensions = manager.installed.values.sorted { $0.manifest.id < $1.manifest.id }
        if extensions.isEmpty {
            print("No extensions installed.")
            print("Install one with: openassist --cli extension install <path>")
            return
        }
        for ext in extensions {
            let state = ext.enabled ? "enabled" : "disabled"
            print("\(ext.manifest.id)\t\(ext.manifest.version)\t\(state)\t\(ext.manifest.name)")
        }
    }

    private static func install(path: String, manager: AssistantExtensionManager) -> Never {
        let expanded = (path as NSString).expandingTildeInPath
        let sourceURL = URL(fileURLWithPath: expanded).standardizedFileURL
        do {
            let manifest = try AssistantExtensionPaths.loadManifest(at: sourceURL)
            let destination = AssistantExtensionPaths.extensionDirectory(id: manifest.id)
            try AssistantExtensionPaths.ensureDirectoryExists()
            if FileManager.default.fileExists(atPath: destination.path) {
                FileHandle.standardError.write(Data("error: \(manifest.id) already installed at \(destination.path)\n".utf8))
                exit(1)
            }
            // We symlink rather than copy, so dev iteration on the source folder
            // stays live. Users who want to vendor the source can copy by hand.
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sourceURL)
            print("Installed \(manifest.id) (\(manifest.version))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func uninstall(id: String, manager: AssistantExtensionManager) -> Never {
        let directory = AssistantExtensionPaths.extensionDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            FileHandle.standardError.write(Data("error: extension \(id) is not installed\n".utf8))
            exit(1)
        }
        do {
            try FileManager.default.removeItem(at: directory)
            print("Uninstalled \(id)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func setEnabled(id: String, enabled: Bool, manager: AssistantExtensionManager) -> Never {
        do {
            try manager.setEnabled(id: id, enabled: enabled)
            print("\(enabled ? "Enabled" : "Disabled") \(id)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Run an extension synchronously in the foreground for development.
    /// Inherits stdout/stderr so logs stream live, and exits with the
    /// child's termination status.
    private static func runForeground(id: String, manager: AssistantExtensionManager) -> Never {
        guard let ext = manager.installed[id] else {
            FileHandle.standardError.write(Data("error: extension \(id) is not installed\n".utf8))
            exit(1)
        }
        let process = Process()
        process.currentDirectoryURL = ext.directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ext.manifest.entry.command] + ext.manifest.entry.args
        var env = ProcessInfo.processInfo.environment
        env["OPENASSIST_EXTENSION_ID"] = ext.manifest.id
        env["OPENASSIST_EXTENSION_DIR"] = ext.directory.path
        for (k, v) in ext.manifest.entry.env ?? [:] { env[k] = v }
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printUsage() {
        let usage = """
        Usage: openassist --cli extension <subcommand>

        Subcommands:
          list                         Show installed extensions
          install <path>               Install an extension from a folder containing extension.json
          uninstall <id>               Remove an installed extension
          enable <id>                  Mark an extension as enabled (auto-starts with the app)
          disable <id>                 Mark an extension as disabled
          run <id>                     Run an extension in the foreground (for development)
          path                         Print the extensions directory
          help                         Show this message

        """
        FileHandle.standardOutput.write(Data(usage.utf8))
    }
}
