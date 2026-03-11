import Foundation

// MARK: - Models

enum SupportedBrowser: String, CaseIterable, Identifiable, Codable {
    case chrome = "Google Chrome"
    case brave = "Brave Browser"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        }
    }

    var executableName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .brave: return "Brave Browser"
        }
    }

    var playwrightChannel: String {
        switch self {
        case .chrome: return "chrome"
        case .brave: return "brave"
        }
    }

    fileprivate var localStatePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .chrome:
            return "\(home)/Library/Application Support/Google/Chrome/Local State"
        case .brave:
            return "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Local State"
        }
    }

    fileprivate var userDataDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .chrome:
            return "\(home)/Library/Application Support/Google/Chrome"
        case .brave:
            return "\(home)/Library/Application Support/BraveSoftware/Brave-Browser"
        }
    }
}

struct BrowserProfile: Identifiable, Hashable, Codable {
    let browser: SupportedBrowser
    let directoryName: String
    let displayName: String
    let gaiaName: String?

    var id: String { "\(browser.rawValue)|\(directoryName)" }

    var userDataDir: String { browser.userDataDir }

    var profilePath: String { "\(browser.userDataDir)/\(directoryName)" }

    var label: String {
        let name = displayName.isEmpty ? directoryName : displayName
        if let gaia = gaiaName, !gaia.isEmpty {
            return "\(name) (\(gaia))"
        }
        return name
    }
}

// MARK: - Manager

final class BrowserProfileManager {
    static let shared = BrowserProfileManager()

    private init() {}

    func installedBrowsers() -> [SupportedBrowser] {
        SupportedBrowser.allCases.filter { browser in
            FileManager.default.fileExists(atPath: browser.localStatePath)
        }
    }

    func profiles(for browser: SupportedBrowser) -> [BrowserProfile] {
        guard let data = FileManager.default.contents(atPath: browser.localStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileSection = json["profile"] as? [String: Any],
              let infoCache = profileSection["info_cache"] as? [String: Any] else {
            return []
        }

        return infoCache.compactMap { key, value -> BrowserProfile? in
            guard let info = value as? [String: Any] else { return nil }
            let name = info["name"] as? String ?? key
            let gaia = info["gaia_name"] as? String
            return BrowserProfile(
                browser: browser,
                directoryName: key,
                displayName: name,
                gaiaName: gaia
            )
        }
        .sorted { $0.directoryName < $1.directoryName }
    }

    func allProfiles() -> [BrowserProfile] {
        installedBrowsers().flatMap { profiles(for: $0) }
    }

    func profile(withID id: String) -> BrowserProfile? {
        allProfiles().first { $0.id == id }
    }
}
