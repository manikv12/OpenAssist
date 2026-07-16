import AppKit
import Foundation

@MainActor
func copyAssistantTextToPasteboard(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    _ = pasteboard.setString(trimmed, forType: .string)
}
