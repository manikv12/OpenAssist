import Foundation

struct AssistantToolExecutionResult: Sendable {
    struct ContentItem: Sendable {
        let type: String
        let text: String?
        let imageURL: String?

        func dictionaryRepresentation() -> [String: Any] {
            var dictionary: [String: Any] = ["type": codexWireType]
            if let text {
                dictionary["text"] = text
            }
            if let imageURL {
                dictionary["image_url"] = imageURL
            }
            return dictionary
        }

        private var codexWireType: String {
            switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "inputText", "input_text":
                return "input_text"
            case "inputImage", "input_image":
                return "input_image"
            default:
                return type
            }
        }
    }

    let contentItems: [ContentItem]
    let success: Bool
    let summary: String
    /// Non-nil when the tool requires the user to log in before proceeding.
    let loginPrompt: AssistantBrowserLoginPrompt?
    let activityMetadata: AssistantAutomationActivityMetadata?

    init(
        contentItems: [ContentItem],
        success: Bool,
        summary: String,
        loginPrompt: AssistantBrowserLoginPrompt? = nil,
        activityMetadata: AssistantAutomationActivityMetadata? = nil
    ) {
        self.contentItems = contentItems
        self.success = success
        self.summary = summary
        self.loginPrompt = loginPrompt
        self.activityMetadata = activityMetadata
    }
}
