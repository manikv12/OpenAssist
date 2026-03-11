import Foundation

struct LocalAIModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeLabel: String
    let performanceLabel: String
    let summary: String
    let isRecommended: Bool
}

enum LocalAIModelCatalog {
    static let curatedModels: [LocalAIModelOption] = [
        LocalAIModelOption(
            id: "qwen2.5:3b",
            displayName: "Qwen 2.5 3B",
            sizeLabel: "~2.0 GB",
            performanceLabel: "Fast",
            summary: "Best balance for rewrite quality and memory-lesson extraction on most Macs.",
            isRecommended: true
        ),
        LocalAIModelOption(
            id: "llama3.2:3b",
            displayName: "Llama 3.2 3B",
            sizeLabel: "~2.0 GB",
            performanceLabel: "Fast",
            summary: "Good all-around local model with broad compatibility.",
            isRecommended: false
        ),
        LocalAIModelOption(
            id: "gemma3:4b",
            displayName: "Gemma 3 4B",
            sizeLabel: "~8.6 GB",
            performanceLabel: "Balanced",
            summary: "Newer Gemma generation with stronger quality while still fitting consumer laptops.",
            isRecommended: false
        ),
        LocalAIModelOption(
            id: "gemma2:2b",
            displayName: "Gemma 2 2B",
            sizeLabel: "~1.6 GB",
            performanceLabel: "Very Fast",
            summary: "Smallest legacy download option. Faster startup with modest quality tradeoffs.",
            isRecommended: false
        )
    ]

    static var recommendedModel: LocalAIModelOption {
        curatedModels.first(where: { $0.isRecommended }) ?? curatedModels[0]
    }

    static func model(withID modelID: String) -> LocalAIModelOption? {
        curatedModels.first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    static func mergedWithWebsiteModels(_ websiteModels: [LocalAIModelOption]) -> [LocalAIModelOption] {
        var merged = curatedModels
        var seenIDs = Set(merged.map { $0.id.lowercased() })

        for model in websiteModels {
            let normalizedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty else { continue }
            guard seenIDs.insert(normalizedID).inserted else { continue }
            merged.append(model)
        }
        return merged
    }

    static func model(withID modelID: String, in options: [LocalAIModelOption]) -> LocalAIModelOption? {
        options.first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }
    }
}
