import Combine
import Foundation

@MainActor
final class AIStudioNavigationState: ObservableObject {
    struct Request: Equatable {
        let id: UUID
        let pageRawValue: String
        let preferredLocalModelID: String?
    }

    static let shared = AIStudioNavigationState()

    @Published private(set) var pendingRequest: Request?

    private init() {}

    func requestOpen(
        pageRawValue: String,
        preferredLocalModelID: String? = nil
    ) {
        let normalizedModelID = preferredLocalModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        pendingRequest = Request(
            id: UUID(),
            pageRawValue: pageRawValue,
            preferredLocalModelID: normalizedModelID
        )
    }

    func clearPendingRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }
}
