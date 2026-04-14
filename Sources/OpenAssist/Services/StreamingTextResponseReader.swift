import Foundation

struct StreamingTextHTTPResponse {
    let data: Data
    let response: URLResponse
    let streamedText: String?
}

enum StreamingTextResponseReader {
    static func collect(
        using session: URLSession,
        request: URLRequest,
        expectsEventStream: Bool,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> StreamingTextHTTPResponse {
        guard expectsEventStream else {
            let (data, response) = try await session.data(for: request)
            return StreamingTextHTTPResponse(
                data: data,
                response: response,
                streamedText: nil
            )
        }

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return StreamingTextHTTPResponse(
                data: try await collectRawData(from: bytes),
                response: response,
                streamedText: nil
            )
        }

        var rawData = Data()
        var accumulatedText = ""

        for try await line in bytes.lines {
            rawData.append(contentsOf: line.utf8)
            rawData.append(0x0A)

            guard let updatedText = updatedEventStreamText(
                from: line,
                currentText: accumulatedText
            ) else {
                continue
            }

            guard updatedText != accumulatedText else { continue }
            accumulatedText = updatedText
            onPartialText?(accumulatedText)
        }

        return StreamingTextHTTPResponse(
            data: rawData,
            response: response,
            streamedText: accumulatedText.nonEmpty
        )
    }

    private static func collectRawData(
        from bytes: URLSession.AsyncBytes
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private static func updatedEventStreamText(
        from rawLine: String,
        currentText: String
    ) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = String(trimmed.dropFirst(5))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]" else { return nil }
        guard let payloadData = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            return nil
        }

        let eventType = (event["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if let delta = event["delta"] as? String,
           let normalizedDelta = delta.nonEmpty {
            return mergeEventText(currentText: currentText, incomingText: normalizedDelta)
        }

        if let delta = event["delta"],
           let extractedDelta = extractText(fromEventPayload: delta) {
            return mergeEventText(currentText: currentText, incomingText: extractedDelta)
        }

        guard let extractedText = extractText(fromEventPayload: event) else {
            return nil
        }

        if eventType == "response.completed" || eventType.hasSuffix(".done") {
            return extractedText
        }

        return mergeEventText(currentText: currentText, incomingText: extractedText)
    }

    static func extractText(fromEventPayload payload: Any) -> String? {
        if let string = payload as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        if let array = payload as? [Any] {
            let joined = array.compactMap(extractText(fromEventPayload:))
                .joined(separator: "\n")
            return joined.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        guard let dictionary = payload as? [String: Any] else {
            return nil
        }

        for key in ["output_text", "text", "content"] {
            if let string = dictionary[key] as? String,
               let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return normalized
            }
        }

        for key in ["delta", "part", "item", "response", "message"] {
            if let nested = dictionary[key],
               let extracted = extractText(fromEventPayload: nested) {
                return extracted
            }
        }

        for key in ["content", "output"] {
            if let nested = dictionary[key],
               let extracted = extractText(fromEventPayload: nested) {
                return extracted
            }
        }

        return nil
    }

    private static func mergeEventText(
        currentText: String,
        incomingText: String
    ) -> String {
        guard !currentText.isEmpty else {
            return incomingText
        }
        if incomingText.hasPrefix(currentText) {
            return incomingText
        }
        if currentText.hasSuffix(incomingText) {
            return currentText
        }
        return currentText + incomingText
    }
}
