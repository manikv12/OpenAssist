import SwiftUI

/// Displays the Open Assist app icon from the bundled PNG asset.
struct AppLogoView: View {
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
        for fileName in ["AppIcon", "AppLogo"] {
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
        for subpath in [
            "OpenAssist_OpenAssist.bundle/AppIcon.png",
            "OpenAssist_OpenAssist.bundle/AppLogo.png",
            "AppIcon.png",
            "AppLogo.png",
        ] {
            let url = execDir.appendingPathComponent(subpath)
            if let nsImage = NSImage(contentsOf: url) {
                return Image(nsImage: nsImage)
            }
        }
        // Fallback to SF Symbol if the asset is missing at runtime.
        return Image(systemName: "mic.circle")
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
