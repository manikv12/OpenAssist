import XCTest
@testable import OpenAssist

final class LocalAIModelCatalogTests: XCTestCase {
    func testCuratedModelsIncludeGemma4Variants() {
        let ids = Set(LocalAIModelCatalog.curatedModels.map { $0.id.lowercased() })

        XCTAssertTrue(ids.contains("gemma4:e2b"))
        XCTAssertTrue(ids.contains("gemma4:e4b"))
        XCTAssertTrue(ids.contains("gemma4:26b"))
        XCTAssertTrue(ids.contains("gemma4:31b"))
    }

    func testRecommendedModelStaysQwenForSharedLocalAIScreen() {
        XCTAssertEqual(LocalAIModelCatalog.recommendedModel.id, "qwen2.5:3b")
    }

    func testModelLookupMatchesGemma4CaseInsensitively() {
        let option = LocalAIModelCatalog.model(withID: "GEMMA4:E4B")

        XCTAssertEqual(option?.id, "gemma4:e4b")
        XCTAssertEqual(option?.displayName, "Gemma 4 E4B")
    }
}
