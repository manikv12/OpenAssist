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

        if let delta = event["delta"] as? String,
           delta.nonEmpty != nil {
            return currentText + delta
        }

        if let delta = event["delta"] as? [String: Any],
           let text = delta["text"] as? String,
           text.nonEmpty != nil {
            return currentText + text
        }

        if let outputText = event["output_text"] as? String,
           outputText.nonEmpty != nil {
            return outputText
        }

        if let output = event["output"] as? [[String: Any]] {
            let joined = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    let text = content.compactMap { block -> String? in
                        if let value = block["text"] as? String,
                           value.nonEmpty != nil {
                            return value
                        }
                        if let value = block["output_text"] as? String,
                           value.nonEmpty != nil {
                            return value
                        }
                        return nil
                    }.joined()
                    return text.nonEmpty
                }
                return nil
            }.joined(separator: "\n")

            if joined.nonEmpty != nil {
                return joined
            }
        }

        return nil
    }
}
