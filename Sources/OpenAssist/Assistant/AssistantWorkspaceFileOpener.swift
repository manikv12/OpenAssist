import AppKit
import Foundation

enum AssistantWorkspaceFileOpener {
    private enum LaunchStyle {
        case openDocuments
        case revealInFinder
    }

    private struct Target {
        let title: String
        let bundleIdentifiers: [String]
        let launchStyle: LaunchStyle
        let remembersAsPreferred: Bool

        var applicationURL: URL? {
            AssistantWorkspaceFileOpener.performOnMain {
                for bundleIdentifier in bundleIdentifiers {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                        return url
                    }
                }
                return nil
            }
        }

        var isInstalled: Bool {
            switch launchStyle {
            case .openDocuments:
                return applicationURL != nil
            case .revealInFinder:
                return true
            }
        }
    }

    private static let preferredTargetIDKey = "assistantPreferredWorkspaceLaunchTargetID"

    // Keep this in sync with the editor picker in AssistantWindowView.
    private static let targets: [Target] = [
        .init(
            title: "VS Code",
            bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Windsurf",
            bundleIdentifiers: ["com.exafunction.windsurf"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Antigravity",
            bundleIdentifiers: ["com.google.antigravity"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Finder",
            bundleIdentifiers: ["com.apple.finder"],
            launchStyle: .revealInFinder,
            remembersAsPreferred: false
        ),
        .init(
            title: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            launchStyle: .openDocuments,
            remembersAsPreferred: false
        ),
        .init(
            title: "Xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        ),
        .init(
            title: "Android Studio",
            bundleIdentifiers: ["com.google.android.studio"],
            launchStyle: .openDocuments,
            remembersAsPreferred: true
        )
    ]

    static func openLink(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        open(url)
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            _ = Self.performOnMain {
                NSWorkspace.shared.open(url)
            }
            return true
        }

        let path = url.path
        if (scheme == "file" || scheme.isEmpty), !path.isEmpty {
            openFileURL(URL(fileURLWithPath: path))
            return true
        }

        return false
    }

    static func openFileURL(_ fileURL: URL) {
        Self.performOnMain {
            let target = preferredTarget()

            switch target.launchStyle {
            case .revealInFinder:
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            case .openDocuments:
                guard let applicationURL = target.applicationURL else {
                    NSWorkspace.shared.open(fileURL)
                    return
                }

                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.promptsUserIfNeeded = false

                NSWorkspace.shared.open(
                    [fileURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                ) { _, error in
                    if error != nil {
                        NSWorkspace.shared.open(fileURL)
                    }
                }
            }
        }
    }

    private static func preferredTarget() -> Target {
        let preferredID = UserDefaults.standard.string(forKey: preferredTargetIDKey)

        if let preferred = targets.first(where: {
            $0.remembersAsPreferred && $0.isInstalled && $0.title == preferredID
        }) {
            return preferred
        }

        return targets.first(where: { $0.remembersAsPreferred && $0.isInstalled })
            ?? targets.first(where: { $0.isInstalled })
            ?? targets.first
            ?? Target(
                title: "Finder",
                bundleIdentifiers: ["com.apple.finder"],
                launchStyle: .revealInFinder,
                remembersAsPreferred: false
            )
    }

    private static func performOnMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }
}
