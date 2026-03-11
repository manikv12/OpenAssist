import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
}

@main
struct WhisperCatalogSmokeTests {
    static func main() {
        let models = WhisperModelCatalog.curatedModels
        check(!models.isEmpty, "Curated model list should not be empty")

        let modelIDs = Set(models.map(\.id))
        let expectedIDs = Set(WhisperModelCatalog.modelIDs)
        check(modelIDs == expectedIDs, "Curated model IDs should match the catalog source list")
        check(models.count >= 25, "Catalog should expose a full set of whisper models")
        check(modelIDs.contains("medium.en"), "Catalog should include medium.en")
        check(modelIDs.contains("large-v3"), "Catalog should include large-v3")
        check(modelIDs.contains("large-v3-turbo"), "Catalog should include large-v3-turbo")

        for model in models {
            check(!model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Display name should not be empty")
            check(!model.useCaseDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Use-case text should not be empty")
            check(model.ggmlDownloadURL.absoluteString.hasPrefix("https://"), "Model URL should use HTTPS")
            if let sha1 = model.ggmlSHA1 {
                check(sha1.count == 40, "SHA1 should be 40 hex chars for \(model.id)")
            }

            if let coreMLURL = model.coreMLDownloadURL {
                check(coreMLURL.absoluteString.hasSuffix(".zip"), "Core ML URL should point to zip for \(model.id)")
            }
        }

        print("✅ Whisper model catalog smoke tests passed")
    }
}
