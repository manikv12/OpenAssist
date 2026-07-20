import XCTest
@testable import OpenAssist

final class CloudTranscriptionProviderTests: XCTestCase {
    func testCodexSessionProviderDoesNotRequireAPIKey() {
        XCTAssertFalse(CloudTranscriptionProvider.codexSession.requiresAPIKey)
    }

    func testCodexSessionFallbackModelCatalogIncludesDefaultModel() async {
        let service = CloudTranscriptionModelCatalogService()

        let result = await service.fetchModels(
            provider: .codexSession,
            baseURL: CloudTranscriptionProvider.codexSession.defaultBaseURL,
            apiKey: ""
        )

        XCTAssertTrue(result.models.contains { $0.id == CloudTranscriptionProvider.codexSession.defaultModel })
        switch result.source {
        case .fallback:
            break
        case .remote:
            XCTFail("Codex session model loading should currently use the built-in fallback catalog.")
        }
    }
}
