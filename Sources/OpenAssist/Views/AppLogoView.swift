import SwiftUI

enum AppLogoVariant {
    case appIcon
    case agentMark

    fileprivate var candidateFileNames: [String] {
        switch self {
        case .appIcon:
            return ["AppIcon", "AppLogo"]
        case .agentMark:
            return ["AppLogo", "OpenAssistLogo", "AppIcon"]
        }
    }

    fileprivate var fallbackSystemSymbolName: String {
        switch self {
        case .appIcon:
            return "app.fill"
        case .agentMark:
            return "brain.head.profile"
        }
    }
}

/// Displays bundled Open Assist branding art from PNG assets.
struct AppLogoView: View {
    var variant: AppLogoVariant = .appIcon
    var size: CGFloat = 256

    var body: some View {
        logoImage
            .renderingMode(.original)
            .antialiased(true)
            .interpolation(.high)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .drawingGroup(opaque: false)
    }

    /// Resolve the bundled app icon image.
    private var logoImage: Image {
        for fileName in variant.candidateFileNames {
            // Look for the processed resource inside the executable's bundle.
            if let url = Bundle.main.url(forResource: fileName, withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                return Image(nsImage: nsImage)
            }

            // Also try the OpenAssist_OpenAssist bundle that SwiftPM may generate.
            if let resourceBundle = Bundle(identifier: "OpenAssist_OpenAssist"),
               let url = resourceBundle.url(forResource: fileName, withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                return Image(nsImage: nsImage)
            }
        }

        // Last resort: load directly from the executable's directory.
        let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let bundlePaths = variant.candidateFileNames.flatMap { fileName in
            [
                "OpenAssist_OpenAssist.bundle/\(fileName).png",
                "\(fileName).png",
            ]
        }
        for subpath in bundlePaths {
            let url = execDir.appendingPathComponent(subpath)
            if let nsImage = NSImage(contentsOf: url) {
                return Image(nsImage: nsImage)
            }
        }
        // Fallback to SF Symbol if the asset is missing at runtime.
        return Image(systemName: variant.fallbackSystemSymbolName)
    }
}

#if DEBUG
#Preview("App Logo") {
    ZStack {
        AppVisualTheme.windowBackground
        AppLogoView(size: 512)
    }
    .frame(width: 600, height: 600)
}
#endif
