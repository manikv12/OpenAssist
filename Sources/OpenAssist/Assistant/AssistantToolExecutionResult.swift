import Foundation

struct AssistantToolExecutionResult: Sendable {
    struct ContentItem: Sendable {
        let type: String
        let text: String?
        let imageURL: String?

        func dictionaryRepresentation() -> [String: Any] {
            var dictionary: [String: Any] = ["type": type]
            if let text {
                dictionary["text"] = text
            }
            if let imageURL {
                dictionary["image_url"] = ["url": imageURL]
            }
            return dictionary
        }
    }

    let contentItems: [ContentItem]
    let success: Bool
    let summary: String
    /// Non-nil when the tool requires the user to log in before proceeding.
    let loginPrompt: AssistantBrowserLoginPrompt?

    init(
        contentItems: [ContentItem],
        success: Bool,
        summary: String,
        loginPrompt: AssistantBrowserLoginPrompt? = nil
    ) {
        self.contentItems = contentItems
        self.success = success
        self.summary = summary
        self.loginPrompt = loginPrompt
    }
}
