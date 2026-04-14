import Foundation

enum AssistantGemma4ModelRecommendation: String, CaseIterable, Sendable {
    case e2b = "gemma4:e2b"
    case e4b = "gemma4:e4b"
    case a26b = "gemma4:26b"
    case a31b = "gemma4:31b"

    var displayName: String {
        switch self {
        case .e2b:
            return "Gemma 4 E2B"
        case .e4b:
            return "Gemma 4 E4B"
        case .a26b:
            return "Gemma 4 26B"
        case .a31b:
            return "Gemma 4 31B"
        }
    }

    var sizeLabel: String {
        switch self {
        case .e2b:
            return "Small"
        case .e4b:
            return "Balanced"
        case .a26b:
            return "Large"
        case .a31b:
            return "Largest"
        }
    }

    var performanceLabel: String {
        switch self {
        case .e2b:
            return "Very Fast"
        case .e4b:
            return "Fast"
        case .a26b:
            return "Balanced"
        case .a31b:
            return "Highest Quality"
        }
    }

    var summary: String {
        switch self {
        case .e2b:
            return "Best for smaller Macs or when you want the lightest local Gemma 4 option."
        case .e4b:
            return "Best default starting point for most Macs."
        case .a26b:
            return "Better quality for machines with plenty of unified memory."
        case .a31b:
            return "Largest local option for high-memory Macs."
        }
    }

    var modelOption: LocalAIModelOption {
        LocalAIModelOption(
            id: rawValue,
            displayName: displayName,
            sizeLabel: sizeLabel,
            performanceLabel: performanceLabel,
            summary: summary,
            isRecommended: false
        )
    }

    static func recommended(for physicalMemoryBytes: UInt64?) -> AssistantGemma4ModelRecommendation {
        guard let physicalMemoryBytes, physicalMemoryBytes > 0 else {
            return .e4b
        }

        let gib = 1_073_741_824 as UInt64
        let sixteenGiB = 16 * gib
        let thirtySixGiB = 36 * gib
        let sixtyFourGiB = 64 * gib

        if physicalMemoryBytes < sixteenGiB {
            return .e2b
        }
        if physicalMemoryBytes < thirtySixGiB {
            return .e4b
        }
        if physicalMemoryBytes < sixtyFourGiB {
            return .a26b
        }
        return .a31b
    }
}

enum AssistantGemma4ModelCatalog {
    private static var baseCatalog: [AssistantGemma4ModelRecommendation] {
        [.e2b, .e4b, .a26b, .a31b]
    }

    static func recommendedModel(
        physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> LocalAIModelOption {
        recommendation(for: physicalMemoryBytes).modelOption
    }

    static func recommendedModelID(
        physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> String {
        recommendation(for: physicalMemoryBytes).rawValue
    }

    static func catalog(
        physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> [LocalAIModelOption] {
        let recommendedID = recommendedModelID(physicalMemoryBytes: physicalMemoryBytes)
        let orderedRecommendations = baseCatalog.filter {
            $0.rawValue.caseInsensitiveCompare(recommendedID) == .orderedSame
        } + baseCatalog.filter {
            $0.rawValue.caseInsensitiveCompare(recommendedID) != .orderedSame
        }

        return orderedRecommendations.map { recommendation in
            var option = recommendation.modelOption
            if recommendation.rawValue.caseInsensitiveCompare(recommendedID) == .orderedSame {
                option = LocalAIModelOption(
                    id: option.id,
                    displayName: option.displayName,
                    sizeLabel: option.sizeLabel,
                    performanceLabel: option.performanceLabel,
                    summary: option.summary,
                    isRecommended: true
                )
            }
            return option
        }
    }

    static func model(
        withID modelID: String,
        physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> LocalAIModelOption? {
        catalog(physicalMemoryBytes: physicalMemoryBytes).first {
            $0.id.caseInsensitiveCompare(modelID) == .orderedSame
        }
    }

    static func recommendation(
        for physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> AssistantGemma4ModelRecommendation {
        AssistantGemma4ModelRecommendation.recommended(for: physicalMemoryBytes)
    }
}
