import Foundation

enum InsertionPath: String, CaseIterable {
    case emptyInput = "empty-input"
    case directAccessibility = "direct-accessibility"
    case typedUnicodeEvents = "typed-unicode-events"
    case specialPasteClipboard = "special-paste-clipboard"
    case specialPasteTransientClipboard = "special-paste-transient-clipboard"
}

struct InsertionDecision: Equatable {
    let path: InsertionPath
    let result: TextInserter.Result
}

enum InsertionDecisionModel {
    static func evaluate(
        text: String,
        copyToClipboard: Bool,
        directInsertSucceeded: Bool,
        typingInsertSucceeded: Bool,
        specialPasteSucceeded: Bool
    ) -> InsertionDecision {
        guard !text.isEmpty else {
            return InsertionDecision(path: .emptyInput, result: .empty)
        }

        if directInsertSucceeded {
            return InsertionDecision(path: .directAccessibility, result: .pasted)
        }

        if typingInsertSucceeded {
            return InsertionDecision(path: .typedUnicodeEvents, result: .pasted)
        }

        if copyToClipboard {
            return InsertionDecision(
                path: .specialPasteClipboard,
                result: specialPasteSucceeded ? .pasted : .copiedOnly
            )
        }

        return InsertionDecision(
            path: .specialPasteTransientClipboard,
            result: specialPasteSucceeded ? .pasted : .notInserted
        )
    }
}
