import Foundation

enum InsertionRetryPlan: Equatable {
    case retry(delay: TimeInterval, nextRetriesRemaining: Int)
    case complete(statusMessage: String?)
}

enum InsertionRetryPolicy {
    static let retryDelay: TimeInterval = 0.12

    static func plan(
        for result: TextInserter.Result,
        retriesRemaining: Int,
        debugStatus: String? = nil
    ) -> InsertionRetryPlan {
        let boundedRetries = max(0, retriesRemaining)

        switch result {
        case .pasted:
            return .complete(statusMessage: "Ready")
        case .copiedOnly:
            if boundedRetries > 0 {
                return .retry(delay: retryDelay, nextRetriesRemaining: boundedRetries - 1)
            }
            return .complete(statusMessage: withDebug("Copied to clipboard", debugStatus: debugStatus))
        case .notInserted:
            if boundedRetries > 0 {
                return .retry(delay: retryDelay, nextRetriesRemaining: boundedRetries - 1)
            }
            return .complete(statusMessage: withDebug("Paste unavailable", debugStatus: debugStatus))
        case .empty:
            return .complete(statusMessage: nil)
        }
    }

    private static func withDebug(_ base: String, debugStatus: String?) -> String {
        guard let debugStatus, !debugStatus.isEmpty else {
            return base
        }
        return "\(base) [\(debugStatus)]"
    }
}
