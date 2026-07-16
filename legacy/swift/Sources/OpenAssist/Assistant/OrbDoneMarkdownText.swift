import SwiftUI

struct OrbDoneMarkdownText: View {
    let text: String

    var body: some View {
        AssistantRichTextView(
            contentID: "orb-done-\(text.hashValue)",
            text: text,
            mode: .finalMarkdown,
            variant: .orbDone
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
