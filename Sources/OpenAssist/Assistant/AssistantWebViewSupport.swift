import AppKit
import SwiftUI
import WebKit

final class AssistantInteractiveWebView: WKWebView {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        if #available(macOS 13.3, *) {
            self.isInspectable = true
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        if #available(macOS 13.3, *) {
            self.isInspectable = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

enum AssistantWebViewThemeBridge {
    static func accentJavaScript(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        let ri = Int(r * 255)
        let gi = Int(g * 255)
        let bi = Int(b * 255)

        let css = "rgb(\(ri),\(gi),\(bi))"
        let accentSoft = "rgba(\(ri),\(gi),\(bi),0.10)"
        let accentStrong = "rgba(\(ri),\(gi),\(bi),0.92)"
        let checkpointHeader = "rgba(\(ri),\(gi),\(bi),0.03)"
        let checkpointCurrentHeader = "rgba(\(ri),\(gi),\(bi),0.09)"
        let checkpointCurrentBorder = "rgba(\(ri),\(gi),\(bi),0.15)"
        let checkpointCurrentText = "rgba(\(ri),\(gi),\(bi),0.95)"
        let checkpointCurrentPill = "rgba(\(ri),\(gi),\(bi),0.12)"

        return """
        (() => {
          const root = document.documentElement.style;
          root.setProperty('--chat-accent', '\(css)');
          root.setProperty('--chat-accent-soft', '\(accentSoft)');
          root.setProperty('--chat-accent-strong', '\(accentStrong)');
          root.setProperty('--chat-checkpoint-header', '\(checkpointHeader)');
          root.setProperty('--chat-checkpoint-current-header', '\(checkpointCurrentHeader)');
          root.setProperty('--chat-checkpoint-current-border', '\(checkpointCurrentBorder)');
          root.setProperty('--chat-checkpoint-current-text', '\(checkpointCurrentText)');
          root.setProperty('--chat-checkpoint-current-pill', '\(checkpointCurrentPill)');
        })();
        """
    }
}
