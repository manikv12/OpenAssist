import Foundation

struct AudioTranscriptionUpload: Sendable {
    let fileData: Data
    let fileName: String
    let mimeType: String
}

struct AudioTranscriptionRequestConfiguration: Sendable {
    let provider: CloudTranscriptionProvider
    let model: String
    let baseURL: String
    let apiKey: String
    let requestTimeoutSeconds: TimeInterval
    let biasPhrases: [String]
}

enum AudioTranscriptionServiceError: LocalizedError {
    case invalidBaseURL
    case emptyAudio
    case missingCredentials
    case sessionUnavailable(String)
    case unsupportedResponse
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid provider base URL."
        case .emptyAudio:
            return "No speech captured."
        case .missingCredentials:
            return "Cloud API key is missing."
        case .sessionUnavailable(let message):
            return message
        case .unsupportedResponse:
            return "Provider returned an unsupported response."
        case .providerError(let message):
            return message
        }
    }
}

final class AudioTranscriptionService {
    static let shared = AudioTranscriptionService()

    private enum Constants {
        static let openAICompatibleUploadLimitBytes = 24_000_000
        static let chatGPTTranscriptionsURL = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    }

    private let session: URLSession
    private let codexSessionAuthContextProvider: @MainActor @Sendable (Bool) async throws -> CodexTranscriptionAuthContext

    init(
        session: URLSession = .shared,
        codexSessionAuthContextProvider: @escaping @MainActor @Sendable (Bool) async throws -> CodexTranscriptionAuthContext = { refreshToken in
            try await AssistantStore.shared.resolveCodexTranscriptionAuthContext(refreshToken: refreshToken)
        }
    ) {
        self.session = session
        self.codexSessionAuthContextProvider = codexSessionAuthContextProvider
    }

    func transcribe(
        upload: AudioTranscriptionUpload,
        configuration: AudioTranscriptionRequestConfiguration
    ) async throws -> String {
        guard !upload.fileData.isEmpty else {
            throw AudioTranscriptionServiceError.emptyAudio
        }

        switch configuration.provider {
        case .codexSession:
            return try await transcribeWithCodexSession(upload: upload, configuration: configuration)
        case .openAI, .groq:
            return try await transcribeWithOpenAICompatibleAPI(upload: upload, configuration: configuration)
        case .deepgram:
            return try await transcribeWithDeepgram(upload: upload, configuration: configuration)
        case .gemini:
            return try await transcribeWithGemini(upload: upload, configuration: configuration)
        }
    }

    private func transcribeWithCodexSession(
        upload: AudioTranscriptionUpload,
        configuration: AudioTranscriptionRequestConfiguration
    ) async throws -> String {
        var authContext = try await codexSessionAuthContextProvider(true)
        if authContext.usesOpenAIAPI {
            let bridgedConfiguration = AudioTranscriptionRequestConfiguration(
                provider: .openAI,
                model: configuration.model,
                baseURL: CloudTranscriptionProvider.openAI.defaultBaseURL,
                apiKey: authContext.token,
                requestTimeoutSeconds: configuration.requestTimeoutSeconds,
                biasPhrases: configuration.biasPhrases
            )
            return try await transcribeWithOpenAICompatibleAPI(upload: upload, configuration: bridgedConfiguration)
        }

        let requestStart = Date()
        let initialRequest = try makeChatGPTRequest(
            upload: upload,
            token: authContext.token,
            timeout: configuration.requestTimeoutSeconds
        )
        let initialResponse = try await session.data(for: initialRequest)
        let initialHTTPResponse = try validatedHTTPResponse(from: initialResponse.1)

        if initialHTTPResponse.statusCode == 401 {
            authContext = try await codexSessionAuthContextProvider(true)
            let retryRequest = try makeChatGPTRequest(
                upload: upload,
                token: authContext.token,
                timeout: configuration.requestTimeoutSeconds
            )
            let retryResponse = try await session.data(for: retryRequest)
            let retryHTTPResponse = try validatedHTTPResponse(from: retryResponse.1)
            return try decodeChatGPTResponse(
                data: retryResponse.0,
                response: retryHTTPResponse,
                requestStart: requestStart,
                upload: upload
            )
        }

        return try decodeChatGPTResponse(
            data: initialResponse.0,
            response: initialHTTPResponse,
            requestStart: requestStart,
            upload: upload
        )
    }

    private func transcribeWithOpenAICompatibleAPI(
        upload: AudioTranscriptionUpload,
        configuration: AudioTranscriptionRequestConfiguration
    ) async throws -> String {
        if upload.fileData.count > Constants.openAICompatibleUploadLimitBytes {
            throw AudioTranscriptionServiceError.providerError("Captured audio is too large for this provider upload limit.")
        }

        let trimmedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw AudioTranscriptionServiceError.missingCredentials
        }

        guard let endpoint = urlByAppendingPath(baseURL: configuration.baseURL, path: "audio/transcriptions") else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }

        let requestStart = Date()
        CrashReporter.logInfo(
            "Audio transcription request started provider=\(configuration.provider.rawValue) model=\(configuration.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(upload.fileData.count) timeout=\(Int(configuration.requestTimeoutSeconds.rounded()))s"
        )

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let prompt = transcriptionPrompt(biasPhrases: configuration.biasPhrases)
        request.httpBody = makeMultipartFormData(
            boundary: boundary,
            fields: [
                ("model", configuration.model),
                ("prompt", prompt)
            ],
            fileFieldName: "file",
            fileName: normalizedFileName(from: upload.fileName, fallback: "audio.wav"),
            fileMimeType: normalizedMimeType(from: upload.mimeType, fallback: "audio/wav"),
            fileData: upload.fileData
        )

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(from: response)
        logHTTPResponse(
            provider: configuration.provider,
            model: configuration.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AudioTranscriptionServiceError.providerError(reason)
        }

        if let text = decodeOpenAICompatibleText(from: data), !text.isEmpty {
            return text
        }

        throw AudioTranscriptionServiceError.unsupportedResponse
    }

    private func transcribeWithDeepgram(
        upload: AudioTranscriptionUpload,
        configuration: AudioTranscriptionRequestConfiguration
    ) async throws -> String {
        let trimmedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw AudioTranscriptionServiceError.missingCredentials
        }

        guard var components = validatedBaseURLComponents(baseURL: configuration.baseURL) else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") && !path.isEmpty {
            path.removeLast()
        }
        if path.isEmpty {
            path = "/v1/listen"
        } else if !path.hasSuffix("/listen") {
            path += "/listen"
        }
        components.path = path

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "model" }) {
            queryItems.append(URLQueryItem(name: "model", value: configuration.model))
        }
        if !queryItems.contains(where: { $0.name == "smart_format" }) {
            queryItems.append(URLQueryItem(name: "smart_format", value: "true"))
        }
        components.queryItems = queryItems

        guard let endpoint = components.url else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }

        let requestStart = Date()
        CrashReporter.logInfo(
            "Audio transcription request started provider=\(configuration.provider.rawValue) model=\(configuration.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(upload.fileData.count) timeout=\(Int(configuration.requestTimeoutSeconds.rounded()))s"
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("Token \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue(normalizedMimeType(from: upload.mimeType, fallback: "audio/wav"), forHTTPHeaderField: "Content-Type")
        request.httpBody = upload.fileData

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(from: response)
        logHTTPResponse(
            provider: configuration.provider,
            model: configuration.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AudioTranscriptionServiceError.providerError(reason)
        }

        if let text = decodeDeepgramText(from: data), !text.isEmpty {
            return text
        }

        throw AudioTranscriptionServiceError.unsupportedResponse
    }

    private func transcribeWithGemini(
        upload: AudioTranscriptionUpload,
        configuration: AudioTranscriptionRequestConfiguration
    ) async throws -> String {
        let trimmedAPIKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw AudioTranscriptionServiceError.missingCredentials
        }

        let encodedModel = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.model
        guard let baseEndpoint = urlByAppendingPath(
            baseURL: configuration.baseURL,
            path: "models/\(encodedModel):generateContent"
        ) else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }

        guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: trimmedAPIKey))
        components.queryItems = queryItems

        guard let endpoint = components.url else {
            throw AudioTranscriptionServiceError.invalidBaseURL
        }

        let requestStart = Date()
        CrashReporter.logInfo(
            "Audio transcription request started provider=\(configuration.provider.rawValue) model=\(configuration.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(upload.fileData.count) timeout=\(Int(configuration.requestTimeoutSeconds.rounded()))s"
        )

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": transcriptionPrompt(biasPhrases: configuration.biasPhrases)],
                        [
                            "inlineData": [
                                "mimeType": normalizedMimeType(from: upload.mimeType, fallback: "audio/wav"),
                                "data": upload.fileData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validatedHTTPResponse(from: response)
        logHTTPResponse(
            provider: configuration.provider,
            model: configuration.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw AudioTranscriptionServiceError.providerError(reason)
        }

        if let text = decodeGeminiText(from: data), !text.isEmpty {
            return text
        }

        throw AudioTranscriptionServiceError.unsupportedResponse
    }

    private func makeChatGPTRequest(
        upload: AudioTranscriptionUpload,
        token: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        if upload.fileData.count > Constants.openAICompatibleUploadLimitBytes {
            throw AudioTranscriptionServiceError.providerError("Captured audio is too large for this provider upload limit.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Constants.chatGPTTranscriptionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartFormData(
            boundary: boundary,
            fields: [],
            fileFieldName: "file",
            fileName: normalizedFileName(from: upload.fileName, fallback: "audio.ogg"),
            fileMimeType: normalizedMimeType(from: upload.mimeType, fallback: "audio/ogg"),
            fileData: upload.fileData
        )
        return request
    }

    private func decodeChatGPTResponse(
        data: Data,
        response: HTTPURLResponse,
        requestStart: Date,
        upload: AudioTranscriptionUpload
    ) throws -> String {
        logHTTPResponse(
            provider: .codexSession,
            model: CloudTranscriptionProvider.codexSession.defaultModel,
            endpoint: Constants.chatGPTTranscriptionsURL,
            statusCode: response.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AudioTranscriptionServiceError.sessionUnavailable(
                    "Your ChatGPT session expired. Sign in again in Open Assist to keep using session transcription, or switch to another provider in Settings > Recognition."
                )
            }
            let reason = extractErrorMessage(from: data) ?? "HTTP \(response.statusCode)"
            throw AudioTranscriptionServiceError.providerError(reason)
        }

        if let text = decodeOpenAICompatibleText(from: data), !text.isEmpty {
            return text
        }

        throw AudioTranscriptionServiceError.unsupportedResponse
    }

    private func validatedHTTPResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AudioTranscriptionServiceError.unsupportedResponse
        }
        return httpResponse
    }

    private func transcriptionPrompt(biasPhrases: [String]) -> String {
        let compact = biasPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let limited = Array(compact.prefix(20))

        if limited.isEmpty {
            return "Transcribe this audio verbatim. Preserve wording and punctuation when clear."
        }

        return "Transcribe this audio verbatim. Preserve wording and punctuation when clear. Prefer these terms if acoustically plausible: \(limited.joined(separator: ", "))."
    }

    private func makeMultipartFormData(
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        fileName: String,
        fileMimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()

        for (name, value) in fields where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(fileMimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }

    private func decodeOpenAICompatibleText(from data: Data) -> String? {
        struct Response: Decodable {
            let text: String?
            let transcript: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return [
            decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            decoded.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap { $0 }
        .first
    }

    private func decodeDeepgramText(from data: Data) -> String? {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String?
                    }

                    let alternatives: [Alternative]
                }

                let channels: [Channel]
            }

            let results: Results?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        return decoded.results?.channels.first?.alternatives.first?.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeGeminiText(from data: Data) -> String? {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }

                    let parts: [Part]?
                }

                let content: Content?
            }

            let candidates: [Candidate]?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        return decoded.candidates?
            .first?
            .content?
            .parts?
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let message = object["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let message = object["err_msg"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logHTTPResponse(
        provider: CloudTranscriptionProvider,
        model: String,
        endpoint: URL,
        statusCode: Int,
        elapsedSince start: Date,
        responseBytes: Int
    ) {
        let elapsed = max(0, Date().timeIntervalSince(start))
        let elapsedText = String(format: "%.2f", elapsed)
        CrashReporter.logInfo(
            "Audio transcription request completed provider=\(provider.rawValue) model=\(model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") status=\(statusCode) duration=\(elapsedText)s responseBytes=\(responseBytes)"
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

        let allowsInsecureLocalhost = scheme == "http" && isLoopbackHost(host)
        guard scheme == "https" || allowsInsecureLocalhost else {
            return nil
        }

        components.fragment = nil
        return components
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    private func normalizedFileName(from rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedMimeType(from rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func sanitizedURLString(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
