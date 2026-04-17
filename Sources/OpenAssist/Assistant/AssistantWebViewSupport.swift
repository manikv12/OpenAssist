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
    @MainActor
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
        let linkColor = accentStrong
        let usesUnifiedDarkAssistantTheme = AppVisualTheme.isDarkAppearance

        let darkOverrides = [
            "--chat-bg": "rgb(13,17,23)",
            "--chat-window-fill": "rgba(13,17,23,0.96)",
            "--chat-window-fill-strong": "rgba(13,17,23,0.985)",
            "--chat-overlay": "rgba(13,17,23,1)",
            "--chat-overlay-fade": "rgba(13,17,23,0)",
            "--chat-surface": "rgba(22,27,34,0.96)",
            "--chat-surface-hover": "rgba(33,38,45,0.98)",
            "--chat-panel": "rgba(22,27,34,0.88)",
            "--chat-panel-hover": "rgba(33,38,45,0.92)",
            "--chat-border": "rgba(48,54,61,0.66)",
            "--chat-border-strong": "rgba(48,54,61,0.88)",
            "--chat-user-bubble": "rgba(33,38,45,0.96)",
            "--chat-user-bubble-hover": "rgba(48,54,61,0.78)",
            "--chat-chip": "rgba(33,38,45,0.74)",
            "--chat-chip-hover": "rgba(48,54,61,0.70)",
            "--chat-code-bg": "rgb(22,27,34)",
            "--chat-link": linkColor
        ]
        let lightOverrides = [
            "--chat-bg": "rgb(250,252,255)",
            "--chat-window-fill": "rgba(250,252,255,0.88)",
            "--chat-window-fill-strong": "rgba(255,255,255,0.97)",
            "--chat-overlay": "rgba(250,252,255,1)",
            "--chat-overlay-fade": "rgba(250,252,255,0)",
            "--chat-surface": "rgba(18,24,38,0.05)",
            "--chat-surface-hover": "rgba(18,24,38,0.08)",
            "--chat-panel": "rgba(18,24,38,0.035)",
            "--chat-panel-hover": "rgba(18,24,38,0.05)",
            "--chat-border": "rgba(18,24,38,0.10)",
            "--chat-border-strong": "rgba(18,24,38,0.16)",
            "--chat-user-bubble": "rgba(18,24,38,0.05)",
            "--chat-user-bubble-hover": "rgba(18,24,38,0.08)",
            "--chat-chip": "rgba(18,24,38,0.045)",
            "--chat-chip-hover": "rgba(18,24,38,0.07)",
            "--chat-code-bg": "rgb(243,246,250)",
            "--chat-link": linkColor
        ]
        let selectedOverrides = usesUnifiedDarkAssistantTheme ? darkOverrides : lightOverrides
        let assistantOverrideJS = selectedOverrides.keys.sorted().compactMap { key in
            guard let value = selectedOverrides[key] else { return nil }
            return "root.setProperty('\(key)', '\(value)');"
        }.joined(separator: "\n      ")

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
          \(assistantOverrideJS)
        })();
        """
    }
}
