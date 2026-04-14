import XCTest
@testable import OpenAssist

final class AssistantGemma4ModelCatalogTests: XCTestCase {
    private func gib(_ value: UInt64) -> UInt64 {
        value * 1_073_741_824
    }

    func testRecommendedModelFallsBackToE4BWhenMemoryIsUnknown() {
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: nil),
            "gemma4:e4b"
        )
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: 0),
            "gemma4:e4b"
        )
    }

    func testRecommendedModelUsesE2BBelow16GiB() {
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(15)),
            "gemma4:e2b"
        )
    }

    func testRecommendedModelUsesE4BFrom16GiBToBelow36GiB() {
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(16)),
            "gemma4:e4b"
        )
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(35)),
            "gemma4:e4b"
        )
    }

    func testRecommendedModelUses26BFrom36GiBToBelow64GiB() {
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(36)),
            "gemma4:26b"
        )
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(63)),
            "gemma4:26b"
        )
    }

    func testRecommendedModelUses31BAt64GiBAndAbove() {
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(64)),
            "gemma4:31b"
        )
        XCTAssertEqual(
            AssistantGemma4ModelCatalog.recommendedModelID(physicalMemoryBytes: gib(96)),
            "gemma4:31b"
        )
    }

    func testCatalogMarksRecommendedModelAndKeepsAllGemmaVariants() {
        let catalog = AssistantGemma4ModelCatalog.catalog(physicalMemoryBytes: gib(36))

        XCTAssertEqual(
            catalog.map(\.id),
            ["gemma4:26b", "gemma4:e2b", "gemma4:e4b", "gemma4:31b"]
        )
        XCTAssertEqual(catalog.first?.id, "gemma4:26b")
        XCTAssertTrue(catalog.first?.isRecommended == true)
        XCTAssertEqual(
            catalog.filter(\.isRecommended).map(\.id),
            ["gemma4:26b"]
        )
    }

    func testModelLookupMatchesCaseInsensitiveIDs() {
        let option = AssistantGemma4ModelCatalog.model(
            withID: "GEMMA4:E4B",
            physicalMemoryBytes: gib(16)
        )

        XCTAssertEqual(option?.id, "gemma4:e4b")
        XCTAssertEqual(option?.displayName, "Gemma 4 E4B")
    }
}
