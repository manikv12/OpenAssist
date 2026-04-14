import Foundation

struct GeminiImageGenerationConfiguration: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String
    let requestTimeoutSeconds: TimeInterval
}

enum AssistantImageGenerationToolDefinition {
    static let name = "generate_image"
    static let toolKind = "imageGeneration"

    static let description = """
    Generate an image with Google Gemini using the shared Google AI Studio API key configured in Open Assist. Use this when the user asks to create, render, draw, illustrate, mock up, or visualize something. Pass the full visual request in `prompt`. Optionally override the Gemini image model with `model` when the user explicitly asks for a specific one.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prompt": [
                "type": "string",
                "description": "The full image-generation prompt."
            ],
            "model": [
                "type": "string",
                "description": "Optional Gemini image model override such as gemini-2.5-flash-image."
            ]
        ],
        "required": ["prompt"],
        "additionalProperties": true
    ]

    static func dynamicToolSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

enum AssistantImageGenerationServiceError: LocalizedError {
    case invalidArguments(String)
    case invalidBaseURL
    case missingAPIKey
    case providerError(String)
    case unsupportedResponse

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .invalidBaseURL:
            return "Invalid Google AI Studio base URL."
        case .missingAPIKey:
            return "Set a Google AI Studio API key in Settings > Models & Connections to use Gemini image generation."
        case .providerError(let message):
            return message
        case .unsupportedResponse:
            return "Google Gemini did not return an image."
        }
    }
}

actor AssistantImageGenerationService {
    struct ParsedRequest: Equatable, Sendable {
        let prompt: String
        let modelOverride: String?

        var summaryLine: String {
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard prompt.count > 120 else { return prompt }
            return String(prompt.prefix(117)) + "..."
        }
    }

    private struct GeneratedImage: Sendable {
        let data: Data
        let mimeType: String
    }

    private struct ReferenceImage: Sendable {
        let data: Data
        let mimeType: String
    }

    private let session: URLSession
    private let configurationProvider: @MainActor @Sendable () -> GeminiImageGenerationConfiguration

    init(
        session: URLSession = .shared,
        configurationProvider: @escaping @MainActor @Sendable () -> GeminiImageGenerationConfiguration = {
            SettingsStore.shared.geminiImageGenerationConfiguration
        }
    ) {
        self.session = session
        self.configurationProvider = configurationProvider
    }

    func run(
        arguments: Any,
        referenceImages: [AssistantAttachment] = [],
        preferredModelID _: String?
    ) async -> AssistantToolExecutionResult {
        do {
            let request = try Self.parseRequest(from: arguments)
            let configuration = await MainActor.run { configurationProvider() }
            return try await generateImage(
                for: request,
                referenceImages: referenceImages.compactMap(Self.referenceImage(from:)),
                configuration: configuration
            )
        } catch let error as AssistantImageGenerationServiceError {
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.failureResult(summary: summary)
        } catch {
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Image generation failed."
            return Self.failureResult(summary: summary)
        }
    }

    static func parseRequest(from arguments: Any) throws -> ParsedRequest {
        guard let dictionary = arguments as? [String: Any] else {
            throw AssistantImageGenerationServiceError.invalidArguments(
                "Image Generation needs a prompt."
            )
        }

        let prompt = (
            dictionary["prompt"] as? String
                ?? dictionary["task"] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard let prompt else {
            throw AssistantImageGenerationServiceError.invalidArguments(
                "Image Generation needs a prompt."
            )
        }

        let modelOverride = (dictionary["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        return ParsedRequest(prompt: prompt, modelOverride: modelOverride)
    }

    private func generateImage(
        for request: ParsedRequest,
        referenceImages: [ReferenceImage],
        configuration: GeminiImageGenerationConfiguration
    ) async throws -> AssistantToolExecutionResult {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AssistantImageGenerationServiceError.missingAPIKey
        }

        let model = request.modelOverride ?? configuration.model
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let baseEndpoint = urlByAppendingPath(
            baseURL: configuration.baseURL,
            path: "models/\(encodedModel):generateContent"
        ) else {
            throw AssistantImageGenerationServiceError.invalidBaseURL
        }

        guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            throw AssistantImageGenerationServiceError.invalidBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = queryItems

        guard let endpoint = components.url else {
            throw AssistantImageGenerationServiceError.invalidBaseURL
        }

        var parts: [[String: Any]] = referenceImages.map { image in
            [
                "inline_data": [
                    "mime_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ]
        }
        parts.append(["text": request.prompt])

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.requestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantImageGenerationServiceError.providerError("Invalid Gemini response.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AssistantImageGenerationServiceError.providerError(reason)
        }

        let decoded = try decodeResponse(from: data)
        guard !decoded.images.isEmpty else {
            if let detail = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                throw AssistantImageGenerationServiceError.providerError(detail)
            }
            throw AssistantImageGenerationServiceError.unsupportedResponse
        }

        let summary = decoded.images.count == 1
            ? "Generated an image with Google Gemini."
            : "Generated \(decoded.images.count) images with Google Gemini."

        var items: [AssistantToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil),
            .init(type: "inputText", text: "The image tool succeeded.", imageURL: nil)
        ]
        if !referenceImages.isEmpty {
            items.append(.init(
                type: "inputText",
                text: "Used the attached image reference(s) while generating this image.",
                imageURL: nil
            ))
        }
        if let detail = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            items.append(.init(type: "inputText", text: detail, imageURL: nil))
        }
        items.append(contentsOf: decoded.images.map { image in
            .init(type: "inputImage", text: nil, imageURL: dataURLString(for: image))
        })

        return AssistantToolExecutionResult(
            contentItems: items,
            success: true,
            summary: summary
        )
    }

    private func decodeResponse(from data: Data) throws -> (text: String?, images: [GeneratedImage]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantImageGenerationServiceError.unsupportedResponse
        }

        var textFragments: [String] = []
        var images: [GeneratedImage] = []
        var seen = Set<String>()

        if let candidates = root["candidates"] as? [Any] {
            for candidate in candidates {
                guard let candidateDictionary = candidate as? [String: Any] else { continue }
                guard let content = candidateDictionary["content"] as? [String: Any] else { continue }
                guard let parts = content["parts"] as? [Any] else { continue }
                for part in parts {
                    guard let partDictionary = part as? [String: Any] else { continue }
                    if let text = (partDictionary["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty {
                        textFragments.append(text)
                    }

                    let inlineData = (partDictionary["inlineData"] as? [String: Any])
                        ?? (partDictionary["inline_data"] as? [String: Any])
                    guard let inlineData else { continue }
                    guard let encoded = inlineData["data"] as? String,
                          let imageData = Data(base64Encoded: encoded) else {
                        continue
                    }
                    let key = MemoryIdentifier.stableHexDigest(data: imageData)
                    guard seen.insert(key).inserted else { continue }
                    let mimeType = ((inlineData["mimeType"] as? String)
                        ?? (inlineData["mime_type"] as? String)
                        ?? "image/png")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    images.append(GeneratedImage(data: imageData, mimeType: mimeType.isEmpty ? "image/png" : mimeType))
                }
            }
        }

        let mergedText = textFragments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (mergedText.isEmpty ? nil : mergedText, images)
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = root["error"] as? [String: Any] {
            if let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return message
            }
            if let status = (error["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return status
            }
        }

        if let message = (root["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return message
        }

        return nil
    }

    private func dataURLString(for image: GeneratedImage) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }

    private static func referenceImage(from attachment: AssistantAttachment) -> ReferenceImage? {
        guard attachment.isImage else { return nil }
        let mimeType = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReferenceImage(
            data: attachment.data,
            mimeType: mimeType.isEmpty ? "image/png" : mimeType
        )
    }

    private func urlByAppendingPath(baseURL: String, path: String) -> URL? {
        guard var components = validatedBaseURLComponents(baseURL: baseURL) else { return nil }

        let existingPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appendedPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let merged = [existingPath, appendedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/\(merged)"

        return components.url
    }

    private func validatedBaseURLComponents(baseURL: String) -> URLComponents? {
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        guard scheme == "https" || scheme == "http" else {
            return nil
        }

        components.fragment = nil
        return components
    }

    private static func failureResult(summary: String) -> AssistantToolExecutionResult {
        AssistantToolExecutionResult(
            contentItems: [.init(type: "inputText", text: summary, imageURL: nil)],
            success: false,
            summary: summary
        )
    }
}
