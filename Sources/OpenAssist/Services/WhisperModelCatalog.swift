import Foundation

struct WhisperModelCatalog {
    struct Model: Identifiable, Hashable {
        let id: String
        let displayName: String
        let useCaseDescription: String
        let diskSizeText: String
        let memoryFootprintText: String
        let ggmlDownloadURL: URL
        let ggmlSHA1: String?
        let coreMLDownloadURL: URL?
        let family: String
        let isEnglishOnly: Bool
        let isQuantized: Bool
        let isDiarization: Bool

        var ggmlFilename: String {
            "ggml-\(id).bin"
        }

        var coreMLDirectoryName: String {
            "ggml-\(id)-encoder.mlmodelc"
        }
    }

    static let modelIDs: [String] = [
        "tiny",
        "tiny.en",
        "tiny-q5_1",
        "tiny.en-q5_1",
        "tiny-q8_0",
        "base",
        "base.en",
        "base-q5_1",
        "base.en-q5_1",
        "base-q8_0",
        "small",
        "small.en",
        "small.en-tdrz",
        "small-q5_1",
        "small.en-q5_1",
        "small-q8_0",
        "medium",
        "medium.en",
        "medium-q5_0",
        "medium.en-q5_0",
        "medium-q8_0",
        "large-v1",
        "large-v2",
        "large-v2-q5_0",
        "large-v2-q8_0",
        "large-v3",
        "large-v3-q5_0",
        "large-v3-turbo",
        "large-v3-turbo-q5_0",
        "large-v3-turbo-q8_0"
    ]

    static let curatedModels: [Model] = modelIDs.map(makeModel)

    static func model(withID id: String) -> Model? {
        curatedModels.first(where: { $0.id == id })
    }

    private static func makeModel(id: String) -> Model {
        let family = familyForModelID(id)
        let isQuantized = id.contains("-q")
        let isEnglishOnly = id.contains(".en")
        let isDiarization = id.contains("tdrz")
        let isTurbo = id.contains("turbo")

        let baseRepo = isDiarization
            ? "https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/main"
            : "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

        let ggmlURL = URL(string: "\(baseRepo)/ggml-\(id).bin")!
        let coreMLURL: URL?
        if isQuantized || isDiarization {
            coreMLURL = nil
        } else {
            coreMLURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id)-encoder.mlmodelc.zip")
        }

        return Model(
            id: id,
            displayName: id,
            useCaseDescription: useCaseDescription(
                family: family,
                isQuantized: isQuantized,
                isEnglishOnly: isEnglishOnly,
                isDiarization: isDiarization,
                isTurbo: isTurbo
            ),
            diskSizeText: diskSizeText(family: family, isQuantized: isQuantized, isTurbo: isTurbo),
            memoryFootprintText: memoryText(family: family, isQuantized: isQuantized, isTurbo: isTurbo),
            ggmlDownloadURL: ggmlURL,
            ggmlSHA1: sha1ByModelID[id],
            coreMLDownloadURL: coreMLURL,
            family: family,
            isEnglishOnly: isEnglishOnly,
            isQuantized: isQuantized,
            isDiarization: isDiarization
        )
    }

    private static func familyForModelID(_ id: String) -> String {
        if id.hasPrefix("large") {
            return "large"
        }

        if let firstPart = id.split(whereSeparator: { $0 == "." || $0 == "-" }).first {
            return String(firstPart)
        }

        return id
    }

    private static func useCaseDescription(
        family: String,
        isQuantized: Bool,
        isEnglishOnly: Bool,
        isDiarization: Bool,
        isTurbo: Bool
    ) -> String {
        if isDiarization {
            return "Speaker-aware tiny diarization model. Best when you need simple speaker turns."
        }

        var base: String
        switch family {
        case "tiny":
            base = "Fastest and lightest. Best for quick notes and lowest resource use."
        case "base":
            base = "Balanced speed and accuracy. Good default for daily dictation."
        case "small":
            base = "Higher accuracy with moderate CPU and memory cost."
        case "medium":
            base = "Strong accuracy for harder audio, accents, and noisy environments."
        case "large":
            base = isTurbo
                ? "Near-large accuracy with better speed than standard large models."
                : "Highest accuracy, but heaviest on memory/CPU and slowest to run."
        default:
            base = "General-purpose whisper.cpp model."
        }

        if isQuantized {
            base += " Quantized variant: smaller download and memory footprint with some accuracy tradeoff."
        }

        if isEnglishOnly {
            base += " English-only model."
        } else {
            base += " Multilingual model."
        }

        return base
    }

    private static func diskSizeText(family: String, isQuantized: Bool, isTurbo: Bool) -> String {
        if isQuantized {
            switch family {
            case "tiny": return "~31–42 MiB"
            case "base": return "~57–81 MiB"
            case "small": return "~181–268 MiB"
            case "medium": return "~590–860 MiB"
            case "large": return isTurbo ? "~640 MiB–1.1 GiB" : "~1.1–1.8 GiB"
            default: return "Quantized size"
            }
        }

        switch family {
        case "tiny":
            return "75 MiB"
        case "base":
            return "142 MiB"
        case "small":
            return "466 MiB"
        case "medium":
            return "1.5 GiB"
        case "large":
            return isTurbo ? "1.6 GiB" : "2.9 GiB"
        default:
            return "Model size"
        }
    }

    private static func memoryText(family: String, isQuantized: Bool, isTurbo: Bool) -> String {
        if isQuantized {
            switch family {
            case "tiny": return "~180–240 MB"
            case "base": return "~240–320 MB"
            case "small": return "~520–700 MB"
            case "medium": return "~1.1–1.6 GB"
            case "large": return isTurbo ? "~1.6–2.4 GB" : "~2.1–3.2 GB"
            default: return "Lower than full"
            }
        }

        switch family {
        case "tiny":
            return "~273 MB"
        case "base":
            return "~388 MB"
        case "small":
            return "~852 MB"
        case "medium":
            return "~2.1 GB"
        case "large":
            return isTurbo ? "~2.3 GB" : "~3.9 GB"
        default:
            return "Model memory"
        }
    }

    private static let sha1ByModelID: [String: String] = [
        "tiny.en": "c78c86eb1a8faa21b369bcd33207cc90d64ae9df",
        "base.en": "137c40403d78fd54d454da0f9bd998f78703390c",
        "small.en": "db8a495a91d927739e50b3fc1cc4c6b8f6c2d022"
    ]
}
