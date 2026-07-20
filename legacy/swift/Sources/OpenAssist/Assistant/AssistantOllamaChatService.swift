import Foundation

enum AssistantOllamaChatRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct AssistantOllamaToolCall: @unchecked Sendable, Equatable {
    let id: String
    let name: String
    let arguments: [String: Any]

    static func == (lhs: AssistantOllamaToolCall, rhs: AssistantOllamaToolCall) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && NSDictionary(dictionary: lhs.arguments).isEqual(to: rhs.arguments)
    }
}

struct AssistantOllamaChatMessage: @unchecked Sendable, Equatable {
    let role: AssistantOllamaChatRole
    var content: String
    var images: [String]
    var toolCalls: [AssistantOllamaToolCall]
    var toolName: String?

    init(
        role: AssistantOllamaChatRole,
        content: String = "",
        images: [String] = [],
        toolCalls: [AssistantOllamaToolCall] = [],
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func == (lhs: AssistantOllamaChatMessage, rhs: AssistantOllamaChatMessage) -> Bool {
        lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.images == rhs.images
            && lhs.toolCalls == rhs.toolCalls
            && lhs.toolName == rhs.toolName
    }
}

struct AssistantOllamaChatRequest: @unchecked Sendable {
    let model: String
    let messages: [AssistantOllamaChatMessage]
    let tools: [[String: Any]]
}

enum AssistantOllamaStreamEvent: Sendable {
    case assistantTextDelta(String)
    case toolCalls([AssistantOllamaToolCall])
}

struct AssistantOllamaChatResponse: Equatable, Sendable {
    let message: AssistantOllamaChatMessage
    let promptEvalCount: Int?
    let evalCount: Int?
}

protocol AssistantOllamaChatServing: Sendable {
    func streamChat(
        request: AssistantOllamaChatRequest,
        onEvent: @escaping @Sendable (AssistantOllamaStreamEvent) async -> Void
    ) async throws -> AssistantOllamaChatResponse
    func unloadModel(named model: String) async throws
}

actor AssistantOllamaChatService: AssistantOllamaChatServing {
    static let shared = AssistantOllamaChatService()

    private let session: URLSession
    private let endpoint: URL
    private let generateEndpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!,
        generateEndpoint: URL = URL(string: "http://127.0.0.1:11434/api/generate")!
    ) {
        self.session = session
        self.endpoint = endpoint
        self.generateEndpoint = generateEndpoint
    }

    func streamChat(
        request: AssistantOllamaChatRequest,
        onEvent: @escaping @Sendable (AssistantOllamaStreamEvent) async -> Void
    ) async throws -> AssistantOllamaChatResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(for: request),
            options: []
        )

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CodexAssistantRuntimeError.requestFailed("Ollama chat failed with HTTP \(http.statusCode).")
        }

        var collectedContent = ""
        var collectedToolCalls: [AssistantOllamaToolCall] = []
        var seenToolCallSignatures: Set<String> = []
        var promptEvalCount: Int?
        var evalCount: Int?

        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let error = Self.errorMessage(from: payload) {
                throw CodexAssistantRuntimeError.requestFailed(error)
            }

            if let message = payload["message"] as? [String: Any] {
                if let delta = (message["content"] as? String)?.streamingDeltaPreservingWhitespace {
                    collectedContent += delta
                    await onEvent(.assistantTextDelta(delta))
                }

                let toolCalls = Self.parseToolCalls(from: message["tool_calls"])
                let freshToolCalls = toolCalls.filter { toolCall in
                    seenToolCallSignatures.insert(Self.toolCallSignature(for: toolCall)).inserted
                }
                if !freshToolCalls.isEmpty {
                    collectedToolCalls.append(contentsOf: freshToolCalls)
                    await onEvent(.toolCalls(freshToolCalls))
                }
            }

            promptEvalCount = payload["prompt_eval_count"] as? Int ?? promptEvalCount
            evalCount = payload["eval_count"] as? Int ?? evalCount

            if payload["done"] as? Bool == true {
                break
            }
        }

        return AssistantOllamaChatResponse(
            message: AssistantOllamaChatMessage(
                role: .assistant,
                content: collectedContent,
                toolCalls: collectedToolCalls
            ),
            promptEvalCount: promptEvalCount,
            evalCount: evalCount
        )
    }

    func unloadModel(named model: String) async throws {
        guard let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        var urlRequest = URLRequest(url: generateEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": normalizedModel,
                "stream": false,
                "keep_alive": 0
            ],
            options: []
        )

        let (_, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CodexAssistantRuntimeError.runtimeUnavailable("Ollama returned an invalid unload response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CodexAssistantRuntimeError.requestFailed("Ollama unload failed with HTTP \(http.statusCode).")
        }
    }

    private func requestBody(for request: AssistantOllamaChatRequest) -> [String: Any] {
        [
            "model": request.model,
            "stream": true,
            "messages": request.messages.map(Self.messageDictionary(from:)),
            "tools": request.tools
        ]
    }

    private static func messageDictionary(from message: AssistantOllamaChatMessage) -> [String: Any] {
        var dictionary: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content
        ]

        if !message.images.isEmpty {
            dictionary["images"] = message.images
        }
        if !message.toolCalls.isEmpty {
            dictionary["tool_calls"] = message.toolCalls.map(Self.toolCallDictionary(from:))
        }
        if let toolName = message.toolName?.nonEmpty {
            dictionary["tool_name"] = toolName
        }
        return dictionary
    }

    private static func toolCallDictionary(from toolCall: AssistantOllamaToolCall) -> [String: Any] {
        [
            "function": [
                "name": toolCall.name,
                "arguments": toolCall.arguments
            ]
        ]
    }

    private static func parseToolCalls(from raw: Any?) -> [AssistantOllamaToolCall] {
        guard let rows = raw as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            let function = row["function"] as? [String: Any]
            guard let name = ((function?["name"] as? String) ?? (row["name"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty else {
                return nil
            }

            let rawArguments = function?["arguments"] ?? row["arguments"]
            let arguments: [String: Any]
            if let dictionary = rawArguments as? [String: Any] {
                arguments = dictionary
            } else if let text = rawArguments as? String,
                      let data = text.data(using: .utf8),
                      let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                arguments = dictionary
            } else {
                arguments = [:]
            }

            let providedID = ((row["id"] as? String) ?? (function?["id"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            let fallbackID = "ollama-tool-\(UUID().uuidString)"
            return AssistantOllamaToolCall(
                id: providedID ?? fallbackID,
                name: name,
                arguments: arguments
            )
        }
    }

    private static func toolCallSignature(for toolCall: AssistantOllamaToolCall) -> String {
        let serializedArguments: String
        if JSONSerialization.isValidJSONObject(toolCall.arguments),
           let data = try? JSONSerialization.data(withJSONObject: toolCall.arguments, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            serializedArguments = text
        } else {
            serializedArguments = ""
        }
        return "\(toolCall.name.lowercased())|\(serializedArguments)"
    }

    private static func errorMessage(from payload: [String: Any]) -> String? {
        if let error = payload["error"] as? String {
            return error.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        if let error = payload["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return nil
    }
}
