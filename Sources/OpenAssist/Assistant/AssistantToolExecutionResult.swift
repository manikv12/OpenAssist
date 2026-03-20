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
                dictionary["imageUrl"] = imageURL
            }
            return dictionary
        }
    }

    let contentItems: [ContentItem]
    let success: Bool
    let summary: String
}
